import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';

class SpacesScreen extends ConsumerWidget {
  const SpacesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spaces = ref.watch(workspacesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Espacios'),
        actions: [
          IconButton(tooltip: 'Tengo un código de invitación', icon: const Icon(Icons.qr_code_2), onPressed: () => _enterCode(context)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-space',
        onPressed: () => showNxSheet(context, builder: (_) => const CreateSpaceSheet()),
        icon: const Icon(Icons.group_add_outlined),
        label: const Text('Nuevo espacio'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.read(spacesRevisionProvider.notifier).bump(),
        child: AsyncView(
          value: spaces,
          onRetry: () => ref.invalidate(workspacesProvider),
          data: (list) {
            final shared = list.where((w) => !w.isPersonal).toList();
            return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 96), children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('Cada espacio tiene sus propios gastos, miembros y reglas. Compartir un espacio no da acceso a tus finanzas personales.'),
              ),
              for (final w in list.where((w) => w.isPersonal)) _SpaceCard(ws: w),
              const SectionTitle('Compartidos'),
              if (shared.isEmpty)
                const Card(
                  child: EmptyState(
                    compact: true,
                    icon: Icons.groups_outlined,
                    title: 'Aún no compartes gastos',
                    message: 'Crea un hogar, una pareja, un grupo de amigos o un viaje e invita a quien quieras.',
                  ),
                ),
              for (final w in shared) Padding(padding: const EdgeInsets.only(bottom: 8), child: _SpaceCard(ws: w)),
            ]);
          },
        ),
      ),
    );
  }

  Future<void> _enterCode(BuildContext context) async {
    final c = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unirme con un enlace'),
        content: TextField(controller: c, decoration: const InputDecoration(labelText: 'Pega el enlace o el código de invitación')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Continuar')),
        ],
      ),
    );
    if (token == null || token.isEmpty || !context.mounted) return;
    final clean = token.contains('/') ? token.split('/').last.split('?').first : token;
    context.push('/invite/$clean');
  }
}

class _SpaceCard extends ConsumerWidget {
  const _SpaceCard({required this.ws});
  final Workspace ws;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(membersProvider(ws.id)).value ?? const <Member>[];
    final active = members.where((m) => m.active).toList();
    return SectionCard(
      onTap: () => context.push('/spaces/${ws.id}'),
      child: Row(children: [
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(color: context.nexo.brandSoft, borderRadius: BorderRadius.circular(14)),
          child: Icon(ws.kind.icon, color: context.colors.primary),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(ws.name, style: context.text.titleMedium, overflow: TextOverflow.ellipsis)),
              if (ws.archived) ...[const SizedBox(width: 6), const Pill('Archivado', icon: Icons.archive_outlined)],
            ]),
            Text(ws.isPersonal ? 'Solo tú · privado' : '${ws.kind.label} · ${active.length} miembro(s) · ${ws.myRole?.label ?? ''}',
                style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
          ]),
        ),
        if (!ws.isPersonal) AvatarStack(names: active.map((m) => m.displayName).toList()),
        const Icon(Icons.chevron_right),
      ]),
    );
  }
}

class CreateSpaceSheet extends ConsumerStatefulWidget {
  const CreateSpaceSheet({super.key});
  @override
  ConsumerState<CreateSpaceSheet> createState() => _CreateSpaceSheetState();
}

class _CreateSpaceSheetState extends ConsumerState<CreateSpaceSheet> with BusyState {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  WorkspaceKind _kind = WorkspaceKind.household;
  String _currency = 'COP';

  @override
  Widget build(BuildContext context) => Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SheetHeader('Nuevo espacio compartido'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final k in WorkspaceKind.values.where((k) => k != WorkspaceKind.personal))
              ChoiceChip(avatar: Icon(k.icon, size: 18), label: Text(k.label), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
          ]),
          const SizedBox(height: 16),
          TextFormField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: 'Nombre', hintText: switch (_kind) {
              WorkspaceKind.household => 'Ej.: Casa',
              WorkspaceKind.couple => 'Ej.: Ana y Bruno',
              WorkspaceKind.trip => 'Ej.: Cartagena 2026',
              _ => 'Ej.: Apartamento 302',
            }),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Escribe un nombre' : null,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: _currency,
            decoration: const InputDecoration(labelText: 'Moneda base', helperText: 'No se podrá cambiar cuando haya movimientos'),
            items: [for (final c in Currency.all) DropdownMenuItem(value: c.code, child: Text('${c.name} (${c.code})'))],
            onChanged: (v) => setState(() => _currency = v ?? 'COP'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy
                ? null
                : () {
                    if (!_form.currentState!.validate()) return;
                    runBusy(() async {
                      final id = await ref.read(workspaceRepositoryProvider).create(_name.text, _kind, _currency);
                      ref.read(spacesRevisionProvider.notifier).bump();
                      if (!context.mounted) return;
                      Navigator.pop(context);
                      context.push('/spaces/$id?tab=2');
                    }, onError: (e) => showFailure(context, e));
                  },
            child: const Text('Crear e invitar'),
          ),
        ]),
      );
}
