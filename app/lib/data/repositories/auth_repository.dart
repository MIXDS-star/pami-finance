import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/env.dart';
import 'guard.dart';

class AuthRepository {
  AuthRepository(this._client);
  final SupabaseClient _client;

  GoTrueClient get _auth => _client.auth;

  Session? get session => _auth.currentSession;
  User? get user => _auth.currentUser;
  Stream<AuthState> get changes => _auth.onAuthStateChange;

  /// Returns true when a session was created right away (e-mail confirmation
  /// disabled), false when the person must confirm the address first.
  Future<bool> signUp({required String email, required String password, required String displayName}) => guard(() async {
        final res = await _auth.signUp(
          email: email.trim(),
          password: password,
          data: {'display_name': displayName.trim()},
          emailRedirectTo: Env.authRedirect,
        );
        return res.session != null;
      });

  Future<void> signIn(String email, String password) =>
      guard(() => _auth.signInWithPassword(email: email.trim(), password: password));

  Future<void> resendConfirmation(String email) =>
      guard(() => _auth.resend(type: OtpType.signup, email: email.trim(), emailRedirectTo: Env.authRedirect));

  Future<void> sendPasswordReset(String email) =>
      guard(() => _auth.resetPasswordForEmail(email.trim(), redirectTo: Env.authRedirect));

  Future<void> updatePassword(String password) => guard(() => _auth.updateUser(UserAttributes(password: password)));

  /// [everywhere]: also closes the sessions on every other device.
  Future<void> signOut({bool everywhere = false}) =>
      guard(() => _auth.signOut(scope: everywhere ? SignOutScope.global : SignOutScope.local));

  Future<void> signOutOtherDevices() => guard(() => _auth.signOut(scope: SignOutScope.others));

  Future<bool> signInWithProvider(OAuthProvider provider) =>
      guard(() => _auth.signInWithOAuth(provider, redirectTo: Env.authRedirect));
}
