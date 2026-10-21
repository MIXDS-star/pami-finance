import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import 'guard.dart';

class ProfileRepository {
  ProfileRepository(this._client);
  final SupabaseClient _client;

  String get _uid => _client.auth.currentUser!.id;

  Future<Profile> me() => guard(() async =>
      Profile.fromJson(await _client.from('profiles').select('id, display_name, deleted_at').eq('id', _uid).single()));

  Future<Preferences> preferences() => guard(() async =>
      Preferences.fromJson(await _client.from('user_preferences').select().eq('user_id', _uid).single()));

  Future<void> updateName(String name) =>
      guard(() => _client.from('profiles').update({'display_name': name.trim()}).eq('id', _uid));

  Future<void> updatePreferences(Map<String, dynamic> values) =>
      guard(() => _client.from('user_preferences').update(values).eq('user_id', _uid));

  Future<void> completeOnboarding() => updatePreferences({'onboarding_completed_at': DateTime.now().toUtc().toIso8601String()});

  Future<Map<String, dynamic>> exportData() =>
      guard(() async => Map<String, dynamic>.from(await _client.rpc('export_my_data') as Map));

  Future<void> deleteAccount() => guard(() => _client.functions.invoke('delete-account', body: {'confirm': 'ELIMINAR'}));
}
