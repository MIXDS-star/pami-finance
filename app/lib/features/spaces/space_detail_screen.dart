import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/config/env.dart';
import '../../core/finance/balances.dart';
import '../../core/finance/expense_draft.dart';
import '../../core/finance/split_rules.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../core/util/ids.dart';
import '../../data/models.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';
import '../movements/draft_mapper.dart';
import '../movements/movements_screen.dart';
import '../movements/split_editor.dart';
import '../movements/tx_tile.dart';

final balancesProvider = FutureProvider.autoDispose.family<List<MemberBalance>, String>((ref, id) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(workspaceRepositoryProvider).balances(id);
});

final settlementsProvider = FutureProvider.autoDispose.family<List<Settlement>, String>((ref, id) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(workspaceRepositoryProvider).settlements(id);
});

final invitationsProvider = FutureProvider.autoDispose.family<List<Invitation>, String>((ref, id) {
  ref.watch(spacesRevisionProvider);
  return ref.watch(workspaceRepositoryProvider).invitations(id);
});

class SpaceDetailScreen extends ConsumerWidget {
  const SpaceDetailScreen({super.key, required this.id, this.initialTab = 0});
  final String id;
  final int initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ws = ref.watch(workspaceProvider(id));
    return AsyncView(
      value: ws,
      onRetry: () => ref.invalidate(workspacesProvider),
      loading: const Scaffold(body: LoadingState()),
      data: (w) {
        if (w == null) {
          return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.lock_outline, title: 'Sin acceso',
              message: 'Ya no eres miembro de este espacio o no existe.'));
        }
        final tabs = [
          const Tab(text: 'Gastos'),
          if (!w.isPersonal) const Tab(text: 'Saldos'),
          if (!w.isPersonal) const Tab(text: 'Miembros'),
          const Tab(text: 'Ajustes'),
        ];
        return DefaultTabController(
          length: tabs.length,
          initialIndex: initialTab.clamp(0, tabs.length - 1),
          child: Scaffold(
            appBar: AppBar(
              title: Text(w.name),
              bottom: TabBar(tabs: tabs, isScrollable: false),
            ),
            floatingActionButton: w.canWrite
                ? FloatingActionButton.extended(
                    heroTag: 'space-add',
                    onPressed: () => context.push('/tx/new?workspace=${w.id}'),
                    icon: const Icon(Icons.add),
                    label: const Text('Gasto'),
                  )
                : null,
            body: TabBarView(children: [
              _ExpensesTab(ws: w),
              if (!w.isPersonal) _BalancesTab(ws: w),
              if (!w.isPersonal) _MembersTab(ws: w),
              _SettingsTab(ws: w),
            ]),
          ),
        );
      },
    );
  }
}

class _ExpensesTab extends ConsumerWidget {
  const _ExpensesTab({required this.ws});
  final Workspace ws;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(selectedMonthProvider);
    final filter = TransactionFilter(from: month, to: monthEnd(month), workspaceIds: [ws.id]);
    final txs = ref.watch(movementsProvider(filter));
    final me = ref.watch(currentUserIdProvider) ?? '';
    final cats = ref.watch(categoriesProvider).value ?? const <Category>[];
    final people = ref.watch(peopleProvider).value ?? const <String, String>{};
    return RefreshIndicator(
      onRefresh: () async => ref.read(ledgerRevisionProvider.notifier).bump(),
      child: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
        Row(children: [
          IconButton(tooltip: 'Mes anterior', icon: const Icon(Icons.chevron_left), onPressed: () => ref.read(selectedMonthProvider.notifier).previous()),
          Expanded(child: Center(child: Text(formatMonth(month), style: context.text.titleMedium))),
          IconButton(tooltip: 'Mes siguiente', icon: const Icon(Icons.chevron_right), onPressed: () => ref.read(selectedMonthProvider.notifier).next()),
        ]),
        AsyncView(
          value: txs,
          compact: true,
          onRetry: () => ref.invalidate(movementsProvider(filter)),
          data: (list) {
            if (list.isEmpty) {
              return const EmptyState(compact: true, icon: Icons.receipt_long_outlined, title: 'Sin gastos este mes',
                  message: 'Los gastos que registre cualquier miembro aparecerán aquí.');
            }
            final total = list.where((t) => t.isExpense && t.currency == ws.baseCurrency).fold<int>(0, (a, t) => a + t.totalMinor);
            return Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Text('Total del espacio', style: context.text.titleSmall),
                  const Spacer(),
                  AmountText(total, ws.baseCurrency),
                ]),
              ),
              for (final t in list)
                TxTile(tx: t, me: me, workspace: ws, people: people, category: cats.where((c) => c.id == t.categoryId).firstOrNull,
                    onTap: () => context.push('/tx/${t.id}')),
            ]);
          },
        ),
      ]),
    );
  }
}

