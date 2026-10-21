import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../providers.dart';

/// Keeps screens fresh: subscribes to authorised realtime changes (RLS
/// applies to postgres_changes) and refreshes on app resume. Without a
/// realtime server (local stack) only the resume/pull-to-refresh paths run.
class RealtimeSync extends ConsumerStatefulWidget {
  const RealtimeSync({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<RealtimeSync> createState() => _RealtimeSyncState();
}

class _RealtimeSyncState extends ConsumerState<RealtimeSync> with WidgetsBindingObserver {
  RealtimeChannel? _channel;
  Timer? _debounce;
  String? _uid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual<String?>(currentUserIdProvider, (_, uid) => _subscribe(uid), fireImmediately: true);
  }

  void _subscribe(String? uid) {
    if (uid == _uid) return;
    _uid = uid;
    _channel?.unsubscribe();
    _channel = null;
    if (uid == null || !Env.realtimeEnabled) return;
    final client = ref.read(supabaseClientProvider);
    var channel = client.channel('ledger-$uid');
    for (final table in ['transactions', 'transaction_splits', 'settlements', 'receipts', 'budgets', 'notifications']) {
      channel = channel.onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: table, callback: (_) => _changed(false));
    }
    channel = channel.onPostgresChanges(event: PostgresChangeEvent.all, schema: 'public', table: 'workspace_members',
        callback: (_) => _changed(true));
    _channel = channel..subscribe();
  }

  void _changed(bool spaces) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      ref.read(ledgerRevisionProvider.notifier).bump();
      if (spaces) ref.read(spacesRevisionProvider.notifier).bump();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _uid != null) _changed(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _channel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
