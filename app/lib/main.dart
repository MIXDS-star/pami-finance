import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';
import 'core/providers.dart';
import 'features/auth/config_missing_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Env.isConfigured) {
    // Honest state instead of a fake demo: the backend is not configured.
    runApp(const ConfigMissingApp());
    return;
  }
  await Supabase.initialize(
    url: Env.supabaseUrl,
    publishableKey: Env.supabaseAnonKey,
    authOptions: const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
    debug: false,
  );
  runApp(ProviderScope(
    overrides: [supabaseClientProvider.overrideWithValue(Supabase.instance.client)],
    // Failed requests are surfaced to the person with a retry button rather
    // than retried silently in the background.
    retry: (_, _) => null,
    child: const NexoApp(),
  ));
}