class _BalancesTab extends ConsumerWidget {
  const _BalancesTab({required this.ws});
  final Workspace ws;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balances = ref.watch(balancesProvider(ws.id));
    final settlements = ref.watch(settlementsProvider(ws.id));
    final members = ref.watch(membersProvider(ws.id)).value ?? const <Member>[];
    final me = ref.watch(currentUserIdProvider) ?? '';
    final names = {for (final m in members) m.userId: m.userId == me ? 'Tú' : m.displayName};
    final realNames = {for (final m in members) m.userId: m.displayName};

    return RefreshIndicator(
      onRefresh: () async => ref.read(ledgerRevisionProvider.notifier).bump(),
      child: AsyncView(
        value: balances,
        onRetry: () => ref.invalidate(balancesProvider(ws.id)),
        data: (list) {
          final byCurrency = <String, List<MemberBalance>>{};
          for (final b in list) {
            byCurrency.putIfAbsent(b.currency, () => []).add(b);
          }
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
            if (list.isEmpty)
              const EmptyState(compact: true, icon: Icons.balance, title: 'Todo en orden', message: 'Aún no hay gastos compartidos en este espacio.'),
            for (final entry in byCurrency.entries) ...[
              _currencyBlock(context, ref, entry.key, entry.value, names, realNames, me),
            ],
            const SectionTitle('Reembolsos registrados'),
            AsyncView(
              value: settlements,
              compact: true,
              data: (s) => s.isEmpty
                  ? const Text('Todavía no hay reembolsos.')
                  : Column(children: [
                      for (final x in s)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.swap_horiz),
                          title: Text('${names[x.fromUserId] ?? 'Exmiembro'} → ${names[x.toUserId] ?? 'Exmiembro'}'),
                          subtitle: Text([formatDateLong(x.occurredOn), if (x.method != null) paymentMethodLabels[x.method] ?? '', if (x.note != null) x.note!].join(' · ')),
                          trailing: AmountText(x.amountMinor, x.currency, style: context.text.titleSmall),
                          onLongPress: (x.createdBy == me || ws.canAdmin) && ws.canWrite
                              ? () async {
                                  if (await confirmAction(context, title: 'Anular reembolso',
                                      message: 'El saldo volverá a mostrar la deuda. Queda en el historial.', confirmLabel: 'Anular', destructive: true)) {
                                    try {
                                      await ref.read(workspaceRepositoryProvider).deleteSettlement(x);
                                      ref.read(ledgerRevisionProvider.notifier).bump();
                                    } catch (e) {
                                      if (context.mounted) showFailure(context, e);
                                    }
                                  }
                                }
                              : null,
                        ),
                      Text('Mantén presionado un reembolso para anularlo.', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
                    ]),
            ),
          ]);
        },
      ),
    );
  }

  Widget _currencyBlock(BuildContext context, WidgetRef ref, String code, List<MemberBalance> list, Map<String, String> names,
      Map<String, String> realNames, String me) {
    final currency = Currency.of(code);
    final transfers = suggestTransfers({for (final b in list) b.userId: b.netMinor});
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionCard(
        title: transfers.isEmpty ? 'Nadie debe nada' : 'Para quedar a mano',
        child: Column(children: [
          if (transfers.isEmpty) const Text('Los pagos y la parte de cada persona están equilibrados.'),
          for (final t in transfers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: PersonAvatar(name: realNames[t.fromUserId] ?? '?'),
              title: Text('${names[t.fromUserId] ?? 'Exmiembro'} ${t.fromUserId == me ? 'debes' : 'debe'} a ${names[t.toUserId] ?? 'Exmiembro'}'),
              subtitle: AmountText(t.amountMinor, currency, style: context.text.titleMedium),
              trailing: ws.canWrite && (t.fromUserId == me || t.toUserId == me || ws.canAdmin)
                  ? FilledButton.tonal(
                      onPressed: () => showNxSheet(context, builder: (_) => SettlementSheet(ws: ws, transfer: t, currency: currency, names: names)),
                      child: const Text('Registrar pago'))
                  : null,
            ),
        ]),
      ),
      const SizedBox(height: 12),
      SectionCard(
        title: 'Detalle por persona',
        child: Column(children: [
          for (final b in list)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                PersonAvatar(name: realNames[b.userId] ?? '?', size: 30),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(names[b.userId] ?? 'Exmiembro', style: context.text.titleSmall),
                    Text('Pagó ${formatMinor(b.paidMinor, currency)} · le corresponde ${formatMinor(b.assignedMinor, currency)}'
                        '${b.sentMinor + b.receivedMinor > 0 ? ' · reembolsos: envió ${formatMinor(b.sentMinor, currency)}, recibió ${formatMinor(b.receivedMinor, currency)}' : ''}',
                        style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
                  ]),
                ),
                AmountText(b.netMinor, currency, colorize: true, semanticPrefix: b.netMinor >= 0 ? 'le deben' : 'debe'),
              ]),
            ),
          const Divider(),
          Text('Saldo = pagado − lo que le corresponde + reembolsos enviados − reembolsos recibidos. '
              'Positivo: le deben; negativo: debe.', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
        ]),
      ),
    ]);
  }
}

