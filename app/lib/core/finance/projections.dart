/// Hypothetical projections for planning and financial education.
/// Integer arithmetic only. Every result is a SCENARIO, not a prediction or
/// a promise of returns.
library;

class Projection {
  const Projection({required this.months, required this.contributedMinor, required this.nominalMinor, required this.realMinor});
  final int months;
  final int contributedMinor;

  /// Balance in money of that future date.
  final int nominalMinor;

  /// Same balance in today's purchasing power (after the assumed inflation).
  final int realMinor;

  int get nominalReturnMinor => nominalMinor - contributedMinor;
}

/// Monthly contributions with monthly compounding at [annualRateBp]/12 and an
/// assumed [annualInflationBp] to express the result in today's money.
Projection projectSavings({required int monthlyMinor, required int months, int initialMinor = 0, int annualRateBp = 0,
    int annualInflationBp = 0}) {
  if (months < 0 || months > 1200) throw ArgumentError('months out of range');
  if (monthlyMinor < 0 || initialMinor < 0) throw ArgumentError('amounts must be non-negative');
  var balance = BigInt.from(initialMinor);
  var contributed = BigInt.from(initialMinor);
  // Price index in parts per billion, grows with inflation each month.
  var index = BigInt.from(1000000000);
  final rate = BigInt.from(annualRateBp);
  final infl = BigInt.from(annualInflationBp);
  final half = BigInt.from(60000);
  final denom = BigInt.from(120000);
  for (var m = 0; m < months; m++) {
    balance += (balance * rate + half) ~/ denom;
    balance += BigInt.from(monthlyMinor);
    contributed += BigInt.from(monthlyMinor);
    index += (index * infl + half) ~/ denom;
  }
  final real = (balance * BigInt.from(1000000000) + index ~/ BigInt.two) ~/ index;
  return Projection(months: months, contributedMinor: contributed.toInt(), nominalMinor: balance.toInt(), realMinor: real.toInt());
}

/// Months needed to reach [targetMinor] saving [monthlyMinor] (no returns
/// assumed). Null when it is not reachable with that contribution.
int? monthsToTarget({required int targetMinor, required int savedMinor, required int monthlyMinor}) {
  final remaining = targetMinor - savedMinor;
  if (remaining <= 0) return 0;
  if (monthlyMinor <= 0) return null;
  return (remaining + monthlyMinor - 1) ~/ monthlyMinor;
}

/// Contribution levels. The names describe how much is set aside, never a
/// promised return.
enum SavingScenario { conservative, intermediate, ambitious }

extension SavingScenarioX on SavingScenario {
  String get label => switch (this) {
        SavingScenario.conservative => 'Conservador',
        SavingScenario.intermediate => 'Intermedio',
        SavingScenario.ambitious => 'Ambicioso',
      };

  /// Share of the monthly margin (income − assigned spending) set aside.
  int get marginShareBp => switch (this) {
        SavingScenario.conservative => 2500,
        SavingScenario.intermediate => 5000,
        SavingScenario.ambitious => 8000,
      };
}

/// Monthly amount for a scenario from the observed margin; 0 if there is no margin.
int scenarioContribution(SavingScenario s, int monthlyMarginMinor) =>
    monthlyMarginMinor <= 0 ? 0 : monthlyMarginMinor * s.marginShareBp ~/ 10000;

/// 50/30/20 reference amounts for an income (an optional guide, not a rule).
({int needs, int wants, int savings}) rule503020(int incomeMinor) {
  final needs = incomeMinor * 50 ~/ 100;
  final wants = incomeMinor * 30 ~/ 100;
  return (needs: needs, wants: wants, savings: incomeMinor - needs - wants);
}
