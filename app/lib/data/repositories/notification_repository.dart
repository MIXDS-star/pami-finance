import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import 'guard.dart';

class NotificationRepository {
  NotificationRepository(this._client);
  final SupabaseClient _client;

  Future<List<AppNotification>> list() => guard(() async {
        final rows = await _client.from('notifications').select().order('created_at', ascending: false).limit(100);
        return rows.map(AppNotification.fromJson).toList();
      });

  Future<void> markRead(String id) =>
      guard(() => _client.from('notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id));

  Future<void> markAllRead() => guard(() => _client
      .from('notifications')
      .update({'read_at': DateTime.now().toUtc().toIso8601String()})
      .isFilter('read_at', null)
      .eq('user_id', _client.auth.currentUser!.id));
}
