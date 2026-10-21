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

final reportsProvider = FutureProvider.autoDispose<(List<MonthlyReport>, Set<String>)>((ref) async {
  ref.watch(ledgerRevisionProvider);
  final repo = ref.watch(planRepositoryProvider);
  return (await repo.reports(), await repo.staleReportIds());
});

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> with BusyState {
  Future<void> _close(DateTime month, String currency, {bool replace = false}) => runBusy(() async {
        await ref.read(planRepositoryProvider).closeMonth(month, currency, replace: replace);
        ref.invalidate(reportsProvider);
        if (mounted) showSuccess(context, replace ? 'Cierre actualizado (nueva versión)' : 'Mes cerrado');
      }, onError: (e) => showFailure(context, e));

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(reportsProvider);
    final currency = ref.watch(preferencesProvider).value?.defaultCurrency ?? 'COP';
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(title: const Text('Informes mensuales')),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(reportsProvider),
        data: (d) {
          final (reports, stale) = d;
          final current = reports.where((r) => !r.superseded).toList();
          final closedMonths = current.map((r) => '${r.periodStart.year}-${r.periodStart.month}').toSet();
          final pending = [for (var i = 1; i <= 12; i++) DateTime(now.year, now.month - i)]
              .where((m) => !closedMonths.contains('${m.year}-${m.month}')).toList();
          return ListView(padding: const EdgeInsets.all(16), children: [
            const Text('Un cierre guarda las cifras del mes tal como estaban. Si después corriges un movimiento de ese mes, '
                'el cierre no se reescribe solo: verás un aviso y podrás generar una versión actualizada.'),
            const SizedBox(height: 12),
            if (pending.isNotEmpty)
              SectionCard(
                title: 'Meses sin cerrar',
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final m in pending.take(6))
                    ActionChip(avatar: const Icon(Icons.lock_clock, size: 18), label: Text(formatMonth(m)), onPressed: busy ? null : () => _close(m, currency)),
                ]),
              ),
            const SectionTitle('Cierres'),
            if (current.isEmpty) const EmptyState(compact: true, icon: Icons.summarize_outlined, title: 'Aún no hay cierres'),
            for (final r in current)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(formatMonth(r.periodStart)),
                  subtitle: Text('Versión ${r.version} · cerrado ${formatDateLong(r.closedAt)}'),
                  trailing: stale.contains(r.id)
                      ? TextButton.icon(
                          onPressed: busy ? null : () async {
                            if (await confirmAction(context, title: 'Actualizar cierre',
                                message: 'Hubo cambios en movimientos de ${formatMonth(r.periodStart)} después del cierre. '
                                    'Se creará la versión ${r.version + 1}; la anterior se conserva.', confirmLabel: 'Actualizar')) {
                              await _close(r.periodStart, r.currency.code, replace: true);
                            }
                          },
                          icon: Icon(Icons.warning_amber_rounded, color: context.nexo.warning),
                          label: const Text('Desactualizado'),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: () => context.push('/plan/reports/${r.id}'),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

class ReportDetailScreen extends ConsumerWidget {
  const ReportDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(reportsProvider);
    final caps = ref.watch(aiCapabilitiesProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Informe')),
      body: AsyncView(
        value: data,
        data: (d) {
          final r = d.$1.where((x) => x.id == id).firstOrNull;
          if (r == null) return const EmptyState(icon: Icons.search_off, title: 'Informe no encontrado');
          final s = PeriodSummary.fromJson(Map<String, dynamic>.from(r.snapshot['summary'] as Map));
          final prev = PeriodSummary.fromJson(Map<String, dynamic>.from(r.snapshot['previous_summary'] as Map));
          final cats = ((r.snapshot['by_category'] as List?) ?? const []).map((c) => CategorySpend.fromJson(Map<String, dynamic>.from(c as Map))).toList();
          final prevCats = {for (final c in ((r.snapshot['previous_by_category'] as List?) ?? const []))
            (c as Map)['category_name'] as String: (c['amount_minor'] as num).toInt()};
          final budgets = ((r.snapshot['budgets'] as List?) ?? const []).map((b) => BudgetStatus.fromJson(Map<String, dynamic>.from(b as Map))).toList();
          final balances = ((r.snapshot['pending_balances'] as List?) ?? const []).cast<Map>();
          final notes = ((r.dataQuality['notes'] as List?) ?? const []).cast<String>();
          final cur = r.currency;
          final variations = [
            for (final c in cats) (c.name, c.amountMinor - (prevCats[c.name] ?? 0)),
          ]..sort((a, b) => b.$2.abs().compareTo(a.$2.abs()));
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text(formatMonth(r.periodStart), style: context.text.headlineSmall),
            Text('Cierre confirmado · versión ${r.version}${r.superseded ? ' (reemplazada)' : ''}', style: context.text.bodySmall),
            for (final n in notes) Padding(padding: const EdgeInsets.only(top: 8), child: Notice(kind: NoticeKind.warning, message: n)),
            const SectionTitle('Resumen'),
            _line(context, 'Ingresos', s.incomeMinor, prev.incomeMinor, cur),
            _line(context, 'Gasto asignado', s.expenseAssignedMinor, prev.expenseAssignedMinor, cur),
            _line(context, 'Ahorro neto', s.netSavingsMinor, prev.netSavingsMinor, cur),
            ListTile(contentPadding: EdgeInsets.zero, title: const Text('Tasa de ahorro'),
                trailing: Text(s.savingsRateBp == null ? 'Sin ingresos' : formatBp(s.savingsRateBp!))),
            const SectionTitle('Gastos por categoría'),
            for (final c in cats)
              ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(c.name), trailing: AmountText(c.amountMinor, cur, style: context.text.bodyMedium)),
            if (variations.isNotEmpty) ...[
              const SectionTitle('Principales variaciones frente al mes anterior'),
              for (final v in variations.take(3))
                ListTile(contentPadding: EdgeInsets.zero, dense: true, leading: Icon(v.$2 >= 0 ? Icons.trending_up : Icons.trending_down),
                    title: Text(v.$1), trailing: AmountText(v.$2, cur, signed: true, style: context.text.bodyMedium)),
            ],
            if (budgets.isNotEmpty) ...[
              const SectionTitle('Presupuestos'),
              for (final b in budgets)
                ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(b.name),
                    subtitle: Text(b.availableMinor >= 0 ? 'Cumplido' : 'Excedido en ${formatMinor(-b.availableMinor, cur)}'),
                    trailing: Text(formatBp(b.consumedBp ?? 0))),
            ],
            if (balances.isNotEmpty) ...[
              const SectionTitle('Saldos pendientes al cierre'),
              for (final b in balances)
                ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(b['workspace_name'] as String),
                    trailing: AmountText((b['net_minor'] as num).toInt(), cur, colorize: true)),
            ],
            const SectionTitle('Recomendaciones'),
            if (caps?.copilot == true)
              OutlinedButton.icon(
                onPressed: () => context.push('/copilot', extra: 'Analiza mi mes de ${formatMonth(r.periodStart)} y dame recomendaciones'),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Pedir recomendaciones al copiloto'),
              )
            else
              const Text('El copiloto con IA no está configurado; las recomendaciones automáticas no están disponibles.'),
          ]);
        },
      ),
    );
  }

  Widget _line(BuildContext context, String label, int v, int prev, Currency c) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: Text('Mes anterior: ${formatMinor(prev, c)}'),
        trailing: AmountText(v, c, style: context.text.titleSmall),
      );
}
