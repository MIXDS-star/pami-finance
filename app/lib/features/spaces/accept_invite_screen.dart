import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/failure.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';

final _previewProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
    (ref, token) => ref.watch(workspaceRepositoryProvider).previewInvitation(token));

class AcceptInviteScreen extends ConsumerStatefulWidget {
  const AcceptInviteScreen({super.key, required this.token});
  final String token;
  @override
  ConsumerState<AcceptInviteScreen> createState() => _AcceptInviteScreenState();
}

class _AcceptInviteScreenState extends ConsumerState<AcceptInviteScreen> with BusyState {
  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(_previewProvider(widget.token));
    return Scaffold(
      appBar: AppBar(title: const Text('Invitación')),
      body: AsyncView(
        value: preview,
        onRetry: () => ref.invalidate(_previewProvider(widget.token)),
        data: (p) {
          final status = p['status'] as String;
          if (status != 'pending') {
            return EmptyState(
              icon: Icons.link_off,
              title: 'Invitación no disponible',
              message: AppFailure.messageFor('invite_$status') ?? 'La invitación no es válida.',
              action: OutlinedButton(onPressed: () => context.go('/spaces'), child: const Text('Ir a espacios')),
            );
          }
          if (p['already_member'] == true) {
            return EmptyState(icon: Icons.check_circle_outline, title: 'Ya eres miembro de ${p['workspace_name']}',
                action: FilledButton(onPressed: () => context.go('/spaces'), child: const Text('Ir a espacios')));
          }
          final role = MemberRole.values.byName(p['role'] as String);
          final kind = WorkspaceKind.values.byName(p['workspace_kind'] as String);
          return ListView(padding: const EdgeInsets.all(24), children: [
            Icon(kind.icon, size: 48, color: context.colors.primary),
            const SizedBox(height: 16),
            Text('${p['invited_by_name']} te invita a «${p['workspace_name']}»', style: context.text.headlineSmall),
            const SizedBox(height: 8),
            Text('Rol: ${role.label}. ${role.description}'),
            const SizedBox(height: 16),
            const Notice(message: 'Los miembros verán los gastos que se registren en este espacio y tu nombre visible. '
                'Tus finanzas personales, cuentas e ingresos siguen siendo privados.'),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: busy ? null : () => runBusy(() async {
                final id = await ref.read(workspaceRepositoryProvider).acceptInvitation(widget.token);
                ref.read(spacesRevisionProvider.notifier).bump();
                ref.read(ledgerRevisionProvider.notifier).bump();
                if (context.mounted) {
                  showSuccess(context, 'Te uniste a ${p['workspace_name']}');
                  context.go('/spaces');
                  context.push('/spaces/$id');
                }
              }, onError: (e) => showFailure(context, e)),
              child: const Text('Aceptar invitación'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: busy ? null : () async {
                if (!await confirmAction(context, title: 'Rechazar invitación', message: 'No podrás usar este enlace después.', confirmLabel: 'Rechazar')) return;
                await runBusy(() async {
                  await ref.read(workspaceRepositoryProvider).declineInvitation(widget.token);
                  if (context.mounted) context.go('/home');
                }, onError: (e) => showFailure(context, e));
              },
              child: const Text('Rechazar'),
            ),
          ]);
        },
      ),
    );
  }
}
