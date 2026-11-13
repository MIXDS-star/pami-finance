import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';
import 'core/providers.dart';
import 'core/theme/theme.dart';
import 'features/auth/config_missing_screen.dart';

/// Last startup/runtime error, shown on screen instead of a blank window.
final _fatal = ValueNotifier<(Object, StackTrace?)?>(null);

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    // On the web, pushed screens are reflected in the URL (refresh keeps you there).
    GoRouter.optionURLReflectsImperativeAPIs = true;
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      if (_fatal.value == null) _fatal.value = (details.exception, details.stack);
    };
    // A broken widget shows its error instead of an empty grey/black box.
    ErrorWidget.builder = (details) => _ErrorPanel(error: details.exception, stack: details.stack);
    if (!Env.isConfigured) {
      // Honest state instead of a fake demo: the backend is not configured.
      runApp(const ConfigMissingApp());
      return;
    }
    // Draw immediately; connect to the backend behind a visible loading screen.
    runApp(const _Bootstrap());
  }, (error, stack) {
    if (_fatal.value == null) _fatal.value = (error, stack);
  });
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  bool _ready = false;
  Object? _error;
  StackTrace? _stack;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _error = null;
      _stack = null;
    });
    try {
      await Supabase.initialize(
        url: Env.supabaseUrl,
        publishableKey: Env.supabaseAnonKey,
        authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
        debug: false,
      ).timeout(const Duration(seconds: 20));
      if (mounted) setState(() => _ready = true);
    } catch (e, st) {
      if (mounted) {
        setState(() {
          _error = e is TimeoutException ? 'No se pudo conectar con el servidor (tiempo agotado). Revisa tu conexión.' : e;
          _stack = st;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: _fatal,
      builder: (context, fatal, _) {
        if (fatal != null) return _Standalone(child: _ErrorPanel(error: fatal.$1, stack: fatal.$2));
        if (_error != null) return _Standalone(child: _ErrorPanel(error: _error!, stack: _stack, onRetry: _init));
        if (!_ready) return const _Standalone(child: _Splash());
        return ProviderScope(
          overrides: [supabaseClientProvider.overrideWithValue(Supabase.instance.client)],
          // Failed requests are surfaced to the person with a retry button rather
          // than retried silently in the background.
          retry: (_, _) => null,
          child: const PamiApp(),
        );
      },
    );
  }
}

class _Standalone extends StatelessWidget {
  const _Standalone({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: Scaffold(body: SafeArea(child: child)),
      );
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: context.colors.primary, borderRadius: BorderRadius.circular(18)),
            child: const Icon(Icons.hub_outlined, color: Colors.white, size: 34),
          ),
          const SizedBox(height: 16),
          Text('Pami Finance', style: context.text.titleLarge),
          const SizedBox(height: 24),
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.4)),
        ]),
      );
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.error, this.stack, this.onRetry});
  final Object error;
  final StackTrace? stack;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final detail = '$error\n\n${(stack?.toString() ?? '').split('\n').take(8).join('\n')}';
    return Material(
      child: ListView(padding: const EdgeInsets.all(24), children: [
        const Icon(Icons.error_outline, size: 40, color: Color(0xFFB4442F)),
        const SizedBox(height: 12),
        const Text('Pami Finance no pudo abrirse', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('Toma una captura de esta pantalla y envíala al equipo de desarrollo.'),
        const SizedBox(height: 16),
        SelectableText(detail, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, children: [
          if (onRetry != null) FilledButton(onPressed: onRetry, child: const Text('Reintentar')),
          OutlinedButton(onPressed: () => Clipboard.setData(ClipboardData(text: detail)), child: const Text('Copiar detalle')),
        ]),
        if (kDebugMode) Text(Env.flavor),
      ]),
    );
  }
}
