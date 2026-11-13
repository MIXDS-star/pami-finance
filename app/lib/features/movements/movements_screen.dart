import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/drafts/draft_store.dart';
import '../../core/errors/failure.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';
import 'tx_tile.dart';

final movementsProvider = FutureProvider.autoDispose.family<List<Transaction>, TransactionFilter>((ref, f) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(transactionRepositoryProvider).list(f);
});

class MovementsScreen extends ConsumerStatefulWidget {
  const MovementsScreen({super.key, this.initialCategoryId, this.initialWorkspaceId});
  final String? initialCategoryId;
  final String? initialWorkspaceId;

  @override
  ConsumerState<MovementsScreen> createState() => _MovementsScreenState();
}

class _MovementsScreenState extends ConsumerState<MovementsScreen> {
  late String? _category = widget.initialCategoryId;
  late String? _workspace = widget.initialWorkspaceId;
  String? _kind;
  String _search = '';
  DateTimeRange? _range;

  TransactionFilter _filter(DateTime month) => TransactionFilter(
        from: _range?.start ?? month,
        to: _range?.end ?? monthEnd(month),
        categoryId: _category,
        workspaceIds: _workspace == null ? null : [_workspace!],
        kind: _kind,
        search: _search.isEmpty ? null : _search,
      );

  @override
  void didUpdateWidget(MovementsScreen old) {
    super.didUpdateWidget(old);
    if (widget.initialCategoryId != old.initialCategoryId) _category = widget.initialCategoryId;
    if (widget.initialWorkspaceId != old.initialWorkspaceId) _workspace = widget.initialWorkspaceId;
  }

  @override
  Widget build(BuildContext context) {
    final month = ref.watch(selectedMonthProvider);
    final filter = _filter(month);
    final txs = ref.watch(movementsProvider(filter));
    final me = ref.watch(currentUserIdProvider) ?? '';
    final spaces = ref.watch(workspacesProvider).value ?? const <Workspace>[];
    final cats = ref.watch(categoriesProvider).value ?? const <Category>[];
    final people = ref.watch(peopleProvider).value ?? const <String, String>{};
    final pending = ref.watch(draftStoreProvider).value ?? const <PendingDraft>[];
    final activeFilters = [_category, _workspace, _kind].whereType<String>().length + (_search.isEmpty ? 0 : 1);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Movimientos'),
        actions: [
          IconButton(tooltip: 'Estadísticas', icon: const Icon(Icons.insights_outlined), onPressed: () => context.push('/stats')),
          IconButton(
            tooltip: 'Filtros${activeFilters > 0 ? ' ($activeFilters activos)' : ''}',
            icon: Badge(isLabelVisible: activeFilters > 0, label: Text('$activeFilters'), child: const Icon(Icons.tune)),
            onPressed: () => _openFilters(spaces, cats),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.read(ledgerRevisionProvider.notifier).bump(),
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(children: [
                _range == null
                    ? _MonthSwitcher(month: month)
                    : Row(children: [
                        Expanded(child: Text('${formatDateShort(_range!.start)} – ${formatDateShort(_range!.end)}', style: context.text.titleMedium)),
                        TextButton(onPressed: () => setState(() => _range = null), child: const Text('Volver al mes')),
                      ]),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(hintText: 'Buscar por concepto o comercio', prefixIcon: Icon(Icons.search)),
                  onSubmitted: (v) => setState(() => _search = v.trim()),
                  textInputAction: TextInputAction.search,
                ),
              ]),
            ),
          ),
          if (pending.isNotEmpty) SliverToBoxAdapter(child: _PendingDrafts(drafts: pending)),
          ...txs.when(
            skipLoadingOnRefresh: true,
            loading: () => [const SliverFillRemaining(hasScrollBody: false, child: LoadingState())],
            error: (e, _) => [SliverFillRemaining(hasScrollBody: false, child: ErrorState(error: e, onRetry: () => ref.invalidate(movementsProvider(filter))))],
            data: (list) {
              if (list.isEmpty) {
                return [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: Icons.receipt_long_outlined,
                      title: activeFilters > 0 ? 'Nada coincide con los filtros' : 'Sin movimientos en este periodo',
                      message: activeFilters > 0 ? 'Prueba quitando algún filtro.' : 'Toca + para registrar tu primer gasto o ingreso.',
                      action: activeFilters > 0
                          ? OutlinedButton(onPressed: () => setState(() { _category = null; _workspace = null; _kind = null; _search = ''; }),
                              child: const Text('Quitar filtros'))
                          : null,
                    ),
                  ),
                ];
              }
              // Totals never mix currencies: only the main currency is added up.
              final currency = Currency.of(ref.watch(preferencesProvider).value?.defaultCurrency ?? 'COP');
              final same = list.where((t) => t.currency == currency);
              final spent = same.where((t) => t.isExpense).fold<int>(0, (a, t) => a + t.shareOf(me));
              final income = same.where((t) => t.isIncome).fold<int>(0, (a, t) => a + t.totalMinor);
              final otherCurrencies = list.length - same.length;
              final groups = <DateTime, List<Transaction>>{};
              for (final t in list) {
                groups.putIfAbsent(t.occurredOn, () => []).add(t);
              }
              return [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Row(children: [
                      Expanded(child: _Total(label: 'Tu gasto asignado', minor: spent, currency: currency)),
                      Expanded(child: _Total(label: 'Ingresos', minor: income, currency: currency)),
                    ]),
                  ),
                ),
                if (otherCurrencies > 0)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text('$otherCurrencies movimiento(s) en otras monedas no se suman a estos totales.',
                          style: context.text.bodySmall?.copyWith(color: context.pami.muted)),
                  ),
                ),
                for (final e in groups.entries) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Semantics(header: true, child: Text(formatDateLong(e.key), style: context.text.labelLarge?.copyWith(color: context.pami.muted))),
                    ),
                  ),
                  SliverList.list(children: [
                    for (final t in e.value)
                      TxTile(
                        tx: t,
                        me: me,
                        category: cats.where((c) => c.id == t.categoryId).firstOrNull,
                        workspace: spaces.where((w) => w.id == t.workspaceId).firstOrNull,
                        people: people,
                        onTap: () => context.push('/tx/${t.id}'),
                      ),
                  ]),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ];
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _openFilters(List<Workspace> spaces, List<Category> cats) async {
    await showNxSheet(context, builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
      void set(VoidCallback f) {
        setState(f);
        setSheet(() {});
      }

      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SheetHeader('Filtrar movimientos'),
        Text('Periodo', style: ctx.text.titleSmall),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.date_range),
          label: Text(_range == null ? 'Periodo personalizado' : '${formatDateShort(_range!.start)} – ${formatDateShort(_range!.end)}'),
          onPressed: () async {
            final now = DateTime.now();
            final r = await showDateRangePicker(context: ctx, firstDate: DateTime(now.year - 10), lastDate: DateTime(now.year + 1), initialDateRange: _range);
            if (r != null) set(() => _range = r);
          },
        ),
        const SizedBox(height: 16),
        Text('Tipo', style: ctx.text.titleSmall),
        Wrap(spacing: 8, children: [
          for (final k in const [(null, 'Todos'), ('expense', 'Gastos'), ('income', 'Ingresos'), ('transfer', 'Transferencias')])
            ChoiceChip(label: Text(k.$2), selected: _kind == k.$1, onSelected: (_) => set(() => _kind = k.$1)),
        ]),
        const SizedBox(height: 16),
        Text('Espacio', style: ctx.text.titleSmall),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(label: const Text('Todos'), selected: _workspace == null, onSelected: (_) => set(() => _workspace = null)),
          for (final w in spaces) ChoiceChip(avatar: Icon(w.kind.icon, size: 16), label: Text(w.name), selected: _workspace == w.id,
              onSelected: (_) => set(() => _workspace = w.id)),
        ]),
        const SizedBox(height: 16),
        Text('Categoría', style: ctx.text.titleSmall),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(label: const Text('Todas'), selected: _category == null, onSelected: (_) => set(() => _category = null)),
          for (final c in cats) ChoiceChip(avatar: Icon(c.iconData, size: 16, color: c.color), label: Text(c.name), selected: _category == c.id,
              onSelected: (_) => set(() => _category = c.id)),
        ]),
        const SizedBox(height: 20),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Ver resultados')),
      ]);
    }));
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.minor, required this.currency});
  final String label;
  final int minor;
  final Currency currency;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: context.text.labelMedium?.copyWith(color: context.pami.muted)),
        AmountText(minor, currency, style: context.text.titleMedium),
      ]);
}

