import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/config/env.dart';
import '../../core/finance/csv_export.dart';
import '../../core/finance/expense_draft.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/security/app_lock.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';
import '../auth/auth_screens.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider).value;
    final email = ref.watch(authRepositoryProvider).user?.email;
    Widget item(IconData icon, String title, String route, {String? subtitle}) => ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push(route),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: ListView(children: [
        ListTile(
          leading: PersonAvatar(name: profile?.displayName ?? '?', size: 48),
          title: Text(profile?.displayName ?? '', style: context.text.titleMedium),
          subtitle: Text(email ?? ''),
          trailing: IconButton(tooltip: 'Editar nombre', icon: const Icon(Icons.edit_outlined), onPressed: () => _editName(context, ref, profile)),
        ),
        const Divider(),
        item(Icons.account_balance_wallet_outlined, 'Cuentas y medios de pago', '/profile/accounts'),
        item(Icons.tune, 'Preferencias', '/profile/preferences', subtitle: 'Moneda, tema, ingresos'),
        item(Icons.notifications_none, 'Notificaciones', '/profile/notifications'),
        item(Icons.lock_outline, 'Seguridad', '/profile/security', subtitle: 'Bloqueo, sesiones, contraseña'),
        item(Icons.privacy_tip_outlined, 'Datos y privacidad', '/profile/data', subtitle: 'Exportar, eliminar cuenta'),
        item(Icons.auto_awesome_outlined, 'Inteligencia artificial', '/profile/ai', subtitle: 'Estado y uso de tus datos'),
        item(Icons.upload_file_outlined, 'Importar movimientos', '/import'),
        const ListTile(
          leading: Icon(Icons.account_balance_outlined),
          title: Text('Conexión bancaria automática'),
          subtitle: Text('Pendiente: requiere un proveedor autorizado en Colombia y tu consentimiento. Usa la importación de archivos.'),
          enabled: false,
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Cerrar sesión'),
          onTap: () async {
            if (!await confirmAction(context, title: 'Cerrar sesión', message: 'Los borradores pendientes de este dispositivo se borrarán.',
                confirmLabel: 'Cerrar sesión')) {
              return;
            }
            try {
              await ref.read(authRepositoryProvider).signOut();
              if (context.mounted) context.go('/welcome');
            } catch (e) {
              if (context.mounted) showFailure(context, e);
            }
          },
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('NEXO Finance · ${Env.flavor}', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
        ),
      ]),
    );
  }

  Future<void> _editName(BuildContext context, WidgetRef ref, Profile? p) async {
    final c = TextEditingController(text: p?.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nombre visible'),
        content: TextField(controller: c, autofocus: true, maxLength: 60, textCapitalization: TextCapitalization.words),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Guardar')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await ref.read(profileRepositoryProvider).updateName(name);
      ref.invalidate(profileProvider);
      ref.read(spacesRevisionProvider.notifier).bump();
    } catch (e) {
      if (context.mounted) showFailure(context, e);
    }
  }
}

final _balancesProvider = FutureProvider.autoDispose<Map<String, int>>((ref) {
  ref.watch(ledgerRevisionProvider);
  return ref.watch(catalogRepositoryProvider).accountBalances();
});

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider);
    final balances = ref.watch(_balancesProvider).value ?? const <String, int>{};
    return Scaffold(
      appBar: AppBar(title: const Text('Cuentas')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'acc',
        onPressed: () => showNxSheet(context, builder: (_) => const _AccountSheet()),
        icon: const Icon(Icons.add),
        label: const Text('Nueva cuenta'),
      ),
      body: AsyncView(
        value: accounts,
        onRetry: () => ref.invalidate(accountsProvider),
        data: (list) => ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
          const Notice(message: 'Tus cuentas son privadas: aunque pagues un gasto compartido con ellas, los demás miembros no las ven. '
              'Los saldos son manuales: parten del saldo inicial y se actualizan con lo que registras.'),
          const SizedBox(height: 12),
          if (list.isEmpty) const EmptyState(compact: true, icon: Icons.account_balance_wallet_outlined, title: 'Sin cuentas',
              message: 'Añade efectivo, cuentas bancarias, tarjetas o billeteras para saber con qué pagas.'),
          for (final a in list)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(a.type.icon),
                title: Text(a.name),
                subtitle: Text(a.type.label + (a.type == AccountType.creditCard ? ' · saldo negativo = deuda' : '')),
                trailing: balances[a.id] == null ? null : AmountText(balances[a.id]!, a.currency, colorize: a.type != AccountType.creditCard),
                onTap: () => showNxSheet(context, builder: (_) => _AccountSheet(account: a)),
              ),
            ),
        ]),
      ),
    );
  }
}

