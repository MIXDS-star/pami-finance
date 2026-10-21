import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../ui/components.dart';
import '../../ui/states.dart';
import '../home/home_screen.dart';

/// Two-series palette (validated with the dataviz checker, light and dark):
/// slot 1 blue = income, slot 2 orange = expenses.
Color _incomeColor(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? const Color(0xFF3987E5) : const Color(0xFF2A78D6);
Color _expenseColor(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? const Color(0xFFD95926) : const Color(0xFFEB6834);

typedef _Period = ({DateTime from, DateTime to, String label});

final _trendProvider = FutureProvider.autoDispose.family<List<TrendPoint>, (int, String)>((ref, args) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(analyticsRepositoryProvider).trend(args.$1, args.$2);
});

final _periodSummaryProvider = FutureProvider.autoDispose.family<PeriodSummary, (DateTime, DateTime, String)>((ref, a) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(analyticsRepositoryProvider).summary(a.$1, a.$2, a.$3);
});

final _categoriesProvider = FutureProvider.autoDispose.family<List<CategorySpend>, (DateTime, DateTime, String, String?)>((ref, a) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(analyticsRepositoryProvider).byCategory(a.$1, a.$2, a.$3, workspaceId: a.$4);
});

final _merchantsProvider = FutureProvider.autoDispose.family<List<MerchantSpend>, (DateTime, DateTime, String)>((ref, a) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(analyticsRepositoryProvider).topMerchants(a.$1, a.$2, a.$3);
});

