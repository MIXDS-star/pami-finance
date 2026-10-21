/// Parsing helpers for importing bank/export files (CSV and spreadsheets).
/// Pure Dart: no I/O, fully unit-tested.
library;

/// RFC 4180-style CSV parser with delimiter detection (`,` `;` or tab).
List<List<String>> parseCsv(String input) {
  var text = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (text.startsWith('﻿')) text = text.substring(1);
  final firstLine = text.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  final delimiter = [';', '\t', ','].reduce((best, d) => _count(firstLine, d) > _count(firstLine, best) ? d : best);

  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == delimiter) {
      row.add(cell.toString().trim());
      cell.clear();
    } else if (ch == '\n') {
      row.add(cell.toString().trim());
      cell.clear();
      if (row.any((c) => c.isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      cell.write(ch);
    }
  }
  row.add(cell.toString().trim());
  if (row.any((c) => c.isNotEmpty)) rows.add(row);
  return rows;
}

int _count(String s, String d) => d.allMatches(s).length;

enum ImportField { date, description, amount, debit, credit, ignore }

/// Guesses the meaning of each header (Spanish and English bank exports).
Map<int, ImportField> guessColumns(List<String> headers) {
  final out = <int, ImportField>{};
  for (var i = 0; i < headers.length; i++) {
    final h = headers[i].toLowerCase().trim();
    ImportField f = ImportField.ignore;
    if (RegExp(r'fecha|date').hasMatch(h)) {
      f = ImportField.date;
    } else if (RegExp(r'descrip|concepto|detalle|referencia|description|comercio').hasMatch(h)) {
      f = ImportField.description;
    } else if (RegExp(r'd[eé]bito|cargo|retiro|egreso|debit').hasMatch(h)) {
      f = ImportField.debit;
    } else if (RegExp(r'cr[eé]dito|abono|ingreso|dep[oó]sito|credit').hasMatch(h)) {
      f = ImportField.credit;
    } else if (RegExp(r'valor|monto|importe|amount|total').hasMatch(h)) {
      f = ImportField.amount;
    }
    if (f != ImportField.ignore && out.containsValue(f)) f = ImportField.ignore;
    out[i] = f;
  }
  return out;
}

/// Accepts 2026-10-21, 21/10/2026, 21-10-2026, 21/10/26 and 21.10.2026.
DateTime? parseImportDate(String raw) {
  final s = raw.trim().split(RegExp(r'[ T]')).first;
  var m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(s);
  if (m != null) return _date(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  m = RegExp(r'^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})$').firstMatch(s);
  if (m != null) {
    var y = int.parse(m[3]!);
    if (y < 100) y += 2000;
    return _date(y, int.parse(m[2]!), int.parse(m[1]!));
  }
  return null;
}

DateTime? _date(int y, int mo, int d) {
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  final dt = DateTime(y, mo, d);
  return dt.month == mo ? dt : null;
}

class ParsedAmount {
  const ParsedAmount(this.minor, {this.negative = false});
  final int minor;
  final bool negative;
}

/// Parses an amount cell into minor units for a currency with [decimals].
/// Handles "-45.000", "(45.000)", "45.000,00", "1,234.56", "$ 1.234".
/// Returns null if the value has more precision than the currency allows
/// (e.g. centavos in COP that are not zero) — never rounds money silently.
ParsedAmount? parseImportAmount(String raw, int decimals) {
  var s = raw.trim().replaceAll(RegExp(r'[\s$€]|COP|USD|EUR', caseSensitive: false), '');
  if (s.isEmpty) return null;
  var negative = false;
  if (s.startsWith('(') && s.endsWith(')')) {
    negative = true;
    s = s.substring(1, s.length - 1);
  }
  if (s.startsWith('-')) {
    negative = true;
    s = s.substring(1);
  } else if (s.endsWith('-')) {
    negative = true;
    s = s.substring(0, s.length - 1);
  }
  if (!RegExp(r'^[0-9.,]+$').hasMatch(s)) return null;
  final lastDot = s.lastIndexOf('.');
  final lastComma = s.lastIndexOf(',');
  String intPart = s;
  String frac = '';
  if (lastDot >= 0 && lastComma >= 0) {
    final sep = lastDot > lastComma ? lastDot : lastComma;
    intPart = s.substring(0, sep).replaceAll(RegExp(r'[.,]'), '');
    frac = s.substring(sep + 1);
  } else if (lastComma >= 0 || lastDot >= 0) {
    final sep = lastComma >= 0 ? lastComma : lastDot;
    final tail = s.substring(sep + 1);
    final sepChar = s[sep];
    final occurrences = sepChar.allMatches(s).length;
    // "45.000" / "1.234.567" are thousands; "12,50" / "12.5" are decimals.
    if (occurrences == 1 && tail.length != 3) {
      intPart = s.substring(0, sep);
      frac = tail;
    } else {
      intPart = s.replaceAll(sepChar, '');
    }
  }
  if (intPart.isEmpty) intPart = '0';
  frac = frac.replaceFirst(RegExp(r'0+$'), '');
  if (frac.length > decimals) return null;
  final digits = intPart + frac.padRight(decimals, '0');
  if (digits.length > 16) return null;
  final v = int.tryParse(digits);
  if (v == null) return null;
  return ParsedAmount(v, negative: negative);
}
