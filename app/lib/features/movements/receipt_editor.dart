import 'package:flutter/material.dart';

import '../../core/finance/receipt_engine.dart';
import '../../core/finance/split_rules.dart';
import '../../core/money/money.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';
import 'split_editor.dart';

/// One receipt, many lines, each assigned to whoever it belongs to.
class ReceiptEditor extends StatefulWidget {
  const ReceiptEditor({super.key, required this.receipt, required this.members, required this.currency, required this.paidTotal,
      required this.categories, required this.onChanged, required this.me});

  final ReceiptDraft receipt;
  final List<Member> members;
  final Currency currency;
  final int paidTotal;
  final List<Category> categories;
  final VoidCallback onChanged;
  final String me;

  @override
  State<ReceiptEditor> createState() => _ReceiptEditorState();
}

class _ReceiptEditorState extends State<ReceiptEditor> {
  ReceiptDraft get r => widget.receipt;
  bool get shared => widget.members.length > 1;

  void _changed() {
    setState(() {});
    widget.onChanged();
  }

  String _assignLabel(SplitRule rule) {
    final names = {for (final m in widget.members) m.userId: m.displayName.split(' ').first};
    return switch (rule) {
      SingleSplit(:final userId) => names[userId] ?? 'Sin asignar',
      EqualSplit(:final users) => users.length == widget.members.length ? 'Todos por igual' : users.map((u) => names[u] ?? '?').join(' + '),
      PercentSplit(:final bp) => bp.entries.map((e) => '${names[e.key] ?? '?'} ${formatBp(e.value, decimals: 0)}').join(' · '),
      FixedSplit() => 'Importes fijos',
      SharesSplit() => 'Proporciones',
      _ => 'Personalizado',
    };
  }

  Future<void> _editLine(int? index) async {
    final line = index == null
        ? ReceiptLine(description: '', lineTotalMinor: 0, rule: shared ? EqualSplit(widget.members.where((m) => m.active).map((m) => m.userId).toList()) : SingleSplit(widget.me))
        : r.lines[index].copy();
    final result = await showNxSheet<Object>(context, builder: (_) => _LineSheet(
      line: line, members: widget.members, currency: widget.currency, categories: widget.categories, isNew: index == null, shared: shared,
    ));
    if (result == null) return;
    if (result == 'delete' && index != null) {
      r.lines.removeAt(index);
    } else if (result is ReceiptLine) {
      if (index == null) {
        r.lines.add(result);
      } else {
        r.lines[index] = result;
      }
    }
    _changed();
  }

  void _quickAssign(int index, SplitRule rule) {
    r.lines[index].rule = rule;
    _changed();
  }