class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});
  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  String _mode = 'month';
  DateTimeRange? _custom;
  String? _workspaceId;
  int _trendMonths = 6;

  _Period _period(DateTime month) {
    switch (_mode) {
      case 'year':
        final now = DateTime.now();
        return (from: DateTime(now.year), to: DateTime(now.year, 12, 31), label: 'Año ${now.year}');
      case 'custom' when _custom != null:
        return (from: _custom!.start, to: _custom!.end, label: '${formatDateShort(_custom!.start)} – ${formatDateShort(_custom!.end)}');
      default:
        return (from: month, to: monthEnd(month), label: formatMonth(month));
    }
  }

  @override
  Widget build(BuildContext context) {
    final month = ref.watch(selectedMonthProvider);
    final p = _period(month);
    final currency = Currency.of(ref.watch(preferencesProvider).value?.defaultCurrency ?? 'COP');
    final spaces = (ref.watch(workspacesProvider).value ?? const <Workspace>[]).where((w) => !w.isPersonal).toList();
    final summary = ref.watch(_periodSummaryProvider((p.from, p.to, currency.code)));
    final cats = ref.watch(_categoriesProvider((p.from, p.to, currency.code, _workspaceId)));
    final trend = ref.watch(_trendProvider((_trendMonths, currency.code)));
    final merchants = ref.watch(_merchantsProvider((p.from, p.to, currency.code)));
    final budgets = _mode == 'month' ? ref.watch(budgetStatusProvider(month)).value ?? const <BudgetStatus>[] : const <BudgetStatus>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Estadísticas')),
      body: RefreshIndicator(
        onRefresh: () async => ref.read(ledgerRevisionProvider.notifier).bump(),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
          // Filters in one row above the charts.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final m in const [('month', 'Mes'), ('year', 'Año'), ('custom', 'Personalizado')])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(m.$2),
                    selected: _mode == m.$1,
                    onSelected: (_) async {
                      if (m.$1 == 'custom') {
                        final now = DateTime.now();
                        final r = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 10), lastDate: now, initialDateRange: _custom);
                        if (r == null) return;
                        _custom = r;
                      }
                      setState(() => _mode = m.$1);
                    },
                  ),
                ),
              const SizedBox(width: 8),
              DropdownButton<String?>(
                value: _workspaceId,
                underline: const SizedBox(),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Mi parte en todo')),
                  for (final w in spaces) DropdownMenuItem(value: w.id, child: Text('Total de ${w.name}')),
                ],
                onChanged: (v) => setState(() => _workspaceId = v),
              ),
            ]),
          ),
          if (_mode == 'month')
            Row(children: [
              IconButton(tooltip: 'Mes anterior', icon: const Icon(Icons.chevron_left), onPressed: () => ref.read(selectedMonthProvider.notifier).previous()),
              Expanded(child: Center(child: Text(p.label, style: context.text.titleMedium))),
              IconButton(tooltip: 'Mes siguiente', icon: const Icon(Icons.chevron_right), onPressed: () => ref.read(selectedMonthProvider.notifier).next()),
            ])
          else
            Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(p.label, style: context.text.titleMedium)),

          AsyncView(
            value: summary,
            compact: true,
            onRetry: () => ref.invalidate(_periodSummaryProvider((p.from, p.to, currency.code))),
            data: (s) => _Kpis(s: s, currency: currency),
          ),

          _ChartCard(
            title: 'Ingresos frente a gastos',
            subtitle: 'Últimos $_trendMonths meses · ${currency.code} · gasto = tu parte asignada',
            action: SegmentedButton<int>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [ButtonSegment(value: 6, label: Text('6 m')), ButtonSegment(value: 12, label: Text('12 m'))],
              selected: {_trendMonths},
              onSelectionChanged: (s) => setState(() => _trendMonths = s.first),
            ),
            table: (trend.value ?? const <TrendPoint>[]).map((t) => [
                  '${monthShort(t.month.month)} ${t.month.year}', formatMinor(t.incomeMinor, currency), formatMinor(t.expenseMinor, currency),
                ]).toList(),
            tableHeader: const ['Mes', 'Ingresos', 'Gastos'],
            child: AsyncView(
              value: trend,
              compact: true,
              data: (points) => _TrendChart(points: points, currency: currency),
            ),
          ),

          _ChartCard(
            title: 'Gasto por categoría',
            subtitle: '${p.label} · ${_workspaceId == null ? 'tu parte asignada' : 'total del espacio'} · toca una barra para ver los movimientos',
            table: (cats.value ?? const <CategorySpend>[]).map((c) => [c.name, '${c.count}', formatMinor(c.amountMinor, currency)]).toList(),
            tableHeader: const ['Categoría', 'Movimientos', 'Importe'],
            child: AsyncView(
              value: cats,
              compact: true,
              data: (list) => list.isEmpty
                  ? const Padding(padding: EdgeInsets.all(16), child: Text('Sin gastos en el periodo.'))
                  : _CategoryBars(list: list, currency: currency, onTap: (c) {
                      if (c.categoryId == null) return;
                      if (_mode == 'month') ref.read(selectedMonthProvider.notifier).set(month);
                      context.go('/movements?category=${c.categoryId}${_workspaceId == null ? '' : '&workspace=$_workspaceId'}');
                    }),
            ),
          ),

          if (budgets.isNotEmpty)
            _ChartCard(
              title: 'Presupuesto frente a gasto real',
              subtitle: p.label,
              table: budgets.map((b) => [b.name, formatMinor(b.limitMinor, b.currency), formatMinor(b.spentMinor, b.currency), formatBp(b.consumedBp ?? 0)]).toList(),
              tableHeader: const ['Presupuesto', 'Límite', 'Gastado', '%'],
              child: Column(children: [
                for (final b in budgets)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(b.name, style: context.text.bodyMedium)),
                        Text('${formatMinor(b.spentMinor, b.currency)} / ${formatMinor(b.limitMinor, b.currency)}', style: context.text.bodySmall),
                      ]),
                      const SizedBox(height: 4),
                      LabeledProgress(valueBp: b.consumedBp ?? 0, alert: b.alert),
                    ]),
                  ),
              ]),
            ),

          _ChartCard(
            title: 'Principales comercios',
            subtitle: '${p.label} · tu parte asignada',
            child: AsyncView(
              value: merchants,
              compact: true,
              data: (list) => list.isEmpty
                  ? const Padding(padding: EdgeInsets.all(16), child: Text('Sin datos en el periodo.'))
                  : Column(children: [
                      for (final m in list)
                        ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(m.merchant), subtitle: Text('${m.count} compra(s)'),
                            trailing: AmountText(m.amountMinor, currency, style: context.text.bodyMedium)),
                    ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.s, required this.currency});
  final PeriodSummary s;
  final Currency currency;

  @override
  Widget build(BuildContext context) {
    final total = s.expensePersonalMinor + s.expenseSharedMinor;
    final sharedBp = total == 0 ? 0 : s.expenseSharedMinor * 10000 ~/ total;
    return Column(children: [
      Row(children: [
        Expanded(child: _Tile(label: 'Ingresos', value: AmountText(s.incomeMinor, currency, style: context.text.titleMedium))),
        const SizedBox(width: 8),
        Expanded(child: _Tile(label: 'Gasto asignado', value: AmountText(s.expenseAssignedMinor, currency, style: context.text.titleMedium))),
        const SizedBox(width: 8),
        Expanded(child: _Tile(label: 'Tasa de ahorro', value: Text(s.savingsRateBp == null ? '—' : formatBp(s.savingsRateBp!), style: context.text.titleMedium))),
      ]),
      const SizedBox(height: 8),
      SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Personal frente a compartido', style: context.text.titleSmall),
          const SizedBox(height: 6),
          LabeledProgress(valueBp: sharedBp, caption: 'compartido ${formatMinor(s.expenseSharedMinor, currency)} · personal ${formatMinor(s.expensePersonalMinor, currency)}'),
          const SizedBox(height: 12),
          Text('Pagado frente a asignado', style: context.text.titleSmall),
          const SizedBox(height: 4),
          Text('Pagaste ${formatMinor(s.paidMinor, currency)} y te corresponden ${formatMinor(s.expenseAssignedMinor, currency)}. '
              '${s.paidMinor > s.expenseAssignedMinor ? 'Adelantaste ${formatMinor(s.paidMinor - s.expenseAssignedMinor, currency)} por otras personas.' : s.paidMinor < s.expenseAssignedMinor ? 'Otras personas pagaron ${formatMinor(s.expenseAssignedMinor - s.paidMinor, currency)} de tu parte.' : ''}'),
          const SizedBox(height: 8),
          Text('Tasa de ahorro = (ingresos registrados − gasto asignado) ÷ ingresos registrados.',
              style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
        ]),
      ),
    ]);
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value});
  final String label;
  final Widget value;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: context.text.labelMedium?.copyWith(color: context.nexo.muted)),
            const SizedBox(height: 4),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: value),
          ]),
        ),
      );
}

