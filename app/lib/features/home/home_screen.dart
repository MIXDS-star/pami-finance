import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';
import '../capture/capture_sheet.dart';
import '../movements/movements_screen.dart';
import '../movements/tx_tile.dart';

final _currencyProvider = Provider<Currency>((ref) => Currency.of(ref.watch(preferencesProvider).value?.defaultCurrency ?? 'COP'));

final monthSummaryProvider = FutureProvider.autoDispose.family<PeriodSummary, DateTime>((ref, month) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(analyticsRepositoryProvider).summary(month, monthEnd(month), ref.watch(_currencyProvider).code);
});

final monthCategoriesProvider = FutureProvider.autoDispose.family<List<CategorySpend>, DateTime>((ref, month) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(analyticsRepositoryProvider).byCategory(month, monthEnd(month), ref.watch(_currencyProvider).code);
});

final budgetStatusProvider = FutureProvider.autoDispose.family<List<BudgetStatus>, DateTime>((ref, month) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(planRepositoryProvider).budgetStatus(month);
});

/// My net in each shared workspace (server-computed balances).
final mySharedBalancesProvider = FutureProvider.autoDispose<List<(Workspace, int, Currency)>>((ref) async {
  ref.watch(ledgerRevisionProvider);
  final me = ref.watch(currentUserIdProvider);
  final spaces = (await ref.watch(workspacesProvider.future)).where((w) => !w.isPersonal && !w.archived);
  final repo = ref.watch(workspaceRepositoryProvider);
  final out = <(Workspace, int, Currency)>[];
  for (final w in spaces) {
    for (final b in await repo.balances(w.id)) {
      if (b.userId == me && b.netMinor != 0) out.add((w, b.netMinor, Currency.of(b.currency)));
    }
  }
  return out;
});

final upcomingWeekProvider = FutureProvider.autoDispose<List<Occurrence>>((ref) {
  ref.watch(ledgerRevisionProvider);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return ref.watch(planRepositoryProvider).upcoming(today, today.add(const Duration(days: 7)));
});

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(selectedMonthProvider);
    final profile = ref.watch(profileProvider).value;
    final unread = (ref.watch(notificationsProvider).value ?? const []).where((n) => !n.read).length;
    final currency = ref.watch(_currencyProvider);
    final now = DateTime.now();
    final isCurrent = month.year == now.year && month.month == now.month;

    return Scaffold(
      appBar: AppBar(
        title: Text(profile == null ? 'Inicio' : 'Hola, ${profile.displayName.split(' ').first}'),
        actions: [
          IconButton(tooltip: 'Copiloto financiero', icon: const Icon(Icons.auto_awesome_outlined), onPressed: () => context.push('/copilot')),
          IconButton(
            tooltip: unread > 0 ? 'Notificaciones, $unread sin leer' : 'Notificaciones',
            icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.notifications_none)),
            onPressed: () => context.push('/notifications'),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              tooltip: 'Perfil y configuración',
              onPressed: () => context.push('/profile'),
              icon: PersonAvatar(name: profile?.displayName ?? '?', size: 30),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.read(ledgerRevisionProvider.notifier).bump();
          ref.read(spacesRevisionProvider.notifier).bump();
        },
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
          Row(children: [
            IconButton(tooltip: 'Mes anterior', icon: const Icon(Icons.chevron_left), onPressed: () => ref.read(selectedMonthProvider.notifier).previous()),
            Expanded(child: Center(child: Text(formatMonth(month), style: context.text.titleMedium))),
            IconButton(tooltip: 'Mes siguiente', icon: const Icon(Icons.chevron_right),
                onPressed: isCurrent ? null : () => ref.read(selectedMonthProvider.notifier).next()),
          ]),
          _SummaryCard(month: month, currency: currency),
          const SizedBox(height: 12),
          const _QuickActions(),
          _SharedBalances(),
          _Budgets(month: month),
          _Categories(month: month, currency: currency),
          if (isCurrent) const _Upcoming(),
          _Recent(month: month),
        ]),
      ),
    );
  }
}

