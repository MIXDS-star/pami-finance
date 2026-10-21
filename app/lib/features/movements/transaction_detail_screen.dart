import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/finance/split_rules.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';

final transactionDetailProvider = FutureProvider.autoDispose.family<Transaction?, String>((ref, id) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(transactionRepositoryProvider).get(id);
});

final transactionHistoryProvider = FutureProvider.autoDispose.family<List<AuditEvent>, String>((ref, id) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(transactionRepositoryProvider).history(id);
});

class TransactionDetailScreen extends ConsumerWidget {
  const TransactionDetailScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tx = ref.watch(transactionDetailProvider(id));
    return Scaffold(
      appBar: AppBar(title: const Text('Detalle')),
      body: AsyncView(
        value: tx,
        onRetry: () => ref.invalidate(transactionDetailProvider(id)),
        data: (t) => t == null
            ? const EmptyState(icon: Icons.search_off, title: 'No encontrado', message: 'El movimiento no existe o ya no tienes acceso.')
            : _Body(t: t),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.t});
  final Transaction t;
  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> with BusyState {
  Transaction get t => widget.t;

  Future<void> _delete() async {
    final ok = await confirmAction(context,
        title: 'Eliminar movimiento',
        message: 'Dejará de contar en saldos, presupuestos y estadísticas. Queda en el historial y se puede restaurar.',
        confirmLabel: 'Eliminar',
        destructive: true);
    if (!ok) return;
    await runBusy(() async {
      await ref.read(transactionRepositoryProvider).delete(t);
      ref.read(ledgerRevisionProvider.notifier).bump();
      if (mounted) showSuccess(context, 'Movimiento eliminado');
    }, onError: (e) => showFailure(context, e));
  }

  Future<void> _restore() => runBusy(() async {
        await ref.read(transactionRepositoryProvider).restore(t.id);
        ref.read(ledgerRevisionProvider.notifier).bump();
        if (mounted) showSuccess(context, 'Movimiento restaurado');
      }, onError: (e) => showFailure(context, e));

  Future<void> _openReceipt() => runBusy(() async {
        final bytes = await ref.read(transactionRepositoryProvider).downloadReceipt(t.receipt!.storagePath!);
        if (!mounted) return;
        await showDialog(
          context: context,
          builder: (ctx) => Dialog.fullscreen(
            child: Scaffold(
              appBar: AppBar(title: const Text('Factura'), leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Cerrar', onPressed: () => Navigator.pop(ctx))),
              body: t.receipt!.mimeType == 'application/pdf'
                  ? const EmptyState(icon: Icons.picture_as_pdf_outlined, title: 'Documento PDF',
                      message: 'La vista previa de PDF no está disponible en la app todavía. Puedes exportarlo desde Datos y privacidad.')
                  : InteractiveViewer(child: Center(child: Image.memory(bytes, semanticLabel: 'Imagen de la factura'))),
            ),
          ),
        );
      }, onError: (e) => showFailure(context, e));

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(currentUserIdProvider) ?? '';
    final spaces = ref.watch(workspacesProvider).value ?? const <Workspace>[];
    final ws = spaces.where((w) => w.id == t.workspaceId).firstOrNull;
    final people = ref.watch(peopleProvider).value ?? const <String, String>{};
    final cats = ref.watch(categoriesProvider).value ?? const <Category>[];
    final cat = cats.where((c) => c.id == t.categoryId).firstOrNull;
    final history = ref.watch(transactionHistoryProvider(t.id));
    String name(String id) => id == me ? 'Tú' : (people[id] ?? 'Exmiembro');
    final canEdit = (ws?.canWrite ?? false) && !t.deleted;
    final canDelete = canEdit && (t.createdBy == me || (ws?.canAdmin ?? false));
    final shared = ws != null && !ws.isPersonal;

    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
      if (t.deleted)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Notice(
            kind: NoticeKind.warning,
            message: 'Este movimiento está eliminado: no cuenta en saldos ni estadísticas.',
            action: (ws?.canWrite ?? false) && (t.createdBy == me || (ws?.canAdmin ?? false))
                ? TextButton(onPressed: busy ? null : _restore, child: const Text('Restaurar'))
                : null,
          ),
        ),
      Row(children: [
        CategoryBadge(category: cat, size: 52, fallbackIcon: t.isTransfer ? Icons.swap_horiz : Icons.receipt_long_outlined),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.description, style: context.text.titleLarge),
            Text([cat?.name ?? (t.isTransfer ? 'Transferencia' : 'Sin categoría'), formatDateLong(t.occurredOn)].join(' · '),
                style: context.text.bodyMedium?.copyWith(color: context.nexo.muted)),
          ]),
        ),
      ]),
      const SizedBox(height: 20),
      AmountText(t.isExpense ? -t.totalMinor : t.totalMinor, t.currency, signed: t.isIncome, colorize: t.isIncome,
          style: context.text.displaySmall, semanticPrefix: t.isExpense ? 'Total pagado' : 'Importe'),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (ws != null) Pill(ws.name, icon: ws.kind.icon),
        Pill(switch (t.source) {
          'receipt' => 'Desde factura', 'voice' => 'Por voz', 'text' => 'Por texto', 'import' => 'Importado', _ => 'Manual'
        }, icon: Icons.input),
        if (t.merchant != null) Pill(t.merchant!, icon: Icons.storefront_outlined),
      ]),
      if (t.isExpense) ...[
        const SectionTitle('Quién pagó'),
        for (final p in t.payments)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: PersonAvatar(name: people[p.payerId] ?? '?'),
            title: Text(name(p.payerId)),
            subtitle: p.method == null ? null : Text(paymentMethodLabels[p.method] ?? p.method!),
            trailing: AmountText(p.amountMinor, t.currency, semanticPrefix: 'pagó'),
          ),
        if (shared) ...[
          SectionTitle('A quién corresponde · ${SplitMethodWire.parse(t.splitMethod).label}'),
          for (final s in t.splits)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: PersonAvatar(name: people[s.userId] ?? '?'),
              title: Text(name(s.userId)),
              subtitle: _balanceLine(context, s.userId, t),
              trailing: AmountText(s.amountMinor, t.currency, semanticPrefix: 'le corresponde'),
            ),
          Text('Pagar no es lo mismo que gastar: cada persona registra como gasto solo su parte. '
              'La diferencia se refleja en los saldos del espacio.', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
        ],
      ],
      if (t.receipt != null) _ReceiptSection(t: t, people: people, onOpen: t.receipt!.storagePath == null ? null : _openReceipt),
      if (t.notes != null) ...[const SectionTitle('Notas'), Text(t.notes!)],
      const SectionTitle('Historial de cambios'),
      AsyncView(
        value: history,
        compact: true,
        data: (events) => Column(children: [
          for (final e in events)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(switch (e.action) { 'created' => Icons.add_circle_outline, 'deleted' => Icons.delete_outline, 'restored' => Icons.restore, _ => Icons.edit_outlined }),
              title: Text('${_action(e.action)} por ${e.actorId == null ? 'el sistema' : name(e.actorId!)}'),
              subtitle: Text([formatDateLong(e.occurredAt), if (e.action == 'updated') _changedFields(e.changes)].join(' · ')),
            ),
          if (events.isEmpty) const Text('Sin cambios registrados.'),
        ]),
      ),
      const SizedBox(height: 24),
      if (canEdit)
        FilledButton.icon(onPressed: () => context.push('/tx/${t.id}/edit'), icon: const Icon(Icons.edit_outlined), label: const Text('Editar')),
      if (canDelete) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: busy ? null : _delete,
          style: OutlinedButton.styleFrom(foregroundColor: context.colors.error),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Eliminar'),
        ),
      ],
      if (!canEdit && !t.deleted)
        const Notice(message: 'Tu rol en este espacio solo permite consultar este movimiento.'),
    ]);
  }

  Widget? _balanceLine(BuildContext context, String userId, Transaction t) {
    final paid = t.paidBy(userId);
    final share = t.shareOf(userId);
    final diff = paid - share;
    if (diff == 0) return null;
    return Text(diff > 0 ? 'Pagó ${formatMinor(paid, t.currency)}: le deben ${formatMinor(diff, t.currency)}'
        : 'Debe ${formatMinor(-diff, t.currency)} por este gasto');
  }

  String _action(String a) => switch (a) {
        'created' => 'Creado',
        'updated' => 'Editado',
        'deleted' => 'Eliminado',
        'restored' => 'Restaurado',
        _ => a,
      };

  String _changedFields(Map<String, dynamic> changes) {
    const labels = {
      'description': 'concepto', 'merchant': 'comercio', 'occurred_on': 'fecha', 'total_minor': 'importe', 'category_id': 'categoría',
      'split_method': 'método de reparto', 'payments': 'pagos', 'splits': 'reparto', 'receipt_lines': 'líneas de factura',
      'has_notes': 'notas', 'currency': 'moneda',
    };
    final fields = changes.keys.map((k) => labels[k] ?? k).toList();
    return fields.isEmpty ? 'sin cambios visibles' : 'cambió ${fields.join(', ')}';
  }
}