/// Card with title, unit/period subtitle and an accessible table view.
class _ChartCard extends StatefulWidget {
  const _ChartCard({required this.title, required this.subtitle, required this.child, this.action, this.table, this.tableHeader});
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? action;
  final List<List<String>>? table;
  final List<String>? tableHeader;

  @override
  State<_ChartCard> createState() => _ChartCardState();
}

class _ChartCardState extends State<_ChartCard> {
  bool _table = false;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: SectionCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Semantics(header: true, child: Text(widget.title, style: context.text.titleMedium)),
                  Text(widget.subtitle, style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
                ]),
              ),
              ?widget.action,
            ]),
            const SizedBox(height: 12),
            if (_table && widget.table != null)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: [for (final h in widget.tableHeader!) DataColumn(label: Text(h))],
                  rows: [for (final r in widget.table!) DataRow(cells: [for (final c in r) DataCell(Text(c))])],
                ),
              )
            else
              widget.child,
            if (widget.table != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _table = !_table),
                  icon: Icon(_table ? Icons.bar_chart : Icons.table_rows_outlined, size: 18),
                  label: Text(_table ? 'Ver gráfico' : 'Ver como tabla'),
                ),
              ),
          ]),
        ),
      );
}

class _TrendChart extends StatelessWidget {
  const _TrendChart({required this.points, required this.currency});
  final List<TrendPoint> points;
  final Currency currency;

