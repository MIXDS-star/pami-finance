import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/finance/projections.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';
import '../home/home_screen.dart';

final goalsProvider = FutureProvider.autoDispose<List<(Goal, GoalProgress?)>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  final repo = ref.watch(planRepositoryProvider);
  final goals = await repo.goals();
  final progress = await repo.goalProgress();
  return [for (final g in goals) (g, progress.where((p) => p.goalId == g.id).firstOrNull)];
});

final upcomingProvider = FutureProvider.autoDispose<List<Occurrence>>((ref) {
  ref.watch(ledgerRevisionProvider);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return ref.watch(planRepositoryProvider).upcoming(today.subtract(const Duration(days: 7)), today.add(const Duration(days: 60)));
});

class PlanScreen extends ConsumerWidget {
  const PlanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
        length: 4,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Plan financiero'),
            bottom: const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
              Tab(text: 'Presupuestos'), Tab(text: 'Metas'), Tab(text: 'Calendario'), Tab(text: 'Planificar'),
            ]),
          ),
          body: const TabBarView(children: [_BudgetsTab(), _GoalsTab(), _CalendarTab(), _PlannerTab()]),
        ),
      );
}

class _BudgetsTab extends ConsumerWidget {
  const _BudgetsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(selectedMonthProvider);
    final status = ref.watch(budgetStatusProvider(month));
    final spaces = ref.watch(workspacesProvider).value ?? const <Workspace>[];
    return RefreshIndicator(
      onRefresh: () async => ref.read(ledgerRevisionProvider.notifier).bump(),
      child: AsyncView(
        value: status,
        onRetry: () => ref.invalidate(budgetStatusProvider(month)),
        data: (list) => ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
          Row(children: [
            IconButton(tooltip: 'Mes anterior', icon: const Icon(Icons.chevron_left), onPressed: () => ref.read(selectedMonthProvider.notifier).previous()),
            Expanded(child: Center(child: Text(formatMonth(month), style: context.text.titleMedium))),
            IconButton(tooltip: 'Mes siguiente', icon: const Icon(Icons.chevron_right), onPressed: () => ref.read(selectedMonthProvider.notifier).next()),
          ]),
          if (list.isEmpty)
            const EmptyState(compact: true, icon: Icons.pie_chart_outline, title: 'Sin presupuestos',
                message: 'Define un límite mensual por categoría o para un espacio compartido y te avisaremos al acercarte.'),
          for (final s in list)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SectionCard(
                onTap: () => context.push('/plan/budget?id=${s.budgetId}'),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(s.name, style: context.text.titleMedium)),
                    Pill(spaces.where((w) => w.id == s.workspaceId).firstOrNull?.name ?? '', icon: Icons.workspaces_outline),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: _kv(context, 'Gastado', AmountText(s.spentMinor, s.currency, style: context.text.titleSmall))),
                    Expanded(child: _kv(context, 'Presupuesto', AmountText(s.limitMinor, s.currency, style: context.text.titleSmall))),
                    Expanded(child: _kv(context, s.availableMinor >= 0 ? 'Disponible' : 'Excedido',
                        AmountText(s.availableMinor.abs(), s.currency, style: context.text.titleSmall))),
                  ]),
                  const SizedBox(height: 10),
                  LabeledProgress(valueBp: s.consumedBp ?? 0, alert: s.alert),
                  if (s.daysElapsed > 0 && s.daysElapsed < s.daysInPeriod)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('Proyección lineal al cierre: ${formatMinor(s.projectedMinor, s.currency)} '
                          '(${s.daysElapsed} de ${s.daysInPeriod} días)', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
                    ),
                ]),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: () => context.push('/plan/budget'), icon: const Icon(Icons.add), label: const Text('Nuevo presupuesto')),
          const SizedBox(height: 8),
          Text('Presupuestos personales: cuenta tu parte asignada en todos tus espacios. Presupuestos de un espacio compartido: '
              'cuenta el total del espacio.', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
        ]),
      ),
    );
  }
}

Widget _kv(BuildContext context, String k, Widget v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(k, style: context.text.labelSmall?.copyWith(color: context.nexo.muted)),
      v,
    ]);

class _GoalsTab extends ConsumerWidget {
  const _GoalsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(goalsProvider);
    return AsyncView(
      value: goals,
      onRetry: () => ref.invalidate(goalsProvider),
      data: (list) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
        if (list.isEmpty)
          const EmptyState(compact: true, icon: Icons.savings_outlined, title: 'Crea tu primera meta',
              message: 'Un fondo de emergencia de 3 a 6 meses de gastos esenciales suele ser el primer paso antes de invertir.'),
        for (final (g, p) in list)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SectionCard(
              onTap: () => context.push('/plan/goal/${g.id}'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(g.name, style: context.text.titleMedium)),
                  Text('Prioridad ${['', 'alta', 'media', 'baja'][g.priority]}', style: context.text.labelSmall),
                ]),
                const SizedBox(height: 6),
                Text('${formatMinor(p?.savedMinor ?? 0, g.currency)} de ${formatMinor(g.targetMinor, g.currency)}'),
                const SizedBox(height: 8),
                LabeledProgress(valueBp: p?.progressBp ?? 0),
                if (p?.projectedCompletion != null)
                  Text('Con tu aporte planificado: ${formatMonth(p!.projectedCompletion!)} (estimación)',
                      style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
                if (p?.requiredMonthlyMinor != null && g.targetDate != null)
                  Text('Para llegar el ${formatDateLong(g.targetDate!)}: ${formatMinor(p!.requiredMonthlyMinor!, g.currency)} al mes',
                      style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
              ]),
            ),
          ),
        FilledButton.icon(onPressed: () => context.push('/plan/goal/new'), icon: const Icon(Icons.add), label: const Text('Nueva meta')),
      ]),
    );
  }
}