class SettlementSheet extends ConsumerStatefulWidget {
  const SettlementSheet({super.key, required this.ws, required this.transfer, required this.currency, required this.names});
  final Workspace ws;
  final SuggestedTransfer transfer;
  final Currency currency;
  final Map<String, String> names;

  @override
  ConsumerState<SettlementSheet> createState() => _SettlementSheetState();
}

class _SettlementSheetState extends ConsumerState<SettlementSheet> with BusyState {
  late int? _amount = widget.transfer.amountMinor;
  DateTime _date = DateTime.now();
  String? _method = 'bank_transfer';
  final _note = TextEditingController();
  final _requestId = newId(); // a retried submit never records two payments

  @override
  Widget build(BuildContext context) {
    final from = widget.names[widget.transfer.fromUserId] ?? '';
    final to = widget.names[widget.transfer.toUserId] ?? '';
    final partial = (_amount ?? 0) < widget.transfer.amountMinor;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader('Registrar reembolso', subtitle: '$from → $to. No es un gasto nuevo: solo actualiza el saldo entre ustedes.'),
      MoneyField(currency: widget.currency, initialMinor: _amount, label: 'Importe pagado', onChanged: (v) => setState(() => _amount = v),
          helper: partial && (_amount ?? 0) > 0 ? 'Pago parcial: quedarán ${formatMinor(widget.transfer.amountMinor - (_amount ?? 0), widget.currency)} pendientes' : null),
      const SizedBox(height: 12),
      DateField(value: _date, onChanged: (d) => setState(() => _date = d)),
      const SizedBox(height: 12),
      DropdownButtonFormField<String?>(
        isExpanded: true,
        initialValue: _method,
        decoration: const InputDecoration(labelText: 'Medio'),
        items: [for (final e in paymentMethodLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
        onChanged: (v) => setState(() => _method = v),
      ),
      const SizedBox(height: 12),
      TextField(controller: _note, decoration: const InputDecoration(labelText: 'Nota (opcional)'), maxLength: 500),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: busy || (_amount ?? 0) <= 0
            ? null
            : () => runBusy(() async {
                  await ref.read(workspaceRepositoryProvider).recordSettlement({
                    'client_request_id': _requestId,
                    'workspace_id': widget.ws.id,
                    'from_user_id': widget.transfer.fromUserId,
                    'to_user_id': widget.transfer.toUserId,
                    'amount_minor': _amount,
                    'currency': widget.currency.code,
                    'occurred_on': isoDate(_date),
                    'method': _method,
                    'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
                  });
                  ref.read(ledgerRevisionProvider.notifier).bump();
                  if (context.mounted) {
                    Navigator.pop(context);
                    showSuccess(context, partial ? 'Pago parcial registrado' : 'Quedaron a mano');
                  }
                }, onError: (e) => showFailure(context, e)),
        child: const Text('Registrar'),
      ),
    ]);
  }
}

