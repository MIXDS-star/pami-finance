import 'package:flutter/material.dart';

import '../core/theme/theme.dart';

/// Bottom sheet that respects the keyboard and safe areas.
Future<T?> showNxSheet<T>(BuildContext context, {required WidgetBuilder builder, bool scrollable = true}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: scrollable
          ? SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), child: builder(ctx))
          : builder(ctx),
    ),
  );
}

class SheetHeader extends StatelessWidget {
  const SheetHeader(this.title, {super.key, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(header: true, child: Text(title, style: context.text.titleLarge)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: context.text.bodyMedium?.copyWith(color: context.nexo.muted)),
          ],
        ]),
      );
}

/// Confirmation for sensitive operations. When [typeToConfirm] is set the
/// person must type that word, for irreversible actions.
Future<bool> confirmAction(BuildContext context, {required String title, required String message,
    String confirmLabel = 'Confirmar', bool destructive = false, String? typeToConfirm}) async {
  final controller = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      final enabled = typeToConfirm == null || controller.text.trim() == typeToConfirm;
      return AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(message),
          if (typeToConfirm != null) ...[
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(labelText: 'Escribe $typeToConfirm para confirmar'),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error) : null,
            onPressed: enabled ? () => Navigator.pop(ctx, true) : null,
            child: Text(confirmLabel),
          ),
        ],
      );
    }),
  );
  controller.dispose();
  return ok ?? false;
}

/// Simple single-choice list in a sheet.
Future<T?> pickOne<T>(BuildContext context, {required String title, required List<T> options,
    required String Function(T) label, Widget Function(T)? leading, String Function(T)? subtitle, T? selected}) {
  return showNxSheet<T>(
    context,
    builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(title),
      for (final o in options)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: leading?.call(o),
          title: Text(label(o)),
          subtitle: subtitle == null ? null : Text(subtitle(o)),
          trailing: o == selected ? Icon(Icons.check, color: Theme.of(ctx).colorScheme.primary, semanticLabel: 'Seleccionado') : null,
          onTap: () => Navigator.pop(ctx, o),
        ),
    ]),
  );
}

/// Runs an async action with a busy flag and reports failures.
mixin BusyState<T extends StatefulWidget> on State<T> {
  bool busy = false;

  Future<R?> runBusy<R>(Future<R> Function() action, {void Function(Object e)? onError}) async {
    if (busy) return null;
    setState(() => busy = true);
    try {
      return await action();
    } catch (e) {
      onError?.call(e);
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
