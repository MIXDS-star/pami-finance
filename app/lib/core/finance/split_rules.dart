/// Split rules: how an amount is divided among people. Used for whole
/// expenses and for individual receipt lines. Every rule produces integer
/// allocations that add up EXACTLY to the amount, plus a human-readable
/// explanation of the calculation.
library;

import '../money/allocation.dart';
import '../money/money.dart';

enum SplitMethod { single, equal, percent, fixed, shares, mixed, byItem }

extension SplitMethodWire on SplitMethod {
  String get wire => switch (this) {
        SplitMethod.byItem => 'by_item',
        _ => name,
      };

  String get label => switch (this) {
        SplitMethod.single => 'Una persona',
        SplitMethod.equal => 'Partes iguales',
        SplitMethod.percent => 'Porcentajes',
        SplitMethod.fixed => 'Importes fijos',
        SplitMethod.shares => 'Proporciones',
        SplitMethod.mixed => 'Fijos + resto igual',
        SplitMethod.byItem => 'Por producto',
      };

  static SplitMethod parse(String? wire) => switch (wire) {
        'by_item' => SplitMethod.byItem,
        'single' => SplitMethod.single,
        'percent' => SplitMethod.percent,
        'fixed' => SplitMethod.fixed,
        'shares' => SplitMethod.shares,
        'mixed' => SplitMethod.mixed,
        _ => SplitMethod.equal,
      };
}

class SplitError implements Exception {
  const SplitError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

class SplitResult {
  const SplitResult(this.allocations, this.explanation);

  /// userId -> minor units, in a stable order.
  final Map<String, int> allocations;
  final List<String> explanation;

  int get total => allocations.values.fold(0, (a, b) => a + b);
}

sealed class SplitRule {
  const SplitRule();

  SplitMethod get method;

  /// People this rule assigns money to.
  List<String> get participants;

  SplitResult apply(int amount, Currency currency, {Map<String, String> names = const {}});

  Map<String, dynamic> toJson();

  static SplitRule fromJson(String method, Map<String, dynamic>? spec, {List<String> fallback = const []}) {
    final s = spec ?? const {};
    Map<String, int> ints(Object? v) =>
        (v is Map ? v : const {}).map((k, val) => MapEntry(k.toString(), (val as num).toInt()));
    List<String> strs(Object? v) => (v is List ? v : const []).map((e) => e.toString()).toList();
    return switch (SplitMethodWire.parse(method)) {
      SplitMethod.single => SingleSplit(s['user_id']?.toString() ?? (fallback.isNotEmpty ? fallback.first : '')),
      SplitMethod.percent => PercentSplit(ints(s['bp'])),
      SplitMethod.fixed => FixedSplit(ints(s['amounts'])),
      SplitMethod.shares => SharesSplit(ints(s['weights'])),
      SplitMethod.mixed => MixedSplit(ints(s['amounts']), strs(s['rest'])),
      SplitMethod.byItem => const ByItemSplit(),
      _ => EqualSplit(strs(s['users']).isEmpty ? fallback : strs(s['users'])),
    };
  }
}

String _n(Map<String, String> names, String id) => names[id] ?? 'Participante';

class SingleSplit extends SplitRule {
  const SingleSplit(this.userId);
  final String userId;

  @override
  SplitMethod get method => SplitMethod.single;
  @override
  List<String> get participants => [userId];

  @override
  SplitResult apply(int amount, Currency currency, {Map<String, String> names = const {}}) {
    if (userId.isEmpty) throw const SplitError('participants_required', 'Elige a quién corresponde el gasto.');
    return SplitResult({userId: amount}, ['${_n(names, userId)} asume ${formatMinor(amount, currency)} (100 %).']);
  }

  @override
  Map<String, dynamic> toJson() => {'user_id': userId};
}

class EqualSplit extends SplitRule {
  const EqualSplit(this.users);
  final List<String> users;

  @override
  SplitMethod get method => SplitMethod.equal;
  @override
  List<String> get participants => users;

  @override
  SplitResult apply(int amount, Currency currency, {Map<String, String> names = const {}}) {
    if (users.isEmpty) throw const SplitError('participants_required', 'Elige al menos una persona.');
    if (users.toSet().length != users.length) throw const SplitError('participant_duplicated', 'Hay personas repetidas.');
    final parts = allocateEqually(amount, users.length);
    final map = {for (var i = 0; i < users.length; i++) users[i]: parts[i]};
    final base = amount ~/ users.length;
    final extra = amount - base * users.length;
    return SplitResult(map, [
      '${formatMinor(amount, currency)} ÷ ${users.length} personas = ${formatMinor(base, currency)} cada una.',
      if (extra != 0)
        'Sobran ${formatMinor(extra.abs(), currency, withSymbol: false)} unidad(es) por redondeo: se asignan una a una '
            'empezando por ${_n(names, users.first)}, para que la suma sea exacta.',
    ]);
  }

  @override
  Map<String, dynamic> toJson() => {'users': users};
}

/// Percentages in basis points (100 bp = 1 %), must add up to 10 000.
class PercentSplit extends SplitRule {
  const PercentSplit(this.bp);
  final Map<String, int> bp;

  @override
  SplitMethod get method => SplitMethod.percent;
  @override
  List<String> get participants => bp.keys.toList();

