import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/auth_screens.dart';
import '../../features/capture/import_screen.dart';
import '../../features/capture/receipt_capture_screen.dart';
import '../../features/capture/text_capture_screen.dart';
import '../../features/capture/voice_capture_screen.dart';
import '../../features/copilot/copilot_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/movements/movements_screen.dart';
import '../../features/movements/transaction_detail_screen.dart';
import '../../features/movements/transaction_editor_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/plan/budget_editor_screen.dart';
import '../../features/plan/education_screen.dart';
import '../../features/plan/goal_screens.dart';
import '../../features/plan/plan_screen.dart';
import '../../features/plan/recurring_editor_screen.dart';
import '../../features/plan/report_screens.dart';
import '../../features/profile/notifications_screen.dart';
import '../../features/profile/profile_screens.dart';
import '../../features/shell/app_shell.dart';
import '../../features/spaces/accept_invite_screen.dart';
import '../../features/spaces/space_detail_screen.dart';
import '../../features/spaces/spaces_screen.dart';
import '../../features/stats/stats_screen.dart';
import '../finance/expense_draft.dart';
import '../providers.dart';

const authRoutes = {'/welcome', '/sign-in', '/sign-up', '/forgot-password', '/verify-email'};

/// Set when the person opens a password-recovery link.
class RecoveryPending extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

final recoveryPendingProvider = NotifierProvider<RecoveryPending, bool>(RecoveryPending.new);

/// Invitation opened before signing in; consumed after authentication.
class PendingInvite extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? token) => state = token;
}

final pendingInviteProvider = NotifierProvider<PendingInvite, String?>(PendingInvite.new);

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.listen(authStateProvider, (_, next) {
    if (next.value?.event == AuthChangeEvent.passwordRecovery) ref.read(recoveryPendingProvider.notifier).set(true);
    refresh.value++;
  });
  ref.listen(preferencesProvider, (_, _) => refresh.value++);
  ref.listen(recoveryPendingProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  final shellKey = GlobalKey<NavigatorState>(debugLabel: 'root');

  return GoRouter(
    navigatorKey: shellKey,
    initialLocation: '/home',
    refreshListenable: refresh,
    debugLogDiagnostics: kDebugMode,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final loggedIn = ref.read(authRepositoryProvider).session != null;
      if (loc.startsWith('/invite/')) {
        if (!loggedIn) {
          ref.read(pendingInviteProvider.notifier).set(state.pathParameters['token']);
          return '/welcome';
        }
        return null;
      }
      if (!loggedIn) return authRoutes.contains(loc) ? null : '/welcome';
      if (ref.read(recoveryPendingProvider)) return loc == '/reset-password' ? null : '/reset-password';
      final prefs = ref.read(preferencesProvider);
      final onboarded = prefs.value?.onboardingCompleted;
      if (onboarded == false && loc != '/onboarding') return '/onboarding';
      final invite = ref.read(pendingInviteProvider);
      if (onboarded == true && invite != null) {
        ref.read(pendingInviteProvider.notifier).set(null);
        return '/invite/$invite';
      }
      if (authRoutes.contains(loc)) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/welcome', builder: (_, _) => const WelcomeScreen()),
      GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
      GoRoute(path: '/sign-up', builder: (_, _) => const SignUpScreen()),
      GoRoute(path: '/forgot-password', builder: (_, _) => const ForgotPasswordScreen()),
      GoRoute(path: '/verify-email', builder: (_, s) => VerifyEmailScreen(email: s.uri.queryParameters['email'] ?? '')),
      GoRoute(path: '/reset-password', builder: (_, _) => const ResetPasswordScreen()),
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      GoRoute(path: '/invite/:token', builder: (_, s) => AcceptInviteScreen(token: s.pathParameters['token']!)),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/movements',
              builder: (_, s) => MovementsScreen(
                initialCategoryId: s.uri.queryParameters['category'],
                initialWorkspaceId: s.uri.queryParameters['workspace'],
              ),
            ),
          ]),
          StatefulShellBranch(routes: [GoRoute(path: '/spaces', builder: (_, _) => const SpacesScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/plan', builder: (_, _) => const PlanScreen())]),
        ],
      ),
      GoRoute(path: '/tx/new', builder: (_, s) => TransactionEditorScreen(initialDraft: s.extra as ExpenseDraft?,
          kind: s.uri.queryParameters['kind'], workspaceId: s.uri.queryParameters['workspace'])),
      GoRoute(path: '/tx/:id', builder: (_, s) => TransactionDetailScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/tx/:id/edit', builder: (_, s) => TransactionEditorScreen(editId: s.pathParameters['id']!)),
      GoRoute(path: '/capture/text', builder: (_, _) => const TextCaptureScreen()),
      GoRoute(path: '/capture/voice', builder: (_, _) => const VoiceCaptureScreen()),
      GoRoute(path: '/capture/text-from-voice', builder: (_, s) => VoiceTranscriptScreen(text: s.extra as String? ?? '')),
      GoRoute(path: '/capture/receipt', builder: (_, s) => ReceiptCaptureScreen(source: s.uri.queryParameters['source'])),
      GoRoute(path: '/import', builder: (_, _) => const ImportScreen()),
      GoRoute(path: '/spaces/:id', builder: (_, s) => SpaceDetailScreen(id: s.pathParameters['id']!,
          initialTab: int.tryParse(s.uri.queryParameters['tab'] ?? '') ?? 0)),
      GoRoute(path: '/plan/budget', builder: (_, s) => BudgetEditorScreen(budgetId: s.uri.queryParameters['id'])),
      GoRoute(path: '/plan/goal/new', builder: (_, _) => const GoalEditorScreen()),
      GoRoute(path: '/plan/goal/:id', builder: (_, s) => GoalDetailScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/plan/goal/:id/edit', builder: (_, s) => GoalEditorScreen(goalId: s.pathParameters['id'])),
      GoRoute(path: '/plan/recurring', builder: (_, s) => RecurringEditorScreen(ruleId: s.uri.queryParameters['id'])),
      GoRoute(path: '/plan/reports', builder: (_, _) => const ReportsScreen()),
      GoRoute(path: '/plan/reports/:id', builder: (_, s) => ReportDetailScreen(id: s.pathParameters['id']!)),
      GoRoute(path: '/plan/education', builder: (_, _) => const EducationScreen()),
      GoRoute(path: '/stats', builder: (_, _) => const StatsScreen()),
      GoRoute(path: '/copilot', builder: (_, s) => CopilotScreen(initialQuestion: s.extra as String?)),
      GoRoute(path: '/notifications', builder: (_, _) => const NotificationsScreen()),
      GoRoute(path: '/profile', builder: (_, _) => const ProfileScreen()),
      GoRoute(path: '/profile/accounts', builder: (_, _) => const AccountsScreen()),
      GoRoute(path: '/profile/preferences', builder: (_, _) => const PreferencesScreen()),
      GoRoute(path: '/profile/notifications', builder: (_, _) => const NotificationSettingsScreen()),
      GoRoute(path: '/profile/security', builder: (_, _) => const SecurityScreen()),
      GoRoute(path: '/profile/data', builder: (_, _) => const DataPrivacyScreen()),
      GoRoute(path: '/profile/ai', builder: (_, _) => const AiStatusScreen()),
    ],
  );
});