class _CalendarTab extends ConsumerWidget {
  const _CalendarTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final upcoming = ref.watch(upcomingProvider);
    return AsyncView(
      value: upcoming,
      onRetry: () => ref.invalidate(upcomingProvider),
      data: (list) {
        final byMonth = <String, List<Occurrence>>{};
        for (final o in list) {
          byMonth.putIfAbsent(formatMonth(o.dueOn), () => []).add(o);
        }
        return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
          const Notice(message: 'Lo previsto no cuenta en tus saldos: se confirma solo al vincularlo con un movimiento real.'),
          const SizedBox(height: 8),
          if (list.isEmpty)
            const EmptyState(compact: true, icon: Icons.event_repeat, title: 'Sin pagos recurrentes',
                message: 'Añade arriendo, servicios, suscripciones, cuotas o ingresos que se repiten.'),
          for (final e in byMonth.entries) ...[
            SectionTitle(e.key),
            for (final o in e.value) _OccurrenceTile(o: o),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: () => context.push('/plan/recurring'), icon: const Icon(Icons.add), label: const Text('Nuevo recurrente')),
        ]);
      },
    );
  }
}

class _OccurrenceTile extends ConsumerWidget {
  const _OccurrenceTile({required this.o});
  final Occurrence o;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final overdue = o.status == 'scheduled' && o.dueOn.isBefore(DateTime(now.year, now.month, now.day));
    final (label, icon, color) = switch (o.status) {
      'confirmed' => ('Confirmado', Icons.check_circle_outline, context.nexo.positive),
      'skipped' => ('Omitido', Icons.remove_circle_outline, context.nexo.muted),
      _ => overdue ? ('Vencido, sin confirmar', Icons.error_outline, context.nexo.warning) : ('Previsto', Icons.schedule, context.nexo.info),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(o.kind == 'income' ? Icons.south_west : Icons.event_outlined),
      title: Text(o.label),
      subtitle: Row(children: [Text('${formatDateShort(o.dueOn)} · '), Pill(label, icon: icon, color: color)]),
      trailing: AmountText(o.expectedMinor, o.currency, style: context.text.titleSmall),
      onTap: o.status == 'confirmed' ? (o.transactionId == null ? null : () => context.push('/tx/${o.transactionId}'))
          : () => showNxSheet(context, builder: (_) => ResolveOccurrenceSheet(o: o)),
      onLongPress: () => context.push('/plan/recurring?id=${o.ruleId}'),
    );
  }
}

/// Confirm with a REAL movement (existing or new) or skip.
class ResolveOccurrenceSheet extends ConsumerStatefulWidget {
  const ResolveOccurrenceSheet({super.key, required this.o});
  final Occurrence o;
  @override
  ConsumerState<ResolveOccurrenceSheet> createState() => _ResolveOccurrenceSheetState();
}

class _ResolveOccurrenceSheetState extends ConsumerState<ResolveOccurrenceSheet> {
  Occurrence get o => widget.o;
  late final Future<List<Transaction>> _candidates = ref.read(transactionRepositoryProvider).list(
      TransactionFilter(from: o.dueOn.subtract(const Duration(days: 10)), to: o.dueOn.add(const Duration(days: 10)),
          workspaceIds: [o.workspaceId], kind: o.kind),
      limit: 20);

  Future<void> _resolve(String status, {String? transactionId}) async {
    try {
      await ref.read(planRepositoryProvider).resolveOccurrence(o.ruleId, o.dueOn, status, transactionId: transactionId);
      ref.read(ledgerRevisionProvider.notifier).bump();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(o.label, subtitle: 'Previsto para ${formatDateLong(o.dueOn)} · ${formatMinor(o.expectedMinor, o.currency)}'),
      Text('¿Ya lo registraste? Vincúlalo:', style: context.text.titleSmall),
      FutureBuilder<List<Transaction>>(
        future: _candidates,
        builder: (context, snap) {
          if (snap.hasError) return ErrorState(error: snap.error!, compact: true);
          if (!snap.hasData) return const LoadingState(compact: true);
          final list = snap.data!;
          if (list.isEmpty) return const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No hay movimientos cercanos en ese espacio.'));
          return Column(children: [
            for (final t in list.take(6))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t.description),
                subtitle: Text(formatDateShort(t.occurredOn)),
                trailing: AmountText(t.totalMinor, t.currency, style: context.text.bodyMedium),
                onTap: () => _resolve('confirmed', transactionId: t.id),
              ),
          ]);
        },
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: () {
          Navigator.pop(context);
          context.push('/tx/new?kind=${o.kind}&workspace=${o.workspaceId}');
        },
        child: const Text('Registrar el movimiento ahora'),
      ),
      TextButton(
        onPressed: () => _resolve(o.status == 'skipped' ? 'scheduled' : 'skipped'),
        child: Text(o.status == 'skipped' ? 'Volver a marcar como previsto' : 'Omitir esta vez'),
      ),
    ]);
  }
}

