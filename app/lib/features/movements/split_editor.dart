import 'package:flutter/material.dart';

import '../../core/finance/split_rules.dart';
import '../../core/money/money.dart';
import '../../core/theme/theme.dart';
import '../../data/models.dart';
import '../../ui/components.dart';
import '../../ui/states.dart';

const _percentCurrency = Currency('PCT', '%', 2, 'Porcentaje');

/// Choose how an amount is divided and see the exact result before saving.
class SplitEditor extends StatefulWidget {
  const SplitEditor({super.key, required this.members, required this.rule, required this.totalMinor, required this.currency,
      required this.onChanged, this.methods = const [SplitMethod.equal, SplitMethod.single, SplitMethod.percent, SplitMethod.fixed,
        SplitMethod.shares, SplitMethod.mixed], this.showPreview = true});

  final List<Member> members;
  final SplitRule rule;
  final int totalMinor;
  final Currency currency;
  final ValueChanged<SplitRule> onChanged;
  final List<SplitMethod> methods;
  final bool showPreview;

  @override
  State<SplitEditor> createState() => _SplitEditorState();
}

class _SplitEditorState extends State<SplitEditor> {
  late SplitMethod _method;
  late Set<String> _selected;
  late String _single;
  final Map<String, int> _bp = {};
  final Map<String, int> _amounts = {};
  final Map<String, int> _weights = {};
  bool _showMath = false;

  List<String> get _ids => widget.members.map((m) => m.userId).toList();
  Map<String, String> get _names => {for (final m in widget.members) m.userId: m.displayName};

  @override
  void initState() {
    super.initState();
    _load(widget.rule);
  }

  void _load(SplitRule r) {
    _method = r is ByItemSplit ? SplitMethod.equal : r.method;
    final participants = r.participants.where(_ids.contains).toList();
    _selected = (participants.isEmpty ? widget.members.where((m) => m.active).map((m) => m.userId) : participants).toSet();
    _single = participants.isNotEmpty ? participants.first : (_ids.isNotEmpty ? _ids.first : '');
    switch (r) {
      case PercentSplit(:final bp):
        _bp.addAll(bp);
      case FixedSplit(:final amounts):
        _amounts.addAll(amounts);
      case SharesSplit(:final weights):
        _weights.addAll(weights);
      case MixedSplit(:final amounts, :final rest):
        _amounts.addAll(amounts);
        _selected = rest.toSet();
      default:
        break;
    }
  }

  List<String> _ordered(Iterable<String> ids) => _ids.where(ids.contains).toList();

  SplitRule _build() => switch (_method) {
        SplitMethod.single => SingleSplit(_single),
        SplitMethod.percent => PercentSplit({for (final id in _ordered(_selected)) id: _bp[id] ?? 0}),
        SplitMethod.fixed => FixedSplit({for (final id in _ordered(_selected)) id: _amounts[id] ?? 0}),
        SplitMethod.shares => SharesSplit({for (final id in _ordered(_selected)) id: _weights[id] ?? 1}),
        SplitMethod.mixed => MixedSplit({for (final e in _amounts.entries) if ((e.value) > 0) e.key: e.value}, _ordered(_selected)),
        _ => EqualSplit(_ordered(_selected)),
      };

  void _emit() {
    setState(() {});
    widget.onChanged(_build());
  }

