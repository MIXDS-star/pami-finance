import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/finance/expense_draft.dart';
import '../../core/util/ids.dart';
import '../models.dart';
import 'guard.dart';

class TransactionFilter {
  const TransactionFilter({this.from, this.to, this.workspaceIds, this.categoryId, this.kind, this.search, this.onlyMine = false});
  final DateTime? from;
  final DateTime? to;
  final List<String>? workspaceIds;
  final String? categoryId;
  final String? kind;
  final String? search;

  /// Only expenses where the current user has an assigned share.
  final bool onlyMine;

  TransactionFilter copyWith({DateTime? from, DateTime? to, List<String>? workspaceIds, String? categoryId, String? kind,
          String? search, bool clearCategory = false, bool clearKind = false, bool clearWorkspaces = false}) =>
      TransactionFilter(
        from: from ?? this.from,
        to: to ?? this.to,
        workspaceIds: clearWorkspaces ? null : (workspaceIds ?? this.workspaceIds),
        categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
        kind: clearKind ? null : (kind ?? this.kind),
        search: search ?? this.search,
        onlyMine: onlyMine,
      );

  @override
  bool operator ==(Object other) =>
      other is TransactionFilter && other.from == from && other.to == to && _listEq(other.workspaceIds, workspaceIds) &&
      other.categoryId == categoryId && other.kind == kind && other.search == search && other.onlyMine == onlyMine;
  @override
  int get hashCode => Object.hash(from, to, workspaceIds?.join(','), categoryId, kind, search, onlyMine);

  static bool _listEq(List<String>? a, List<String>? b) => (a?.join(',') ?? '') == (b?.join(',') ?? '');
}

const _listSelect = '*, transaction_payments(payer_id, amount_minor, account_id, method), transaction_splits(user_id, amount_minor)';
const _detailSelect = '$_listSelect, receipts(*, receipt_items(*, receipt_item_allocations(user_id, amount_minor)))';

class TransactionRepository {
  TransactionRepository(this._client);
  final SupabaseClient _client;

  Future<List<Transaction>> list(TransactionFilter f, {int limit = 200, bool includeDeleted = false}) => guard(() async {
        var q = _client.from('transactions').select(f.onlyMine ? '$_listSelect, mine:transaction_splits!inner(user_id)' : _listSelect);
        if (!includeDeleted) q = q.isFilter('deleted_at', null);
        if (f.from != null) q = q.gte('occurred_on', isoDate(f.from!));
        if (f.to != null) q = q.lte('occurred_on', isoDate(f.to!));
        if (f.workspaceIds != null && f.workspaceIds!.isNotEmpty) q = q.inFilter('workspace_id', f.workspaceIds!);
        if (f.categoryId != null) q = q.eq('category_id', f.categoryId!);
        if (f.kind != null) q = q.eq('kind', f.kind!);
        if (f.onlyMine) q = q.eq('mine.user_id', _client.auth.currentUser!.id);
        final s = f.search?.trim();
        if (s != null && s.isNotEmpty) {
          final safe = s.replaceAll(RegExp(r'[%,()*]'), ' ');
          q = q.or('description.ilike.*$safe*,merchant.ilike.*$safe*');
        }
        final rows = await q.order('occurred_on', ascending: false).order('created_at', ascending: false).limit(limit);
        return rows.map(Transaction.fromJson).toList();
      });

  Future<Transaction?> get(String id) => guard(() async {
        final row = await _client.from('transactions').select(_detailSelect).eq('id', id).maybeSingle();
        return row == null ? null : Transaction.fromJson(row);
      });

  /// The single write path. Returns the stored id and version.
  Future<({String id, int version, bool replayed})> save(ExpenseDraft draft) => guard(() async {
        final r = Map<String, dynamic>.from(await _client.rpc('save_transaction', params: {'p': draft.toPayload()}) as Map);
        return (id: r['id'] as String, version: (r['version'] as num).toInt(), replayed: r['replayed'] == true);
      });

  Future<void> delete(Transaction t) =>
      guard(() => _client.rpc('delete_transaction', params: {'p_id': t.id, 'p_expected_version': t.version}));

  Future<void> restore(String id) => guard(() => _client.rpc('restore_transaction', params: {'p_id': id}));

  Future<List<Map<String, dynamic>>> possibleDuplicates({required String workspaceId, required int totalMinor,
          required DateTime date, String? merchant, String? invoiceNumber, String? excludeId}) =>
      guard(() async {
        final rows = await _client.rpc('find_possible_duplicates', params: {
          'p_workspace': workspaceId, 'p_total_minor': totalMinor, 'p_occurred_on': isoDate(date),
          'p_merchant': merchant, 'p_invoice_number': invoiceNumber, 'p_exclude': excludeId,
        }) as List;
        return rows.cast<Map<String, dynamic>>();
      });

  Future<List<AuditEvent>> history(String transactionId) => guard(() async {
        final rows = await _client.from('audit_events').select().eq('entity_type', 'transaction').eq('entity_id', transactionId)
            .order('occurred_at', ascending: false);
        return rows.map(AuditEvent.fromJson).toList();
      });

  /// Uploads a receipt file to the private bucket: `<workspace>/<uuid>/<name>`.
  Future<String> uploadReceipt(String workspaceId, Uint8List bytes, String mimeType) => guard(() async {
        final ext = switch (mimeType) { 'application/pdf' => 'pdf', 'image/png' => 'png', 'image/webp' => 'webp', _ => 'jpg' };
        final path = '$workspaceId/${newId()}/factura.$ext';
        await _client.storage.from('receipts').uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mimeType));
        return path;
      });

  /// Short-lived link: receipts are never public.
  Future<String> receiptUrl(String path) => guard(() => _client.storage.from('receipts').createSignedUrl(path, 120));

  Future<Uint8List> downloadReceipt(String path) => guard(() => _client.storage.from('receipts').download(path));
}
