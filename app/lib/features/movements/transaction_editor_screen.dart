import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/failure.dart';
import '../../core/finance/expense_draft.dart';
import '../../core/finance/receipt_engine.dart';
import '../../core/finance/split_rules.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';
import 'draft_mapper.dart';
import 'receipt_editor.dart';
import 'save_flow.dart';
import 'split_editor.dart';

class TransactionEditorScreen extends ConsumerStatefulWidget {
  const TransactionEditorScreen({super.key, this.initialDraft, this.kind, this.workspaceId, this.editId});
  final ExpenseDraft? initialDraft;
  final String? kind;
  final String? workspaceId;
  final String? editId;

  @override
  ConsumerState<TransactionEditorScreen> createState() => _TransactionEditorScreenState();
}

class _TransactionEditorScreenState extends ConsumerState<TransactionEditorScreen> with BusyState {
  ExpenseDraft? _draft;
  Object? _loadError;
  int _formKey = 0;
  bool _multiPayer = false;

  String get _me => ref.read(currentUserIdProvider)!;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _loadError = null;
      _draft = null;
    });
    try {
      final spaces = await ref.read(workspacesProvider.future);
      ExpenseDraft draft;
      if (widget.editId != null) {
        final t = await ref.read(transactionRepositoryProvider).get(widget.editId!);
        if (t == null || t.deleted) throw const AppFailure(FailureKind.notFound, 'Este movimiento ya no existe o fue eliminado.');
        final ws = spaces.firstWhere((w) => w.id == t.workspaceId);
        if (!ws.canWrite) throw const AppFailure(FailureKind.permission, 'Tu rol en este espacio solo permite consultar.');
        draft = draftFromTransaction(t, ws);
      } else if (widget.initialDraft != null) {
        draft = widget.initialDraft!;
      } else {
        final kind = switch (widget.kind) {
          'income' => TxKind.income,
          'transfer' => TxKind.transfer,
          _ => TxKind.expense,
        };
        final personal = spaces.firstWhere((w) => w.isPersonal);
        final ws = kind == TxKind.expense && widget.workspaceId != null
            ? spaces.firstWhere((w) => w.id == widget.workspaceId && w.canWrite, orElse: () => personal)
            : personal;
        final members = await ref.read(membersProvider(ws.id).future);
        draft = newDraft(ws: ws, me: _me, members: members, kind: kind);
      }
      // Membership may have changed since it was cached (someone joined or
      // left): always offer the current members when composing a split.
      ref.invalidate(membersProvider(draft.workspaceId));
      if (widget.editId == null && widget.initialDraft == null) {
        final ws = (await ref.read(workspacesProvider.future)).firstWhere((w) => w.id == draft.workspaceId);
        draft.rule = defaultRule(ws, _me, await ref.read(membersProvider(ws.id).future));
      }
      _multiPayer = draft.payments.length > 1;
      if (mounted) setState(() => _draft = draft);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _update(void Function(ExpenseDraft d) change) => setState(() => change(_draft!));

  Future<void> _changeWorkspace(Workspace ws) async {
    ref.invalidate(membersProvider(ws.id));
    final members = await ref.read(membersProvider(ws.id).future);
    final cats = await ref.read(categoriesProvider.future);
    _update((d) {
      d.workspaceId = ws.id;
      d.personalWorkspace = ws.isPersonal;
      d.currency = ws.baseCurrency;
      d.rule = d.byItem ? const ByItemSplit() : defaultRule(ws, _me, members);
      d.payments = [PaymentDraft(payerId: _me, amountMinor: d.totalMinor ?? 0)];
      final cat = cats.where((c) => c.id == d.categoryId).firstOrNull;
      if (cat?.workspaceId != null && cat!.workspaceId != ws.id) d.categoryId = null;
      final active = members.where((m) => m.active).map((m) => m.userId).toList();
      for (final l in d.receipt?.lines ?? <ReceiptLine>[]) {
        l.rule = ws.isPersonal ? SingleSplit(_me) : EqualSplit(active);
      }
    });
    _multiPayer = false;
    _formKey++;
  }

  Future<void> _save() async {
    final d = _draft!;
    if (d.kind == TxKind.expense && d.payments.length == 1) d.payments.first.amountMinor = d.totalMinor ?? 0;
    final blocking = d.validate().where((i) => i.blocking).toList();
    if (blocking.isNotEmpty) {
      HapticFeedback.heavyImpact();
      await showNxSheet(
        context,
        builder: (_) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHeader('Revisa antes de guardar'),
            for (final i in blocking)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Notice(kind: NoticeKind.warning, message: i.message),
              ),
          ],
        ),
      );
      return;
    }
    final outcome = await runBusy(() => saveDraft(context, ref, d));
    if (!mounted || outcome == null) return;
    switch (outcome) {
      case Saved(:final id):
        HapticFeedback.lightImpact();
        showSuccess(context, d.isEdit ? 'Cambios guardados' : 'Movimiento guardado');
        if (d.isEdit) {
          context.pop();
        } else {
          context.pushReplacement('/tx/$id');
        }
      case KeptOffline():
        showSuccess(context, 'Sin conexión: quedó en este dispositivo como pendiente de sincronizar.');
        context.pop();
      case Failed(:final failure) when failure.kind == FailureKind.conflict:
        final reload = await confirmAction(
          context,
          title: 'Otra persona editó este gasto',
          message: 'Para no sobrescribir sus cambios, recarga la versión actual. Tus cambios sin guardar se descartarán.',
          confirmLabel: 'Recargar',
        );
        if (reload) _init();
      case Failed(:final failure):
        showFailure(context, failure);
      case Cancelled():
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _draft;
    final title = widget.editId != null
        ? 'Editar movimiento'
        : switch (d?.kind) {
            TxKind.income => 'Nuevo ingreso',
            TxKind.transfer => 'Nueva transferencia',
            _ => 'Nuevo gasto',
          };
    if (_loadError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ErrorState(error: _loadError!, onRetry: _init),
      );
    }
    if (d == null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const LoadingState(),
      );
    }

    final spaces = ref.watch(workspacesProvider).value ?? const <Workspace>[];
    final ws = spaces.where((w) => w.id == d.workspaceId).firstOrNull;
    final membersAsync = ref.watch(membersProvider(d.workspaceId));
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    final accounts = (ref.watch(accountsProvider).value ?? const <Account>[]).where((a) => a.currency == d.currency).toList();
    final issues = d.validate().where((i) => !i.blocking).toList();

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: AsyncView(
        value: membersAsync,
        onRetry: () => ref.invalidate(membersProvider(d.workspaceId)),
        data: (allMembers) {
          final involved = {...d.payments.map((p) => p.payerId), ...d.rule.participants};
          final members = allMembers.where((m) => m.active || involved.contains(m.userId)).toList();
          return ListView(
            key: ValueKey(_formKey),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              if (widget.editId == null && d.source == TxSource.manual) _kindSelector(d),
              const SizedBox(height: 12),
              MoneyField(
                currency: d.currency,
                large: true,
                autofocus: d.totalMinor == null,
                initialMinor: d.totalMinor,
                label: d.kind == TxKind.expense ? 'Total pagado' : 'Importe',
                onChanged: (v) => _update((x) {
                  x.totalMinor = v;
                  if (x.payments.length == 1) x.payments.first.amountMinor = v ?? 0;
                }),
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: d.description,
                decoration: const InputDecoration(labelText: 'Concepto'),
                textCapitalization: TextCapitalization.sentences,
                maxLength: 140,
                onChanged: (v) => _update((x) => x.description = v),
              ),
              if (d.kind == TxKind.expense)
                TextFormField(
                  initialValue: d.merchant,
                  decoration: const InputDecoration(labelText: 'Comercio (opcional)'),
                  onChanged: (v) => _update((x) => x.merchant = v),
                ),
              const SizedBox(height: 12),
              DateField(value: d.occurredOn, onChanged: (v) => _update((x) => x.occurredOn = v)),
              if (d.kind != TxKind.transfer) ...[const SizedBox(height: 12), _categoryField(context, d, categories)],
              if (d.kind == TxKind.expense) ...[
                const SectionTitle('Espacio'),
                _workspaceSelector(spaces, d),
                const SectionTitle('Quién pagó'),
                _payers(context, d, members, accounts),
                if (!(ws?.isPersonal ?? true)) ...[
                  SectionTitle(
                    'Cómo se reparte',
                    action: d.receipt != null && d.receipt!.lines.isNotEmpty
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const ExcludeSemantics(child: Text('Por producto')),
                              Semantics(
                                label: 'Repartir por producto',
                                child: Switch(
                                  value: d.byItem,
                                  onChanged: (v) => _update(
                                    (x) => x.rule = v
                                        ? const ByItemSplit()
                                        : EqualSplit(members.where((m) => m.active).map((m) => m.userId).toList()),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : null,
                  ),
                  if (!d.byItem)
                    SplitEditor(
                      key: ValueKey('split-${d.workspaceId}'),
                      members: members,
                      rule: d.rule,
                      totalMinor: d.totalMinor ?? 0,
                      currency: d.currency,
                      onChanged: (r) => _update((x) => x.rule = r),
                    )
                  else
                    const Notice(message: 'Cada línea de la factura se asigna a quien corresponde. El total por persona se calcula abajo.'),
                ],
                SectionTitle(
                  'Factura y productos',
                  action: d.receipt == null
                      ? TextButton.icon(
                          onPressed: () => _update((x) {
                            x.receipt = ReceiptDraft();
                            // Detailing a shared bill means assigning it product by product.
                            if (!(ws?.isPersonal ?? true)) x.rule = const ByItemSplit();
                          }),
                          icon: const Icon(Icons.list_alt, size: 18),
                          label: const Text('Detallar'),
                        )
                      : TextButton(
                          onPressed: () => _update((x) {
                            x.receipt = null;
                            if (x.byItem || x.rule is ByItemSplit) {
                              x.rule = EqualSplit(members.where((m) => m.active).map((m) => m.userId).toList());
                            }
                          }),
                          child: const Text('Quitar detalle'),
                        ),
                ),
                if (d.receipt != null)
                  ReceiptEditor(
                    receipt: d.receipt!,
                    members: ws?.isPersonal ?? true ? members.where((m) => m.userId == _me).toList() : members,
                    currency: d.currency,
                    paidTotal: d.totalMinor ?? 0,
                    categories: categories,
                    me: _me,
                    onChanged: () => setState(() {}),
                  )
                else
                  Text(
                    'Opcional: añade los productos para asignarlos por persona o categoría.',
                    style: context.text.bodyMedium?.copyWith(color: context.pami.muted),
                  ),
              ],
              if (d.kind == TxKind.income) ...[
                const SectionTitle('Cuenta que recibe'),
                _accountDropdown(accounts, d.accountId, (v) => _update((x) => x.accountId = v), allowNone: true),
              ],
              if (d.kind == TxKind.transfer) ...[
                const SectionTitle('Cuentas'),
                if (accounts.length < 2)
                  Notice(
                    kind: NoticeKind.info,
                    message: 'Necesitas al menos dos cuentas en ${d.currency.code} para registrar una transferencia.',
                    action: TextButton(onPressed: () => context.push('/profile/accounts'), child: const Text('Gestionar cuentas')),
                  ),
                _accountDropdown(accounts, d.accountId, (v) => _update((x) => x.accountId = v), label: 'Desde'),
                const SizedBox(height: 12),
                _accountDropdown(accounts, d.toAccountId, (v) => _update((x) => x.toAccountId = v), label: 'Hacia'),
                const SizedBox(height: 8),
                const Notice(message: 'Las transferencias y pagos de tarjeta mueven dinero entre tus cuentas: no se cuentan como gasto.'),
              ],
              const SectionTitle('Notas'),
              TextFormField(
                initialValue: d.notes,
                decoration: InputDecoration(
                  labelText: 'Notas (opcional)',
                  helperText: ws?.isPersonal ?? true ? 'Solo tú las ves' : 'Las verán los miembros de ${ws!.name}',
                ),
                maxLines: 3,
                maxLength: 2000,
                onChanged: (v) => _update((x) => x.notes = v),
              ),
              for (final i in issues)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Notice(message: i.message),
                ),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + MediaQuery.viewInsetsOf(context).bottom * 0),
          child: FilledButton(
            onPressed: busy ? null : _save,
            child: busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : Text(widget.editId != null ? 'Guardar cambios' : 'Guardar'),
          ),
        ),
      ),
    );
  }

  Widget _kindSelector(ExpenseDraft d) => SegmentedButton<TxKind>(
    segments: const [
      ButtonSegment(value: TxKind.expense, label: Text('Gasto'), icon: Icon(Icons.north_east, size: 18)),
      ButtonSegment(value: TxKind.income, label: Text('Ingreso'), icon: Icon(Icons.south_west, size: 18)),
      ButtonSegment(value: TxKind.transfer, label: Text('Transferencia'), icon: Icon(Icons.swap_horiz, size: 18)),
    ],
    selected: {d.kind},
    onSelectionChanged: (s) async {
      final kind = s.first;
      final personal = await ref.read(personalWorkspaceProvider.future);
      if (kind != TxKind.expense && d.workspaceId != personal.id) await _changeWorkspace(personal);
      _update((x) {
        x.kind = kind;
        x.categoryId = null;
        x.payments = kind == TxKind.expense ? [PaymentDraft(payerId: _me, amountMinor: x.totalMinor ?? 0)] : [];
        if (kind != TxKind.expense) x.receipt = null;
      });
    },
  );

  Widget _categoryField(BuildContext context, ExpenseDraft d, List<Category> categories) {
    final kind = d.kind == TxKind.income ? 'income' : 'expense';
    final options = categories.where((c) => c.kind == kind && (c.workspaceId == null || c.workspaceId == d.workspaceId)).toList();
    final selected = options.where((c) => c.id == d.categoryId).firstOrNull;
    return InkWell(
      borderRadius: BorderRadius.circular(PamiTokens.radiusS),
      onTap: () async {
        final picked = await showNxSheet<Category>(
          context,
          builder: (ctx) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHeader('Categoría'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in options)
                    ChoiceChip(
                      avatar: Icon(c.iconData, size: 18, color: c.color),
                      label: Text(c.name),
                      selected: c.id == d.categoryId,
                      onSelected: (_) => Navigator.pop(ctx, c),
                    ),
                ],
              ),
            ],
          ),
        );
        if (picked != null) _update((x) => x.categoryId = picked.id);
      },
      child: InputDecorator(
        decoration: const InputDecoration(labelText: 'Categoría', suffixIcon: Icon(Icons.expand_more)),
        child: Row(
          children: [
            if (selected != null) ...[CategoryBadge(category: selected, size: 24), const SizedBox(width: 8)],
            Text(selected?.name ?? 'Elegir categoría'),
          ],
        ),
      ),
    );
  }

  Widget _workspaceSelector(List<Workspace> spaces, ExpenseDraft d) {
    final writable = spaces.where((w) => w.canWrite).toList();
    if (widget.editId != null) {
      final ws = spaces.where((w) => w.id == d.workspaceId).firstOrNull;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(ws?.kind.icon),
        title: Text(ws?.name ?? ''),
        subtitle: const Text('El espacio de un movimiento no se puede cambiar.'),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final w in writable)
          ChoiceChip(
            avatar: Icon(w.kind.icon, size: 18),
            label: Text(w.name),
            selected: w.id == d.workspaceId,
            onSelected: (_) => _changeWorkspace(w),
          ),
      ],
    );
  }

  Widget _payers(BuildContext context, ExpenseDraft d, List<Member> members, List<Account> accounts) {
    final shared = members.length > 1 || !(d.personalWorkspace);
    final myPayment = d.payments.where((p) => p.payerId == _me).firstOrNull;
    final children = <Widget>[];
    if (!_multiPayer) {
      final payer = d.payments.firstOrNull?.payerId ?? _me;
      if (shared) {
        children.add(
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in members.where((m) => m.active || m.userId == payer))
                ChoiceChip(
                  avatar: PersonAvatar(name: m.displayName, size: 22),
                  label: Text(m.userId == _me ? 'Yo' : m.displayName),
                  selected: payer == m.userId,
                  onSelected: (_) => _update((x) => x.payments = [PaymentDraft(payerId: m.userId, amountMinor: x.totalMinor ?? 0)]),
                ),
            ],
          ),
        );
      }
    } else {
      for (final m in members.where((m) => m.active || d.payments.any((p) => p.payerId == m.userId))) {
        final p = d.payments.where((p) => p.payerId == m.userId).firstOrNull;
        children.add(
          Row(
            children: [
              Checkbox(
                value: p != null,
                onChanged: (v) => _update((x) {
                  if (v == true) {
                    x.payments.add(PaymentDraft(payerId: m.userId, amountMinor: 0));
                  } else {
                    x.payments.removeWhere((q) => q.payerId == m.userId);
                  }
                }),
              ),
              Expanded(child: Text(m.userId == _me ? 'Yo' : m.displayName)),
              if (p != null)
                SizedBox(
                  width: 150,
                  child: MoneyField(
                    currency: d.currency,
                    label: 'Pagó',
                    initialMinor: p.amountMinor == 0 ? null : p.amountMinor,
                    onChanged: (v) => _update((_) => p.amountMinor = v ?? 0),
                  ),
                ),
            ],
          ),
        );
      }
    }
    if (shared) {
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() {
              _multiPayer = !_multiPayer;
              if (!_multiPayer) d.payments = [PaymentDraft(payerId: _me, amountMinor: d.totalMinor ?? 0)];
            }),
            child: Text(_multiPayer ? 'Pagó una sola persona' : 'Pagaron varias personas'),
          ),
        ),
      );
    }
    if (myPayment != null) {
      children.add(const SizedBox(height: 8));
      children.add(
        Row(
          children: [
            Expanded(
              child: _accountDropdown(
                accounts,
                myPayment.accountId,
                (v) => _update((_) => myPayment.accountId = v),
                allowNone: true,
                label: 'Mi cuenta o medio',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String?>(
                initialValue: myPayment.method,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Forma de pago'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Sin indicar')),
                  for (final e in paymentMethodLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => _update((_) => myPayment.method = v),
              ),
            ),
          ],
        ),
      );
      if (shared) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Los demás miembros ven que pagaste, no con qué cuenta.',
              style: context.text.bodySmall?.copyWith(color: context.pami.muted),
            ),
          ),
        );
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _accountDropdown(
    List<Account> accounts,
    String? value,
    ValueChanged<String?> onChanged, {
    bool allowNone = false,
    String label = 'Cuenta',
  }) {
    final valid = accounts.any((a) => a.id == value) ? value : null;
    return DropdownButtonFormField<String?>(
      initialValue: valid,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        if (allowNone || accounts.isEmpty) const DropdownMenuItem(value: null, child: Text('Sin cuenta')),
        for (final a in accounts)
          DropdownMenuItem(
            value: a.id,
            child: Row(
              children: [
                Icon(a.type.icon, size: 18),
                const SizedBox(width: 8),
                Flexible(child: Text(a.name, overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
