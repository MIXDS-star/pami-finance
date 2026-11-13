/// Money is always an integer number of minor units plus a currency.
/// Never use floating point for amounts (see docs/FORMULAS.md).
library;

class Currency {
  const Currency(this.code, this.symbol, this.decimals, this.name);

  final String code;
  final String symbol;

  /// Decimals used by Pami. COP uses 0 (centavos are not used in practice).
  final int decimals;
  final String name;

  static const cop = Currency('COP', r'$', 0, 'Peso colombiano');
  static const usd = Currency('USD', r'US$', 2, 'Dólar estadounidense');
  static const eur = Currency('EUR', '€', 2, 'Euro');
  static const mxn = Currency('MXN', r'MX$', 2, 'Peso mexicano');
  static const all = [cop, usd, eur, mxn];

  static Currency of(String code) =>
      all.firstWhere((c) => c.code == code, orElse: () => Currency(code, code, 2, code));

  int get minorPerUnit {
    var f = 1;
    for (var i = 0; i < decimals; i++) {
      f *= 10;
    }
    return f;
  }

  @override
  bool operator ==(Object other) => other is Currency && other.code == code;

  @override
  int get hashCode => code.hashCode;
}

/// Upper bound accepted by the backend (and safe on every platform, incl. web).
const int kMaxMinor = 1000000000000000;

class Money implements Comparable<Money> {
  const Money(this.minor, this.currency);

  Money.zero(this.currency) : minor = 0;

  final int minor;
  final Currency currency;

  bool get isZero => minor == 0;
  bool get isNegative => minor < 0;

  Money operator +(Money o) {
    _same(o);
    return Money(minor + o.minor, currency);
  }

  Money operator -(Money o) {
    _same(o);
    return Money(minor - o.minor, currency);
  }

  Money operator -() => Money(-minor, currency);

  Money abs() => Money(minor.abs(), currency);

  void _same(Money o) {
    if (o.currency != currency) {
      throw ArgumentError('Cannot mix ${currency.code} and ${o.currency.code} without an explicit conversion');
    }
  }

  @override
  int compareTo(Money other) {
    _same(other);
    return minor.compareTo(other.minor);
  }

  @override
  bool operator ==(Object other) => other is Money && other.minor == minor && other.currency == currency;

  @override
  int get hashCode => Object.hash(minor, currency);

  /// Colombian formatting: `$ 1.250.000`, `US$ 12,50`, `-$ 4.500`.
  String format({bool withSymbol = true, bool signed = false}) =>
      formatMinor(minor, currency, withSymbol: withSymbol, signed: signed);

  @override
  String toString() => format();
}

String formatMinor(int minor, Currency currency, {bool withSymbol = true, bool signed = false}) {
  final negative = minor < 0;
  final abs = minor.abs();
  final unit = currency.minorPerUnit;
  final whole = abs ~/ unit;
  final fraction = abs % unit;
  final digits = whole.toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write('.');
    buf.write(digits[i]);
  }
  if (currency.decimals > 0) {
    buf
      ..write(',')
      ..write(fraction.toString().padLeft(currency.decimals, '0'));
  }
  final sign = negative ? '-' : (signed && minor > 0 ? '+' : '');
  return withSymbol ? '$sign${currency.symbol} $buf' : '$sign$buf';
}

/// Parses what a person types in an amount field, using Colombian
/// conventions: `.` groups thousands and `,` separates decimals.
/// Returns null when the text is not a valid non-negative amount.
int? parseAmountInput(String input, Currency currency) {
  var s = input.trim().replaceAll(RegExp(r'[\s$€]|COP|USD|EUR|MXN|US', caseSensitive: false), '');
  if (s.isEmpty) return null;
  if (!RegExp(r'^[0-9.,]+$').hasMatch(s)) return null;
  String intPart;
  String fracPart = '';
  final lastComma = s.lastIndexOf(',');
  if (lastComma >= 0) {
    intPart = s.substring(0, lastComma);
    fracPart = s.substring(lastComma + 1);
    if (fracPart.contains('.') || intPart.contains(',')) return null;
  } else {
    intPart = s;
  }
  // Thousands groups must be well formed: 1.234.567
  if (intPart.contains('.')) {
    if (!RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(intPart)) return null;
    intPart = intPart.replaceAll('.', '');
  }
  if (intPart.isEmpty) intPart = '0';
  if (fracPart.length > currency.decimals) return null;
  final minorStr = intPart + fracPart.padRight(currency.decimals, '0');
  if (minorStr.length > 16) return null;
  final value = int.tryParse(minorStr);
  if (value == null || value > kMaxMinor) return null;
  return value;
}

/// Basis points (1 % = 100 bp) as a percentage, rounded half-up with integer
/// math: 9125 -> "91,3 %" (1 decimal), 8750 -> "87,5 %", 5000 -> "50 %".
String formatBp(int bp, {int decimals = 1}) {
  assert(decimals >= 0 && decimals <= 2);
  final sign = bp < 0 ? '-' : '';
  final step = decimals == 0 ? 100 : (decimals == 1 ? 10 : 1);
  final unit = decimals == 0 ? 1 : (decimals == 1 ? 10 : 100);
  final rounded = (bp.abs() + step ~/ 2) ~/ step;
  final whole = rounded ~/ unit;
  final frac = rounded % unit;
  if (decimals == 0 || frac == 0) return '$sign$whole %';
  return '$sign$whole,${frac.toString().padLeft(decimals, '0')} %';
}
