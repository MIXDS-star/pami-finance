import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../ui/sheets.dart';

Future<void> showCaptureSheet(BuildContext context) => showNxSheet(context, builder: (_) => const CaptureSheet());

/// Every capture path ends in the same editor and the same server engine.
class CaptureSheet extends ConsumerWidget {
  const CaptureSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ai = ref.watch(aiCapabilitiesProvider).value;
    void go(String route) {
      Navigator.pop(context);
      context.push(route);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SheetHeader('Nuevo registro', subtitle: 'Elige la forma más rápida para ti. Siempre revisas antes de guardar.'),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.45,
        children: [
          _Option(icon: Icons.edit_note, title: 'Escribir', subtitle: ai?.textParsing == true ? 'Con IA' : 'Interpretación básica',
              onTap: () => go('/capture/text')),
          _Option(
            icon: Icons.mic_none,
            title: 'Dictar',
            subtitle: kIsWeb ? 'Solo en la app móvil' : (ai?.transcription == true ? 'Nota de voz' : 'Transcripción no configurada'),
            enabled: !kIsWeb && ai?.transcription == true,
            onTap: () => go('/capture/voice'),
          ),
          _Option(icon: Icons.document_scanner_outlined, title: 'Factura',
              subtitle: ai?.receiptExtraction == true ? 'Foto o PDF · lectura con IA' : 'Foto o PDF · líneas manuales',
              onTap: () => go('/capture/receipt')),
          _Option(icon: Icons.keyboard_outlined, title: 'Manual', subtitle: 'Formulario completo', onTap: () => go('/tx/new')),
        ],
      ),
      const SizedBox(height: 12),
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: const Icon(Icons.south_west),
        title: const Text('Ingreso'),
        subtitle: const Text('Salario, ingresos variables o extraordinarios'),
        onTap: () => go('/tx/new?kind=income'),
      ),
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: const Icon(Icons.swap_horiz),
        title: const Text('Transferencia o pago de tarjeta'),
        subtitle: const Text('Entre tus cuentas; no cuenta como gasto'),
        onTap: () => go('/tx/new?kind=transfer'),
      ),
      ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: const Icon(Icons.upload_file_outlined),
        title: const Text('Importar movimientos'),
        subtitle: const Text('CSV o Excel exportado de tu banco'),
        onTap: () => go('/import'),
      ),
    ]);
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.icon, required this.title, required this.subtitle, required this.onTap, this.enabled = true});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? context.colors.primary : context.nexo.muted;
    return Semantics(
      button: true,
      enabled: enabled,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: Material(
        color: enabled ? context.nexo.brandSoft : context.nexo.surfaceSoft,
        borderRadius: BorderRadius.circular(NexoTokens.radiusM),
        child: InkWell(
          borderRadius: BorderRadius.circular(NexoTokens.radiusM),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Icon(icon, color: color, size: 28),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: context.text.titleMedium?.copyWith(color: enabled ? null : context.nexo.muted)),
                Text(subtitle, style: context.text.bodySmall?.copyWith(color: context.nexo.muted), maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