class _MembersTab extends ConsumerWidget {
  const _MembersTab({required this.ws});
  final Workspace ws;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final members = ref.watch(membersProvider(ws.id));
    final me = ref.watch(currentUserIdProvider) ?? '';
    return AsyncView(
      value: members,
      onRetry: () => ref.invalidate(membersProvider(ws.id)),
      data: (list) {
        final active = list.where((m) => m.active).toList();
        final former = list.where((m) => !m.active).toList();
        return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
          if (ws.canAdmin && ws.canWrite)
            FilledButton.icon(
              onPressed: () => showNxSheet(context, builder: (_) => InviteSheet(ws: ws)),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Invitar'),
            ),
          const SectionTitle('Miembros'),
          for (final m in active)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: PersonAvatar(name: m.displayName),
              title: Text(m.userId == me ? '${m.displayName} (tú)' : m.displayName),
              subtitle: Text(m.role.label),
              trailing: m.userId != me && _canManage(ws.myRole, m.role)
                  ? PopupMenuButton<String>(
                      tooltip: 'Opciones de ${m.displayName}',
                      onSelected: (a) => _memberAction(context, ref, m, a),
                      itemBuilder: (_) => [
                        for (final r in [MemberRole.admin, MemberRole.member, MemberRole.viewer])
                          if (r != m.role && (ws.myRole == MemberRole.owner || r != MemberRole.admin))
                            PopupMenuItem(value: 'role:${r.name}', child: Text('Cambiar a ${r.label}')),
                        if (ws.myRole == MemberRole.owner) const PopupMenuItem(value: 'owner', child: Text('Transferir propiedad')),
                        const PopupMenuItem(value: 'remove', child: Text('Retirar del espacio')),
                      ],
                    )
                  : null,
            ),
          if (former.isNotEmpty) ...[
            const SectionTitle('Antiguos miembros'),
            Text('Su historial se conserva para que los saldos sigan siendo correctos.', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
            for (final m in former)
              ListTile(contentPadding: EdgeInsets.zero, leading: PersonAvatar(name: m.displayName, inactive: true),
                  title: Text(m.displayName), subtitle: const Text('Ya no es miembro')),
          ],
          if (ws.canAdmin) _Invitations(ws: ws),
          const SectionTitle('Roles'),
          for (final r in MemberRole.values)
            ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(r.label), subtitle: Text(r.description)),
        ]);
      },
    );
  }

  bool _canManage(MemberRole? mine, MemberRole theirs) =>
      theirs != MemberRole.owner && (mine == MemberRole.owner || (mine == MemberRole.admin && (theirs == MemberRole.member || theirs == MemberRole.viewer)));

  Future<void> _memberAction(BuildContext context, WidgetRef ref, Member m, String action) async {
    final repo = ref.read(workspaceRepositoryProvider);
    try {
      if (action.startsWith('role:')) {
        await repo.changeRole(ws.id, m.userId, MemberRole.values.byName(action.substring(5)));
      } else if (action == 'owner') {
        if (!await confirmAction(context, title: 'Transferir propiedad', message: '${m.displayName} será el propietario y tú pasarás a administrador.',
            confirmLabel: 'Transferir')) {
          return;
        }
        await repo.transferOwnership(ws.id, m.userId);
      } else if (action == 'remove') {
        if (!context.mounted) return;
        if (!await confirmAction(context, title: 'Retirar a ${m.displayName}',
            message: 'Perderá el acceso a este espacio. Sus gastos y saldos pendientes se conservan en el historial.',
            confirmLabel: 'Retirar', destructive: true)) {
          return;
        }
        await repo.removeMember(ws.id, m.userId);
      }
      ref.read(spacesRevisionProvider.notifier).bump();
      if (context.mounted) showSuccess(context, 'Cambios guardados');
    } catch (e) {
      if (context.mounted) showFailure(context, e);
    }
  }
}