class _PlannerTab extends ConsumerWidget {
  const _PlannerTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final lastMonth = DateTime(now.year, now.month - 1);
    final summary = ref.watch(monthSummaryProvider(lastMonth));
    final cats = ref.watch(monthCategoriesProvider(lastMonth)).value ?? const <CategorySpend>[];
    final allCats = ref.watch(categoriesProvider).value ?? const <Category>[];
    final goals = ref.watch(goalsProvider).value ?? const [];
    return AsyncView(
      value: summary,
      onRetry: () => ref.invalidate(monthSummaryProvider(lastMonth)),
      data: (s) {
        final currency = Currency.of(ref.watch(preferencesProvider).value?.defaultCurrency ?? 'COP');
        final margin = s.incomeMinor - s.expenseAssignedMinor;
        int bucket(String b) => cats.where((c) => allCats.where((x) => x.id == c.categoryId).firstOrNull?.bucket == b)
            .fold<int>(0, (a, c) => a + c.amountMinor);
        final ref503020 = rule503020(s.incomeMinor);
        return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
          Text('Basado en ${formatMonth(lastMonth)} (último mes completo).', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
          if (s.incomeCount == 0)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Notice(kind: NoticeKind.warning, message: 'No hay ingresos registrados el mes pasado; sin ellos no podemos estimar tu margen de ahorro.'),
            ),
          SectionCard(
            title: 'Referencia 50/30/20 (opcional)',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Una guía, no una obligación: 50 % necesidades (vivienda, mercado, servicios, transporte, salud), '
                  '30 % deseos (restaurantes, ocio, compras) y 20 % ahorro o pago de deudas. Ajústala a tu realidad.'),
              const SizedBox(height: 12),
              _ruleRow(context, 'Necesidades', bucket('needs'), ref503020.needs, currency),
              _ruleRow(context, 'Deseos', bucket('wants'), ref503020.wants, currency),
              _ruleRow(context, 'Ahorro (margen)', margin, ref503020.savings, currency),
              const SizedBox(height: 4),
              Text('Real (izquierda) vs. referencia (derecha). La clasificación viene de cada categoría y la puedes cambiar.',
                  style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
            ]),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Escenarios de ahorro',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(margin > 0
                  ? 'Tu margen del mes pasado fue ${formatMinor(margin, currency)} (ingresos − gasto asignado). Cada escenario aparta una parte:'
                  : 'El mes pasado no quedó margen. Revisa gastos variables o registra tus ingresos para ver escenarios.'),
              const SizedBox(height: 8),
              for (final sc in SavingScenario.values)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${sc.label} · ${formatBp(sc.marginShareBp, decimals: 0)} del margen'),
                  subtitle: Text(goals.isEmpty
                      ? 'En 12 meses: ${formatMinor(scenarioContribution(sc, margin) * 12, currency)} (sin rendimientos)'
                      : goals.take(2).map((g) {
                          final m = monthsToTarget(targetMinor: g.$1.targetMinor, savedMinor: g.$2?.savedMinor ?? 0,
                              monthlyMinor: scenarioContribution(sc, margin));
                          return '${g.$1.name}: ${m == null ? 'no alcanzable' : '$m meses'}';
                        }).join(' · ')),
                  trailing: AmountText(scenarioContribution(sc, margin), currency, style: context.text.titleSmall),
                ),
              Text('Los nombres describen cuánto apartas, no una rentabilidad. No incluyen intereses.',
                  style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
            ]),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Informes mensuales',
            onTap: () => context.push('/plan/reports'),
            child: const Text('Cierres de mes con ingresos, gastos, presupuestos, metas y saldos pendientes.'),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Aprender a invertir',
            onTap: () => context.push('/plan/education'),
            child: const Text('Horizonte, riesgo, liquidez, inflación y simulaciones hipotéticas. Sin promesas de rentabilidad.'),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Estadísticas',
            onTap: () => context.push('/stats'),
            child: const Text('Ingresos frente a gastos, categorías, comercios y gastos compartidos.'),
          ),
        ]);
      },
    );
  }

  Widget _ruleRow(BuildContext context, String label, int actual, int reference, Currency c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label)),
          AmountText(actual, c, style: context.text.bodyMedium),
          Text('  /  ', style: TextStyle(color: context.nexo.muted)),
          AmountText(reference, c, style: context.text.bodyMedium?.copyWith(color: context.nexo.muted)),
        ]),
      );
}
