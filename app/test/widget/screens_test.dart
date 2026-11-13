import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pami_finance/core/finance/balances.dart';
import 'package:pami_finance/core/finance/split_rules.dart';
import 'package:pami_finance/data/models.dart';
import 'package:pami_finance/data/repositories/ai_repository.dart';
import 'package:pami_finance/features/copilot/copilot_screen.dart';
import 'package:pami_finance/features/home/home_screen.dart';
import 'package:pami_finance/features/movements/movements_screen.dart';
import 'package:pami_finance/features/movements/transaction_editor_screen.dart';
import 'package:pami_finance/features/spaces/space_detail_screen.dart';
import 'package:pami_finance/features/stats/stats_screen.dart';

import 'fakes.dart';

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.dragUntilVisible(f, find.byType(ListView).first, const Offset(0, -250));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('manual shared expense: equal split preview and balanced payload', (tester) async {
    final fakes = Fakes();
    await pumpApp(tester, fakes, (_) => const TransactionEditorScreen(workspaceId: 'casa'));

    await tester.enterText(find.widgetWithText(TextFormField, 'Total pagado'), '64000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Concepto'), 'Almuerzo');
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('Bruno').last);
    expect(find.text(r'$ 32.000'), findsNWidgets(2), reason: 'each person sees their share before saving');

    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();

    final d = fakes.transactions.saved.single;
    final p = d.toPayload();
    expect(p['workspace_id'], 'casa');
    expect(p['total_minor'], 64000);
    expect(p['payments'], [{'payer_id': me, 'amount_minor': 64000}]);
    expect((p['splits'] as List).fold<int>(0, (a, s) => a + ((s as Map)['amount_minor'] as int)), 64000);
    expect(find.text('detalle tx-1'), findsOneWidget, reason: 'after saving it opens the stored movement');
  });

  testWidgets('saving is blocked with a clear message when the amount is missing', (tester) async {
    final fakes = Fakes();
    await pumpApp(tester, fakes, (_) => const TransactionEditorScreen());
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.text('Revisa antes de guardar'), findsOneWidget);
    expect(find.text('Indica un importe mayor que cero.'), findsOneWidget);
    expect(fakes.transactions.saved, isEmpty);
  });

  testWidgets('receipt lines show the exact difference and an explicit adjustment fixes it', (tester) async {
    final fakes = Fakes();
    await pumpApp(tester, fakes, (_) => const TransactionEditorScreen(workspaceId: 'casa'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Total pagado'), '100000');
    await tester.enterText(find.widgetWithText(TextFormField, 'Concepto'), 'Mercado');
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('Detallar'));
    await tester.tap(find.text('Detallar'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('Añadir línea'));
    await tester.tap(find.text('Añadir línea'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Descripción'), 'Leche');
    await tester.enterText(find.widgetWithText(TextFormField, 'Valor de la línea'), '95000');
    await tester.tap(find.text('Listo'));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.textContaining('Diferencia de'));
    expect(find.textContaining(r'Diferencia de +$ 5.000'), findsOneWidget);
    await scrollTo(tester, find.textContaining('Añadir ajuste'));
    await tester.tap(find.textContaining('Añadir ajuste'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('La factura cuadra con el total pagado.'));
    expect(find.text('La factura cuadra con el total pagado.'), findsOneWidget);
  });

  testWidgets('balances suggest who pays whom and record a partial reimbursement', (tester) async {
    final fakes = Fakes();
    fakes.workspaces.balanceRows = [
      const MemberBalance(userId: me, currency: 'COP', paidMinor: 300000, assignedMinor: 155000, sentMinor: 0, receivedMinor: 0, netMinor: 145000),
      const MemberBalance(userId: bruno, currency: 'COP', paidMinor: 0, assignedMinor: 145000, sentMinor: 0, receivedMinor: 0, netMinor: -145000),
    ];
    await pumpApp(tester, fakes, (_) => const SpaceDetailScreen(id: 'casa', initialTab: 1));
    expect(find.text('Bruno debe a Tú'), findsOneWidget);
    await tester.tap(find.text('Registrar pago'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Importe pagado'), '45000');
    await tester.pumpAndSettle();
    expect(find.textContaining(r'quedarán $ 100.000 pendientes'), findsOneWidget);
    await tester.tap(find.text('Registrar'));
    await tester.pumpAndSettle();
    final p = fakes.workspaces.recorded.single;
    expect(p['from_user_id'], bruno);
    expect(p['to_user_id'], me);
    expect(p['amount_minor'], 45000);
    expect(p['client_request_id'], isNotEmpty);
  });

  testWidgets('movements empty state invites the first record', (tester) async {
    await pumpApp(tester, Fakes(), (_) => const MovementsScreen());
    expect(find.text('Sin movimientos en este periodo'), findsOneWidget);
  });

  testWidgets('shared expense row shows the user share, not the amount paid', (tester) async {
    final fakes = Fakes();
    fakes.transactions.rows = [
      Transaction.fromJson({
        'id': 't1', 'workspace_id': 'casa', 'kind': 'expense', 'description': 'Mercado', 'merchant': null,
        'occurred_on': '2026-10-21', 'currency': 'COP', 'total_minor': 300000, 'category_id': 'cat-g', 'split_method': 'by_item',
        'split_spec': {}, 'notes': null, 'source': 'receipt', 'account_id': null, 'to_account_id': null, 'created_by': me,
        'created_at': '2026-10-21T12:00:00Z', 'updated_at': '2026-10-21T12:00:00Z', 'deleted_at': null, 'version': 1,
        'transaction_payments': [{'payer_id': me, 'amount_minor': 300000}],
        'transaction_splits': [{'user_id': me, 'amount_minor': 155000}, {'user_id': bruno, 'amount_minor': 145000}],
      }),
    ];
    await pumpApp(tester, fakes, (_) => const MovementsScreen());
    expect(find.text(r'-$ 155.000'), findsOneWidget);
    expect(find.text(r'de $ 300.000'), findsOneWidget);
    expect(find.textContaining('pagaste tú'), findsOneWidget);
  });

  testWidgets('copilot shows an honest pending-configuration state', (tester) async {
    await pumpApp(tester, Fakes(), (_) => const CopilotScreen());
    expect(find.text('Copiloto no configurado'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: 'no input that pretends to work');
  });

  testWidgets('copilot input appears when the server has it configured', (tester) async {
    final fakes = Fakes()..ai = const AiCapabilities(copilot: true);
    await pumpApp(tester, fakes, (_) => const CopilotScreen());
    expect(find.byType(TextField), findsOneWidget);
  });

  for (final (name, size, brightness) in [
    ('small phone light', const Size(320, 568), Brightness.light),
    ('large phone dark', const Size(430, 932), Brightness.dark),
  ]) {
    testWidgets('home and stats render without overflow on $name', (tester) async {
      await pumpApp(tester, Fakes(), (_) => const HomeScreen(), size: size, brightness: brightness);
      expect(tester.takeException(), isNull);
      expect(find.text('Tu gasto del mes'), findsOneWidget);
      expect(find.text('91,3 %'), findsOneWidget);
      await pumpApp(tester, Fakes(), (_) => const StatsScreen(), size: size, brightness: brightness);
      expect(tester.takeException(), isNull);
      await scrollTo(tester, find.text('Ingresos frente a gastos'));
      expect(find.text('Ingresos frente a gastos'), findsOneWidget);
      await scrollTo(tester, find.text('Principales comercios'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('split editor keeps percentages honest', (tester) async {
    final fakes = Fakes();
    await pumpApp(tester, fakes, (_) => const TransactionEditorScreen(workspaceId: 'casa'));
    await tester.enterText(find.widgetWithText(TextFormField, 'Total pagado'), '100000');
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text(SplitMethod.percent.label));
    await tester.tap(find.text(SplitMethod.percent.label));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('Bruno').last);
    final boxes = find.widgetWithText(TextFormField, '%');
    await tester.enterText(boxes.first, '70');
    await tester.pumpAndSettle();
    expect(find.textContaining('deben sumar 100 %'), findsOneWidget);
    await tester.enterText(boxes.last, '30');
    await tester.pumpAndSettle();
    expect(find.textContaining('deben sumar 100 %'), findsNothing);
    expect(find.text(r'$ 70.000'), findsOneWidget);
  });

  test('workspace roles map to permissions', () {
    expect(MemberRole.viewer.canWrite, isFalse);
    expect(MemberRole.admin.canAdmin, isTrue);
  });
}
