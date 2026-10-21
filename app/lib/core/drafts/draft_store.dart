import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Unsynchronised movements kept ON THIS DEVICE (encrypted by the OS
/// keychain/keystore) when saving failed for lack of connection. They are
/// never shown as confirmed; retrying reuses the same client_request_id, so
/// the server stores them at most once.
class PendingDraft {
  PendingDraft({required this.payload, required this.savedAt, this.lastError});
  final Map<String, dynamic> payload;
  final DateTime savedAt;
  final String? lastError;

  String get requestId => payload['client_request_id'] as String;
  String get description => payload['description'] as String? ?? 'Movimiento';
  int get totalMinor => (payload['total_minor'] as num?)?.toInt() ?? 0;
  String get currency => payload['currency'] as String? ?? 'COP';

  Map<String, dynamic> toJson() => {'payload': payload, 'saved_at': savedAt.toIso8601String(), 'last_error': lastError};
  static PendingDraft fromJson(Map<String, dynamic> j) => PendingDraft(
      payload: Map<String, dynamic>.from(j['payload'] as Map), savedAt: DateTime.parse(j['saved_at'] as String),
      lastError: j['last_error'] as String?);
}

/// Minimal secure key-value storage (OS keychain/keystore in the app,
/// in-memory in tests).
abstract class SecureKeyValue {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class OsSecureKeyValue implements SecureKeyValue {
  const OsSecureKeyValue();
  static const _s = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class MemoryKeyValue implements SecureKeyValue {
  final _m = <String, String>{};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

final secureKeyValueProvider = Provider<SecureKeyValue>((ref) => const OsSecureKeyValue());

class DraftStore extends AsyncNotifier<List<PendingDraft>> {
  static const _key = 'nexo.pending_drafts.v1';
  SecureKeyValue get _storage => ref.read(secureKeyValueProvider);

  @override
  Future<List<PendingDraft>> build() async {
    try {
      final raw = await _storage.read(_key);
      if (raw == null) return [];
      return (jsonDecode(raw) as List).map((e) => PendingDraft.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _persist(List<PendingDraft> list) async {
    state = AsyncData(list);
    await _storage.write(_key, jsonEncode(list.map((d) => d.toJson()).toList()));
  }

  Future<void> put(Map<String, dynamic> payload, {String? error}) async {
    final list = [...(state.value ?? await future)]..removeWhere((d) => d.requestId == payload['client_request_id']);
    list.add(PendingDraft(payload: payload, savedAt: DateTime.now(), lastError: error));
    await _persist(list);
  }

  Future<void> remove(String requestId) async {
    final list = [...(state.value ?? await future)]..removeWhere((d) => d.requestId == requestId);
    await _persist(list);
  }

  /// Called on sign-out: drafts never outlive the session that made them.
  Future<void> clear() async {
    state = const AsyncData([]);
    await _storage.delete(_key);
  }
}

final draftStoreProvider = AsyncNotifierProvider<DraftStore, List<PendingDraft>>(DraftStore.new);
