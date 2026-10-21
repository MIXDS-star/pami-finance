/// Receipt engine: one original document, many lines, each line assigned
/// with its own rule. Document-level extras (tip, other charges, tax added on
/// top, document discount) are prorated by each person's share of the lines
/// using the same largest-remainder policy, so the final splits add up
/// exactly to the amount paid. Nothing is invented to force a match: when the
/// lines don't explain the total, the difference is reported.
library;

import '../money/allocation.dart';
import '../money/money.dart';
import 'split_rules.dart';

class ReceiptLine {
  ReceiptLine({
    required this.description,
    required this.lineTotalMinor,
    required this.rule,
    this.rawText,
    this.quantityMilli = 1000,
    this.unitPriceMinor,
    this.lineDiscountMinor = 0,
    this.categoryId,
    this.confidence,
    this.isAdjustment = false,
  });

  String description;
  String? rawText;

  /// Quantity in thousandths (1,5 kg = 1500) so no float is ever involved.
  int quantityMilli;
  int? unitPriceMinor;
  int lineDiscountMinor;

  /// Source of truth for the line (after its own discount).
  int lineTotalMinor;
  String? categoryId;
  double? confidence;
  bool isAdjustment;
  SplitRule rule;

  ReceiptLine copy() => ReceiptLine(
        description: description,
        lineTotalMinor: lineTotalMinor,
        rule: rule,
        rawText: rawText,
        quantityMilli: quantityMilli,
        unitPriceMinor: unitPriceMinor,
        lineDiscountMinor: lineDiscountMinor,
        categoryId: categoryId,
        confidence: confidence,
        isAdjustment: isAdjustment,
      );
}

class ReceiptDraft {
  ReceiptDraft({
    List<ReceiptLine>? lines,
    this.discountMinor = 0,
    this.taxMinor = 0,
    this.taxesIncluded = true,
    this.tipMinor = 0,
    this.otherChargesMinor = 0,
    this.printedTotalMinor,
    this.printedSubtotalMinor,
    this.merchantName,
    this.merchantTaxId,
    this.invoiceNumber,
    this.issuedOn,
    this.storagePath,
    this.mimeType,
    this.extractionStatus = 'manual',
    this.extractionProvider,
    this.extractionConfidence,
  }) : lines = lines ?? [];

  List<ReceiptLine> lines;
  int discountMinor;
  int taxMinor;
  bool taxesIncluded;
  int tipMinor;
  int otherChargesMinor;
  int? printedTotalMinor;
  int? printedSubtotalMinor;
  String? merchantName;
  String? merchantTaxId;
  String? invoiceNumber;
  DateTime? issuedOn;
  String? storagePath;
  String? mimeType;
  String extractionStatus;
  String? extractionProvider;
  double? extractionConfidence;

  int get linesTotal => lines.fold(0, (a, l) => a + l.lineTotalMinor);

  /// Tip + other charges + tax added on top − document discount.
  int get extrasNet => tipMinor + otherChargesMinor + (taxesIncluded ? 0 : taxMinor) - discountMinor;

  int get computedTotal => linesTotal + extrasNet;
}

class ReceiptComputation {
  ReceiptComputation({
    required this.lineAllocations,
    required this.splits,
    required this.extrasByUser,
    required this.computedTotal,
    required this.paidTotal,
    required this.warnings,
    required this.lineErrors,
  });

  /// Index of line -> userId -> amount.
  final List<Map<String, int>?> lineAllocations;
  final Map<String, int> splits;
  final Map<String, int> extrasByUser;
  final int computedTotal;
  final int paidTotal;
  final List<String> warnings;

  /// Index of line -> problem with its rule (e.g. percentages not 100 %).
  final Map<int, String> lineErrors;

  int get difference => paidTotal - computedTotal;
  bool get reconciled => difference == 0 && lineErrors.isEmpty;
}

ReceiptComputation computeReceipt(ReceiptDraft draft, int paidTotal, Currency currency) {
  final warnings = <String>[];
  final lineErrors = <int, String>{};
  final lineAllocations = <Map<String, int>?>[];
  final itemsByUser = <String, int>{};

  for (var i = 0; i < draft.lines.length; i++) {
    final line = draft.lines[i];
    try {
      final r = line.rule.apply(line.lineTotalMinor, currency);
      lineAllocations.add(r.allocations);
      r.allocations.forEach((u, v) => itemsByUser[u] = (itemsByUser[u] ?? 0) + v);
    } on SplitError catch (e) {
      lineAllocations.add(null);
      lineErrors[i] = e.message;
    }
    final unit = line.unitPriceMinor;
    if (unit != null && !line.isAdjustment) {
      final expected = (unit * line.quantityMilli + 500) ~/ 1000 - line.lineDiscountMinor;
      if (expected != line.lineTotalMinor) {
        warnings.add('«${line.description}»: cantidad × precio − descuento = ${formatMinor(expected, currency)}, '
            'pero la línea dice ${formatMinor(line.lineTotalMinor, currency)}. Revisa la lectura.');
      }
    }
  }

  final extrasByUser = <String, int>{};
  final extras = draft.extrasNet;
  final positiveUsers = itemsByUser.entries.where((e) => e.value > 0).toList();
  if (extras != 0) {
    if (positiveUsers.isEmpty) {
      warnings.add('No hay líneas asignadas para repartir propina, cargos o descuentos.');
    } else {
      final parts = allocateByWeights(extras, positiveUsers.map((e) => e.value).toList());
      for (var i = 0; i < positiveUsers.length; i++) {
        extrasByUser[positiveUsers[i].key] = parts[i];
      }
    }
  }

  final splits = <String, int>{};
  for (final u in {...itemsByUser.keys, ...extrasByUser.keys}) {
    splits[u] = (itemsByUser[u] ?? 0) + (extrasByUser[u] ?? 0);
  }
  if (splits.values.any((v) => v < 0)) {
    warnings.add('Un descuento deja a alguien con un importe negativo: revisa la asignación de líneas.');
  }

  final printed = draft.printedTotalMinor;
  if (printed != null && printed != draft.computedTotal) {
    warnings.add('El total impreso (${formatMinor(printed, currency)}) no coincide con la suma calculada '
        '(${formatMinor(draft.computedTotal, currency)}).');
  }
  final subtotal = draft.printedSubtotalMinor;
  if (subtotal != null && subtotal != draft.linesTotal && draft.taxesIncluded) {
    warnings.add('El subtotal impreso (${formatMinor(subtotal, currency)}) difiere de la suma de líneas '
        '(${formatMinor(draft.linesTotal, currency)}).');
  }

  return ReceiptComputation(
    lineAllocations: lineAllocations,
    splits: splits,
    extrasByUser: extrasByUser,
    computedTotal: draft.computedTotal,
    paidTotal: paidTotal,
    warnings: warnings,
    lineErrors: lineErrors,
  );
}
