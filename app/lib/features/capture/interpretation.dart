import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/failure.dart';
import '../../core/finance/expense_draft.dart';
import '../../core/finance/local_parser.dart';
import '../../core/finance/receipt_engine.dart';
import '../../core/finance/split_rules.dart';
import '../../core/providers.dart';
import '../../data/models.dart';
import '../movements/draft_mapper.dart';

/// What we understood from a phrase, shown to the person before the editor.
class Interpretation {
  Interpretation({required this.draft, required this.byAi, required this.ambiguities, required this.missing, this.notice});
  final ExpenseDraft draft;
  final bool byAi;
  final List<String> ambiguities;
  final List<String> missing;

  /// Why the local interpreter was used instead of AI, if relevant.
  final String? notice;
}

const _missingLabels = {
  'amount': 'importe', 'amount_minor': 'importe', 'description': 'concepto', 'occurred_on': 'fecha',
  'workspace_alias': 'espacio', 'payer_alias': 'quién pagó', 'category_key': 'categoría', 'currency': 'moneda',
};

/// Interprets [text] with the server AI when configured, otherwise (or when
/// it fails) with the on-device rule-based interpreter.
Future<Interpretation> interpretExpense(WidgetRef ref, String text, TxSource source) async {
  final me = ref.read(currentUserIdProvider)!;
  final spaces = (await ref.read(workspacesProvider.future)).where((w) => w.canWrite).toList();
  final cats = await ref.read(categoriesProvider.future);
  final caps = await ref.read(aiCapabilitiesProvider.future);
  String? notice;

  if (caps.textParsing) {
    try {
      final d = await ref.read(aiRepositoryProvider).parseExpense(text);
      return await _fromAi(ref, d, spaces, cats, me, source);
    } on AppFailure catch (f) {
      notice = 'La IA no respondió (${f.message}). Usé la interpretación básica en el dispositivo.';
    }
  } else {
    notice = 'Interpretación básica en el dispositivo: la IA no está configurada en el servidor.';
  }

  final parseSpaces = <ParseWorkspace>[];
  for (final w in spaces) {
    final members = await ref.read(membersProvider(w.id).future);
    parseSpaces.add(ParseWorkspace(id: w.id, name: w.name, kind: w.kind.name, members: [
      for (final m in members.where((m) => m.active)) ParseMember(id: m.userId, name: m.displayName, isMe: m.userId == me),
    ]));
  }
  final now = DateTime.now();
  final r = parseExpenseText(text, today: DateTime(now.year, now.month, now.day), workspaces: parseSpaces);
  final ws = spaces.firstWhere((w) => w.id == r.workspaceId, orElse: () => spaces.firstWhere((w) => w.isPersonal));
  final members = await ref.read(membersProvider(ws.id).future);
  final draft = newDraft(ws: ws, me: me, members: members, source: source)
    ..totalMinor = r.amountMinor
    ..description = r.description ?? ''
    ..occurredOn = r.date ?? DateTime(now.year, now.month, now.day)
    ..categoryId = cats.where((c) => c.systemKey == r.categoryKey).firstOrNull?.id
    ..notes = null;
  draft.payments = [PaymentDraft(payerId: r.payerId ?? me, amountMinor: r.amountMinor ?? 0, method: r.paymentMethod)];
  if (!ws.isPersonal && r.participantIds.isNotEmpty) draft.rule = EqualSplit(r.participantIds);
  return Interpretation(
    draft: draft,
    byAi: false,
    ambiguities: r.ambiguities,
    missing: r.missing.map((m) => _missingLabels[m] ?? m).toList(),
    notice: notice,
  );
}

Future<Interpretation> _fromAi(WidgetRef ref, Map<String, dynamic> d, List<Workspace> spaces, List<Category> cats, String me, TxSource source) async {
  final personal = spaces.firstWhere((w) => w.isPersonal);
  final ws = spaces.firstWhere((w) => w.id == d['workspace_id'], orElse: () => personal);
  final members = await ref.read(membersProvider(ws.id).future);
  final activeIds = members.where((m) => m.active).map((m) => m.userId).toSet();
  final now = DateTime.now();
  final amount = (d['amount_minor'] as num?)?.toInt();
  final draft = newDraft(ws: ws, me: me, members: members, source: source)
    ..totalMinor = amount
    ..description = (d['description'] as String?) ?? ''
    ..merchant = d['merchant'] as String?
    ..occurredOn = DateTime.tryParse(d['occurred_on'] as String? ?? '') ?? DateTime(now.year, now.month, now.day)
    ..categoryId = cats.where((c) => c.systemKey == d['category_key']).firstOrNull?.id;
  final payer = d['payer_id'] as String?;
  draft.payments = [PaymentDraft(payerId: payer != null && activeIds.contains(payer) ? payer : me, amountMinor: amount ?? 0,
      method: d['payment_method'] as String?)];

  final ambiguities = ((d['ambiguities'] as List?) ?? const []).cast<String>();
  if (ws.currencyMismatch(d['currency'] as String?)) {
    ambiguities.add('La moneda mencionada (${d['currency']}) no es la del espacio (${ws.baseCurrency.code}). Revísalo.');
  }

  if (!ws.isPersonal) {
    final parts = ((d['participants'] as List?) ?? const []).cast<Map>()
        .where((p) => activeIds.contains(p['user_id'])).toList();
    if (parts.isNotEmpty) {
      final type = parts.first['share_type'];
      final values = {for (final p in parts) p['user_id'] as String: (p['value'] as num?)?.toInt()};
      if (type == 'percent' && values.values.every((v) => v != null)) {
        draft.rule = PercentSplit(values.map((k, v) => MapEntry(k, v! * 100)));
      } else if (type == 'fixed' && values.values.every((v) => v != null)) {
        draft.rule = FixedSplit(values.map((k, v) => MapEntry(k, v!)));
      } else {
        draft.rule = EqualSplit(values.keys.toList());
      }
    }
    final items = ((d['items'] as List?) ?? const []).cast<Map>().where((i) => i['amount_minor'] != null).toList();
    if (items.length > 1) {
      draft.receipt = ReceiptDraft(lines: [
        for (final i in items)
          ReceiptLine(
            description: i['description'] as String,
            lineTotalMinor: (i['amount_minor'] as num).toInt(),
            rule: _lineRule(((i['participant_ids'] as List?) ?? const []).cast<String>().where(activeIds.contains).toList(), draft.rule),
          ),
      ]);
      draft.rule = const ByItemSplit();
    }
  }
  return Interpretation(
    draft: draft,
    byAi: true,
    ambiguities: ambiguities,
    missing: ((d['missing_fields'] as List?) ?? const []).cast<String>().map((m) => _missingLabels[m] ?? m).toSet().toList(),
  );
}

SplitRule _lineRule(List<String> ids, SplitRule fallback) => switch (ids.length) {
      0 => fallback is ByItemSplit ? const EqualSplit([]) : fallback,
      1 => SingleSplit(ids.first),
      _ => EqualSplit(ids),
    };

extension on Workspace {
  bool currencyMismatch(String? code) => code != null && code != baseCurrency.code;
}
