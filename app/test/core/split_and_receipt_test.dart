import 'package:flutter_test/flutter_test.dart';
import 'package:pami_finance/core/finance/balances.dart';
import 'package:pami_finance/core/finance/receipt_engine.dart';
import 'package:pami_finance/core/finance/split_rules.dart';
import 'package:pami_finance/core/money/money.dart';

const cop = Currency.cop;
const a = 'user-a';
const b = 'user-b';
const c = 'user-c';

void main() {
  group('split rules', () {
    test('single person', () {
      expect(const SingleSplit(a).apply(52000, cop).allocations, {a: 52000});
    });
    test('equal split with exact rounding', () {
      final r = const EqualSplit([a, b, c]).apply(100000, cop);
      expect(r.allocations, {a: 33334, b: 33333, c: 33333});
      expect(r.total, 100000);
      expect(r.explanation.join(' '), contains('redondeo'));
    });
    test('percentages must add up to 100 %', () {
      expect(const PercentSplit({a: 6000, b: 4000}).apply(250000, cop).allocations, {a: 150000, b: 100000});
      expect(() => const PercentSplit({a: 6000, b: 3000}).apply(1000, cop),
          throwsA(isA<SplitError>().having((e) => e.code, 'code', 'percent_sum')));
    });
    test('fixed amounts must match the total exactly', () {
      expect(const FixedSplit({a: 70000, b: 30000}).apply(100000, cop).allocations, {a: 70000, b: 30000});
      expect(() => const FixedSplit({a: 70000}).apply(100000, cop), throwsA(isA<SplitError>()));
    });
    test('shares (2:1)', () {
      expect(const SharesSplit({a: 2, b: 1}).apply(90000, cop).allocations, {a: 60000, b: 30000});
    });
    test('mixed: fixed for someone, rest equal', () {
      final r = const MixedSplit({a: 20000}, [a, b]).apply(100000, cop);
      expect(r.allocations, {a: 60000, b: 40000});
      expect(() => const MixedSplit({a: 200000}, [b]).apply(100000, cop), throwsA(isA<SplitError>()));
    });
    test('rules round-trip through their stored spec', () {
      for (final rule in <SplitRule>[
        const SingleSplit(a), const EqualSplit([a, b]), const PercentSplit({a: 5000, b: 5000}),
        const FixedSplit({a: 1, b: 2}), const SharesSplit({a: 3, b: 1}), const MixedSplit({a: 10}, [b]),
      ]) {
        final back = SplitRule.fromJson(rule.method.wire, rule.toJson());
        final amount = rule.method == SplitMethod.fixed ? 3 : 1000; // fixed amounts are absolute
        expect(back.apply(amount, cop).allocations, rule.apply(amount, cop).allocations);
        expect(back.method, rule.method);
      }
    });
  });

  group('receipt engine', () {
    test('spec example: 300.000 COP, per-item split, A paid everything', () {
      final draft = ReceiptDraft(lines: [
        ReceiptLine(description: 'Productos de A', lineTotalMinor: 80000, rule: const SingleSplit(a)),
        ReceiptLine(description: 'Productos de B', lineTotalMinor: 70000, rule: const SingleSplit(b)),
        ReceiptLine(description: 'Compartidos', lineTotalMinor: 150000, rule: const EqualSplit([a, b])),
      ]);
      final rc = computeReceipt(draft, 300000, cop);
      expect(rc.reconciled, isTrue);
      expect(rc.splits, {a: 155000, b: 145000});

      // Settlement: A paid 300.000 and was assigned 155.000 -> +145.000.
      final nets = {a: 300000 - 155000, b: 0 - 145000};
      expect(suggestTransfers(nets), [const SuggestedTransfer(b, a, 145000)]);
    });

    test('included IVA is informational and never added twice', () {
      final draft = ReceiptDraft(taxesIncluded: true, taxMinor: 15966, lines: [
        ReceiptLine(description: 'X', lineTotalMinor: 100000, rule: const SingleSplit(a)),
      ]);
      expect(computeReceipt(draft, 100000, cop).reconciled, isTrue);
    });

    test('tax on top, tip and discount are prorated by line share', () {
      final draft = ReceiptDraft(taxesIncluded: false, taxMinor: 19000, tipMinor: 10000, discountMinor: 9000, lines: [
        ReceiptLine(description: 'Plato A', lineTotalMinor: 60000, rule: const SingleSplit(a)),
        ReceiptLine(description: 'Plato B', lineTotalMinor: 40000, rule: const SingleSplit(b)),
      ]);
      final rc = computeReceipt(draft, 120000, cop);
      expect(rc.computedTotal, 120000);
      expect(rc.extrasByUser, {a: 12000, b: 8000});
      expect(rc.splits, {a: 72000, b: 48000});
      expect(rc.splits.values.reduce((x, y) => x + y), 120000);
    });

    test('a mismatch is reported, never forced', () {
      final draft = ReceiptDraft(lines: [
        ReceiptLine(description: 'X', lineTotalMinor: 95000, rule: const SingleSplit(a)),
      ]);
      final rc = computeReceipt(draft, 100000, cop);
      expect(rc.reconciled, isFalse);
      expect(rc.difference, 5000);
      expect(draft.lines, hasLength(1), reason: 'no invented lines');
    });

    test('an explicit adjustment line created by the person reconciles', () {
      final draft = ReceiptDraft(lines: [
        ReceiptLine(description: 'X', lineTotalMinor: 95000, rule: const EqualSplit([a, b])),
        ReceiptLine(description: 'Ajuste', lineTotalMinor: 5000, rule: const EqualSplit([a, b]), isAdjustment: true),
      ]);
      expect(computeReceipt(draft, 100000, cop).splits, {a: 50000, b: 50000});
    });

    test('line math warnings keep original text', () {
      final draft = ReceiptDraft(lines: [
        ReceiptLine(description: 'Leche', rawText: 'LECHE 1L X3', quantityMilli: 3000, unitPriceMinor: 4500,
            lineTotalMinor: 14500, rule: const SingleSplit(a)),
      ]);
      final rc = computeReceipt(draft, 14500, cop);
      expect(rc.warnings.single, contains('13.500'));
      expect(draft.lines.single.rawText, 'LECHE 1L X3');
    });

    test('weighted quantities use integer thousandths', () {
      final draft = ReceiptDraft(lines: [
        ReceiptLine(description: 'Queso', quantityMilli: 452, unitPriceMinor: 38900, lineTotalMinor: 17583, rule: const SingleSplit(a)),
      ]);
      expect(computeReceipt(draft, 17583, cop).warnings, isEmpty);
    });

    test('invalid line rules are surfaced per line', () {
      final draft = ReceiptDraft(lines: [
        ReceiptLine(description: 'X', lineTotalMinor: 1000, rule: const PercentSplit({a: 5000})),
      ]);
      final rc = computeReceipt(draft, 1000, cop);
      expect(rc.lineErrors.keys, [0]);
      expect(rc.reconciled, isFalse);
    });
  });

  group('settlement suggestions', () {
    test('minimal deterministic transfers', () {
      final t = suggestTransfers({a: 100000, b: -60000, c: -40000});
      expect(t, [const SuggestedTransfer(b, a, 60000), const SuggestedTransfer(c, a, 40000)]);
    });
    test('partial settlement reduces the remaining debt', () {
      expect(suggestTransfers({a: 100000, b: -100000}), [const SuggestedTransfer(b, a, 100000)]);
      expect(suggestTransfers({a: 0, b: 0}), isEmpty);
    });
    test('rejects unbalanced input', () {
      expect(() => suggestTransfers({a: 10, b: -5}), throwsStateError);
    });
  });
}
