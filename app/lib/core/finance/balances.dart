/// Settlement suggestions from server-computed net balances
/// (public.workspace_balances is the source of truth for the nets).
library;

class MemberBalance {
  const MemberBalance({
    required this.userId,
    required this.currency,
    required this.paidMinor,
    required this.assignedMinor,
    required this.sentMinor,
    required this.receivedMinor,
    required this.netMinor,
  });

  factory MemberBalance.fromJson(Map<String, dynamic> j) => MemberBalance(
        userId: j['user_id'] as String,
        currency: j['currency'] as String,
        paidMinor: (j['paid_minor'] as num).toInt(),
        assignedMinor: (j['assigned_minor'] as num).toInt(),
        sentMinor: (j['sent_minor'] as num).toInt(),
        receivedMinor: (j['received_minor'] as num).toInt(),
        netMinor: (j['net_minor'] as num).toInt(),
      );

  final String userId;
  final String currency;
  final int paidMinor;
  final int assignedMinor;
  final int sentMinor;
  final int receivedMinor;

  /// > 0: others owe this person; < 0: this person owes.
  final int netMinor;
}

class SuggestedTransfer {
  const SuggestedTransfer(this.fromUserId, this.toUserId, this.amountMinor);
  final String fromUserId;
  final String toUserId;
  final int amountMinor;

  @override
  bool operator ==(Object other) =>
      other is SuggestedTransfer && other.fromUserId == fromUserId && other.toUserId == toUserId && other.amountMinor == amountMinor;
  @override
  int get hashCode => Object.hash(fromUserId, toUserId, amountMinor);
  @override
  String toString() => '$fromUserId -> $toUserId: $amountMinor';
}

/// Minimal list of transfers that brings every net to zero. Greedy: the
/// biggest debtor pays the biggest creditor; ties broken by user id so every
/// device shows the same suggestion. Requires nets to add up to zero.
List<SuggestedTransfer> suggestTransfers(Map<String, int> nets) {
  final total = nets.values.fold(0, (a, b) => a + b);
  if (total != 0) {
    throw StateError('Balances must add up to zero (got $total)');
  }
  final debtors = nets.entries.where((e) => e.value < 0).map((e) => [e.key, -e.value]).toList();
  final creditors = nets.entries.where((e) => e.value > 0).map((e) => [e.key, e.value]).toList();
  int cmp(List<Object> a, List<Object> b) {
    final c = (b[1] as int).compareTo(a[1] as int);
    return c != 0 ? c : (a[0] as String).compareTo(b[0] as String);
  }

  final out = <SuggestedTransfer>[];
  while (debtors.isNotEmpty && creditors.isNotEmpty) {
    debtors.sort(cmp);
    creditors.sort(cmp);
    final d = debtors.first;
    final c = creditors.first;
    final amount = (d[1] as int) < (c[1] as int) ? d[1] as int : c[1] as int;
    out.add(SuggestedTransfer(d[0] as String, c[0] as String, amount));
    d[1] = (d[1] as int) - amount;
    c[1] = (c[1] as int) - amount;
    if (d[1] == 0) debtors.removeAt(0);
    if (c[1] == 0) creditors.removeAt(0);
  }
  return out;
}
