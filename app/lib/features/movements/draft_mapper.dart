import '../../core/finance/expense_draft.dart';
import '../../core/finance/receipt_engine.dart';
import '../../core/finance/split_rules.dart';
import '../../core/util/ids.dart';
import '../../data/models.dart';

/// Default rule for a new expense in [ws]: the person alone in their
/// personal space, otherwise the workspace's saved rule.
SplitRule defaultRule(Workspace ws, String me, List<Member> members) {
  if (ws.isPersonal) return SingleSplit(me);
  final active = members.where((m) => m.active).map((m) => m.userId).toList();
  final method = ws.defaultSplit['method'] as String? ?? 'equal';
  final rule = SplitRule.fromJson(method, ws.defaultSplit, fallback: active);
  // Saved rules may reference people who left: fall back to equal among active members.
  final valid = rule.participants.isNotEmpty && rule.participants.every(active.contains);
  return valid && rule is! ByItemSplit ? rule : EqualSplit(active);
}

ExpenseDraft newDraft({required Workspace ws, required String me, required List<Member> members, TxKind kind = TxKind.expense,
    TxSource source = TxSource.manual}) {
  return ExpenseDraft(
    clientRequestId: newId(),
    workspaceId: ws.id,
    personalWorkspace: ws.isPersonal,
    currency: ws.baseCurrency,
    occurredOn: _today(),
    kind: kind,
    source: source,
    rule: defaultRule(ws, me, members),
    payments: kind == TxKind.expense ? [PaymentDraft(payerId: me, amountMinor: 0)] : [],
  );
}

DateTime _today() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

int quantityToMilli(String q) {
  final parts = q.split('.');
  final whole = int.tryParse(parts[0]) ?? 1;
  final frac = parts.length > 1 ? parts[1].padRight(3, '0').substring(0, 3) : '000';
  return whole * 1000 + int.parse(frac);
}

ExpenseDraft draftFromTransaction(Transaction t, Workspace ws) {
  final participants = t.splits.map((s) => s.userId).toList();
  final rule = t.splitMethod == null
      ? SingleSplit(t.createdBy)
      : SplitRule.fromJson(t.splitMethod!, t.splitSpec, fallback: participants);
  final r = t.receipt;
  return ExpenseDraft(
    clientRequestId: newId(),
    id: t.id,
    version: t.version,
    workspaceId: t.workspaceId,
    personalWorkspace: ws.isPersonal,
    kind: TxKind.values.byName(t.kind),
    currency: t.currency,
    totalMinor: t.totalMinor,
    description: t.description,
    merchant: t.merchant,
    occurredOn: t.occurredOn,
    categoryId: t.categoryId,
    notes: t.notes,
    source: TxSource.values.byName(t.source),
    accountId: t.accountId,
    toAccountId: t.toAccountId,
    rule: rule,
    payments: [for (final p in t.payments) PaymentDraft(payerId: p.payerId, amountMinor: p.amountMinor, accountId: p.accountId, method: p.method)],
    receipt: r == null
        ? null
        : ReceiptDraft(
            storagePath: r.storagePath,
            mimeType: r.mimeType,
            merchantName: r.merchantName,
            merchantTaxId: r.merchantTaxId,
            invoiceNumber: r.invoiceNumber,
            issuedOn: r.issuedOn,
            printedSubtotalMinor: r.printedSubtotalMinor,
            printedTotalMinor: r.printedTotalMinor,
            discountMinor: r.discountMinor,
            taxMinor: r.taxMinor,
            taxesIncluded: r.taxesIncluded,
            tipMinor: r.tipMinor,
            otherChargesMinor: r.otherChargesMinor,
            extractionStatus: r.extractionStatus,
            extractionProvider: r.extractionProvider,
            extractionConfidence: r.extractionConfidence,
            lines: [
              for (final i in r.items)
                ReceiptLine(
                  description: i.description,
                  rawText: i.rawText,
                  quantityMilli: quantityToMilli(i.quantity),
                  unitPriceMinor: i.unitPriceMinor,
                  lineDiscountMinor: i.lineDiscountMinor,
                  lineTotalMinor: i.lineTotalMinor,
                  categoryId: i.categoryId,
                  confidence: i.confidence,
                  isAdjustment: i.kind == 'adjustment',
                  rule: SplitRule.fromJson(i.allocationMethod, i.allocationSpec,
                      fallback: i.allocations.map((a) => a.userId).toList()),
                ),
            ],
          ),
  );
}
