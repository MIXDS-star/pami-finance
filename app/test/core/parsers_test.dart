import 'package:flutter_test/flutter_test.dart';
import 'package:pami_finance/core/finance/csv_export.dart';
import 'package:pami_finance/core/finance/import_parser.dart';
import 'package:pami_finance/core/finance/local_parser.dart';
import 'package:pami_finance/core/finance/projections.dart';

void main() {
  final today = DateTime(2026, 10, 21); // a Wednesday
  const home = ParseWorkspace(id: 'casa', name: 'Casa', kind: 'household', members: [
    ParseMember(id: 'ana', name: 'Ana', isMe: true),
    ParseMember(id: 'bruno', name: 'Bruno Díaz', isMe: false),
  ]);
  const personal = ParseWorkspace(id: 'p', name: 'Personal', kind: 'personal', members: [ParseMember(id: 'ana', name: 'Ana', isMe: true)]);

  group('local Spanish interpreter', () {
    test('spec example: mercado 280.000, tarjeta, para mi casa', () {
      final r = parseExpenseText('Compré mercado por 280.000 pesos, pagué con mi tarjeta y es para mi casa',
          today: today, workspaces: [personal, home]);
      expect(r.amountMinor, 280000);
      expect(r.categoryKey, 'groceries');
      expect(r.description, 'Mercado');
      expect(r.workspaceId, 'casa');
      expect(r.payerId, 'ana');
      expect(r.date, today);
      expect(r.ambiguities.join(), contains('débito o crédito'), reason: '"tarjeta" alone is ambiguous');
    });
    test('amount words', () {
      expect(extractCopAmounts('almuerzo 25 mil'), [25000]);
      expect(extractCopAmounts('arriendo 1,2 millones'), [1200000]);
      expect(extractCopAmounts(r'pagué $45.500'), [45500]);
      expect(extractCopAmounts('el 15 compré 2 cosas'), isEmpty, reason: 'small bare numbers are not amounts');
      expect(extractCopAmounts('45k de gasolina'), [45000]);
    });
    test('corrections take the last value', () {
      final r = parseExpenseText('Taxi 30 mil, no, eran 35 mil', today: today, workspaces: [personal]);
      expect(r.amountMinor, 35000);
      expect(r.categoryKey, 'transport');
    });
    test('relative dates', () {
      expect(parseExpenseText('cena ayer 80 mil', today: today, workspaces: [personal]).date, DateTime(2026, 10, 20));
      expect(parseExpenseText('cena anteayer 80 mil', today: today, workspaces: [personal]).date, DateTime(2026, 10, 19));
      expect(parseExpenseText('cine el lunes 40 mil', today: today, workspaces: [personal]).date, DateTime(2026, 10, 19));
      expect(parseExpenseText('regalo el 3 de diciembre 50 mil', today: today, workspaces: [personal]).date, DateTime(2025, 12, 3),
          reason: 'a future day without a year means last year');
    });
    test('people and payer in shared spaces', () {
      final r = parseExpenseText('almuerzo con Bruno 64 mil en la casa, pagó Bruno', today: today, workspaces: [personal, home]);
      expect(r.workspaceId, 'casa');
      expect(r.payerId, 'bruno');
      expect(r.participantIds.toSet(), {'ana', 'bruno'});
    });
    test('missing amount is reported, never invented', () {
      final r = parseExpenseText('compré algo para la casa', today: today, workspaces: [personal, home]);
      expect(r.amountMinor, isNull);
      expect(r.missing, contains('amount'));
    });
  });

  group('import parsing', () {
    test('CSV with semicolons, quotes and BOM', () {
      final rows = parseCsv('﻿Fecha;Descripción;Valor\n21/10/2026;"Éxito; calle 80";-280.000\n22/10/2026;Nómina;3.500.000,00\n');
      expect(rows, hasLength(3));
      expect(rows[1], ['21/10/2026', 'Éxito; calle 80', '-280.000']);
      expect(guessColumns(rows.first), {0: ImportField.date, 1: ImportField.description, 2: ImportField.amount});
    });
    test('dates', () {
      expect(parseImportDate('2026-10-21'), DateTime(2026, 10, 21));
      expect(parseImportDate('21/10/2026'), DateTime(2026, 10, 21));
      expect(parseImportDate('21-10-26'), DateTime(2026, 10, 21));
      expect(parseImportDate('31/02/2026'), isNull);
    });
    test('amounts for COP never round centavos away', () {
      expect(parseImportAmount('-280.000', 0)!.minor, 280000);
      expect(parseImportAmount('-280.000', 0)!.negative, isTrue);
      expect(parseImportAmount('3.500.000,00', 0)!.minor, 3500000);
      expect(parseImportAmount('(45.000)', 0)!.negative, isTrue);
      expect(parseImportAmount('1.234,56', 0), isNull, reason: 'non-zero centavos in COP are rejected');
      expect(parseImportAmount('1,234.56', 2)!.minor, 123456);
      expect(parseImportAmount('12,5', 2)!.minor, 1250);
      expect(parseImportAmount('abc', 0), isNull);
    });
  });

  group('CSV export', () {
    test('documents the money format and escapes cells', () {
      final csv = buildMovementsCsv([
        const ExportRow(date: '2026-10-21', kind: 'expense', workspace: 'Casa', description: 'Mercado, semana', currency: 'COP',
            totalMinor: 300000, myShareMinor: 155000, paidByMeMinor: 300000, notes: '=HYPERLINK("x")'),
      ], includeNotes: true);
      expect(csv, contains('unidad mínima'));
      expect(csv, contains('"Mercado, semana"'));
      expect(csv, contains(',300000,155000,300000,'));
      expect(csv, contains("'=HYPERLINK"), reason: 'formula injection is neutralised');
    });
  });

  group('projections', () {
    test('no return, no inflation = plain sum', () {
      final p = projectSavings(monthlyMinor: 500000, months: 12);
      expect(p.nominalMinor, 6000000);
      expect(p.realMinor, 6000000);
    });
    test('inflation lowers real value; returns raise nominal', () {
      final p = projectSavings(monthlyMinor: 100000, months: 60, annualRateBp: 900, annualInflationBp: 500);
      expect(p.nominalMinor, greaterThan(p.contributedMinor));
      expect(p.realMinor, lessThan(p.nominalMinor));
    });
    test('months to target and 50/30/20 add up exactly', () {
      expect(monthsToTarget(targetMinor: 3000000, savedMinor: 1000000, monthlyMinor: 300000), 7);
      expect(monthsToTarget(targetMinor: 1, savedMinor: 0, monthlyMinor: 0), isNull);
      final r = rule503020(3333333);
      expect(r.needs + r.wants + r.savings, 3333333);
    });
    test('scenario names describe contribution levels', () {
      expect(scenarioContribution(SavingScenario.ambitious, 1000000), 800000);
      expect(scenarioContribution(SavingScenario.conservative, -5), 0);
    });
  });
}
