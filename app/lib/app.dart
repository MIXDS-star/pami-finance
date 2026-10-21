import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:quick_actions/quick_actions.dart';

import 'core/drafts/draft_store.dart';
import 'core/providers.dart';
import 'core/realtime/realtime_sync.dart';
import 'core/router/router.dart';
import 'core/security/app_lock.dart';
import 'core/theme/theme.dart';

class NexoApp extends ConsumerStatefulWidget {
  const NexoApp({super.key});

  @override
  ConsumerState<NexoApp> createState() => _NexoAppState();
}

class _NexoAppState extends ConsumerState<NexoApp> {
  StreamSubscription<Uri>? _links;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      // Invitation links: co.nexofinance://invite/<token> (auth links are handled by supabase_flutter).
      _links = AppLinks().uriLinkStream.listen((uri) {
        final token = uri.host == 'invite' ? uri.pathSegments.firstOrNull : (uri.pathSegments.length >= 2 && uri.pathSegments[0] == 'invite' ? uri.pathSegments[1] : null);
        if (token != null && token.isNotEmpty) ref.read(routerProvider).go('/invite/$token');
      }, onError: (_) {});
      _setupQuickActions();
    }
  }

  void _setupQuickActions() {
    const actions = QuickActions();
    actions.initialize((type) {
      final router = ref.read(routerProvider);
      switch (type) {
        case 'add_expense':
          router.push('/tx/new');
        case 'voice':
          router.push('/capture/voice');
        case 'month':
          router.go('/home');
        case 'budget':
          router.go('/plan');
      }
    });
    // Shortcut titles never include amounts (they are visible on the lock screen/home).
    actions.setShortcutItems(const [
      ShortcutItem(type: 'add_expense', localizedTitle: 'Añadir gasto'),
      ShortcutItem(type: 'voice', localizedTitle: 'Registrar por voz'),
      ShortcutItem(type: 'month', localizedTitle: 'Gasto del mes'),
      ShortcutItem(type: 'budget', localizedTitle: 'Presupuesto restante'),
    ]).catchError((_) {});
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(preferencesProvider).value?.themeMode ?? ThemeMode.system;
    ref.listen(currentUserIdProvider, (prev, next) {
      if (prev != null && next == null) ref.read(draftStoreProvider.notifier).clear();
    });
    return MaterialApp.router(
      title: 'NEXO Finance',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: themeMode,
      routerConfig: router,
      locale: const Locale('es', 'CO'),
      supportedLocales: const [Locale('es', 'CO'), Locale('es')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => RealtimeSync(child: LockGate(child: child ?? const SizedBox())),
    );
  }
}