class _Invitations extends ConsumerWidget {
  const _Invitations({required this.ws});
  final Workspace ws;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inv = ref.watch(invitationsProvider(ws.id)).value ?? const <Invitation>[];
    final pending = inv.where((i) => i.status == 'pending').toList();
    if (pending.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Invitaciones pendientes'),
      for (final i in pending)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.mail_outline),
          title: Text(i.email ?? 'Enlace abierto'),
          subtitle: Text('${i.role.label} · vence ${formatDateLong(i.expiresAt)}'),
          trailing: TextButton(
            onPressed: () async {
              try {
                await ref.read(workspaceRepositoryProvider).revokeInvitation(i.id);
                ref.read(spacesRevisionProvider.notifier).bump();
              } catch (e) {
                if (context.mounted) showFailure(context, e);
              }
            },
            child: const Text('Revocar'),
          ),
        ),
    ]);
  }
}

class InviteSheet extends ConsumerStatefulWidget {
  const InviteSheet({super.key, required this.ws});
  final Workspace ws;
  @override
  ConsumerState<InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<InviteSheet> with BusyState {
  MemberRole _role = MemberRole.member;
  final _email = TextEditingController();
  String? _link;
  DateTime? _expires;

  @override
  Widget build(BuildContext context) {
    if (_link != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SheetHeader('Invitación creada', subtitle: 'Compártela solo con la persona invitada. Funciona una vez.'),
        SelectableText(_link!, style: context.text.bodyMedium),
        const SizedBox(height: 8),
        Text('Vence el ${formatDateLong(_expires!)}.${_email.text.trim().isNotEmpty ? ' Solo podrá aceptarla ${_email.text.trim()}.' : ''}',
            style: context.text.bodySmall),
        const SizedBox(height: 8),
        const Notice(message: 'El envío automático por correo requiere configurar un proveedor de e-mail (pendiente). Por ahora comparte el enlace.'),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => SharePlus.instance.share(ShareParams(text: 'Te invito a "${widget.ws.name}" en NEXO Finance: $_link')),
          icon: const Icon(Icons.share),
          label: const Text('Compartir'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _link!));
            showSuccess(context, 'Enlace copiado');
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copiar enlace'),
        ),
      ]);
    }
    final roles = [if (widget.ws.myRole == MemberRole.owner) MemberRole.admin, MemberRole.member, MemberRole.viewer];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader('Invitar a ${widget.ws.name}'),
      RadioGroup<MemberRole>(
        groupValue: _role,
        onChanged: (v) => setState(() => _role = v!),
        child: Column(children: [
          for (final r in roles)
            RadioListTile<MemberRole>(contentPadding: EdgeInsets.zero, value: r, title: Text(r.label), subtitle: Text(r.description)),
        ]),
      ),
      TextField(
        controller: _email,
        keyboardType: TextInputType.emailAddress,
        decoration: const InputDecoration(labelText: 'Correo de la persona (opcional)', helperText: 'Si lo indicas, solo esa cuenta podrá aceptar'),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: busy
            ? null
            : () => runBusy(() async {
                  final r = await ref.read(workspaceRepositoryProvider).invite(widget.ws.id, _role, email: _email.text.trim().isEmpty ? null : _email.text.trim());
                  ref.read(spacesRevisionProvider.notifier).bump();
                  setState(() {
                    _link = '${Env.inviteBaseUrl}/${r.token}';
                    _expires = r.expiresAt;
                  });
                }, onError: (e) => showFailure(context, e)),
        child: const Text('Crear enlace de invitación'),
      ),
    ]);
  }
}

