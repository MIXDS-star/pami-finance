/// Rule-based Spanish (Colombia) interpreter for quick expense phrases.
/// Works offline and without any AI provider. It is deliberately
/// conservative: anything uncertain is reported as an ambiguity for the
/// person to confirm instead of being guessed.
library;

class ParseWorkspace {
  const ParseWorkspace({required this.id, required this.name, required this.kind, required this.members});
  final String id;
  final String name;
  final String kind;
  final List<ParseMember> members;
}

class ParseMember {
  const ParseMember({required this.id, required this.name, required this.isMe});
  final String id;
  final String name;
  final bool isMe;
}

class LocalParseResult {
  LocalParseResult();
  int? amountMinor;
  String? description;
  DateTime? date;
  String? categoryKey;
  String? paymentMethod;
  String? workspaceId;
  String? payerId;
  List<String> participantIds = [];
  bool splitEqually = false;
  final List<String> ambiguities = [];
  final List<String> missing = [];
}

const _categoryKeywords = <String, List<String>>{
  'groceries': ['mercado', 'supermercado', 'éxito', 'exito', 'd1', 'ara', 'olímpica', 'olimpica', 'jumbo', 'carulla', 'víveres', 'viveres', 'fruver', 'tienda'],
  'restaurants': ['restaurante', 'almuerzo', 'cena', 'desayuno', 'domicilio', 'rappi', 'pizza', 'hamburguesa', 'café', 'cafe', 'comida', 'corrientazo'],
  'transport': ['taxi', 'uber', 'didi', 'cabify', 'bus', 'transmilenio', 'metro', 'gasolina', 'peaje', 'parqueadero', 'sitp', 'pasaje'],
  'housing': ['arriendo', 'administración', 'administracion', 'alquiler', 'hipoteca'],
  'utilities': ['luz', 'agua', 'gas', 'internet', 'energía', 'energia', 'servicios', 'celular', 'plan de datos'],
  'health': ['farmacia', 'droguería', 'drogueria', 'médico', 'medico', 'eps', 'medicamento', 'odontólogo', 'odontologo', 'cita'],
  'education': ['colegio', 'universidad', 'curso', 'matrícula', 'matricula', 'libros', 'pensión', 'pension'],
  'entertainment': ['cine', 'concierto', 'fiesta', 'bar', 'teatro', 'partido', 'juego'],
  'shopping': ['ropa', 'zapatos', 'compras', 'regalo para mí', 'electrodoméstico', 'electrodomestico'],
  'subscriptions': ['netflix', 'spotify', 'disney', 'suscripción', 'suscripcion', 'hbo', 'prime', 'youtube premium'],
  'travel': ['viaje', 'hotel', 'vuelo', 'tiquete', 'airbnb', 'hostal'],
  'pets': ['mascota', 'veterinario', 'concentrado', 'perro', 'gato'],
  'personal_care': ['peluquería', 'peluqueria', 'barbería', 'barberia', 'uñas', 'gimnasio', 'gym'],
  'gifts': ['regalo', 'detalle', 'cumpleaños'],
  'debt': ['cuota', 'préstamo', 'prestamo', 'crédito hipotecario'],
  'taxes': ['impuesto', 'predial', 'dian', 'multa', 'trámite', 'tramite'],
};

const _weekdays = {'lunes': 1, 'martes': 2, 'miércoles': 3, 'miercoles': 3, 'jueves': 4, 'viernes': 5, 'sábado': 6, 'sabado': 6, 'domingo': 7};
const _months = {
  'enero': 1, 'febrero': 2, 'marzo': 3, 'abril': 4, 'mayo': 5, 'junio': 6, 'julio': 7, 'agosto': 8,
  'septiembre': 9, 'setiembre': 9, 'octubre': 10, 'noviembre': 11, 'diciembre': 12,
};

final _amountRe = RegExp(
  r'(\$\s*)?(\d{1,3}(?:\.\d{3})+|\d+)(?:[,.](\d{1,2}))?\s*(millones|millón|millon|mil|k|lucas|pesos|cop)?\b',
  caseSensitive: false,
);

/// Amounts in COP (0 decimals) found in [text], in order of appearance.
List<int> extractCopAmounts(String text) {
  final out = <int>[];
  for (final m in _amountRe.allMatches(text)) {
    final hasMarker = m.group(1) != null || m.group(4) != null;
    final rawInt = m.group(2)!;
    final grouped = rawInt.contains('.');
    if (!hasMarker && !grouped && rawInt.length < 4) continue; // "el 15", "2 personas"
    final unit = (m.group(4) ?? '').toLowerCase();
    final whole = int.parse(rawInt.replaceAll('.', ''));
    final frac = m.group(3);
    int value;
    if (unit.startsWith('mill')) {
      final f = frac == null ? 0 : int.parse(frac.padRight(2, '0'));
      value = whole * 1000000 + f * 10000;
    } else if (unit == 'mil' || unit == 'k' || unit == 'lucas') {
      final f = frac == null ? 0 : int.parse(frac.padRight(2, '0'));
      value = whole * 1000 + f * 10;
    } else {
      value = whole; // COP has no decimals: "12.500,50" is not expected
    }
    if (value > 0) out.add(value);
  }
  return out;
}