class _SummaryCard extends ConsumerWidget {
  const _SummaryCard({required this.month, required this.currency});
  final DateTime month;
  final Currency currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(monthSummaryProvider(month));
    return Card(
      color: context.nexo.brandSoft,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: AsyncView(
          value: s,
          compact: true,
          onRetry: () => ref.invalidate(monthSummaryProvider(month)),
          data: (sum) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('Tu gasto del mes', style: context.text.titleSmall?.copyWith(color: context.nexo.muted))),
              IconButton(
                tooltip: 'Cómo se calcula',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.info_outline, size: 20),
                onPressed: () => showNxSheet(context, builder: (_) => _Formulas(summary: sum)),
              ),
            ]),
            AmountText(sum.expenseAssignedMinor, currency, style: context.text.displaySmall, semanticPrefix: 'Tu gasto del mes'),
            if (sum.expenseSharedMinor > 0)
              Text('Incluye ${formatMinor(sum.expenseSharedMinor, currency)} de tu parte en gastos compartidos',
                  style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _Metric(label: 'Ingresos', child: AmountText(sum.incomeMinor, currency, style: context.text.titleMedium))),
              Expanded(child: _Metric(label: 'Ahorro neto', child: AmountText(sum.netSavingsMinor, currency, colorize: true, style: context.text.titleMedium))),
              Expanded(
                child: _Metric(
                  label: 'Tasa de ahorro',
                  child: Text(sum.savingsRateBp == null ? '—' : formatBp(sum.savingsRateBp!),
                      semanticsLabel: sum.savingsRateBp == null ? 'Sin ingresos registrados' : null, style: context.text.titleMedium),
                ),
              ),
            ]),
            if (sum.paidMinor != sum.expenseAssignedMinor) ...[
              const SizedBox(height: 12),
              Text('Pagaste ${formatMinor(sum.paidMinor, currency)}; lo que te corresponde es ${formatMinor(sum.expenseAssignedMinor, currency)}.',
                  style: context.text.bodySmall),
            ],
            if (sum.incomeCount == 0) ...[
              const SizedBox(height: 12),
              const Notice(message: 'No hay ingresos registrados este mes, así que la tasa de ahorro no se puede calcular.'),
            ],
            if (!sum.periodComplete)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Mes en curso: las cifras cambiarán a medida que registres movimientos.',
                    style: context.text.labelSmall?.copyWith(color: context.nexo.muted)),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Formulas extends StatelessWidget {
  const _Formulas({required this.summary});
  final PeriodSummary summary;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SheetHeader('Cómo se calculan estas cifras'),
        for (final e in {
          'Gasto del mes': summary.formulas['expense_assigned'],
          'Ahorro neto': summary.formulas['net_savings'],
          'Tasa de ahorro': summary.formulas['savings_rate'],
        }.entries)
          if (e.value != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.key, style: context.text.titleSmall),
                Text(e.value!),
              ]),
            ),
        const Text('Solo se cuentan movimientos confirmados por el servidor. Las transferencias entre tus cuentas, '
            'los pagos de tarjeta y los reembolsos entre personas no son gasto.'),
      ]);
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: context.text.labelMedium?.copyWith(color: context.nexo.muted)),
        const SizedBox(height: 2),
        child,
      ]);
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: _Quick(icon: Icons.add, label: 'Registrar', onTap: () => showCaptureSheet(context))),
        const SizedBox(width: 8),
        Expanded(child: _Quick(icon: Icons.document_scanner_outlined, label: 'Factura', onTap: () => context.push('/capture/receipt'))),
        const SizedBox(width: 8),
        Expanded(child: _Quick(icon: Icons.insights_outlined, label: 'Estadísticas', onTap: () => context.push('/stats'))),
      ]);
}

class _Quick extends StatelessWidget {
  const _Quick({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12)),
        onPressed: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon), const SizedBox(height: 4), Text(label, style: context.text.labelMedium)]),
      );
}

class _SharedBalances extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(mySharedBalancesProvider);
    final list = b.value ?? const [];
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Saldos compartidos', action: TextButton(onPressed: () => context.go('/spaces'), child: const Text('Espacios'))),
      Card(
        child: Column(children: [
          for (final (ws, net, cur) in list)
            ListTile(
              leading: Icon(ws.kind.icon),
              title: Text(ws.name),
              subtitle: Text(net > 0 ? 'Te deben' : 'Debes'),
              trailing: AmountText(net, cur, colorize: true),
              onTap: () => context.push('/spaces/${ws.id}?tab=1'),
            ),
        ]),
      ),
    ]);
  }
}