  @override
  Widget build(BuildContext context) {
    if (points.every((p) => p.incomeMinor == 0 && p.expenseMinor == 0)) {
      return const Padding(padding: EdgeInsets.all(16), child: Text('Aún no hay datos para comparar.'));
    }
    final income = _incomeColor(context);
    final expense = _expenseColor(context);
    final unit = currency.minorPerUnit;
    final maxV = points.fold<int>(0, (a, p) => [a, p.incomeMinor, p.expenseMinor].reduce((x, y) => x > y ? x : y)) / unit;
    String compact(double v) => v >= 1000000 ? '${(v / 1000000).toStringAsFixed(1)} M' : v >= 1000 ? '${(v / 1000).round()} mil' : v.round().toString();

    return Column(children: [
      Row(children: [
        _Legend(color: income, label: 'Ingresos'),
        const SizedBox(width: 16),
        _Legend(color: expense, label: 'Gastos'),
      ]),
      const SizedBox(height: 12),
      SizedBox(
        height: 200,
        child: Semantics(
          label: 'Gráfico de barras de ingresos y gastos por mes. Usa «Ver como tabla» para leer los valores.',
          child: BarChart(BarChartData(
            maxY: maxV == 0 ? 1 : maxV * 1.15,
            gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: context.nexo.border, strokeWidth: 1)),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 52,
                  getTitlesWidget: (v, meta) => v == meta.max && v % meta.appliedInterval != 0
                    ? const SizedBox.shrink() // avoid the overlapping top label
                    : SideTitleWidget(meta: meta, child: Text(compact(v), style: context.text.labelSmall?.copyWith(color: context.nexo.muted))))),
              bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true,
                  getTitlesWidget: (v, meta) => SideTitleWidget(meta: meta,
                      child: Text(monthShort(points[v.toInt()].month.month), style: context.text.labelSmall?.copyWith(color: context.nexo.muted))))),
            ),
            barTouchData: BarTouchData(
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (_) => Theme.of(context).colorScheme.inverseSurface,
                getTooltipItem: (group, _, rod, rodIndex) {
                  final p = points[group.x];
                  return BarTooltipItem('${formatMonth(p.month)}\n${rodIndex == 0 ? 'Ingresos' : 'Gastos'}: '
                      '${formatMinor(rodIndex == 0 ? p.incomeMinor : p.expenseMinor, currency)}',
                      TextStyle(color: Theme.of(context).colorScheme.onInverseSurface, fontSize: 12));
                },
              ),
            ),
            barGroups: [
              for (var i = 0; i < points.length; i++)
                BarChartGroupData(x: i, barsSpace: 2, barRods: [
                  BarChartRodData(toY: points[i].incomeMinor / unit, color: income, width: 9,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
                  BarChartRodData(toY: points[i].expenseMinor / unit, color: expense, width: 9,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
                ]),
            ],
          )),
        ),
      ),
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Text(label, style: context.text.labelMedium),
      ]);
}

/// Single-hue horizontal bars: magnitude by category, value always labelled.
class _CategoryBars extends StatelessWidget {
  const _CategoryBars({required this.list, required this.currency, required this.onTap});
  final List<CategorySpend> list;
  final Currency currency;
  final ValueChanged<CategorySpend> onTap;

  @override
  Widget build(BuildContext context) {
    final total = list.fold<int>(0, (a, c) => a + c.amountMinor);
    final maxV = list.first.amountMinor;
    final shown = list.take(8).toList();
    final rest = list.skip(8).fold<int>(0, (a, c) => a + c.amountMinor);
    Widget bar(String name, int v, VoidCallback? tap) => Semantics(
          button: tap != null,
          onTap: tap,
          label: '$name: ${formatMinor(v, currency)}, ${formatBp(total == 0 ? 0 : v * 10000 ~/ total)} del total',
          excludeSemantics: true,
          child: InkWell(
            onTap: tap,
            borderRadius: BorderRadius.circular(NexoTokens.radiusS),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(name, style: context.text.bodyMedium)),
                  Text('${formatMinor(v, currency)} · ${formatBp(total == 0 ? 0 : v * 10000 ~/ total, decimals: 0)}',
                      style: context.text.bodySmall?.copyWith(fontFeatures: NexoTokens.tabular)),
                ]),
                const SizedBox(height: 4),
                LayoutBuilder(builder: (context, c) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 10,
                        width: maxV == 0 ? 0 : (c.maxWidth * v / maxV).clamp(4, c.maxWidth).toDouble(),
                        decoration: BoxDecoration(color: context.colors.primary, borderRadius: BorderRadius.circular(4)),
                      ),
                    )),
              ]),
            ),
          ),
        );
    return Column(children: [
      for (final c in shown) bar(c.name, c.amountMinor, c.categoryId == null ? null : () => onTap(c)),
      if (rest > 0) bar('Otras categorías', rest, null),
    ]);
  }
}
