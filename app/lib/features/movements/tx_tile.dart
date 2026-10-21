import 'package:flutter/material.dart';

import '../../core/money/money.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../ui/components.dart';

/// One movement. For shared expenses it shows YOUR share (what counts for
/// you) and the receipt total, so paid amounts and assigned amounts are
/// never confused.
class TxTile extends StatelessWidget {
  const TxTile({super.key, required this.tx, required this.me, this.category, this.workspace, this.people = const {}, this.onTap});
  final Transaction tx;
  final String me;
  final Category? category;
  final Workspace? workspace;
  final Map<String, String> people;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final shared = workspace != null && !workspace!.isPersonal;
    final myShare = tx.shareOf(me);
    final payerIds = tx.payments.map((p) => p.payerId).toList();
    final payer = payerIds.length == 1 ? (payerIds.first == me ? 'pagaste tú' : 'pagó ${people[payerIds.first] ?? 'otro miembro'}') : 'varios pagadores';

    final subtitle = [
      if (shared) workspace!.name,
      if (tx.isExpense && shared) payer,
      if (tx.isTransfer) 'Transferencia',
      formatDateShort(tx.occurredOn),
    ].join(' · ');

    final (amount, signed, prefix) = switch (tx.kind) {
      'income' => (tx.totalMinor, true, 'Ingreso'),
      'transfer' => (tx.totalMinor, false, 'Transferencia'),
      _ => (shared ? myShare : tx.totalMinor, false, shared ? 'Tu parte' : 'Gasto'),
    };

    return ListTile(
      onTap: onTap,
      leading: CategoryBadge(
        category: category,
        fallbackIcon: tx.isTransfer ? Icons.swap_horiz : (tx.isIncome ? Icons.south_west : Icons.receipt_long_outlined),
      ),
      title: Row(children: [
        Flexible(child: Text(tx.description, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (tx.receipt != null) ...[const SizedBox(width: 6), Icon(Icons.receipt_outlined, size: 14, color: context.nexo.muted, semanticLabel: 'Con factura')],
      ]),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        AmountText(tx.isExpense ? -amount : amount, tx.currency, signed: signed, colorize: tx.isIncome,
            semanticPrefix: prefix, style: context.text.titleSmall),
        if (shared && tx.isExpense)
          Text('de ${formatMinor(tx.totalMinor, tx.currency)}', style: context.text.labelSmall?.copyWith(color: context.nexo.muted)),
      ]),
    );
  }
}