LocalParseResult parseExpenseText(String input, {required DateTime today, required List<ParseWorkspace> workspaces}) {
  final r = LocalParseResult();
  final text = input.trim();
  final lower = text.toLowerCase();

  // Amount (corrections such as "no, eran 50 mil" take the last value).
  final amounts = extractCopAmounts(text);
  final correcting = RegExp(r'\b(no,|perdón|perdon|mejor dicho|corrijo|en realidad)').hasMatch(lower);
  if (amounts.isEmpty) {
    r.missing.add('amount');
  } else {
    r.amountMinor = correcting ? amounts.last : amounts.first;
    if (amounts.length > 1 && !correcting) {
      r.ambiguities.add('Encontré varios importes; tomé el primero. Si son varios artículos, regístralos en la factura.');
    }
  }

  // Date.
  if (lower.contains('anteayer') || lower.contains('antier')) {
    r.date = today.subtract(const Duration(days: 2));
  } else if (lower.contains('ayer')) {
    r.date = today.subtract(const Duration(days: 1));
  } else {
    final wd = _weekdays.entries.where((e) => RegExp('\\b(el |este |el pasado )?${e.key}\\b').hasMatch(lower)).firstOrNull;
    final explicit = RegExp(r'\b(?:el )?(\d{1,2}) de ([a-záéíóú]+)\b').firstMatch(lower);
    if (explicit != null && _months.containsKey(explicit.group(2))) {
      final day = int.parse(explicit.group(1)!);
      final month = _months[explicit.group(2)]!;
      var d = DateTime(today.year, month, day);
      if (d.isAfter(today)) d = DateTime(today.year - 1, month, day);
      if (d.month == month) r.date = d;
    } else if (wd != null) {
      var diff = today.weekday - wd.value;
      if (diff <= 0) diff += 7;
      if (diff == 7 && lower.contains('hoy')) diff = 0;
      r.date = today.subtract(Duration(days: diff));
    } else {
      r.date = today;
    }
  }

  // Category and description.
  String? keyword;
  for (final e in _categoryKeywords.entries) {
    for (final k in e.value) {
      if (RegExp('\\b${RegExp.escape(k)}\\b').hasMatch(lower)) {
        r.categoryKey ??= e.key;
        keyword ??= k;
      }
    }
  }
  if (keyword != null) {
    r.description = keyword[0].toUpperCase() + keyword.substring(1);
  } else {
    var d = text.replaceAll(_amountRe, ' ').replaceAll(RegExp(r'\b(compré|compre|pagué|pague|gasté|gaste|por|en|de|un|una|el|la)\b', caseSensitive: false), ' ');
    d = d.replaceAll(RegExp(r'[,.;]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (d.isNotEmpty) r.description = (d[0].toUpperCase() + d.substring(1)).substring(0, d.length.clamp(0, 60));
  }
  if (r.description == null) r.missing.add('description');

  // Payment method.
  if (RegExp(r'cr[eé]dito|visa|mastercard|amex').hasMatch(lower)) {
    r.paymentMethod = 'credit_card';
  } else if (RegExp(r'd[eé]bito').hasMatch(lower)) {
    r.paymentMethod = 'debit_card';
  } else if (RegExp(r'efectivo|cash|billete').hasMatch(lower)) {
    r.paymentMethod = 'cash';
  } else if (RegExp(r'nequi|daviplata|billetera|movii').hasMatch(lower)) {
    r.paymentMethod = 'digital_wallet';
  } else if (RegExp(r'transferencia|pse').hasMatch(lower)) {
    r.paymentMethod = 'bank_transfer';
  } else if (lower.contains('tarjeta')) {
    r.ambiguities.add('Mencionas una tarjeta: ¿débito o crédito?');
  }

  // Workspace.
  final shared = workspaces.where((w) => w.kind != 'personal').toList();
  ParseWorkspace? ws = shared.where((w) => lower.contains(w.name.toLowerCase())).firstOrNull;
  if (ws == null && RegExp(r'(para|de) (la|mi|nuestra) casa|del hogar|para el hogar|para la familia').hasMatch(lower)) {
    final homes = shared.where((w) => w.kind == 'household').toList();
    if (homes.length == 1) {
      ws = homes.first;
    } else if (homes.length > 1) {
      r.ambiguities.add('Tienes varios hogares: elige a cuál corresponde.');
    } else {
      r.ambiguities.add('Mencionas la casa, pero no tienes un espacio de hogar compartido.');
    }
  }
  if (ws == null && RegExp(r'con mi pareja|para los dos|de los dos').hasMatch(lower)) {
    final couples = shared.where((w) => w.kind == 'couple').toList();
    if (couples.length == 1) ws = couples.first;
  }
  ws ??= workspaces.where((w) => w.kind == 'personal').firstOrNull;
  r.workspaceId = ws?.id;

  // People within the chosen workspace.
  if (ws != null && ws.kind != 'personal') {
    final me = ws.members.where((m) => m.isMe).firstOrNull;
    for (final m in ws.members.where((m) => !m.isMe)) {
      final first = m.name.split(' ').first.toLowerCase();
      if (first.length < 2) continue;
      if (RegExp('\\bpag[oó] $first\\b').hasMatch(lower)) r.payerId = m.id;
      if (RegExp('\\b$first\\b').hasMatch(lower)) r.participantIds.add(m.id);
    }
    if (RegExp(r'pagu[eé]|con mi tarjeta|yo pagu').hasMatch(lower) || r.payerId == null) r.payerId ??= me?.id;
    if (me != null && !r.participantIds.contains(me.id)) r.participantIds.insert(0, me.id);
    if (r.participantIds.length == 1) {
      // Nobody named: default to everybody, but ask.
      r.participantIds = ws.members.map((m) => m.id).toList();
      r.ambiguities.add('No indicaste entre quiénes se reparte: propongo a todos los miembros de ${ws.name}.');
    }
    // Equal split is the proposed default; the person can change it.
    r.splitEqually = true;
  } else if (ws != null) {
    final me = ws.members.where((m) => m.isMe).firstOrNull;
    r.payerId = me?.id;
    if (me != null) r.participantIds = [me.id];
  }
  return r;
}