class _AccountSheet extends ConsumerStatefulWidget {
  const _AccountSheet({this.account});
  final Account? account;
  @override
  ConsumerState<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends ConsumerState<_AccountSheet> with BusyState {
  late final _name = TextEditingController(text: widget.account?.name);
  late AccountType _type = widget.account?.type ?? AccountType.bank;
  late String _currency = widget.account?.currency.code ?? 'COP';
  late int? _opening = widget.account?.openingBalanceMinor;

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SheetHeader(a == null ? 'Nueva cuenta' : 'Editar cuenta'),
      TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nombre', hintText: 'Ej.: Bancolombia ahorros')),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in AccountType.values)
          ChoiceChip(avatar: Icon(t.icon, size: 18), label: Text(t.label), selected: _type == t, onSelected: (_) => setState(() => _type = t)),
      ]),
      const SizedBox(height: 12),
      if (a == null)
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: _currency,
          decoration: const InputDecoration(labelText: 'Moneda'),
          items: [for (final c in Currency.all) DropdownMenuItem(value: c.code, child: Text(c.code))],
          onChanged: (v) => setState(() => _currency = v ?? 'COP'),
        ),
      const SizedBox(height: 12),
      MoneyField(currency: Currency.of(_currency), label: _type == AccountType.creditCard ? 'Deuda actual (opcional)' : 'Saldo inicial',
          allowZero: true, initialMinor: _opening?.abs(), onChanged: (v) => _opening = v),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: busy ? null : () => runBusy(() async {
          if (_name.text.trim().isEmpty) return;
          final opening = _type == AccountType.creditCard ? -(_opening ?? 0) : (_opening ?? 0);
          final repo = ref.read(catalogRepositoryProvider);
          if (a == null) {
            await repo.createAccount(name: _name.text, type: _type, currency: _currency, opening: opening);
          } else {
            await repo.updateAccount(a.id, {'name': _name.text.trim(), 'type': _type.wire, 'opening_balance_minor': opening});
          }
          ref.read(ledgerRevisionProvider.notifier).bump();
          if (context.mounted) Navigator.pop(context);
        }, onError: (e) => showFailure(context, e)),
        child: const Text('Guardar'),
      ),
      if (a != null)
        TextButton(
          onPressed: busy ? null : () => runBusy(() async {
            await ref.read(catalogRepositoryProvider).updateAccount(a.id, {'archived_at': DateTime.now().toUtc().toIso8601String()});
            ref.read(ledgerRevisionProvider.notifier).bump();
            if (context.mounted) Navigator.pop(context);
          }, onError: (e) => showFailure(context, e)),
          child: const Text('Archivar cuenta'),
        ),
    ]);
  }
}

class PreferencesScreen extends ConsumerStatefulWidget {
  const PreferencesScreen({super.key});
  @override
  ConsumerState<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends ConsumerState<PreferencesScreen> {
  Future<void> _set(Map<String, dynamic> v) async {
    try {
      await ref.read(profileRepositoryProvider).updatePreferences(v);
      ref.invalidate(preferencesProvider);
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(preferencesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Preferencias')),
      body: AsyncView(
        value: prefs,
        data: (p) => ListView(padding: const EdgeInsets.all(16), children: [
          Text('Tema', style: context.text.titleSmall),
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'system', label: Text('Sistema')), ButtonSegment(value: 'light', label: Text('Claro')),
              ButtonSegment(value: 'dark', label: Text('Oscuro'))],
            selected: {p.theme},
            onSelectionChanged: (s) => _set({'theme': s.first}),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: p.defaultCurrency,
            decoration: const InputDecoration(labelText: 'Moneda principal', helperText: 'Para resúmenes y estadísticas; no convierte importes'),
            items: [for (final c in Currency.all) DropdownMenuItem(value: c.code, child: Text('${c.name} (${c.code})'))],
            onChanged: (v) => _set({'default_currency': v}),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: p.timezone,
            decoration: const InputDecoration(labelText: 'Zona horaria'),
            items: const [DropdownMenuItem(value: 'America/Bogota', child: Text('Bogotá (UTC−5)'))],
            onChanged: (v) => _set({'timezone': v}),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            isExpanded: true,
            initialValue: p.incomeFrequency,
            decoration: const InputDecoration(labelText: 'Frecuencia de ingresos'),
            items: const [
              DropdownMenuItem(value: null, child: Text('Sin indicar')),
              DropdownMenuItem(value: 'monthly', child: Text('Mensual')),
              DropdownMenuItem(value: 'biweekly', child: Text('Quincenal')),
              DropdownMenuItem(value: 'weekly', child: Text('Semanal')),
              DropdownMenuItem(value: 'irregular', child: Text('Variable')),
            ],
            onChanged: (v) => _set({'income_frequency': v}),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int?>(
            isExpanded: true,
            initialValue: p.incomeDay,
            decoration: const InputDecoration(labelText: 'Día habitual de ingreso'),
            items: [const DropdownMenuItem(value: null, child: Text('Sin día fijo')),
              for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('Día $d'))],
            onChanged: (v) => _set({'income_day': v}),
          ),
          const SizedBox(height: 12),
          const Notice(message: 'Idioma: español (Colombia). La arquitectura admite más idiomas y países en el futuro.'),
        ]),
      ),
    );
  }
}

