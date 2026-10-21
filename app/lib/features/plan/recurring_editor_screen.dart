import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../data/models.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';

final _rulesProvider = FutureProvider.autoDispose<List<RecurringRule>>((ref) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(planRepositoryProvider).recurringRules();
});

class RecurringEditorScreen extends ConsumerStatefulWidget {
  const RecurringEditorScreen({super.key, this.ruleId});
  final String? ruleId;
  @override
  ConsumerState<RecurringEditorScreen> createState() => _RecurringEditorScreenState();
}

class _RecurringEditorScreenState extends ConsumerState<RecurringEditorScreen> with BusyState {
  final _form = GlobalKey<FormState>();
  final _label = TextEditingController();
  String _kind = 'expense';
  String? _workspaceId;
  String? _categoryId;
  int? _amount;
  String _frequency = 'monthly';
  DateTime _anchor = DateTime.now();
  bool _active = true;
  bool _loaded = false;

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(_rulesProvider);
    final spaces = (ref.watch(workspacesProvider).value ?? const <Workspace>[]).where((w) => w.canWrite).toList();
    final cats = ref.watch(categoriesProvider).value ?? const <Category>[];
    return Scaffold(
      appBar: AppBar(title: Text(widget.ruleId == null ? 'Nuevo recurrente' : 'Editar recurrente')),
      body: AsyncView(
        value: rules,
        data: (list) {
          if (!_loaded) {
            _loaded = true;
            final r = list.where((r) => r.id == widget.ruleId).firstOrNull;
            if (r != null) {
              _label.text = r.label;
              _kind = r.kind;
              _workspaceId = r.workspaceId;
              _categoryId = r.categoryId;
              _amount = r.expectedMinor;
              _frequency = r.frequency;
              _anchor = r.anchorDate;
              _active = r.active;
            }
          }
          final personal = spaces.where((w) => w.isPersonal).firstOrNull;
          final ws = spaces.where((w) => w.id == _workspaceId).firstOrNull ?? personal;
          if (ws == null) return const LoadingState();
          return Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (widget.ruleId == null)
                SegmentedButton<String>(
                  segments: const [ButtonSegment(value: 'expense', label: Text('Pago')), ButtonSegment(value: 'income', label: Text('Ingreso'))],
                  selected: {_kind},
                  onSelectionChanged: (s) => setState(() {
                    _kind = s.first;
                    _categoryId = null;
                    if (_kind == 'income') _workspaceId = personal?.id;
                  }),
                ),
              const SizedBox(height: 12),
              TextFormField(controller: _label, decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Ej.: Arriendo, Netflix, Salario'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Escribe un nombre' : null),
              const SizedBox(height: 12),
              MoneyField(currency: ws.baseCurrency, label: 'Importe esperado', initialMinor: _amount, onChanged: (v) => _amount = v),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _frequency,
                decoration: const InputDecoration(labelText: 'Frecuencia'),
                items: const [
                  DropdownMenuItem(value: 'weekly', child: Text('Semanal')),
                  DropdownMenuItem(value: 'biweekly', child: Text('Quincenal')),
                  DropdownMenuItem(value: 'monthly', child: Text('Mensual')),
                  DropdownMenuItem(value: 'yearly', child: Text('Anual')),
                ],
                onChanged: (v) => setState(() => _frequency = v!),
              ),
              const SizedBox(height: 12),
              DateField(value: _anchor, label: 'Próxima fecha', onChanged: (d) => setState(() => _anchor = d)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                isExpanded: true,
                initialValue: _categoryId,
                decoration: const InputDecoration(labelText: 'Categoría'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Sin categoría')),
                  for (final c in cats.where((c) => c.kind == _kind && (c.workspaceId == null || c.workspaceId == ws.id)))
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => _categoryId = v,
              ),
              if (_kind == 'expense' && widget.ruleId == null) ...[
                const SectionTitle('Espacio responsable'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final w in spaces) ChoiceChip(avatar: Icon(w.kind.icon, size: 18), label: Text(w.name), selected: w.id == ws.id,
                      onSelected: (_) => setState(() => _workspaceId = w.id)),
                ]),
              ],
              SwitchListTile(contentPadding: EdgeInsets.zero, value: _active, onChanged: (v) => setState(() => _active = v), title: const Text('Activo')),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy ? null : () {
                  if (!_form.currentState!.validate() || (_amount ?? 0) <= 0) return;
                  runBusy(() async {
                    await ref.read(planRepositoryProvider).saveRecurringRule(id: widget.ruleId, workspaceId: ws.id, kind: _kind,
                        label: _label.text, categoryId: _categoryId, currency: ws.baseCurrency.code, expectedMinor: _amount!,
                        frequency: _frequency, anchorDate: _anchor, active: _active);
                    ref.read(ledgerRevisionProvider.notifier).bump();
                    if (context.mounted) {
                      showSuccess(context, 'Guardado. Aparecerá en el calendario como previsto.');
                      context.pop();
                    }
                  }, onError: (e) => showFailure(context, e));
                },
                child: const Text('Guardar'),
              ),
            ]),
          );
        },
      ),
    );
  }
}
