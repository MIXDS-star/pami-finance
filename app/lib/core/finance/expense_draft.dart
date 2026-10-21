/// The single editable model behind every capture method (manual, text,
/// voice, receipt, import). It validates with the same rules as the server
/// and builds the payload for public.save_transaction.
library;

import '../money/money.dart';
import 'receipt_engine.dart';
import 'split_rules.dart';

enum TxKind { expense, income, transfer }

enum TxSource { manual, text, voice, receipt, import, bank }

class PaymentDraft {
  PaymentDraft({required this.payerId, required this.amountMinor, this.accountId, this.method});
  String payerId;
  int amountMinor;
  String? accountId;
  String? method;

  Map<String, dynamic> toJson() => {
        'payer_id': payerId,
        'amount_minor': amountMinor,
        if (accountId != null) 'account_id': accountId,
        if (method != null) 'method': method,
      };
}

class DraftIssue {
  const DraftIssue(this.field, this.message, {this.blocking = true});
  final String field;
  final String message;

  /// Non-blocking issues are suggestions; blocking ones prevent saving.
  final bool blocking;
}

class ExpenseDraft {
  ExpenseDraft({
    required this.clientRequestId,
    required this.workspaceId,
    required this.currency,
    required this.occurredOn,
    required this.rule,
    this.kind = TxKind.expense,
    this.id,
    this.version,
    this.totalMinor,
    this.description = '',
    this.merchant,
    this.categoryId,
    this.notes,
    this.source = TxSource.manual,
    List<PaymentDraft>? payments,
    this.receipt,
    this.accountId,
    this.toAccountId,
    this.personalWorkspace = false,
  }) : payments = payments ?? [];

  /// Stable for the life of the draft: retries never create duplicates.
  final String clientRequestId;
  String? id;
  int? version;
  TxKind kind;
  String workspaceId;
  bool personalWorkspace;
  Currency currency;
  int? totalMinor;
  String description;
  String? merchant;
  DateTime occurredOn;
  String? categoryId;
  String? notes;
  TxSource source;
  List<PaymentDraft> payments;
  SplitRule rule;
  ReceiptDraft? receipt;
  String? accountId;
  String? toAccountId;

  bool get isEdit => id != null;
  bool get byItem => receipt != null && receipt!.lines.isNotEmpty && rule.method == SplitMethod.byItem;

  /// Final per-person assignment. Throws [SplitError] when the rule is invalid.
  Map<String, int> computeSplits() {
    final total = totalMinor ?? 0;
    if (byItem) {
      final c = computeReceipt(receipt!, total, currency);
      if (c.lineErrors.isNotEmpty) {
        throw SplitError('line_rule', c.lineErrors.values.first);
      }
      return c.splits;
    }
    return rule.apply(total, currency).allocations;
  }

  ReceiptComputation? receiptComputation() =>
      receipt == null || receipt!.lines.isEmpty ? null : computeReceipt(receipt!, totalMinor ?? 0, currency);

  List<DraftIssue> validate({DateTime? today}) {
    final issues = <DraftIssue>[];
    final now = today ?? DateTime.now();
    final total = totalMinor;
    if (total == null || total <= 0) {
      issues.add(const DraftIssue('amount', 'Indica un importe mayor que cero.'));
    } else if (total > kMaxMinor) {
      issues.add(const DraftIssue('amount', 'El importe es demasiado alto.'));
    }
    if (description.trim().isEmpty) issues.add(const DraftIssue('description', 'Escribe un concepto.'));
    if (description.trim().length > 140) issues.add(const DraftIssue('description', 'El concepto admite hasta 140 caracteres.'));
    if (occurredOn.isAfter(DateTime(now.year + 1, now.month, now.day))) {
      issues.add(const DraftIssue('date', 'La fecha está demasiado lejos en el futuro.'));
    } else if (occurredOn.isAfter(now)) {
      issues.add(const DraftIssue('date', 'La fecha es futura: confirma que es correcta.', blocking: false));
    }
    if (categoryId == null && kind != TxKind.transfer) {
      issues.add(const DraftIssue('category', 'Sin categoría: no contará en presupuestos por categoría.', blocking: false));
    }

    switch (kind) {
      case TxKind.income:
        if (!personalWorkspace) issues.add(const DraftIssue('workspace', 'Los ingresos se registran en tu espacio personal.'));
      case TxKind.transfer:
        if (!personalWorkspace) issues.add(const DraftIssue('workspace', 'Las transferencias se registran en tu espacio personal.'));
        if (accountId == null || toAccountId == null) {
          issues.add(const DraftIssue('account', 'Elige la cuenta de origen y la de destino.'));
        } else if (accountId == toAccountId) {
          issues.add(const DraftIssue('account', 'Las cuentas de origen y destino deben ser distintas.'));
        }
      case TxKind.expense:
        if (payments.isEmpty) issues.add(const DraftIssue('payer', 'Indica quién pagó.'));
        final paid = payments.fold(0, (a, p) => a + p.amountMinor);
        if (total != null && payments.isNotEmpty && paid != total) {
          issues.add(DraftIssue('payer',
              'Los pagos suman ${formatMinor(paid, currency)} y el total es ${formatMinor(total, currency)}.'));
        }
        if (payments.map((p) => p.payerId).toSet().length != payments.length) {
          issues.add(const DraftIssue('payer', 'Hay pagadores repetidos.'));
        }
        if (total != null && total > 0) {
          try {
            final splits = computeSplits();
            final sum = splits.values.fold(0, (a, b) => a + b);
            if (!byItem && sum != total) {
              issues.add(DraftIssue('split', 'El reparto suma ${formatMinor(sum, currency)}, no ${formatMinor(total, currency)}.'));
            }
            if (splits.values.any((v) => v < 0)) {
              issues.add(const DraftIssue('split', 'Nadie puede quedar con un importe negativo.'));
            }
          } on SplitError catch (e) {
            issues.add(DraftIssue('split', e.message));
          }
          final rc = receiptComputation();
          if (rc != null && rc.difference != 0) {
            issues.add(DraftIssue('receipt',
                'Las líneas de la factura suman ${formatMinor(rc.computedTotal, currency)} y el total pagado es '
                '${formatMinor(total, currency)} (diferencia ${formatMinor(rc.difference, currency, signed: true)}). '
                'Corrige las líneas o añade una línea de ajuste explícita.'));
          }
        }
    }
    return issues;
  }

