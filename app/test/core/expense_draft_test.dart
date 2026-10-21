import 'package:flutter_test/flutter_test.dart';
import 'package:nexo_finance/core/finance/expense_draft.dart';
import 'package:nexo_finance/core/finance/receipt_engine.dart';
import 'package:nexo_finance/core/finance/split_rules.dart';
import 'package:nexo_finance/core/money/money.dart';

ExpenseDraft draft({int? total = 300000, SplitRule? rule, ReceiptDraft? receipt}) => ExpenseDraft(
      clientRequestId: 'req-1',
      workspaceId: 'casa',
      currency: Currency.cop,
      occurredOn: DateTime(2026, 10, 21),
      totalMinor: total,
      description: 'Mercado',
      categoryId: 'cat',
      rule: rule ?? const EqualSplit(['a', 'b']),
      payments: [PaymentDraft(payerId: 'a', amountMinor: total ?? 0)],
      receipt: receipt,
    );

void main() {
  test('payload for an equal split is balanced and carries the idempotency key', () {
    final p = draft().toPayload();
    expect(p['client_request_id'], 'req-1');
    expect(p['split_method'], 'equal');
    expect(p['splits'], [
      {'user_id': 'a', 'amount_minor': 150000},
      {'user_id': 'b', 'amount_minor': 150000},
    ]);
    expect(p['payments'], [{'payer_id': 'a', 'amount_minor': 300000}]);
    expect(p['occurred_on'], '2026-10-21');
  });

  test('by-item payload sends one receipt with per-line allocations', () {
    final d = draft(
      rule: const ByItemSplit(),
      receipt: ReceiptDraft(lines: [
        ReceiptLine(description: 'A', lineTotalMinor: 80000, rule: const SingleSplit('a')),
        ReceiptLine(description: 'B', lineTotalMinor: 70000, rule: const SingleSplit('b')),
        ReceiptLine(description: 'Shared', lineTotalMinor: 150000, rule: const EqualSplit(['a', 'b'])),
      ]),
    );
    expect(d.validate().where((i) => i.blocking), isEmpty);
    final p = d.toPayload();
    expect(p['split_method'], 'by_item');
    expect((p['splits'] as List).map((s) => (s as Map)['amount_minor']), [155000, 145000]);
    final items = (p['receipt'] as Map)['items'] as List;
    expect(items, hasLength(3));
    expect((items[2] as Map)['allocations'], [
      {'user_id': 'a', 'amount_minor': 75000},
      {'user_id': 'b', 'amount_minor': 75000},
    ]);
  });

  test('validation blocks missing amount, mismatched payments and unreconciled receipts', () {
    expect(draft(total: null).validate().any((i) => i.field == 'amount' && i.blocking), isTrue);

    final d = draft()..payments = [PaymentDraft(payerId: 'a', amountMinor: 100)];
    expect(d.validate().any((i) => i.field == 'payer' && i.blocking), isTrue);

    final r = draft(rule: const ByItemSplit(), receipt: ReceiptDraft(lines: [
      ReceiptLine(description: 'A', lineTotalMinor: 290000, rule: const SingleSplit('a')),
    ]));
    final issue = r.validate().firstWhere((i) => i.field == 'receipt');
    expect(issue.message, contains('10.000'));
    expect(r.canSave, isFalse);
  });

  test('missing category is a suggestion, not a blocker', () {
    final d = draft()..categoryId = null;
    expect(d.validate().where((i) => i.field == 'category').single.blocking, isFalse);
    expect(d.canSave, isTrue);
  });

  test('income and transfers must live in the personal workspace', () {
    final d = draft()..kind = TxKind.income;
    expect(d.validate().any((i) => i.field == 'workspace'), isTrue);
    d.personalWorkspace = true;
    expect(d.validate().any((i) => i.field == 'workspace'), isFalse);
    final t = draft()
      ..kind = TxKind.transfer
      ..personalWorkspace = true
      ..accountId = 'x'
      ..toAccountId = 'x';
    expect(t.validate().any((i) => i.field == 'account' && i.blocking), isTrue);
  });
}