class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  static const _kinds = {
    'budget_alerts': 'Presupuesto cerca del límite',
    'due_reminders': 'Próximos vencimientos',
    'shared_expenses': 'Gastos compartidos nuevos',
    'receipt_changes': 'Cambios en una factura',
    'invitations': 'Invitaciones a espacios',
    'settlements': 'Reembolsos',
    'goals': 'Metas de ahorro',
    'monthly_close': 'Cierre mensual disponible',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(preferencesProvider);
    Future<void> set(Map<String, dynamic> v) async {
      try {
        await ref.read(profileRepositoryProvider).updatePreferences(v);
        ref.invalidate(preferencesProvider);
      } catch (e) {
        if (context.mounted) showFailure(context, e);
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Notificaciones')),
      body: AsyncView(
        value: prefs,
        data: (p) => ListView(children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Notice(message: 'Las notificaciones aparecen dentro de la app. Las notificaciones push requieren configurar '
                'Firebase Cloud Messaging y APNs (pendiente).'),
          ),
          for (final e in _kinds.entries)
            SwitchListTile(
              title: Text(e.value),
              value: p.notificationSettings[e.key] as bool? ?? true,
              onChanged: (v) => set({'notification_settings': {...p.notificationSettings, e.key: v}}),
            ),
          const Divider(),
          SwitchListTile(
            title: const Text('Mostrar importes en notificaciones'),
            subtitle: const Text('Desactivado por defecto para que no se vean en la pantalla bloqueada.'),
            value: p.showAmountsInNotifications,
            onChanged: (v) => set({'show_amounts_in_notifications': v}),
          ),
        ]),
      ),
    );
  }
}

class SecurityScreen extends ConsumerWidget {
  const SecurityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lock = ref.watch(appLockProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Seguridad')),
      body: ListView(children: [
        SwitchListTile(
          secondary: const Icon(Icons.fingerprint),
          title: const Text('Bloqueo biométrico'),
          subtitle: Text(lock?.supported == false
              ? 'No disponible en este dispositivo.'
              : 'Pide huella, rostro o el código del dispositivo al abrir la app y tras 1 minuto en segundo plano.'),
          value: lock?.enabled ?? false,
          onChanged: lock?.supported == true
              ? (v) async {
                  final ok = await ref.read(appLockProvider.notifier).setEnabled(v);
                  if (!ok && context.mounted) showFailure(context, Exception('No se pudo verificar tu identidad.'));
                }
              : null,
        ),
        ListTile(
          leading: const Icon(Icons.password),
          title: const Text('Cambiar contraseña'),
          onTap: () => showNxSheet(context, builder: (_) => const _ChangePasswordSheet()),
        ),
        ListTile(
          leading: const Icon(Icons.devices_other),
          title: const Text('Cerrar sesión en otros dispositivos'),
          subtitle: const Text('Mantiene abierta solo esta sesión.'),
          onTap: () async {
            if (!await confirmAction(context, title: 'Cerrar otras sesiones', message: 'Se cerrará la sesión en todos tus otros dispositivos.')) return;
            try {
              await ref.read(authRepositoryProvider).signOutOtherDevices();
              if (context.mounted) showSuccess(context, 'Otras sesiones cerradas');
            } catch (e) {
              if (context.mounted) showFailure(context, e);
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Cerrar sesión en todos los dispositivos'),
          onTap: () async {
            if (!await confirmAction(context, title: 'Cerrar todas las sesiones', message: 'Tendrás que iniciar sesión de nuevo en todos lados.')) return;
            try {
              await ref.read(authRepositoryProvider).signOut(everywhere: true);
              if (context.mounted) context.go('/welcome');
            } catch (e) {
              if (context.mounted) showFailure(context, e);
            }
          },
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Notice(message: 'Tu sesión se guarda cifrada en el almacenamiento seguro del dispositivo. Las comunicaciones usan HTTPS.'),
        ),
      ]),
    );
  }
}

class _ChangePasswordSheet extends ConsumerStatefulWidget {
  const _ChangePasswordSheet();
  @override
  ConsumerState<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends ConsumerState<_ChangePasswordSheet> with BusyState {
  final _form = GlobalKey<FormState>();
  final _p = TextEditingController();

  @override
  Widget build(BuildContext context) => Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SheetHeader('Nueva contraseña'),
          TextFormField(controller: _p, obscureText: true, decoration: const InputDecoration(labelText: 'Nueva contraseña'), validator: validatePassword),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : () {
              if (!_form.currentState!.validate()) return;
              runBusy(() async {
                await ref.read(authRepositoryProvider).updatePassword(_p.text);
                if (context.mounted) {
                  Navigator.pop(context);
                  showSuccess(context, 'Contraseña actualizada');
                }
              }, onError: (e) => showFailure(context, e));
            },
            child: const Text('Guardar'),
          ),
        ]),
      );
}

