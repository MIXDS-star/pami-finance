import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pami_finance/core/drafts/draft_store.dart';
import 'package:pami_finance/core/finance/balances.dart';
import 'package:pami_finance/core/finance/expense_draft.dart';
import 'package:pami_finance/core/money/money.dart';
import 'package:pami_finance/core/providers.dart';
import 'package:pami_finance/core/theme/theme.dart';
import 'package:pami_finance/data/models.dart';
import 'package:pami_finance/data/repositories/ai_repository.dart';
import 'package:pami_finance/data/repositories/analytics_repository.dart';
import 'package:pami_finance/data/repositories/catalog_repository.dart';
import 'package:pami_finance/data/repositories/notification_repository.dart';
import 'package:pami_finance/data/repositories/plan_repository.dart';
import 'package:pami_finance/data/repositories/profile_repository.dart';
import 'package:pami_finance/data/repositories/transaction_repository.dart';
import 'package:pami_finance/data/repositories/workspace_repository.dart';

const me = 'ana';
const bruno = 'bruno';

final personal = Workspace(id: 'p', kind: WorkspaceKind.personal, name: 'Personal', baseCurrency: Currency.cop,
    defaultSplit: const {'method': 'single'}, version: 1, createdBy: me, myRole: MemberRole.owner);
final casa = Workspace(id: 'casa', kind: WorkspaceKind.household, name: 'Casa', baseCurrency: Currency.cop,
    defaultSplit: const {'method': 'equal'}, version: 1, createdBy: me, myRole: MemberRole.owner);

final testMembers = {
  'p': [const Member(userId: me, role: MemberRole.owner, active: true, displayName: 'Ana')],
  'casa': [
    const Member(userId: me, role: MemberRole.owner, active: true, displayName: 'Ana'),
    const Member(userId: bruno, role: MemberRole.member, active: true, displayName: 'Bruno'),
  ],
};

final groceries = Category.fromJson({'id': 'cat-g', 'kind': 'expense', 'name': 'Mercado', 'icon': 'shopping_basket',
  'color': '#2E8B6E', 'system_key': 'groceries', 'workspace_id': null, 'budget_bucket': 'needs'});

class FakeWorkspaces extends Fake implements WorkspaceRepository {
  List<MemberBalance> balanceRows = [];
  final recorded = <Map<String, dynamic>>[];
  @override
  Future<List<Workspace>> list() async => [personal, casa];
  @override
  Future<List<Member>> members(String workspaceId) async => testMembers[workspaceId] ?? [];
  @override
  Future<List<MemberBalance>> balances(String workspaceId) async => balanceRows;
  @override
  Future<List<Settlement>> settlements(String workspaceId) async => [];
  @override
  Future<List<Invitation>> invitations(String workspaceId) async => [];
  @override
  Future<void> recordSettlement(Map<String, dynamic> payload) async => recorded.add(payload);
}

class FakeTransactions extends Fake implements TransactionRepository {
  final saved = <ExpenseDraft>[];
  List<Transaction> rows = [];
  @override
  Future<List<Transaction>> list(TransactionFilter f, {int limit = 200, bool includeDeleted = false}) async => rows;
  @override
  Future<({String id, int version, bool replayed})> save(ExpenseDraft draft) async {
    saved.add(draft);
    return (id: 'tx-1', version: 1, replayed: false);
  }

  @override
  Future<List<Map<String, dynamic>>> possibleDuplicates({required String workspaceId, required int totalMinor, required DateTime date,
          String? merchant, String? invoiceNumber, String? excludeId}) async => [];
  @override
  Future<Transaction?> get(String id) async => rows.where((t) => t.id == id).firstOrNull;
  @override
  Future<List<AuditEvent>> history(String transactionId) async => [];
}

class FakeCatalog extends Fake implements CatalogRepository {
  @override
  Future<List<Category>> categories() async => [groceries];
  @override
  Future<List<Account>> accounts({bool includeArchived = false}) async => [];
  @override
  Future<Map<String, int>> accountBalances() async => {};
}