  @override
  SplitResult apply(int amount, Currency currency, {Map<String, String> names = const {}}) {
    if (bp.isEmpty) throw const SplitError('participants_required', 'Elige al menos una persona.');
    final sum = bp.values.fold(0, (a, b) => a + b);
    if (bp.values.any((v) => v < 0) || sum != 10000) {
      throw SplitError('percent_sum', 'Los porcentajes suman ${formatBp(sum, decimals: 2)}; deben sumar 100 %.');
    }
    final ids = bp.keys.toList();
    final parts = allocateByWeights(amount, ids.map((k) => bp[k]!).toList());
    return SplitResult({for (var i = 0; i < ids.length; i++) ids[i]: parts[i]}, [
      for (var i = 0; i < ids.length; i++)
        '${_n(names, ids[i])}: ${formatBp(bp[ids[i]]!, decimals: 2)} de ${formatMinor(amount, currency)} = ${formatMinor(parts[i], currency)}',
      'Redondeo por mayor resto: la suma es exactamente ${formatMinor(amount, currency)}.',
    ]);
  }

  @override
  Map<String, dynamic> toJson() => {'bp': bp};
}

class FixedSplit extends SplitRule {
  const FixedSplit(this.amounts);
  final Map<String, int> amounts;

  @override
  SplitMethod get method => SplitMethod.fixed;
  @override
  List<String> get participants => amounts.keys.toList();

  @override
  SplitResult apply(int amount, Currency currency, {Map<String, String> names = const {}}) {
    if (amounts.isEmpty) throw const SplitError('participants_required', 'Elige al menos una persona.');
    final sum = amounts.values.fold(0, (a, b) => a + b);
    if (amounts.values.any((v) => v < 0)) throw const SplitError('amount_negative', 'Los importes no pueden ser negativos.');
    if (sum != amount) {
      final diff = amount - sum;
      throw SplitError('fixed_sum',
          'Los importes suman ${formatMinor(sum, currency)}; ${diff > 0 ? 'faltan' : 'sobran'} ${formatMinor(diff.abs(), currency)}.');
    }
    return SplitResult(Map.of(amounts), [
      for (final e in amounts.entries) '${_n(names, e.key)}: ${formatMinor(e.value, currency)} (importe fijo)',
    ]);
  }

  @override
  Map<String, dynamic> toJson() => {'amounts': amounts};
}

/// Proportional weights, e.g. 2:1 for "two nights vs one night".
class SharesSplit extends SplitRule {
  const SharesSplit(this.weights);
  final Map<String, int> weights;

  @override
  SplitMethod get method => SplitMethod.shares;
  @override
  List<String> get participants => weights.keys.toList();

  @override
  SplitResult apply(int amount, Currency currency, {Map<String, String> names = const {}}) {
    if (weights.isEmpty || weights.values.every((w) => w == 0)) {
      throw const SplitError('participants_required', 'Asigna al menos una proporción mayor que cero.');
    }
    if (weights.values.any((w) => w < 0)) throw const SplitError('amount_negative', 'Las proporciones no pueden ser negativas.');
    final ids = weights.keys.toList();
    final parts = allocateByWeights(amount, ids.map((k) => weights[k]!).toList());
    final total = weights.values.fold(0, (a, b) => a + b);
    return SplitResult({for (var i = 0; i < ids.length; i++) ids[i]: parts[i]}, [
      for (var i = 0; i < ids.length; i++)
        '${_n(names, ids[i])}: ${weights[ids[i]]}/$total de ${formatMinor(amount, currency)} = ${formatMinor(parts[i], currency)}',
    ]);
  }

  @override
  Map<String, dynamic> toJson() => {'weights': weights};
}

/// Fixed amounts for some people, the rest split equally among [rest].
class MixedSplit extends SplitRule {
  const MixedSplit(this.amounts, this.rest);
  final Map<String, int> amounts;
  final List<String> rest;

  @override
  SplitMethod get method => SplitMethod.mixed;
  @override
  List<String> get participants => {...amounts.keys, ...rest}.toList();

  @override
  SplitResult apply(int amount, Currency currency, {Map<String, String> names = const {}}) {
    final fixedSum = amounts.values.fold(0, (a, b) => a + b);
    if (amounts.values.any((v) => v < 0)) throw const SplitError('amount_negative', 'Los importes no pueden ser negativos.');
    if (fixedSum > amount) {
      throw SplitError('fixed_sum', 'Los importes fijos (${formatMinor(fixedSum, currency)}) superan el total.');
    }
    final remaining = amount - fixedSum;
    if (rest.isEmpty && remaining != 0) {
      throw SplitError('fixed_sum', 'Quedan ${formatMinor(remaining, currency)} sin asignar: elige quién comparte el resto.');
    }
    final result = <String, int>{...amounts};
    final explanation = [
      for (final e in amounts.entries) '${_n(names, e.key)}: ${formatMinor(e.value, currency)} fijos',
    ];
    if (rest.isNotEmpty) {
      final eq = EqualSplit(rest).apply(remaining, currency, names: names);
      eq.allocations.forEach((k, v) => result[k] = (result[k] ?? 0) + v);
      explanation
        ..add('Resto ${formatMinor(remaining, currency)} a partes iguales:')
        ..addAll(eq.explanation);
    }
    return SplitResult(result, explanation);
  }

  @override
  Map<String, dynamic> toJson() => {'amounts': amounts, 'rest': rest};
}

/// Marker: the expense is split line by line through its receipt
/// (see receipt_engine.dart); the rule itself never allocates.
class ByItemSplit extends SplitRule {
  const ByItemSplit();

  @override
  SplitMethod get method => SplitMethod.byItem;
  @override
  List<String> get participants => const [];

  @override
  SplitResult apply(int amount, Currency currency, {Map<String, String> names = const {}}) =>
      throw const SplitError('by_item', 'El reparto por producto se calcula con las líneas de la factura.');

  @override
  Map<String, dynamic> toJson() => const {};
}
