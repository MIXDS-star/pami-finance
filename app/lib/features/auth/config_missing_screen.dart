import 'package:flutter/material.dart';

import '../../core/theme/theme.dart';

/// Shown when the build has no backend configuration. No demo data is
/// invented to fill the screen.
class ConfigMissingApp extends StatelessWidget {
  const ConfigMissingApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.settings_suggest_outlined, size: 48, color: context.colors.primary),
                  const SizedBox(height: 16),
                  Text('Configuración pendiente', style: context.text.headlineSmall),
                  const SizedBox(height: 8),
                  const Text('Esta compilación no tiene conexión configurada con el servidor de Pami Finance. '
                      'Compila la app con SUPABASE_URL y SUPABASE_ANON_KEY (ver README, sección «Configurar la app»).'),
                ]),
              ),
            ),
          ),
        ),
      );
}
