import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/finance/projections.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../core/util/ids.dart';
import '../../data/models.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';
import 'plan_screen.dart';

const goalKinds = {
  'emergency_fund': ('Fondo de emergencia', Icons.health_and_safety_outlined),
  'travel': ('Viaje', Icons.flight_takeoff),
  'housing': ('Vivienda', Icons.house_outlined),
  'education': ('Estudios', Icons.school_outlined),
  'purchase': ('Compra futura', Icons.shopping_cart_outlined),
  'investment': ('Inversión', Icons.trending_up),
  'custom': ('Personalizada', Icons.flag_outlined),
};

final _contributionsProvider = FutureProvider.autoDispose.family<List<Contribution>, String>((ref, id) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(planRepositoryProvider).contributions(id);
});

class GoalDetailScreen extends ConsumerWidget {
  const GoalDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(goalsProvider);
    final contributions = ref.watch(_contributionsProvider(id));
    return Scaffold(
      appBar: AppBar(title: const Text('Meta'), actions: [
        IconButton(tooltip: 'Editar meta', icon: const Icon(Icons.edit_outlined), onPressed: () => context.push('/plan/goal/$id/edit')),
      ]),
      body: AsyncView(
        value: goals,
        data: (list) {
          final entry = list.where((e) => e.$1.id == id).firstOrNull;
          if (entry == null) return const EmptyState(icon: Icons.search_off, title: 'Meta no encontrada');
          final (g, p) = entry;
          final saved = p?.savedMinor ?? 0;
          final planned = g.plannedMonthlyMinor ?? 0;
          final months = monthsToTarget(targetMinor: g.targetMinor, savedMinor: saved, monthlyMinor: planned);
          return ListView(padding: const EdgeInsets.all(16), children: [
            Row(children: [
              Icon(goalKinds[g.kind]?.$2 ?? Icons.flag_outlined, size: 32, color: context.colors.primary),
              const SizedBox(width: 12),
              Expanded(child: Text(g.name, style: context.text.headlineSmall)),
            ]),
            const SizedBox(height: 16),
            AmountText(saved, g.currency, style: context.text.displaySmall, semanticPrefix: 'Ahorrado'),
            Text('de ${formatMinor(g.targetMinor, g.currency)}'),
            const SizedBox(height: 12),
            LabeledProgress(valueBp: p?.progressBp ?? 0),
            const SizedBox(height: 12),
            if (g.targetDate != null && p?.requiredMonthlyMinor != null)
              Text('Para llegar el ${formatDateLong(g.targetDate!)} necesitas ${formatMinor(p!.requiredMonthlyMinor!, g.currency)} al mes.'),
            if (planned > 0)
              Text(months == 0 ? '¡Meta alcanzada!' : 'Con tu aporte de ${formatMinor(planned, g.currency)} al mes: unos $months meses (estimación sin rendimientos).'),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => showNxSheet(context, builder: (_) => _ContributionSheet(goal: g)),
              icon: const Icon(Icons.add),
              label: const Text('Registrar aporte o retiro'),
            ),
            const SectionTitle('Aportes'),
            AsyncView(
              value: contributions,
              compact: true,
              data: (cs) => cs.isEmpty
                  ? const Text('Aún no hay aportes.')
                  : Column(children: [
                      for (final c in cs)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(c.amountMinor >= 0 ? Icons.add_circle_outline : Icons.remove_circle_outline),
                          title: Text(c.amountMinor >= 0 ? 'Aporte' : 'Retiro'),
                          subtitle: Text([formatDateLong(c.occurredOn), if (c.note != null) c.note!].join(' · ')),
                          trailing: AmountText(c.amountMinor, g.currency, colorize: true, style: context.text.titleSmall),
                          onLongPress: () async {
                            if (await confirmAction(context, title: 'Anular registro', message: 'Se descontará del ahorro de la meta.',
                                confirmLabel: 'Anular', destructive: true)) {
                              try {
                                await ref.read(planRepositoryProvider).deleteContribution(c.id);
                                ref.read(ledgerRevisionProvider.notifier).bump();
                              } catch (e) {
                                if (context.mounted) showFailure(context, e);
                              }
                            }
                          },
                        ),
                    ]),
            ),
            const SizedBox(height: 12),
            Text('Los aportes registran el dinero que apartas para la meta. Moverlo realmente entre cuentas es una acción tuya fuera de la app.',
                style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
          ]);
        },
      ),
    );
  }
}

class _ContributionSheet extends ConsumerStatefulWidget {
  const _ContributionSheet({required this.goal});
  final Goal goal;
  @override
  ConsumerState<_ContributionSheet> createState() => _ContributionSheetState();
}

class _ContributionSheetState extends ConsumerState<_ContributionSheet> with BusyState {
  int? _amount;
  bool _withdrawal = false;
  DateTime _date = DateTime.now();
  final _note = TextEditingController();
  final _req = newId();

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SheetHeader('Movimiento de la meta'),
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: false, label: Text('Aporte')), ButtonSegment(value: true, label: Text('Retiro'))],
          selected: {_withdrawal},
          onSelectionChanged: (s) => setState(() => _withdrawal = s.first),
        ),
        const SizedBox(height: 12),
        MoneyField(currency: widget.goal.currency, onChanged: (v) => _amount = v, autofocus: true),
        const SizedBox(height: 12),
        DateField(value: _date, onChanged: (d) => setState(() => _date = d)),
        const SizedBox(height: 12),
        TextField(controller: _note, decoration: const InputDecoration(labelText: 'Nota (opcional)'), maxLength: 300),
        FilledButton(
          onPressed: busy ? null : () {
            if ((_amount ?? 0) <= 0) return;
            runBusy(() async {
              await ref.read(planRepositoryProvider).addContribution(widget.goal.id, _withdrawal ? -_amount! : _amount!, _date,
                  note: _note.text.trim().isEmpty ? null : _note.text.trim(), requestId: _req);
              ref.read(ledgerRevisionProvider.notifier).bump();
              if (context.mounted) Navigator.pop(context);
            }, onError: (e) => showFailure(context, e));
          },
          child: const Text('Guardar'),
        ),
      ]);
}