  @override
  Widget build(BuildContext context) {
    final c = computeReceipt(r, widget.paidTotal, widget.currency);
    final names = {for (final m in widget.members) m.userId: m.displayName};

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < r.lines.length; i++) _lineTile(context, i, c),
      if (r.lines.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Aún no hay líneas. Añade los productos de la factura.')),
      Wrap(spacing: 8, children: [
        OutlinedButton.icon(onPressed: () => _editLine(null), icon: const Icon(Icons.add), label: const Text('Añadir línea')),
        if (c.difference != 0 && r.lines.isNotEmpty)
          TextButton.icon(
            onPressed: () {
              r.lines.add(ReceiptLine(
                description: 'Ajuste por diferencia', lineTotalMinor: c.difference, isAdjustment: true,
                rule: shared ? EqualSplit(widget.members.where((m) => m.active).map((m) => m.userId).toList()) : SingleSplit(widget.me),
              ));
              _changed();
            },
            icon: const Icon(Icons.tune),
            label: Text('Añadir ajuste de ${formatMinor(c.difference, widget.currency, signed: true)}'),
          ),
      ]),
      const SizedBox(height: 16),
      Text('Impuestos, propina y descuentos', style: context.text.titleSmall),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: r.taxesIncluded,
        onChanged: (v) {
          r.taxesIncluded = v;
          _changed();
        },
        title: const Text('Los precios ya incluyen IVA'),
        subtitle: Text(r.taxesIncluded ? 'El impuesto es informativo y no se suma otra vez.' : 'El impuesto se suma al final y se reparte en proporción.'),
      ),
      Wrap(spacing: 12, runSpacing: 12, children: [
        _extra('IVA / impuestos', r.taxMinor, (v) => r.taxMinor = v),
        _extra('Propina', r.tipMinor, (v) => r.tipMinor = v),
        _extra('Descuento total', r.discountMinor, (v) => r.discountMinor = v),
        _extra('Otros cargos', r.otherChargesMinor, (v) => r.otherChargesMinor = v),
      ]),
      const SizedBox(height: 16),
      _Reconciliation(c: c, receipt: r, currency: widget.currency),
      for (final w in c.warnings) Padding(padding: const EdgeInsets.only(top: 8), child: Notice(kind: NoticeKind.warning, message: w)),
      if (shared && c.splits.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('Le corresponde a cada persona', style: context.text.titleSmall),
        const SizedBox(height: 4),
        for (final e in c.splits.entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: PersonAvatar(name: names[e.key] ?? '?', size: 28),
            title: Text(names[e.key] ?? 'Participante'),
            subtitle: (c.extrasByUser[e.key] ?? 0) != 0
                ? Text('Productos ${formatMinor(e.value - (c.extrasByUser[e.key] ?? 0), widget.currency)} + '
                    'extras ${formatMinor(c.extrasByUser[e.key]!, widget.currency)}')
                : null,
            trailing: AmountText(e.value, widget.currency),
          ),
      ],
    ]);
  }

  Widget _extra(String label, int value, void Function(int) set) => SizedBox(
        width: 160,
        child: MoneyField(
          currency: widget.currency,
          label: label,
          allowZero: true,
          initialMinor: value == 0 ? null : value,
          onChanged: (v) {
            set(v ?? 0);
            _changed();
          },
        ),
      );

  Widget _lineTile(BuildContext context, int i, ReceiptComputation c) {
    final line = r.lines[i];
    final lowConfidence = (line.confidence ?? 1) < 0.75;
    final err = c.lineErrors[i];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(NexoTokens.radiusM),
        onTap: () => _editLine(i),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(line.description.isEmpty ? 'Sin descripción' : line.description, style: context.text.titleSmall),
                  if (line.rawText != null && line.rawText != line.description)
                    Text('Leído: «${line.rawText}»', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
                ]),
              ),
              AmountText(line.lineTotalMinor, widget.currency, style: context.text.titleSmall),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (line.isAdjustment) Pill('Ajuste manual', icon: Icons.tune, color: context.nexo.info),
              if (lowConfidence) Pill('Revisar lectura', icon: Icons.visibility_outlined, color: context.nexo.warning),
              if (shared) ...[
                Pill(_assignLabel(line.rule), icon: Icons.call_split, color: err != null ? context.colors.error : context.colors.primary),
                for (final m in widget.members.where((m) => m.active))
                  _QuickPerson(
                    name: m.displayName,
                    selected: line.rule is SingleSplit && (line.rule as SingleSplit).userId == m.userId,
                    onTap: () => _quickAssign(i, SingleSplit(m.userId)),
                  ),
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: const Text('Todos'),
                  onPressed: () => _quickAssign(i, EqualSplit(widget.members.where((m) => m.active).map((m) => m.userId).toList())),
                ),
              ],
            ]),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(err, style: TextStyle(color: context.colors.error))),
          ]),
        ),
      ),
    );
  }
}

class _QuickPerson extends StatelessWidget {
  const _QuickPerson({required this.name, required this.selected, required this.onTap});
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        onTap: onTap,
        selected: selected,
        label: 'Asignar solo a $name',
        excludeSemantics: true,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(shape: BoxShape.circle,
                border: Border.all(color: selected ? context.colors.primary : Colors.transparent, width: 2)),
            child: PersonAvatar(name: name, size: 26),
          ),
        ),
      );
}

class _Reconciliation extends StatelessWidget {
  const _Reconciliation({required this.c, required this.receipt, required this.currency});
  final ReceiptComputation c;
  final ReceiptDraft receipt;
  final Currency currency;