  void _setMethod(SplitMethod m) {
    _method = m;
    final people = _ordered(_selected);
    if (m == SplitMethod.percent && people.isNotEmpty && _bp.isEmpty) {
      final parts = List.generate(people.length, (i) => 10000 ~/ people.length + (i < 10000 % people.length ? 1 : 0));
      for (var i = 0; i < people.length; i++) {
        _bp[people[i]] = parts[i];
      }
    }
    if (m == SplitMethod.fixed && _amounts.isEmpty && people.isNotEmpty) {
      final rule = EqualSplit(people).apply(widget.totalMinor, widget.currency);
      _amounts.addAll(rule.allocations);
    }
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    SplitResult? result;
    String? error;
    try {
      result = _build().apply(widget.totalMinor, widget.currency, names: _names);
    } on SplitError catch (e) {
      error = e.message;
    }
    final members = widget.members;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final m in widget.methods)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(label: Text(m.label), selected: _method == m, onSelected: (_) => _setMethod(m)),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      if (_method == SplitMethod.single)
        RadioGroup<String>(
          groupValue: _single,
          onChanged: (v) {
            _single = v!;
            _emit();
          },
          child: Column(children: [for (final m in members) _row(context, m, result)]),
        )
      else
        for (final m in members) _row(context, m, result),
      if (error != null) ...[const SizedBox(height: 8), Notice(kind: NoticeKind.warning, message: error)],
      if (widget.showPreview && result != null) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _showMath = !_showMath),
            icon: Icon(_showMath ? Icons.expand_less : Icons.calculate_outlined, size: 18),
            label: Text(_showMath ? 'Ocultar cálculo' : 'Ver cómo se calcula'),
          ),
        ),
        if (_showMath)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: context.pami.surfaceSoft, borderRadius: BorderRadius.circular(PamiTokens.radiusS)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final line in result.explanation) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(line, style: context.text.bodySmall)),
            ]),
          ),
      ],
    ]);
  }

  Widget _row(BuildContext context, Member m, SplitResult? result) {
    final amount = result?.allocations[m.userId];
    final included = _method == SplitMethod.single ? _single == m.userId : _selected.contains(m.userId);
    final name = '${m.displayName}${m.active ? '' : ' (ya no es miembro)'}';

    Widget? input;
    switch (_method) {
      case SplitMethod.percent when included:
        input = _NumberBox(
          key: ValueKey('pct-${m.userId}'),
          initial: _bp[m.userId] == null ? '' : formatMinor(_bp[m.userId]!, _percentCurrency, withSymbol: false),
          suffix: '%',
          label: 'Porcentaje de ${m.displayName}',
          onChanged: (v) {
            _bp[m.userId] = parseAmountInput(v, _percentCurrency) ?? 0;
            _emit();
          },
        );
      case SplitMethod.fixed when included:
      case SplitMethod.mixed:
        input = SizedBox(
          width: 140,
          child: MoneyField(
            key: ValueKey('fx-${m.userId}-$_method'),
            currency: widget.currency,
            label: _method == SplitMethod.mixed ? 'Fijo' : 'Importe',
            allowZero: true,
            initialMinor: _amounts[m.userId],
            onChanged: (v) {
              _amounts[m.userId] = v ?? 0;
              _emit();
            },
          ),
        );
      case SplitMethod.shares when included:
        input = _NumberBox(
          key: ValueKey('sh-${m.userId}'),
          initial: '${_weights[m.userId] ?? 1}',
          suffix: 'partes',
          label: 'Proporción de ${m.displayName}',
          onChanged: (v) {
            _weights[m.userId] = int.tryParse(v) ?? 0;
            _emit();
          },
        );
      default:
        input = null;
    }

    final selector = _method == SplitMethod.single
        ? Radio<String>(value: m.userId)
        : Checkbox(
            value: included,
            semanticLabel: _method == SplitMethod.mixed ? '${m.displayName} comparte el resto' : 'Incluir a ${m.displayName}',
            onChanged: (v) {
              v == true ? _selected.add(m.userId) : _selected.remove(m.userId);
              _emit();
            },
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        selector,
        PersonAvatar(name: m.displayName, size: 30, inactive: !m.active),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (amount != null && widget.showPreview)
              AmountText(amount, widget.currency, style: context.text.bodySmall?.copyWith(color: context.pami.muted), semanticPrefix: 'le corresponde'),
          ]),
        ),
        ?input,
      ]),
    );
  }
}

class _NumberBox extends StatelessWidget {
  const _NumberBox({super.key, required this.initial, required this.suffix, required this.label, required this.onChanged});
  final String initial;
  final String suffix;
  final String label;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 110,
        child: TextFormField(
          initialValue: initial,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(suffixText: suffix, isDense: true, labelText: suffix == '%' ? '%' : 'Partes'),
          onChanged: onChanged,
          style: const TextStyle(fontFeatures: PamiTokens.tabular),
        ),
      );
}
