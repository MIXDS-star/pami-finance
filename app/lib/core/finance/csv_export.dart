/// CSV export of movements. Amounts are written as integers in the minor
/// unit of each currency (COP = pesos, no decimals); the header documents it.
library;

class ExportRow {
  const ExportRow({required this.date, required this.kind, required this.workspace, required this.description, this.merchant,
      this.category, required this.currency, required this.totalMinor, this.myShareMinor, this.paidByMeMinor, this.notes,
      this.receiptLines});
  final String date;
  final String kind;
  final String workspace;
  final String description;
  final String? merchant;
  final String? category;
  final String currency;
  final int totalMinor;
  final int? myShareMinor;
  final int? paidByMeMinor;
  final String? notes;
  final String? receiptLines;
}

String _esc(String? v) {
  var s = v ?? '';
  // Neutralise spreadsheet formula injection (=, +, -, @ at the start).
  if (s.startsWith(RegExp(r'[=+\-@]'))) s = "'$s";
  return RegExp(r'[",\n\r;]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

String buildMovementsCsv(List<ExportRow> rows, {bool includeNotes = false, bool includeReceipt = false}) {
  final b = StringBuffer()
    ..writeln('# NEXO Finance · importes en unidad mínima de cada moneda (COP sin decimales; USD/EUR en centavos)')
    ..write('fecha,tipo,espacio,concepto,comercio,categoria,moneda,importe_total,mi_parte,pagado_por_mi');
  if (includeNotes) b.write(',notas');
  if (includeReceipt) b.write(',lineas_factura');
  b.writeln();
  for (final r in rows) {
    b.write([
      r.date, r.kind, _esc(r.workspace), _esc(r.description), _esc(r.merchant), _esc(r.category), r.currency,
      '${r.totalMinor}', r.myShareMinor?.toString() ?? '', r.paidByMeMinor?.toString() ?? '',
      if (includeNotes) _esc(r.notes),
      if (includeReceipt) _esc(r.receiptLines),
    ].join(','));
    b.writeln();
  }
  return b.toString();
}
