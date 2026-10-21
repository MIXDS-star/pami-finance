/// Deterministic integer allocation (largest remainder / Hamilton method).
///
/// Splits [total] minor units proportionally to [weights] so that the parts
/// ALWAYS add up exactly to [total]. Leftover units go to the largest
/// fractional remainders; ties go to the earliest position, so the same input
/// always produces the same output on every device and on the server.
library;

List<int> allocateByWeights(int total, List<int> weights) {
  if (weights.isEmpty) {
    throw ArgumentError('at least one weight is required');
  }
  if (weights.any((w) => w < 0)) {
    throw ArgumentError('weights must be non-negative');
  }
  if (total < 0) {
    return allocateByWeights(-total, weights).map((v) => -v).toList();
  }
  final sum = weights.fold<BigInt>(BigInt.zero, (a, w) => a + BigInt.from(w));
  if (sum == BigInt.zero) {
    throw ArgumentError('weights must not all be zero');
  }
  final t = BigInt.from(total);
  final parts = <int>[];
  final remainders = <BigInt>[];
  var assigned = 0;
  for (final w in weights) {
    final product = t * BigInt.from(w);
    final q = product ~/ sum;
    parts.add(q.toInt());
    remainders.add(product - q * sum);
    assigned += q.toInt();
  }
  var leftover = total - assigned;
  final order = List<int>.generate(weights.length, (i) => i)
    ..sort((a, b) {
      final c = remainders[b].compareTo(remainders[a]);
      return c != 0 ? c : a.compareTo(b);
    });
  for (final i in order) {
    if (leftover == 0) break;
    if (weights[i] == 0) continue;
    parts[i] += 1;
    leftover -= 1;
  }
  return parts;
}

/// Equal split of [total] among [n] people.
List<int> allocateEqually(int total, int n) => allocateByWeights(total, List.filled(n, 1));
