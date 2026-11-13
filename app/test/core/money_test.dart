import 'package:flutter_test/flutter_test.dart';
import 'package:pami_finance/core/money/allocation.dart';
import 'package:pami_finance/core/money/money.dart';

void main() {
  group('formatting', () {
    test('COP uses dots for thousands and no decimals', () {
      expect(const Money(1250000, Currency.cop).format(), r'$ 1.250.000');
      expect(const Money(-4500, Currency.cop).format(), r'-$ 4.500');
      expect(const Money(0, Currency.cop).format(), r'$ 0');
      expect(formatMinor(145000, Currency.cop, signed: true), r'+$ 145.000');
    });
    test('USD keeps two decimals with comma', () {
      expect(const Money(1250, Currency.usd).format(), r'US$ 12,50');
      expect(const Money(5, Currency.usd).format(), r'US$ 0,05');
    });
    test('basis points', () {
      expect(formatBp(8750), '87,5 %');
      expect(formatBp(5000), '50 %');
      expect(formatBp(9125, decimals: 2), '91,25 %');
      expect(formatBp(3333, decimals: 0), '33 %');
    });
  });

  group('parsing input', () {
    test('Colombian conventions', () {
      expect(parseAmountInput('280.000', Currency.cop), 280000);
      expect(parseAmountInput(r'$ 1.250.000', Currency.cop), 1250000);
      expect(parseAmountInput('45500', Currency.cop), 45500);
      expect(parseAmountInput('12,50', Currency.usd), 1250);
      expect(parseAmountInput('12,5', Currency.usd), 1250);
    });
    test('rejects malformed or fractional COP', () {
      expect(parseAmountInput('12,50', Currency.cop), isNull, reason: 'COP has no decimals');
      expect(parseAmountInput('1.23', Currency.cop), isNull, reason: 'bad thousands group');
      expect(parseAmountInput('abc', Currency.cop), isNull);
      expect(parseAmountInput('-500', Currency.cop), isNull);
      expect(parseAmountInput('', Currency.cop), isNull);
      expect(parseAmountInput('99999999999999999', Currency.cop), isNull);
    });
  });

  test('money never mixes currencies silently', () {
    expect(() => const Money(1, Currency.cop) + const Money(1, Currency.usd), throwsArgumentError);
  });

  group('largest remainder allocation', () {
    test('parts always add up exactly', () {
      for (final total in [1, 2, 10, 100, 999, 100000, 1000001, 33333333]) {
        for (final n in [1, 2, 3, 7, 13]) {
          final parts = allocateEqually(total, n);
          expect(parts.fold<int>(0, (a, b) => a + b), total);
          expect(parts.reduce((a, b) => a > b ? a : b) - parts.reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(1));
        }
      }
    });
    test('deterministic tie-breaking by position', () {
      expect(allocateEqually(100, 3), [34, 33, 33]);
      expect(allocateEqually(101, 3), [34, 34, 33]);
    });
    test('proportional weights', () {
      expect(allocateByWeights(100000, [6000, 4000]), [60000, 40000]);
      expect(allocateByWeights(10, [1, 1, 1]), [4, 3, 3]);
      expect(allocateByWeights(1000, [2, 1]), [667, 333]);
    });
    test('negative totals (discounts) mirror positive ones', () {
      expect(allocateByWeights(-10, [1, 1, 1]), [-4, -3, -3]);
    });
    test('zero weights get nothing', () {
      expect(allocateByWeights(5, [0, 1, 0, 1]), [0, 3, 0, 2]);
      expect(() => allocateByWeights(5, [0, 0]), throwsArgumentError);
    });
    test('large values do not overflow', () {
      final parts = allocateByWeights(999999999999999, [3, 3, 3]);
      expect(parts.fold<int>(0, (a, b) => a + b), 999999999999999);
    });
  });
}