class DataPrivacyScreen extends ConsumerStatefulWidget {
  const DataPrivacyScreen({super.key});
  @override
  ConsumerState<DataPrivacyScreen> createState() => _DataPrivacyScreenState();
}

class _DataPrivacyScreenState extends ConsumerState<DataPrivacyScreen> with BusyState {
  DateTimeRange? _range;
  String? _workspace;
  bool _notes = false;
  bool _receipt = false;
  String? _kind;

  Future<void> _share(Uint8List bytes, String name, String mime) =>
      SharePlus.instance.share(ShareParams(files: [XFile.fromData(bytes, name: name, mimeType: mime)], fileNameOverrides: [name]));

  Future<void> _exportJson() => runBusy(() async {
        final data = await ref.read(profileRepositoryProvider).exportData();
        final bytes = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(data)));
        await _share(bytes, 'nexo-mis-datos.json', 'application/json');
      }, onError: (e) => showFailure(context, e));

  Future<void> _exportCsv() => runBusy(() async {
        final now = DateTime.now();
        final range = _range ?? DateTimeRange(start: DateTime(now.year, now.month), end: now);
        // Only rows the person can read are returned (RLS), so the export never
        // contains data outside their authorised workspaces.
        final txs = await ref.read(transactionRepositoryProvider).list(
            TransactionFilter(from: range.start, to: range.end, workspaceIds: _workspace == null ? null : [_workspace!], kind: _kind), limit: 5000);
        final me = ref.read(currentUserIdProvider)!;
        final spaces = await ref.read(workspacesProvider.future);
        final cats = await ref.read(categoriesProvider.future);
        final rows = <ExportRow>[];
        for (final t in txs) {
          String? lines;
          if (_receipt) {
            final full = await ref.read(transactionRepositoryProvider).get(t.id);
            lines = full?.receipt?.items.map((i) => '${i.description}=${i.lineTotalMinor}').join(' | ');
          }
          rows.add(ExportRow(
            date: isoDate(t.occurredOn), kind: t.kind, workspace: spaces.where((w) => w.id == t.workspaceId).firstOrNull?.name ?? '',
            description: t.description, merchant: t.merchant, category: cats.where((c) => c.id == t.categoryId).firstOrNull?.name,
            currency: t.currency.code, totalMinor: t.totalMinor,
            myShareMinor: t.isExpense ? t.shareOf(me) : null, paidByMeMinor: t.isExpense ? t.paidBy(me) : null,
            notes: t.notes, receiptLines: lines,
          ));
        }
        final csv = buildMovementsCsv(rows, includeNotes: _notes, includeReceipt: _receipt);
        await _share(Uint8List.fromList(utf8.encode(csv)), 'nexo-movimientos-${isoDate(range.start)}-${isoDate(range.end)}.csv', 'text/csv');
      }, onError: (e) => showFailure(context, e));

  @override
  Widget build(BuildContext context) {
    final spaces = ref.watch(workspacesProvider).value ?? const <Workspace>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Datos y privacidad')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Notice(message: 'Conforme a la Ley 1581 de 2012 puedes conocer, actualizar, rectificar y suprimir tus datos, '
            'y revocar la autorización de tratamiento.'),
        const SectionTitle('Exportar movimientos (CSV)'),
        OutlinedButton.icon(
          icon: const Icon(Icons.date_range),
          label: Text(_range == null ? 'Periodo: mes actual' : '${formatDateShort(_range!.start)} – ${formatDateShort(_range!.end)}'),
          onPressed: () async {
            final now = DateTime.now();
            final r = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 10), lastDate: now);
            if (r != null) setState(() => _range = r);
          },
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          isExpanded: true,
          initialValue: _workspace,
          decoration: const InputDecoration(labelText: 'Espacio'),
          items: [const DropdownMenuItem(value: null, child: Text('Todos mis espacios')),
            for (final w in spaces) DropdownMenuItem(value: w.id, child: Text(w.name))],
          onChanged: (v) => setState(() => _workspace = v),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          isExpanded: true,
          initialValue: _kind,
          decoration: const InputDecoration(labelText: 'Tipo'),
          items: const [DropdownMenuItem(value: null, child: Text('Todos')), DropdownMenuItem(value: 'expense', child: Text('Gastos')),
            DropdownMenuItem(value: 'income', child: Text('Ingresos')), DropdownMenuItem(value: 'transfer', child: Text('Transferencias'))],
          onChanged: (v) => setState(() => _kind = v),
        ),
        CheckboxListTile(contentPadding: EdgeInsets.zero, value: _notes, onChanged: (v) => setState(() => _notes = v ?? false), title: const Text('Incluir notas')),
        CheckboxListTile(contentPadding: EdgeInsets.zero, value: _receipt, onChanged: (v) => setState(() => _receipt = v ?? false),
            title: const Text('Incluir líneas de factura')),
        Text('Formato monetario: enteros en la unidad mínima de cada moneda (COP sin decimales).',
            style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: busy ? null : _exportCsv, icon: const Icon(Icons.download), label: const Text('Exportar CSV')),
        const SizedBox(height: 4),
        Text('Excel y PDF: pendientes. El CSV abre directamente en Excel o Google Sheets.', style: context.text.bodySmall),
        const SectionTitle('Copia completa de tus datos'),
        OutlinedButton.icon(onPressed: busy ? null : _exportJson, icon: const Icon(Icons.data_object), label: const Text('Descargar mis datos (JSON)')),
        const SectionTitle('Eliminar cuenta'),
        const Text('Se borran tu espacio personal, cuentas, ingresos, metas, informes y preferencias. En los espacios compartidos tu '
            'historial se conserva con el nombre «Usuario eliminado» para que los saldos de los demás sigan siendo correctos.'),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: context.colors.error),
          icon: const Icon(Icons.delete_forever_outlined),
          label: const Text('Eliminar mi cuenta'),
          onPressed: busy ? null : () async {
            if (!await confirmAction(context, title: 'Eliminar cuenta', message: 'Esta acción no se puede deshacer. Te recomendamos exportar tus datos antes.',
                confirmLabel: 'Eliminar definitivamente', destructive: true, typeToConfirm: 'ELIMINAR')) {
              return;
            }
            await runBusy(() async {
              await ref.read(profileRepositoryProvider).deleteAccount();
              await ref.read(authRepositoryProvider).signOut().catchError((_) {});
              if (context.mounted) context.go('/welcome');
            }, onError: (e) => showFailure(context, e));
          },
        ),
        const SectionTitle('Política de datos'),
        const PrivacyPolicySummary(),
      ]),
    );
  }
}