class _MonthSwitcher extends ConsumerWidget {
  const _MonthSwitcher({required this.month});
  final DateTime month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final isCurrent = month.year == now.year && month.month == now.month;
    return Row(children: [
      IconButton(tooltip: 'Mes anterior', icon: const Icon(Icons.chevron_left), onPressed: () => ref.read(selectedMonthProvider.notifier).previous()),
      Expanded(child: Center(child: Text(formatMonth(month), style: context.text.titleMedium))),
      IconButton(tooltip: 'Mes siguiente', icon: const Icon(Icons.chevron_right), onPressed: isCurrent ? null : () => ref.read(selectedMonthProvider.notifier).next()),
    ]);
  }
}

class _PendingDrafts extends ConsumerStatefulWidget {
  const _PendingDrafts({required this.drafts});
  final List<PendingDraft> drafts;
  @override
  ConsumerState<_PendingDrafts> createState() => _PendingDraftsState();
}

class _PendingDraftsState extends ConsumerState<_PendingDrafts> with BusyState {
  Future<void> _retryAll() => runBusy(() async {
        var ok = 0;
        for (final d in widget.drafts) {
          try {
            await ref.read(supabaseClientProvider).rpc('save_transaction', params: {'p': d.payload});
            await ref.read(draftStoreProvider.notifier).remove(d.requestId);
            ok++;
          } catch (e) {
            final f = AppFailure.from(e);
            await ref.read(draftStoreProvider.notifier).put(d.payload, error: f.message);
            if (f.kind == FailureKind.network) break;
          }
        }
        if (ok > 0) ref.read(ledgerRevisionProvider.notifier).bump();
        if (mounted) showSuccess(context, ok == widget.drafts.length ? 'Todo sincronizado' : 'Sincronizados $ok de ${widget.drafts.length}');
      });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: SectionCard(
          title: 'Pendientes de sincronizar (${widget.drafts.length})',
          action: TextButton(onPressed: busy ? null : _retryAll, child: Text(busy ? 'Enviando…' : 'Reintentar')),
          child: Column(children: [
            const Text('Están guardados solo en este dispositivo. No cuentan en saldos ni estadísticas hasta que el servidor los confirme.'),
            for (final d in widget.drafts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.cloud_upload_outlined),
                title: Text(d.description),
                subtitle: Text(d.lastError ?? 'Sin enviar'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  AmountText(d.totalMinor, Currency.of(d.currency), style: context.text.bodyMedium),
                  IconButton(
                    tooltip: 'Descartar borrador',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (await confirmAction(context, title: 'Descartar borrador', message: 'Se borrará de este dispositivo y no se enviará.',
                          confirmLabel: 'Descartar', destructive: true)) {
                        await ref.read(draftStoreProvider.notifier).remove(d.requestId);
                      }
                    },
                  ),
                ]),
              ),
          ]),
        ),
      );
}
