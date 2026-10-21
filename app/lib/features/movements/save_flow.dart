import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/drafts/draft_store.dart';
import '../../core/errors/failure.dart';
import '../../core/finance/expense_draft.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../ui/components.dart';

sealed class SaveOutcome {}

class Saved extends SaveOutcome {
  Saved(this.id);
  final String id;
}

class KeptOffline extends SaveOutcome {}

class Cancelled extends SaveOutcome {}

class Failed extends SaveOutcome {
  Failed(this.failure);
  final AppFailure failure;
}

/// The one save routine every capture method uses.
Future<SaveOutcome> saveDraft(BuildContext context, WidgetRef ref, ExpenseDraft draft) async {
  if (draft.kind == TxKind.expense && draft.payments.length == 1) {
    draft.payments.first.amountMinor = draft.totalMinor ?? 0;
  }
  final repo = ref.read(transactionRepositoryProvider);

  // Possible duplicates are a hint, never a block.
  if (!draft.isEdit && draft.kind == TxKind.expense) {
    try {
      final dups = await repo.possibleDuplicates(
        workspaceId: draft.workspaceId, totalMinor: draft.totalMinor!, date: draft.occurredOn,
        merchant: draft.merchant ?? draft.receipt?.merchantName, invoiceNumber: draft.receipt?.invoiceNumber);
      if (dups.isNotEmpty && context.mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('¿Posible duplicado?'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Ya existe un movimiento parecido en este espacio:'),
              const SizedBox(height: 12),
              for (final d in dups.take(3))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.content_copy_outlined),
                  title: Text(d['description'] as String),
                  subtitle: Text('${formatDateShort(DateTime.parse(d['occurred_on'] as String))} · '
                      '${_reasons((d['reasons'] as List).cast<String>())}'),
                  trailing: Text(formatMinor((d['total_minor'] as num).toInt(), draft.currency)),
                ),
              const SizedBox(height: 8),
              const Text('Dos compras parecidas pueden ser legítimas. ¿Quieres guardarlo de todos modos?'),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Revisar')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar igual')),
            ],
          ),
        );
        if (proceed != true) return Cancelled();
      }
    } catch (_) {
      // The duplicate hint is best-effort; saving decides connectivity below.
    }
  }

  try {
    final r = await repo.save(draft);
    await ref.read(draftStoreProvider.notifier).remove(draft.clientRequestId);
    ref.read(ledgerRevisionProvider.notifier).bump();
    return Saved(r.id);
  } on AppFailure catch (f) {
    if (f.kind == FailureKind.network && !draft.isEdit) {
      // Kept encrypted on the device, clearly marked as NOT synchronised.
      await ref.read(draftStoreProvider.notifier).put(draft.toPayload(), error: f.message);
      return KeptOffline();
    }
    return Failed(f);
  }
}

String _reasons(List<String> r) => r.map((x) => switch (x) {
      'same_amount' => 'mismo importe',
      'same_date' => 'misma fecha',
      'near_date' => 'fecha cercana',
      'same_merchant' => 'mismo comercio',
      'same_invoice' => 'misma factura',
      _ => x,
    }).join(', ');