  bool get canSave => validate().every((i) => !i.blocking);

  Map<String, dynamic> toPayload() {
    final payload = <String, dynamic>{
      if (id != null) 'id': id,
      if (version != null) 'expected_version': version,
      'client_request_id': clientRequestId,
      'workspace_id': workspaceId,
      'kind': kind.name,
      'description': description.trim(),
      'merchant': merchant?.trim().isEmpty ?? true ? null : merchant!.trim(),
      'occurred_on': _date(occurredOn),
      'currency': currency.code,
      'total_minor': totalMinor,
      'category_id': categoryId,
      'notes': notes?.trim().isEmpty ?? true ? null : notes!.trim(),
      'source': source.name,
    };
    switch (kind) {
      case TxKind.income:
        payload['account_id'] = accountId;
      case TxKind.transfer:
        payload['account_id'] = accountId;
        payload['to_account_id'] = toAccountId;
      case TxKind.expense:
        final splits = computeSplits();
        payload['split_method'] = byItem ? 'by_item' : rule.method.wire;
        payload['split_spec'] = byItem ? <String, dynamic>{} : rule.toJson();
        payload['payments'] = payments.map((p) => p.toJson()).toList();
        payload['splits'] = [
          for (final e in splits.entries) {'user_id': e.key, 'amount_minor': e.value},
        ];
        final r = receipt;
        if (r != null) payload['receipt'] = _receiptPayload(r);
    }
    return payload;
  }

  Map<String, dynamic> _receiptPayload(ReceiptDraft r) {
    final rc = r.lines.isEmpty ? null : computeReceipt(r, totalMinor ?? 0, currency);
    return {
      'storage_path': r.storagePath,
      'mime_type': r.mimeType,
      'merchant_name': r.merchantName,
      'merchant_tax_id': r.merchantTaxId,
      'invoice_number': r.invoiceNumber,
      'issued_on': r.issuedOn == null ? null : _date(r.issuedOn!),
      'printed_subtotal_minor': r.printedSubtotalMinor,
      'printed_total_minor': r.printedTotalMinor,
      'discount_minor': r.discountMinor,
      'tax_minor': r.taxMinor,
      'taxes_included': r.taxesIncluded,
      'tip_minor': r.tipMinor,
      'other_charges_minor': r.otherChargesMinor,
      'extraction_status': r.extractionStatus,
      'extraction_provider': r.extractionProvider,
      'extraction_confidence': r.extractionConfidence,
      'items': [
        for (var i = 0; i < r.lines.length; i++)
          {
            'kind': r.lines[i].isAdjustment ? 'adjustment' : 'item',
            'raw_text': r.lines[i].rawText,
            'description': r.lines[i].description,
            'quantity': r.lines[i].quantityMilli / 1000,
            'unit_price_minor': r.lines[i].unitPriceMinor,
            'line_discount_minor': r.lines[i].lineDiscountMinor,
            'line_total_minor': r.lines[i].lineTotalMinor,
            'category_id': r.lines[i].categoryId,
            'confidence': r.lines[i].confidence,
            'allocation_method': r.lines[i].rule.method.wire,
            'allocation_spec': r.lines[i].rule.toJson(),
            if (byItem && rc != null && rc.lineAllocations[i] != null)
              'allocations': [
                for (final e in rc.lineAllocations[i]!.entries) {'user_id': e.key, 'amount_minor': e.value},
              ],
          },
      ],
    };
  }
}

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String isoDate(DateTime d) => _date(d);