  @override
  Widget build(BuildContext context) {
    final ok = c.difference == 0;
    Widget row(String label, int v, {bool strong = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(label, style: strong ? context.text.titleSmall : context.text.bodyMedium)),
            AmountText(v, currency, style: strong ? context.text.titleSmall : context.text.bodyMedium),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (ok ? context.nexo.positive : context.nexo.warning).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(NexoTokens.radiusS),
        border: Border.all(color: (ok ? context.nexo.positive : context.nexo.warning).withValues(alpha: 0.4)),
      ),
      child: Column(children: [
        row('Suma de líneas', receipt.linesTotal),
        if (receipt.extrasNet != 0) row('Impuestos, propina y descuentos', receipt.extrasNet),
        row('Total calculado', c.computedTotal, strong: true),
        row('Total pagado', c.paidTotal, strong: true),
        const Divider(height: 16),
        Semantics(
          liveRegion: true,
          child: Row(children: [
            Icon(ok ? Icons.check_circle_outline : Icons.warning_amber_rounded, color: ok ? context.nexo.positive : context.nexo.warning, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(ok ? 'La factura cuadra con el total pagado.'
                  : 'Diferencia de ${formatMinor(c.difference, currency, signed: true)}. Corrige las líneas o añade un ajuste explícito.'),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _LineSheet extends StatefulWidget {
  const _LineSheet({required this.line, required this.members, required this.currency, required this.categories, required this.isNew, required this.shared});
  final ReceiptLine line;
  final List<Member> members;
  final Currency currency;
  final List<Category> categories;
  final bool isNew;
  final bool shared;

  @override
  State<_LineSheet> createState() => _LineSheetState();
}

class _LineSheetState extends State<_LineSheet> {
  final _form = GlobalKey<FormState>();
  late final _desc = TextEditingController(text: widget.line.description);
  late ReceiptLine line = widget.line;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SheetHeader(widget.isNew ? 'Nueva línea' : 'Editar línea',
            subtitle: line.rawText == null ? null : 'Texto original detectado: «${line.rawText}»'),
        TextFormField(
          controller: _desc,
          decoration: const InputDecoration(labelText: 'Descripción'),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Escribe una descripción' : null,
        ),
        const SizedBox(height: 12),
        MoneyField(
          currency: widget.currency,
          label: line.isAdjustment ? 'Valor del ajuste' : 'Valor de la línea',
          initialMinor: line.lineTotalMinor == 0 ? null : line.lineTotalMinor.abs(),
          helper: line.isAdjustment && line.lineTotalMinor < 0 ? 'Este ajuste resta del total' : null,
          onChanged: (v) => setState(() => line.lineTotalMinor = (line.lineTotalMinor < 0 ? -1 : 1) * (v ?? 0)),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          isExpanded: true,
          initialValue: line.categoryId,
          decoration: const InputDecoration(labelText: 'Categoría de la línea (opcional)'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Igual que el gasto')),
            for (final c in widget.categories.where((c) => c.kind == 'expense')) DropdownMenuItem(value: c.id, child: Text(c.name)),
          ],
          onChanged: (v) => line.categoryId = v,
        ),
        if (widget.shared) ...[
          const SizedBox(height: 16),
          Text('¿A quién corresponde?', style: context.text.titleSmall),
          const SizedBox(height: 8),
          SplitEditor(
            members: widget.members,
            rule: line.rule,
            totalMinor: line.lineTotalMinor,
            currency: widget.currency,
            methods: const [SplitMethod.single, SplitMethod.equal, SplitMethod.percent, SplitMethod.fixed, SplitMethod.shares],
            onChanged: (r) => line.rule = r,
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            line.description = _desc.text.trim();
            if (line.rawText != null && line.confidence != null) line.confidence = 1; // reviewed by a person
            Navigator.pop(context, line);
          },
          child: const Text('Listo'),
        ),
        if (!widget.isNew)
          TextButton(
            onPressed: () => Navigator.pop(context, 'delete'),
            style: TextButton.styleFrom(foregroundColor: context.colors.error),
            child: const Text('Eliminar línea'),
          ),
      ]),
    );
  }
}
