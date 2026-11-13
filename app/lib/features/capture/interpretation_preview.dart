import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../ui/components.dart';
import '../../ui/states.dart';
import 'interpretation.dart';

/// Shows what was understood. Nothing is saved here: the next step is the
/// editor, where the person confirms.
class InterpretationPreview extends ConsumerWidget {
  const InterpretationPreview({super.key, required this.result});
  final Interpretation result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = result.draft;
    final spaces = ref.watch(workspacesProvider).value ?? const <Workspace>[];
    final ws = spaces.where((w) => w.id == d.workspaceId).firstOrNull;
    final cats = ref.watch(categoriesProvider).value ?? const <Category>[];
    final cat = cats.where((c) => c.id == d.categoryId).firstOrNull;
    final people = ref.watch(peopleProvider).value ?? const <String, String>{};
    final me = ref.watch(currentUserIdProvider);

    Widget row(String label, String value, {bool missing = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 110, child: Text(label, style: context.text.bodyMedium?.copyWith(color: context.pami.muted))),
            Expanded(child: Text(value, style: missing ? TextStyle(color: context.pami.warning, fontWeight: FontWeight.w600) : null)),
          ]),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (result.notice != null) ...[Notice(message: result.notice!), const SizedBox(height: 12)],
      SectionCard(
        title: result.byAi ? 'Esto entendió la IA' : 'Esto entendimos',
        child: Column(children: [
          row('Importe', d.totalMinor == null ? 'Falta: indícalo en el siguiente paso' : formatMinor(d.totalMinor!, d.currency),
              missing: d.totalMinor == null),
          row('Concepto', d.description.isEmpty ? 'Falta' : d.description, missing: d.description.isEmpty),
          row('Fecha', formatDateLong(d.occurredOn)),
          row('Categoría', cat?.name ?? 'Sin categoría'),
          row('Espacio', ws?.name ?? 'Personal'),
          if (d.payments.isNotEmpty)
            row('Pagó', d.payments.first.payerId == me ? 'Tú' : (people[d.payments.first.payerId] ?? '—')),
          if (d.payments.firstOrNull?.method != null) row('Medio', paymentMethodLabels[d.payments.first.method] ?? ''),
          if (!(ws?.isPersonal ?? true))
            row('Reparto', d.receipt != null ? 'Por producto (${d.receipt!.lines.length} artículos)'
                : '${d.rule.method.name == 'equal' ? 'Partes iguales' : 'Personalizado'} entre ${d.rule.participants.map((p) => p == me ? 'tú' : people[p] ?? '?').join(', ')}'),
        ]),
      ),
      if (result.ambiguities.isNotEmpty || result.missing.isNotEmpty) ...[
        const SizedBox(height: 12),
        Notice(
          kind: NoticeKind.warning,
          title: 'Revisa antes de guardar',
          message: [
            ...result.ambiguities,
            if (result.missing.isNotEmpty) 'No se mencionó: ${result.missing.join(', ')}.',
          ].join('\n'),
        ),
      ],
      const SizedBox(height: 20),
      FilledButton(
        onPressed: () => context.pushReplacement('/tx/new', extra: d),
        child: const Text('Revisar y confirmar'),
      ),
    ]);
  }
}
