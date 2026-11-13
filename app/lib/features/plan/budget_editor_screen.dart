import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';

final _budgetsProvider = FutureProvider.autoDispose<List<Budget>>((ref) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(planRepositoryProvider).budgets();
});

class BudgetEditorScreen extends ConsumerStatefulWidget {
  const BudgetEditorScreen({super.key, this.budgetId});
  final String? budgetId;
  @override
  ConsumerState<BudgetEditorScreen> createState() => _BudgetEditorScreenState();
}

class _BudgetEditorScreenState extends ConsumerState<BudgetEditorScreen> with BusyState {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  String? _workspaceId;
  bool _byIncome = false;
  int? _amount;
  int _incomeShareBp = 1000;
  int _threshold = 8000;
  final Set<String> _cats = {};
  bool _loaded = false;

  void _load(List<Budget> budgets, Workspace personal) {
    if (_loaded) return;
    _loaded = true;
    final b = budgets.where((b) => b.id == widget.budgetId).firstOrNull;
    if (b == null) {
      _workspaceId = personal.id;
      return;
    }
    _name.text = b.name;
    _workspaceId = b.workspaceId;
    _byIncome = b.incomeShareBp != null;
    _amount = b.amountMinor;
    _incomeShareBp = b.incomeShareBp ?? 1000;
    _threshold = b.alertThresholdBp;
    _cats.addAll(b.categoryIds);
  }

  @override
  Widget build(BuildContext context) {
    final budgets = ref.watch(_budgetsProvider);
    final spaces = (ref.watch(workspacesProvider).value ?? const <Workspace>[]).where((w) => w.canWrite).toList();
    final cats = (ref.watch(categoriesProvider).value ?? const <Category>[]).where((c) => c.kind == 'expense').toList();
    final personal = spaces.where((w) => w.isPersonal).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(widget.budgetId == null ? 'Nuevo presupuesto' : 'Editar presupuesto')),
      body: AsyncView(
        value: budgets,
        data: (list) {
          if (personal != null) _load(list, personal);
          final ws = spaces.where((w) => w.id == _workspaceId).firstOrNull ?? personal;
          if (ws == null) return const LoadingState();
          final currency = ws.baseCurrency;
          return Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Ej.: Mercado'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Escribe un nombre' : null),
              const SectionTitle('Espacio'),
              if (widget.budgetId != null)
                Text(ws.name)
              else
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final w in spaces)
                    ChoiceChip(avatar: Icon(w.kind.icon, size: 18), label: Text(w.name), selected: w.id == ws.id,
                        onSelected: (_) => setState(() {
                              _workspaceId = w.id;
                              if (!w.isPersonal) _byIncome = false;
                              _cats.removeWhere((c) {
                                final owner = cats.where((x) => x.id == c).firstOrNull?.workspaceId;
                                return owner != null && owner != w.id;
                              });
                            })),
                ]),
              Text(ws.isPersonal ? 'Cuenta tu parte asignada en todos tus espacios.' : 'Cuenta el total de gastos de ${ws.name}.',
                  style: context.text.bodySmall?.copyWith(color: context.pami.muted)),
              const SectionTitle('Límite mensual'),
              if (ws.isPersonal)
                SegmentedButton<bool>(
                  segments: const [ButtonSegment(value: false, label: Text('Importe fijo')), ButtonSegment(value: true, label: Text('% de mis ingresos'))],
                  selected: {_byIncome},
                  onSelectionChanged: (s) => setState(() => _byIncome = s.first),
                ),
              const SizedBox(height: 12),
              if (!_byIncome)
                MoneyField(currency: currency, initialMinor: _amount, label: 'Límite', onChanged: (v) => _amount = v)
              else ...[
                Text('${formatBp(_incomeShareBp, decimals: 0)} de los ingresos registrados en el mes'),
                Slider(value: _incomeShareBp.toDouble(), min: 100, max: 10000, divisions: 99, label: formatBp(_incomeShareBp, decimals: 0),
                    onChanged: (v) => setState(() => _incomeShareBp = v.round())),
                Text('Si en el mes no registras ingresos, el límite será 0.', style: context.text.bodySmall?.copyWith(color: context.pami.muted)),
              ],
              const SectionTitle('Alerta'),
              Text('Avisar al llegar al ${formatBp(_threshold, decimals: 0)}'),
              Slider(value: _threshold.toDouble(), min: 1000, max: 10000, divisions: 18, label: formatBp(_threshold, decimals: 0),
                  onChanged: (v) => setState(() => _threshold = v.round())),
              const SectionTitle('Categorías'),
              Text(_cats.isEmpty ? 'Sin selección: cuenta todas las categorías de gasto.' : '${_cats.length} seleccionada(s)',
                  style: context.text.bodySmall?.copyWith(color: context.pami.muted)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final c in cats.where((c) => c.workspaceId == null || c.workspaceId == ws.id))
                  FilterChip(avatar: Icon(c.iconData, size: 16, color: c.color), label: Text(c.name), selected: _cats.contains(c.id),
                      onSelected: (v) => setState(() => v ? _cats.add(c.id) : _cats.remove(c.id))),
              ]),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: busy
                    ? null
                    : () {
                        if (!_form.currentState!.validate()) return;
                        if (!_byIncome && (_amount ?? 0) <= 0) {
                          showFailure(context, Exception('Indica un límite mayor que cero.'));
                          return;
                        }
                        runBusy(() async {
                          await ref.read(planRepositoryProvider).saveBudget(
                              id: widget.budgetId, workspaceId: ws.id, name: _name.text, currency: currency.code,
                              amountMinor: _byIncome ? null : _amount, incomeShareBp: _byIncome ? _incomeShareBp : null,
                              alertThresholdBp: _threshold, categoryIds: _cats.toList());
                          ref.read(ledgerRevisionProvider.notifier).bump();
                          if (context.mounted) {
                            showSuccess(context, 'Presupuesto guardado');
                            context.pop();
                          }
                        }, onError: (e) => showFailure(context, e));
                      },
                child: const Text('Guardar'),
              ),
              if (widget.budgetId != null)
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: context.colors.error),
                  onPressed: () async {
                    if (!await confirmAction(context, title: 'Archivar presupuesto', message: 'Dejará de mostrarse. Tus movimientos no cambian.',
                        confirmLabel: 'Archivar', destructive: true)) {
                      return;
                    }
                    await runBusy(() async {
                      await ref.read(planRepositoryProvider).archiveBudget(widget.budgetId!);
                      ref.read(ledgerRevisionProvider.notifier).bump();
                      if (context.mounted) context.pop();
                    }, onError: (e) => showFailure(context, e));
                  },
                  child: const Text('Archivar presupuesto'),
                ),
            ]),
          );
        },
      ),
    );
  }
}