class _ReceiptSection extends StatelessWidget {
  const _ReceiptSection({required this.t, required this.people, required this.onOpen});
  final Transaction t;
  final Map<String, String> people;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final r = t.receipt!;
    final linesTotal = r.items.fold<int>(0, (a, i) => a + i.lineTotalMinor);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Factura', action: onOpen == null ? null : TextButton.icon(onPressed: onOpen, icon: const Icon(Icons.image_outlined, size: 18), label: const Text('Ver original'))),
      if (r.merchantName != null || r.merchantTaxId != null || r.invoiceNumber != null)
        Text([
          if (r.merchantName != null) r.merchantName!,
          if (r.merchantTaxId != null) 'NIT ${r.merchantTaxId}',
          if (r.invoiceNumber != null) 'Factura ${r.invoiceNumber}',
        ].join(' · '), style: context.text.bodyMedium?.copyWith(color: context.nexo.muted)),
      if (r.extractionStatus == 'completed')
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Leída automáticamente y revisada antes de guardar.', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
        ),
      const SizedBox(height: 8),
      for (final i in r.items)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(i.description),
          subtitle: i.allocations.isEmpty
              ? null
              : Text(i.allocations.map((a) => '${people[a.userId] ?? 'Exmiembro'} ${formatMinor(a.amountMinor, t.currency)}').join(' · ')),
          trailing: AmountText(i.lineTotalMinor, t.currency, style: context.text.bodyMedium),
        ),
      const Divider(),
      _row(context, 'Suma de líneas', linesTotal),
      if (r.taxMinor != 0) _row(context, r.taxesIncluded ? 'IVA (incluido en precios)' : 'IVA', r.taxMinor),
      if (r.tipMinor != 0) _row(context, 'Propina', r.tipMinor),
      if (r.discountMinor != 0) _row(context, 'Descuento', -r.discountMinor),
      if (r.otherChargesMinor != 0) _row(context, 'Otros cargos', r.otherChargesMinor),
      _row(context, 'Total pagado', t.totalMinor, strong: true),
    ]);
  }

  Widget _row(BuildContext context, String label, int v, {bool strong = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(label, style: strong ? context.text.titleSmall : null)),
          AmountText(v, t.currency, style: strong ? context.text.titleSmall : context.text.bodyMedium),
        ]),
      );
}