class FakeAnalytics extends Fake implements AnalyticsRepository {
  @override
  Future<PeriodSummary> summary(DateTime from, DateTime to, String currency) async => PeriodSummary.fromJson({
        'income_minor': 4000000, 'expense_assigned_minor': 350000, 'expense_personal_minor': 200000,
        'expense_shared_assigned_minor': 150000, 'paid_minor': 500000, 'net_savings_minor': 3650000, 'savings_rate_bp': 9125,
        'counts': {'expenses': 2, 'incomes': 1}, 'data_quality': {'period_complete': false}, 'formulas': {'net_savings': 'Ingresos − gasto'},
      });
  @override
  Future<List<CategorySpend>> byCategory(DateTime from, DateTime to, String currency, {String? workspaceId}) async => [
        CategorySpend.fromJson({'category_id': 'cat-g', 'category_name': 'Mercado', 'color': '#2E8B6E', 'icon': 'shopping_basket',
          'amount_minor': 350000, 'tx_count': 2}),
      ];
  @override
  Future<List<TrendPoint>> trend(int months, String currency) async => [
        for (var i = 0; i < months; i++)
          TrendPoint.fromJson({'month': '2026-${(i % 12 + 1).toString().padLeft(2, '0')}-01', 'income_minor': 4000000, 'expense_assigned_minor': 350000 * (i + 1)}),
      ];
  @override
  Future<List<MerchantSpend>> topMerchants(DateTime from, DateTime to, String currency) async =>
      [MerchantSpend.fromJson({'merchant': 'Éxito', 'amount_minor': 350000, 'tx_count': 2})];
}

class FakePlan extends Fake implements PlanRepository {
  @override
  Future<List<BudgetStatus>> budgetStatus(DateTime month) async => [];
  @override
  Future<List<Occurrence>> upcoming(DateTime from, DateTime to) async => [];
  @override
  Future<List<Goal>> goals() async => [];
  @override
  Future<List<GoalProgress>> goalProgress() async => [];
}

class FakeAi extends Fake implements AiRepository {
  FakeAi([this.caps = const AiCapabilities()]);
  final AiCapabilities caps;
  @override
  Future<AiCapabilities> status() async => caps;
}

class FakeNotifications extends Fake implements NotificationRepository {
  @override
  Future<List<AppNotification>> list() async => [];
}

class FakeProfiles extends Fake implements ProfileRepository {
  @override
  Future<Profile> me() async => const Profile(id: 'ana', displayName: 'Ana Gómez');
  @override
  Future<Preferences> preferences() async => Preferences.fromJson({
        'country_code': 'CO', 'default_currency': 'COP', 'timezone': 'America/Bogota', 'theme': 'system',
        'onboarding_completed_at': '2026-10-01T00:00:00Z', 'notification_settings': <String, dynamic>{},
      });
}

class Fakes {
  final workspaces = FakeWorkspaces();
  final transactions = FakeTransactions();
  AiCapabilities ai = const AiCapabilities();

  List<dynamic> get overrides => [
        currentUserIdProvider.overrideWithValue(me),
        authStateProvider.overrideWith((ref) => const Stream.empty()),
        workspaceRepositoryProvider.overrideWithValue(workspaces),
        transactionRepositoryProvider.overrideWithValue(transactions),
        catalogRepositoryProvider.overrideWithValue(FakeCatalog()),
        analyticsRepositoryProvider.overrideWithValue(FakeAnalytics()),
        planRepositoryProvider.overrideWithValue(FakePlan()),
        aiRepositoryProvider.overrideWithValue(FakeAi(ai)),
        notificationRepositoryProvider.overrideWithValue(FakeNotifications()),
        profileRepositoryProvider.overrideWithValue(FakeProfiles()),
        connectivityProvider.overrideWith((ref) => Stream.value(true)),
        secureKeyValueProvider.overrideWithValue(MemoryKeyValue()),
      ];
}

/// Pumps [home] at [initial] inside a router with stub targets, so screens
/// that navigate after saving can be exercised.
Future<GoRouter> pumpApp(WidgetTester tester, Fakes fakes, Widget Function(GoRouterState) home,
    {String initial = '/', Brightness brightness = Brightness.light, Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final router = GoRouter(initialLocation: initial, routes: [
    GoRoute(path: '/', builder: (_, s) => home(s)),
    GoRoute(path: '/tx/:id', builder: (_, s) => Scaffold(body: Text('detalle ${s.pathParameters['id']}'))),
  ]);
  await tester.pumpWidget(ProviderScope(
    overrides: fakes.overrides.cast(),
    retry: (_, _) => null,
    child: MaterialApp.router(
      routerConfig: router,
      theme: buildTheme(brightness),
      locale: const Locale('es', 'CO'),
      supportedLocales: const [Locale('es', 'CO')],
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
    ),
  ));
  await tester.pumpAndSettle();
  return router;
}