class AiStatusScreen extends ConsumerWidget {
  const AiStatusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(aiCapabilitiesProvider);
    Widget row(String title, bool on, String detail) => ListTile(
          leading: Icon(on ? Icons.check_circle_outline : Icons.pending_outlined, color: on ? context.nexo.positive : context.nexo.muted),
          title: Text(title),
          subtitle: Text('${on ? 'Configurado' : 'Pendiente de configuración'} · $detail'),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Inteligencia artificial')),
      body: AsyncView(
        value: caps,
        data: (c) => ListView(children: [
          if (!c.reachable) const Padding(padding: EdgeInsets.all(16), child: Notice(kind: NoticeKind.warning, message: 'No pudimos consultar el estado del servidor.')),
          row('Interpretar texto', c.textParsing, 'si no está, se usa una interpretación básica en el dispositivo'),
          row('Leer facturas', c.receiptExtraction, 'si no está, puedes escribir las líneas'),
          row('Transcribir voz', c.transcription, 'si no está, el registro por voz no se ofrece'),
          row('Copiloto', c.copilot, 'responde con agregaciones verificadas del servidor'),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Qué se envía: solo el texto, la factura o el audio que tú decides procesar, con nombres de pila y alias en lugar de '
                'identificadores. No se envían tus saldos ni datos de otros miembros salvo los nombres necesarios para repartir. '
                'Nada se guarda sin tu confirmación, y el audio no se almacena.'),
          ),
        ]),
      ),
    );
  }
}
