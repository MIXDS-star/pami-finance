/// Build-time configuration, injected with --dart-define / --dart-define-from-file.
/// Only PUBLIC values belong here (the anon key is public by design and is
/// protected by RLS). Provider secrets live in Edge Function secrets only.
library;

class Env {
  const Env._();

  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// development | staging | production
  static const flavor = String.fromEnvironment('APP_FLAVOR', defaultValue: 'development');

  /// The Docker-less local stack has no Realtime server.
  static const realtimeEnabled = bool.fromEnvironment('REALTIME_ENABLED', defaultValue: true);

  /// Deep link used by e-mail confirmation, password recovery and invites.
  static const authRedirect = String.fromEnvironment('AUTH_REDIRECT_URL', defaultValue: 'co.pamifinance://auth-callback');
  static const inviteBaseUrl = String.fromEnvironment('INVITE_BASE_URL', defaultValue: 'co.pamifinance://invite');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
  static bool get isProduction => flavor == 'production';
}