class _Budgets extends ConsumerWidget {
  const _Budgets({required this.month});
  final DateTime month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(budgetStatusProvider(month)).value ?? const <BudgetStatus>[];
    if (list.isEmpty) return const SizedBox.shrink();
    final sorted = [...list]..sort((a, b) => (b.consumedBp ?? 0).compareTo(a.consumedBp ?? 0));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Presupuestos', action: TextButton(onPressed: () => context.go('/plan'), child: const Text('Ver todos'))),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            for (final s in sorted.take(3))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(s.name, style: context.text.titleSmall)),
                    Text('${formatMinor(s.availableMinor, s.currency)} ${s.availableMinor >= 0 ? 'disponibles' : 'por encima'}',
                        style: context.text.bodySmall),
                  ]),
                  const SizedBox(height: 6),
                  LabeledProgress(valueBp: s.consumedBp ?? 0, alert: s.alert, caption: 'de ${formatMinor(s.limitMinor, s.currency)}'),
                ]),
              ),
          ]),
        ),
      ),
    ]);
  }
}

class _Categories extends ConsumerWidget {
  const _Categories({required this.month, required this.currency});
  final DateTime month;
  final Currency currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(monthCategoriesProvider(month)).value ?? const <CategorySpend>[];
    if (list.isEmpty) return const SizedBox.shrink();
    final total = list.fold<int>(0, (a, c) => a + c.amountMinor);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('En qué se fue', action: TextButton(onPressed: () => context.push('/stats'), child: const Text('Detalle'))),
      Card(
        child: Column(children: [
          for (final c in list.take(4))
            ListTile(
              leading: CategoryBadge(category: Category(id: c.categoryId ?? '', kind: 'expense', name: c.name, icon: c.icon, color: c.color), size: 36),
              title: Text(c.name),
              subtitle: Text('${c.count} movimiento(s) · ${formatBp(total == 0 ? 0 : c.amountMinor * 10000 ~/ total)}'),
              trailing: AmountText(c.amountMinor, currency, style: context.text.titleSmall),
              onTap: c.categoryId == null ? null : () => context.go('/movements?category=${c.categoryId}'),
            ),
        ]),
      ),
    ]);
  }
}

class _Upcoming extends ConsumerWidget {
  const _Upcoming();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = (ref.watch(upcomingWeekProvider).value ?? const <Occurrence>[]).where((o) => o.status == 'scheduled').toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Próximos 7 días', action: TextButton(onPressed: () => context.go('/plan'), child: const Text('Calendario'))),
      Card(
        child: Column(children: [
          for (final o in list.take(4))
            ListTile(
              leading: Icon(o.kind == 'income' ? Icons.south_west : Icons.event_outlined),
              title: Text(o.label),
              subtitle: Text('${formatDateLong(o.dueOn)} · previsto, sin confirmar'),
              trailing: AmountText(o.expectedMinor, o.currency, style: context.text.bodyMedium),
            ),
        ]),
      ),
    ]);
  }
}

class _Recent extends ConsumerWidget {
  const _Recent({required this.month});
  final DateTime month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = TransactionFilter(from: month, to: monthEnd(month));
    final txs = ref.watch(movementsProvider(filter));
    final me = ref.watch(currentUserIdProvider) ?? '';
    final spaces = ref.watch(workspacesProvider).value ?? const <Workspace>[];
    final cats = ref.watch(categoriesProvider).value ?? const <Category>[];
    final people = ref.watch(peopleProvider).value ?? const <String, String>{};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Últimos movimientos', action: TextButton(onPressed: () => context.go('/movements'), child: const Text('Ver todos'))),
      AsyncView(
        value: txs,
        compact: true,
        onRetry: () => ref.invalidate(movementsProvider(filter)),
        data: (list) => list.isEmpty
            ? Card(
                child: EmptyState(
                  compact: true,
                  icon: Icons.bolt_outlined,
                  title: 'Registra tu primer gasto',
                  message: 'Escribe "Almuerzo 25 mil", dicta una nota o fotografía una factura. '
                      'Para compartir gastos, crea un espacio e invita a otras personas.',
                  action: Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                    FilledButton(onPressed: () => showCaptureSheet(context), child: const Text('Registrar')),
                    OutlinedButton(onPressed: () => context.go('/spaces'), child: const Text('Crear espacio')),
                  ]),
                ),
              )
            : Card(
                child: Column(children: [
                  for (final t in list.take(5))
                    TxTile(
                      tx: t,
                      me: me,
                      category: cats.where((c) => c.id == t.categoryId).firstOrNull,
                      workspace: spaces.where((w) => w.id == t.workspaceId).firstOrNull,
                      people: people,
                      onTap: () => context.push('/tx/${t.id}'),
                    ),
                ]),
              ),
      ),
    ]);
  }
}