class _SettingsTab extends ConsumerStatefulWidget {
  const _SettingsTab({required this.ws});
  final Workspace ws;
  @override
  ConsumerState<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<_SettingsTab> with BusyState {
  late final _name = TextEditingController(text: widget.ws.name);
  SplitRule? _rule;
  static const _example = 100000;

  @override
  Widget build(BuildContext context) {
    final ws = widget.ws;
    final members = ref.watch(membersProvider(ws.id)).value ?? const <Member>[];
    final me = ref.watch(currentUserIdProvider) ?? '';
    final active = members.where((m) => m.active).toList();
    _rule ??= defaultRule(ws, me, members);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
      if (ws.canAdmin && !ws.isPersonal) ...[
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nombre del espacio')),
        const SectionTitle('Regla de reparto por defecto'),
        Text('Se propone en cada gasto nuevo y se puede cambiar en cada uno. Vista previa con ${formatMinor(_example, ws.baseCurrency)}:',
            style: context.text.bodySmall),
        const SizedBox(height: 8),
        if (active.isNotEmpty)
          SplitEditor(
            members: active,
            rule: _rule!,
            totalMinor: _example,
            currency: ws.baseCurrency,
            methods: const [SplitMethod.equal, SplitMethod.percent, SplitMethod.shares],
            onChanged: (r) => _rule = r,
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy
              ? null
              : () => runBusy(() async {
                    await ref.read(workspaceRepositoryProvider).update(ws, name: _name.text, defaultSplit: {'method': _rule!.method.wire, ..._rule!.toJson()});
                    ref.read(spacesRevisionProvider.notifier).bump();
                    if (context.mounted) showSuccess(context, 'Ajustes guardados');
                  }, onError: (e) => showFailure(context, e)),
          child: const Text('Guardar ajustes'),
        ),
      ],
      const SectionTitle('Información'),
      ListTile(contentPadding: EdgeInsets.zero, title: const Text('Tipo'), trailing: Text(ws.kind.label)),
      ListTile(contentPadding: EdgeInsets.zero, title: const Text('Moneda base'), trailing: Text(ws.baseCurrency.code)),
      ListTile(contentPadding: EdgeInsets.zero, title: const Text('Tu rol'), trailing: Text(ws.myRole?.label ?? '')),
      if (ws.isPersonal) const Notice(message: 'Tu espacio personal es privado: nadie más puede verlo ni unirse.'),
      if (!ws.isPersonal) ...[
        const SectionTitle('Zona sensible'),
        OutlinedButton.icon(
          onPressed: busy ? null : () async {
            if (!await confirmAction(context, title: 'Abandonar ${ws.name}',
                message: 'Perderás el acceso. Tus gastos y saldos pendientes se conservan en el historial del espacio.',
                confirmLabel: 'Abandonar', destructive: true)) {
              return;
            }
            await runBusy(() async {
              await ref.read(workspaceRepositoryProvider).leave(ws.id);
              ref.read(spacesRevisionProvider.notifier).bump();
              if (context.mounted) context.go('/spaces');
            }, onError: (e) => showFailure(context, e));
          },
          icon: const Icon(Icons.logout),
          label: const Text('Abandonar espacio'),
        ),
        if (ws.myRole == MemberRole.owner && !ws.archived) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: context.colors.error),
            onPressed: busy ? null : () async {
              if (!await confirmAction(context, title: 'Archivar ${ws.name}',
                  message: 'Nadie podrá registrar nuevos movimientos. El historial seguirá visible para los miembros.',
                  confirmLabel: 'Archivar', destructive: true, typeToConfirm: 'ARCHIVAR')) {
                return;
              }
              await runBusy(() async {
                await ref.read(workspaceRepositoryProvider).archive(ws.id);
                ref.read(spacesRevisionProvider.notifier).bump();
              }, onError: (e) => showFailure(context, e));
            },
            icon: const Icon(Icons.archive_outlined),
            label: const Text('Archivar espacio'),
          ),
        ],
      ],
    ]);
  }
}
