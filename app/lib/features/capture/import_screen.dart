import 'dart:convert';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/finance/expense_draft.dart';
import '../../core/finance/import_parser.dart';
import '../../core/finance/split_rules.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../core/util/ids.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';

class _Row {
  _Row({required this.index, required this.date, required this.description, required this.amount, required this.isIncome,
      this.error}) : duplicate = false;
  final int index;
  final DateTime? date;
  final String description;
  final int? amount;
  final bool isIncome;
  final String? error;
  bool duplicate;
  late bool selected = error == null && !duplicate;
}

/// CSV/XLSX import into the personal workspace: preview, column mapping,
/// date/amount normalisation, duplicate detection and explicit confirmation.
/// Re-importing the same file is idempotent (deterministic request ids).
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});
  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> with BusyState {
  String? _fileName;
  String _fileFingerprint = '';
  List<List<String>> _table = const [];
  Map<int, ImportField> _mapping = {};
  bool _expensesNegative = true;
  List<_Row>? _rows;
  String? _error;
  int _progress = 0;

  Future<void> _pick() async {
    setState(() => _error = null);
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['csv', 'txt', 'xlsx']);
    if (files.isEmpty) return;
    final f = files.single;
    final data = await f.readAsBytes();
    if (data.length > 5 * 1024 * 1024) {
      setState(() => _error = 'El archivo supera 5 MB.');
      return;
    }
    try {
      List<List<String>> table;
      if (f.name.toLowerCase().endsWith('.xlsx')) {
        final book = Excel.decodeBytes(data);
        final sheet = book.tables.values.first;
        table = [
          for (final row in sheet.rows)
            [for (final c in row) _cell(c?.value)],
        ].where((r) => r.any((c) => c.isNotEmpty)).toList();
      } else {
        table = parseCsv(utf8.decode(data, allowMalformed: true));
      }
      if (table.length < 2) throw const FormatException('vacío');
      setState(() {
        _fileName = f.name;
        _fileFingerprint = '${f.name}:${data.length}';
        _table = table;
        _mapping = guessColumns(table.first);
        _rows = null;
      });
    } catch (_) {
      setState(() => _error = 'No pudimos leer el archivo. Usa un CSV (separado por comas o punto y coma) o un Excel .xlsx con encabezados.');
    }
  }

  String _cell(CellValue? v) => switch (v) {
        null => '',
        DateCellValue(:final year, :final month, :final day) =>
          '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
        DateTimeCellValue(:final year, :final month, :final day) =>
          '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
        _ => v.toString(),
      };

  int? _col(ImportField f) => _mapping.entries.where((e) => e.value == f).firstOrNull?.key;

  Future<void> _preview() async {
    final dateCol = _col(ImportField.date);
    final descCol = _col(ImportField.description);
    final amountCol = _col(ImportField.amount);
    final debitCol = _col(ImportField.debit);
    final creditCol = _col(ImportField.credit);
    if (dateCol == null || descCol == null || (amountCol == null && debitCol == null && creditCol == null)) {
      setState(() => _error = 'Indica qué columna es la fecha, la descripción y el valor (o débito/crédito).');
      return;
    }
    final personal = await ref.read(personalWorkspaceProvider.future);
    final decimals = personal.baseCurrency.decimals;
    final rows = <_Row>[];
    for (var i = 1; i < _table.length; i++) {
      final r = _table[i];
      String at(int? c) => c == null || c >= r.length ? '' : r[c];
      final date = parseImportDate(at(dateCol));
      int? amount;
      var income = false;
      String? error;
      if (amountCol != null) {
        final p = parseImportAmount(at(amountCol), decimals);
        if (p != null) {
          amount = p.minor;
          income = _expensesNegative ? !p.negative : p.negative;
        }
      } else {
        final d = parseImportAmount(at(debitCol), decimals);
        final c = parseImportAmount(at(creditCol), decimals);
        if (d != null && d.minor > 0) {
          amount = d.minor;
        } else if (c != null && c.minor > 0) {
          amount = c.minor;
          income = true;
        }
      }
      if (date == null) error = 'Fecha no reconocida: «${at(dateCol)}»';
      if (amount == null || amount == 0) error ??= 'Valor no válido: «${at(amountCol ?? debitCol)}»${decimals == 0 ? ' (COP no admite centavos)' : ''}';
      rows.add(_Row(index: i, date: date, description: at(descCol).isEmpty ? 'Movimiento importado' : at(descCol),
          amount: amount, isIncome: income, error: error));
    }
    // Duplicates against what is already registered (same day and amount).
    final valid = rows.where((r) => r.error == null).toList();
    if (valid.isNotEmpty) {
      final from = valid.map((r) => r.date!).reduce((a, b) => a.isBefore(b) ? a : b);
      final to = valid.map((r) => r.date!).reduce((a, b) => a.isAfter(b) ? a : b);
      final existing = await ref.read(transactionRepositoryProvider)
          .list(TransactionFilter(from: from, to: to, workspaceIds: [personal.id]), limit: 1000);
      final keys = existing.map((t) => '${isoDate(t.occurredOn)}|${t.totalMinor}|${t.kind}').toSet();
      for (final r in valid) {
        r.duplicate = keys.contains('${isoDate(r.date!)}|${r.amount}|${r.isIncome ? 'income' : 'expense'}');
        r.selected = !r.duplicate;
      }
    }
    setState(() {
      _rows = rows;
      _error = null;
    });
  }

  Future<void> _import() async {
    final rows = _rows!.where((r) => r.selected && r.error == null).toList();
    if (rows.isEmpty) return;
    final ok = await confirmAction(context, title: 'Importar ${rows.length} movimientos',
        message: 'Se registrarán en tu espacio personal. Podrás editarlos o eliminarlos después.', confirmLabel: 'Importar');
    if (!ok) return;
    await runBusy(() async {
      final client = ref.read(supabaseClientProvider);
      final me = ref.read(currentUserIdProvider)!;
      final personal = await ref.read(personalWorkspaceProvider.future);
      final job = await client.from('import_jobs').insert({
        'user_id': me, 'workspace_id': personal.id, 'source_type': _fileName!.toLowerCase().endsWith('.xlsx') ? 'xlsx' : 'csv',
        'file_name': _fileName, 'column_mapping': _mapping.map((k, v) => MapEntry('$k', v.name)), 'row_count': _rows!.length,
      }).select('id').single();
      var imported = 0;
      String? failure;
      for (final r in rows) {
        final draft = ExpenseDraft(
          clientRequestId: stableId('$me|$_fileFingerprint|${r.index}|${isoDate(r.date!)}|${r.amount}|${r.description}'),
          workspaceId: personal.id,
          personalWorkspace: true,
          currency: personal.baseCurrency,
          occurredOn: r.date!,
          kind: r.isIncome ? TxKind.income : TxKind.expense,
          totalMinor: r.amount,
          description: r.description.length > 140 ? r.description.substring(0, 140) : r.description,
          source: TxSource.import,
          rule: SingleSplit(me),
          payments: r.isIncome ? [] : [PaymentDraft(payerId: me, amountMinor: r.amount!)],
        );
        try {
          await ref.read(transactionRepositoryProvider).save(draft);
          imported++;
          setState(() => _progress = imported);
        } catch (e) {
          failure = e.toString();
          break;
        }
      }
      await client.from('import_jobs').update({
        'status': failure == null ? 'imported' : 'failed',
        'imported_count': imported,
        'duplicate_count': _rows!.where((r) => r.duplicate).length,
        'completed_at': DateTime.now().toUtc().toIso8601String(),
        if (failure != null) 'error': {'message': 'stopped after $imported rows'},
      }).eq('id', job['id'] as String);
      ref.read(ledgerRevisionProvider.notifier).bump();
      if (!mounted) return;
      if (failure == null) {
        showSuccess(context, '$imported movimientos importados');
        context.go('/movements');
      } else {
        showFailure(context, Exception(failure));
        setState(() => _error = 'Se importaron $imported de ${rows.length}. Puedes volver a intentarlo: los ya importados no se duplican.');
      }
    }, onError: (e) => showFailure(context, e));
  }

  @override
  Widget build(BuildContext context) {
    final personal = ref.watch(personalWorkspaceProvider).value;
    final currency = personal?.baseCurrency ?? Currency.cop;
    return Scaffold(
      appBar: AppBar(title: const Text('Importar movimientos')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Notice(message: 'Importa archivos que exportaste de tu banco o de otra app (CSV o Excel). '
            'La conexión bancaria automática es un módulo aparte y aún no está disponible.'),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: busy ? null : _pick, icon: const Icon(Icons.upload_file), label: Text(_fileName ?? 'Elegir archivo')),
        if (_error != null) ...[const SizedBox(height: 12), Notice(kind: NoticeKind.error, message: _error!)],
        if (_table.isNotEmpty && _rows == null) ...[
          const SectionTitle('¿Qué contiene cada columna?'),
          for (var i = 0; i < _table.first.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_table.first[i].isEmpty ? 'Columna ${i + 1}' : _table.first[i], style: context.text.titleSmall),
                    Text('Ej.: ${_table.length > 1 && i < _table[1].length ? _table[1][i] : ''}', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
                  ]),
                ),
                DropdownButton<ImportField>(
                  value: _mapping[i] ?? ImportField.ignore,
                  items: const [
                    DropdownMenuItem(value: ImportField.ignore, child: Text('Ignorar')),
                    DropdownMenuItem(value: ImportField.date, child: Text('Fecha')),
                    DropdownMenuItem(value: ImportField.description, child: Text('Descripción')),
                    DropdownMenuItem(value: ImportField.amount, child: Text('Valor')),
                    DropdownMenuItem(value: ImportField.debit, child: Text('Débito (gasto)')),
                    DropdownMenuItem(value: ImportField.credit, child: Text('Crédito (ingreso)')),
                  ],
                  onChanged: (v) => setState(() => _mapping[i] = v ?? ImportField.ignore),
                ),
              ]),
            ),
          if (_col(ImportField.amount) != null)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _expensesNegative,
              onChanged: (v) => setState(() => _expensesNegative = v),
              title: const Text('Los gastos aparecen con signo negativo'),
            ),
          const SizedBox(height: 12),
          FilledButton(onPressed: busy ? null : () => runBusy(_preview, onError: (e) => showFailure(context, e)), child: const Text('Previsualizar')),
        ],
        if (_rows != null) ...[
          SectionTitle('${_rows!.where((r) => r.selected).length} de ${_rows!.length} filas seleccionadas',
              action: TextButton(onPressed: () => setState(() => _rows = null), child: const Text('Cambiar columnas'))),
          if (_rows!.any((r) => r.duplicate))
            const Notice(kind: NoticeKind.warning, message: 'Algunas filas coinciden con movimientos ya registrados (misma fecha e importe). '
                'Quedan desmarcadas; márcalas si son compras distintas.'),
          for (final r in _rows!.take(300))
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: r.selected,
              onChanged: r.error != null ? null : (v) => setState(() => r.selected = v ?? false),
              title: Text(r.description, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(r.error ?? [if (r.date != null) formatDateShort(r.date!), r.isIncome ? 'Ingreso' : 'Gasto', if (r.duplicate) 'posible duplicado'].join(' · '),
                  style: r.error != null ? TextStyle(color: context.colors.error) : null),
              secondary: r.amount == null ? null : AmountText(r.isIncome ? r.amount! : -r.amount!, currency, colorize: r.isIncome, style: context.text.bodyMedium),
            ),
          if (_rows!.length > 300) Text('Se muestran 300 de ${_rows!.length} filas; se importarán todas las seleccionadas.'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : _import,
            child: Text(busy ? 'Importando… $_progress' : 'Importar seleccionadas'),
          ),
          const SizedBox(height: 8),
          Text('Los importes se guardan como enteros en ${currency.code}${currency.decimals == 0 ? ' (sin centavos)' : ''}. '
              'Importar dos veces el mismo archivo no duplica movimientos.', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
        ],
      ]),
    );
  }
}
