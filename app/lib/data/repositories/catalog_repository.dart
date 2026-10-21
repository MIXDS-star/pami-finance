import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';
import 'guard.dart';

/// Categories and private accounts.
class CatalogRepository {
  CatalogRepository(this._client);
  final SupabaseClient _client;

  String get _uid => _client.auth.currentUser!.id;

  Future<List<Category>> categories() => guard(() async {
        final rows = await _client.from('categories').select().isFilter('archived_at', null).order('sort_order').order('name');
        return rows.map(Category.fromJson).toList();
      });

  Future<void> createCategory({required String workspaceId, required String name, required String kind, String icon = 'category',
          String color = '#6B7C78'}) =>
      guard(() => _client.from('categories').insert({
            'workspace_id': workspaceId, 'name': name.trim(), 'kind': kind, 'icon': icon, 'color': color, 'created_by': _uid,
          }));

  Future<List<Account>> accounts({bool includeArchived = false}) => guard(() async {
        var q = _client.from('accounts').select();
        if (!includeArchived) q = q.isFilter('archived_at', null);
        final rows = await q.order('created_at');
        return rows.map(Account.fromJson).toList();
      });

  Future<void> createAccount({required String name, required AccountType type, required String currency, int opening = 0,
          int? creditLimit}) =>
      guard(() => _client.from('accounts').insert({
            'owner_id': _uid, 'name': name.trim(), 'type': type.wire, 'currency': currency,
            'opening_balance_minor': opening, 'credit_limit_minor': creditLimit,
          }));

  Future<void> updateAccount(String id, Map<String, dynamic> values) => guard(() => _client.from('accounts').update(values).eq('id', id));

  /// Server-derived balances (single source of truth): accountId -> minor units.
  Future<Map<String, int>> accountBalances() => guard(() async {
        final rows = await _client.rpc('my_account_balances') as List;
        return {for (final r in rows) r['account_id'] as String: (r['balance_minor'] as num).toInt()};
      });
}
