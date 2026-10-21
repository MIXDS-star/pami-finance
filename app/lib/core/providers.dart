import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models.dart';
import '../data/repositories/ai_repository.dart';
import '../data/repositories/analytics_repository.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/catalog_repository.dart';
import '../data/repositories/notification_repository.dart';
import '../data/repositories/plan_repository.dart';
import '../data/repositories/profile_repository.dart';
import '../data/repositories/transaction_repository.dart';
import '../data/repositories/workspace_repository.dart';

/// Overridden in main() with the initialised client and in tests with fakes.
final supabaseClientProvider = Provider<SupabaseClient>((ref) => throw UnimplementedError('supabase client not configured'));

final authRepositoryProvider = Provider((ref) => AuthRepository(ref.watch(supabaseClientProvider)));
final profileRepositoryProvider = Provider((ref) => ProfileRepository(ref.watch(supabaseClientProvider)));
final workspaceRepositoryProvider = Provider((ref) => WorkspaceRepository(ref.watch(supabaseClientProvider)));
final catalogRepositoryProvider = Provider((ref) => CatalogRepository(ref.watch(supabaseClientProvider)));
final transactionRepositoryProvider = Provider((ref) => TransactionRepository(ref.watch(supabaseClientProvider)));
final planRepositoryProvider = Provider((ref) => PlanRepository(ref.watch(supabaseClientProvider)));
final analyticsRepositoryProvider = Provider((ref) => AnalyticsRepository(ref.watch(supabaseClientProvider)));
final aiRepositoryProvider = Provider((ref) => AiRepository(ref.watch(supabaseClientProvider)));
final notificationRepositoryProvider = Provider((ref) => NotificationRepository(ref.watch(supabaseClientProvider)));

/// Emits on sign-in, sign-out, token refresh and password recovery.
final authStateProvider = StreamProvider<AuthState>((ref) => ref.watch(authRepositoryProvider).changes);

final currentUserIdProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(authRepositoryProvider).user?.id;
});

/// Bumped after every confirmed write and on realtime events; everything
/// derived from the ledger watches it, so screens never show stale totals.
class LedgerRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final ledgerRevisionProvider = NotifierProvider<LedgerRevision, int>(LedgerRevision.new);

/// Bumped when memberships/workspaces change.
class SpacesRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final spacesRevisionProvider = NotifierProvider<SpacesRevision, int>(SpacesRevision.new);

final profileProvider = FutureProvider<Profile>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(profileRepositoryProvider).me();
});

final preferencesProvider = FutureProvider<Preferences>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(profileRepositoryProvider).preferences();
});

final workspacesProvider = FutureProvider<List<Workspace>>((ref) {
  ref.watch(currentUserIdProvider);
  ref.watch(spacesRevisionProvider);
  return ref.watch(workspaceRepositoryProvider).list();
});

final personalWorkspaceProvider = FutureProvider<Workspace>((ref) async {
  final list = await ref.watch(workspacesProvider.future);
  return list.firstWhere((w) => w.isPersonal);
});

final workspaceProvider = FutureProvider.family<Workspace?, String>((ref, id) async {
  final list = await ref.watch(workspacesProvider.future);
  return list.where((w) => w.id == id).firstOrNull;
});

final membersProvider = FutureProvider.family<List<Member>, String>((ref, workspaceId) {
  ref.watch(spacesRevisionProvider);
  return ref.watch(workspaceRepositoryProvider).members(workspaceId);
});

/// Display names for everyone the user can see (all their workspaces).
final peopleProvider = FutureProvider<Map<String, String>>((ref) async {
  final spaces = await ref.watch(workspacesProvider.future);
  final out = <String, String>{};
  for (final w in spaces) {
    for (final m in await ref.watch(membersProvider(w.id).future)) {
      out[m.userId] = m.displayName;
    }
  }
  return out;
});

final categoriesProvider = FutureProvider<List<Category>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(catalogRepositoryProvider).categories();
});

final accountsProvider = FutureProvider<List<Account>>((ref) {
  ref.watch(currentUserIdProvider);
  ref.watch(ledgerRevisionProvider);
  return ref.watch(catalogRepositoryProvider).accounts();
});

final aiCapabilitiesProvider = FutureProvider<AiCapabilities>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(aiRepositoryProvider).status();
});

final notificationsProvider = FutureProvider<List<AppNotification>>((ref) {
  ref.watch(currentUserIdProvider);
  ref.watch(ledgerRevisionProvider);
  return ref.watch(notificationRepositoryProvider).list();
});

/// true = some network interface is up (not a guarantee the server is reachable).
final connectivityProvider = StreamProvider<bool>((ref) async* {
  final c = Connectivity();
  bool online(List<ConnectivityResult> r) => r.any((x) => x != ConnectivityResult.none);
  try {
    yield online(await c.checkConnectivity());
  } catch (_) {
    yield true;
  }
  yield* c.onConnectivityChanged.map(online);
});

/// Month currently selected in Home / Movements / Plan.
class SelectedMonth extends Notifier<DateTime> {
  @override
  DateTime build() {
    final now = DateTime.now();
    return DateTime(now.year, now.month);
  }

  void set(DateTime month) => state = DateTime(month.year, month.month);
  void previous() => state = DateTime(state.year, state.month - 1);
  void next() => state = DateTime(state.year, state.month + 1);
}

final selectedMonthProvider = NotifierProvider<SelectedMonth, DateTime>(SelectedMonth.new);

DateTime monthEnd(DateTime month) => DateTime(month.year, month.month + 1, 0);
