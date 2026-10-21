import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/finance/balances.dart';
import '../models.dart';
import 'guard.dart';

class WorkspaceRepository {
  WorkspaceRepository(this._client);
  final SupabaseClient _client;

  String get _uid => _client.auth.currentUser!.id;

  Future<List<Workspace>> list() => guard(() async {
        final rows = await _client
            .from('workspace_members')
            .select('role, workspaces(*)')
            .eq('user_id', _uid)
            .eq('status', 'active');
        final list = [
          for (final r in rows)
            Workspace.fromJson(r['workspaces'] as Map<String, dynamic>, myRole: MemberRole.values.byName(r['role'] as String)),
        ]..sort((a, b) {
            if (a.isPersonal != b.isPersonal) return a.isPersonal ? -1 : 1;
            if (a.archived != b.archived) return a.archived ? 1 : -1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
        return list;
      });

  /// All members, including people who left (their history stays readable).
  Future<List<Member>> members(String workspaceId) => guard(() async {
        final rows = await _client
            .from('workspace_members')
            .select('user_id, role, status, joined_at')
            .eq('workspace_id', workspaceId)
            .order('joined_at');
        final ids = rows.map((r) => r['user_id'] as String).toList();
        final profiles = ids.isEmpty
            ? const <Map<String, dynamic>>[]
            : await _client.from('profiles').select('id, display_name').inFilter('id', ids);
        final names = {for (final p in profiles) p['id'] as String: p['display_name'] as String};
        return [
          for (final r in rows)
            Member(
              userId: r['user_id'] as String,
              role: MemberRole.values.byName(r['role'] as String),
              active: r['status'] == 'active',
              displayName: names[r['user_id']] ?? 'Miembro',
              joinedAt: DateTime.tryParse(r['joined_at'] as String? ?? ''),
            ),
        ];
      });

  Future<String> create(String name, WorkspaceKind kind, String currency) => guard(() async =>
      await _client.rpc('create_workspace', params: {'p_name': name.trim(), 'p_kind': kind.name, 'p_currency': currency}) as String);

  Future<void> update(Workspace w, {String? name, Map<String, dynamic>? defaultSplit}) => guard(() => _client.rpc(
      'update_workspace',
      params: {'p_workspace': w.id, 'p_expected_version': w.version, 'p_name': name, 'p_default_split': defaultSplit}));

  Future<void> setCurrency(String workspaceId, String currency) =>
      guard(() => _client.rpc('set_workspace_currency', params: {'p_workspace': workspaceId, 'p_currency': currency}));

  Future<void> archive(String workspaceId) => guard(() => _client.rpc('archive_workspace', params: {'p_workspace': workspaceId}));

  Future<({String token, DateTime expiresAt})> invite(String workspaceId, MemberRole role, {String? email}) => guard(() async {
        final r = Map<String, dynamic>.from(await _client.rpc('create_invitation',
            params: {'p_workspace': workspaceId, 'p_role': role.name, 'p_email': email}) as Map);
        return (token: r['token'] as String, expiresAt: DateTime.parse(r['expires_at'] as String).toLocal());
      });

  Future<List<Invitation>> invitations(String workspaceId) => guard(() async {
        final rows = await _client.from('workspace_invitations').select().eq('workspace_id', workspaceId).order('created_at', ascending: false);
        return rows.map(Invitation.fromJson).toList();
      });

  Future<void> revokeInvitation(String id) => guard(() => _client.rpc('revoke_invitation', params: {'p_invitation': id}));

  Future<Map<String, dynamic>> previewInvitation(String token) =>
      guard(() async => Map<String, dynamic>.from(await _client.rpc('preview_invitation', params: {'p_token': token}) as Map));

  Future<String> acceptInvitation(String token) =>
      guard(() async => await _client.rpc('accept_invitation', params: {'p_token': token}) as String);

  Future<void> declineInvitation(String token) => guard(() => _client.rpc('decline_invitation', params: {'p_token': token}));

  Future<void> leave(String workspaceId) => guard(() => _client.rpc('leave_workspace', params: {'p_workspace': workspaceId}));

  Future<void> changeRole(String workspaceId, String userId, MemberRole role) => guard(() =>
      _client.rpc('change_member_role', params: {'p_workspace': workspaceId, 'p_user': userId, 'p_role': role.name}));

  Future<void> removeMember(String workspaceId, String userId) =>
      guard(() => _client.rpc('remove_member', params: {'p_workspace': workspaceId, 'p_user': userId}));

  Future<void> transferOwnership(String workspaceId, String userId) =>
      guard(() => _client.rpc('transfer_ownership', params: {'p_workspace': workspaceId, 'p_user': userId}));

  Future<List<MemberBalance>> balances(String workspaceId) => guard(() async {
        final rows = await _client.rpc('workspace_balances', params: {'p_workspace': workspaceId}) as List;
        return rows.map((r) => MemberBalance.fromJson(r as Map<String, dynamic>)).toList();
      });

  Future<List<Settlement>> settlements(String workspaceId) => guard(() async {
        final rows = await _client
            .from('settlements')
            .select()
            .eq('workspace_id', workspaceId)
            .isFilter('deleted_at', null)
            .order('occurred_on', ascending: false)
            .order('created_at', ascending: false);
        return rows.map(Settlement.fromJson).toList();
      });

  Future<void> recordSettlement(Map<String, dynamic> payload) =>
      guard(() => _client.rpc('record_settlement', params: {'p': payload}));

  Future<void> deleteSettlement(Settlement s) =>
      guard(() => _client.rpc('delete_settlement', params: {'p_id': s.id, 'p_expected_version': s.version}));
}