class GoalEditorScreen extends ConsumerStatefulWidget {
  const GoalEditorScreen({super.key, this.goalId});
  final String? goalId;
  @override
  ConsumerState<GoalEditorScreen> createState() => _GoalEditorScreenState();
}

class _GoalEditorScreenState extends ConsumerState<GoalEditorScreen> with BusyState {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  String _kind = 'emergency_fund';
  int? _target;
  int? _monthly;
  DateTime? _date;
  int _priority = 2;
  bool _loaded = false;
  String? _workspaceId;

  @override
  Widget build(BuildContext context) {
    final goals = ref.watch(goalsProvider).value;
    final spaces = (ref.watch(workspacesProvider).value ?? const <Workspace>[]).where((w) => w.canWrite).toList();
    final personal = spaces.where((w) => w.isPersonal).firstOrNull;
    if (!_loaded && goals != null) {
      _loaded = true;
      final g = goals.where((e) => e.$1.id == widget.goalId).firstOrNull?.$1;
      if (g != null) {
        _name.text = g.name;
        _kind = g.kind;
        _target = g.targetMinor;
        _monthly = g.plannedMonthlyMinor;
        _date = g.targetDate;
        _priority = g.priority;
        _workspaceId = g.workspaceId;
      }
    }
    final ws = spaces.where((w) => w.id == _workspaceId).firstOrNull ?? personal;
    if (ws == null) return const Scaffold(body: LoadingState());
    return Scaffold(
      appBar: AppBar(title: Text(widget.goalId == null ? 'Nueva meta' : 'Editar meta')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in goalKinds.entries)
              ChoiceChip(avatar: Icon(e.value.$2, size: 18), label: Text(e.value.$1), selected: _kind == e.key,
                  onSelected: (_) => setState(() {
                        _kind = e.key;
                        if (_name.text.isEmpty) _name.text = e.value.$1;
                      })),
          ]),
          const SizedBox(height: 16),
          TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Nombre'),
              validator: (v) => (v ?? '').trim().isEmpty ? 'Escribe un nombre' : null),
          const SizedBox(height: 12),
          MoneyField(currency: ws.baseCurrency, label: 'Objetivo', initialMinor: _target, onChanged: (v) => _target = v),
          const SizedBox(height: 12),
          MoneyField(currency: ws.baseCurrency, label: 'Aporte mensual planificado (opcional)', initialMinor: _monthly,
              allowZero: true, onChanged: (v) => _monthly = v),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_date == null ? 'Sin fecha objetivo' : 'Fecha objetivo: ${formatDateLong(_date!)}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_date != null) IconButton(tooltip: 'Quitar fecha', icon: const Icon(Icons.close), onPressed: () => setState(() => _date = null)),
              IconButton(
                tooltip: 'Elegir fecha',
                icon: const Icon(Icons.event),
                onPressed: () async {
                  final now = DateTime.now();
                  final d = await showDatePicker(context: context, firstDate: now, lastDate: DateTime(now.year + 40),
                      initialDate: _date ?? DateTime(now.year + 1, now.month, now.day));
                  if (d != null) setState(() => _date = d);
                },
              ),
            ]),
          ),
          const SizedBox(height: 8),
          Text('Prioridad', style: context.text.titleSmall),
          SegmentedButton<int>(
            segments: const [ButtonSegment(value: 1, label: Text('Alta')), ButtonSegment(value: 2, label: Text('Media')), ButtonSegment(value: 3, label: Text('Baja'))],
            selected: {_priority},
            onSelectionChanged: (s) => setState(() => _priority = s.first),
          ),
          if (spaces.length > 1 && widget.goalId == null) ...[
            const SectionTitle('Espacio'),
            Wrap(spacing: 8, children: [
              for (final w in spaces) ChoiceChip(label: Text(w.name), selected: w.id == ws.id, onSelected: (_) => setState(() => _workspaceId = w.id)),
            ]),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : () {
              if (!_form.currentState!.validate() || (_target ?? 0) <= 0) return;
              runBusy(() async {
                await ref.read(planRepositoryProvider).saveGoal(id: widget.goalId, workspaceId: ws.id, kind: _kind, name: _name.text,
                    currency: ws.baseCurrency.code, targetMinor: _target!, targetDate: _date, plannedMonthlyMinor: _monthly, priority: _priority);
                ref.read(ledgerRevisionProvider.notifier).bump();
                if (context.mounted) context.pop();
              }, onError: (e) => showFailure(context, e));
            },
            child: const Text('Guardar meta'),
          ),
          if (widget.goalId != null)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: context.colors.error),
              onPressed: () async {
                if (!await confirmAction(context, title: 'Archivar meta', message: 'Dejará de mostrarse; sus aportes quedan en el historial.',
                    confirmLabel: 'Archivar', destructive: true)) {
                  return;
                }
                await runBusy(() async {
                  await ref.read(planRepositoryProvider).archiveGoal(widget.goalId!);
                  ref.read(ledgerRevisionProvider.notifier).bump();
                  if (context.mounted) context.go('/plan');
                }, onError: (e) => showFailure(context, e));
              },
              child: const Text('Archivar meta'),
            ),
        ]),
      ),
    );
  }
}
