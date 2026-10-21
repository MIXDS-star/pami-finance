import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../drafts/draft_store.dart';
import '../theme/theme.dart';

/// Optional biometric/device-credential lock. The preference is per device
/// and stored in secure storage; locking happens on cold start and after the
/// app spent more than [_grace] in the background.
class AppLockState {
  const AppLockState({required this.enabled, required this.locked, required this.supported});
  final bool enabled;
  final bool locked;
  final bool supported;
}

class AppLock extends AsyncNotifier<AppLockState> {
  static const _key = 'nexo.app_lock.enabled';
  static const _grace = Duration(seconds: 60);
  SecureKeyValue get _storage => ref.read(secureKeyValueProvider);
  final _auth = LocalAuthentication();
  DateTime? _backgroundedAt;

  @override
  Future<AppLockState> build() async {
    final supported = await _supported();
    final enabled = supported && (await _storage.read(_key)) == 'true';
    return AppLockState(enabled: enabled, locked: enabled, supported: supported);
  }

  Future<bool> _supported() async {
    if (kIsWeb) return false;
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
    } catch (_) {
      return false;
    }
  }

  Future<bool> setEnabled(bool value) async {
    final s = await future;
    if (!s.supported) return false;
    if (value && !await _authenticate('Confirma tu identidad para activar el bloqueo')) return false;
    await _storage.write(_key, '$value');
    state = AsyncData(AppLockState(enabled: value, locked: false, supported: true));
    return true;
  }

  Future<void> unlock() async {
    final s = await future;
    if (await _authenticate('Desbloquea NEXO Finance')) {
      state = AsyncData(AppLockState(enabled: s.enabled, locked: false, supported: s.supported));
    }
  }

  void onLifecycle(AppLifecycleState lifecycle) {
    final s = state.value;
    if (s == null || !s.enabled) return;
    if (lifecycle == AppLifecycleState.paused || lifecycle == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
    } else if (lifecycle == AppLifecycleState.resumed) {
      final away = _backgroundedAt == null ? Duration.zero : DateTime.now().difference(_backgroundedAt!);
      _backgroundedAt = null;
      if (away > _grace) state = AsyncData(AppLockState(enabled: true, locked: true, supported: s.supported));
    }
  }
}

final appLockProvider = AsyncNotifierProvider<AppLock, AppLockState>(AppLock.new);

/// Covers the whole app (and hides content from the app switcher) while locked.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => ref.read(appLockProvider.notifier).onLifecycle(state);

  @override
  Widget build(BuildContext context) {
    final locked = ref.watch(appLockProvider).value?.locked ?? false;
    return Stack(children: [
      widget.child,
      if (locked)
        Positioned.fill(
          child: Material(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: SafeArea(
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.lock_outline, size: 48, color: context.colors.primary),
                  const SizedBox(height: 16),
                  Text('NEXO Finance está bloqueado', style: context.text.titleLarge),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () => ref.read(appLockProvider.notifier).unlock(),
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Desbloquear'),
                  ),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}
