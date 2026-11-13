import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../ui/components.dart';
import '../../ui/states.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(notificationsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Notificaciones'), actions: [
        TextButton(
          onPressed: () async {
            try {
              await ref.read(notificationRepositoryProvider).markAllRead();
              ref.invalidate(notificationsProvider);
            } catch (e) {
              if (context.mounted) showFailure(context, e);
            }
          },
          child: const Text('Marcar todo leído'),
        ),
      ]),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(notificationsProvider),
        child: AsyncView(
          value: list,
          onRetry: () => ref.invalidate(notificationsProvider),
          data: (items) => items.isEmpty
              ? ListView(children: const [EmptyState(icon: Icons.notifications_none, title: 'Sin notificaciones')])
              : ListView(children: [
                  for (final n in items)
                    ListTile(
                      leading: Icon(n.read ? Icons.notifications_none : Icons.notifications_active, color: n.read ? context.pami.muted : context.colors.primary),
                      title: Text(n.title, style: n.read ? null : const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text([if (n.body != null) n.body!, formatDateLong(n.createdAt)].join(' · ')),
                      onTap: () async {
                        if (!n.read) {
                          await ref.read(notificationRepositoryProvider).markRead(n.id).catchError((_) {});
                          ref.invalidate(notificationsProvider);
                        }
                        if (!context.mounted) return;
                        switch (n.entityType) {
                          case 'transaction':
                            context.push('/tx/${n.entityId}');
                          case 'settlement':
                            if (n.workspaceId != null) context.push('/spaces/${n.workspaceId}?tab=1');
                          case 'workspace':
                            context.push('/spaces/${n.entityId}?tab=2');
                        }
                      },
                    ),
                ]),
        ),
      ),
    );
  }
}
