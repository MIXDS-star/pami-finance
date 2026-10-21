import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/money/money.dart';
import '../core/theme/theme.dart';
import '../data/models.dart';

/// Money with tabular figures, explicit sign and a spoken label.
class AmountText extends StatelessWidget {
  const AmountText(this.minor, this.currency, {super.key, this.style, this.signed = false, this.colorize = false, this.semanticPrefix});

  final int minor;
  final Currency currency;
  final TextStyle? style;

  /// Show "+" for positive values (balances, income).
  final bool signed;

  /// Tint positive/negative; the sign is always shown so color is not the only cue.
  final bool colorize;
  final String? semanticPrefix;

  @override
  Widget build(BuildContext context) {
    final s = formatMinor(minor, currency, signed: signed || colorize);
    final color = !colorize || minor == 0 ? null : (minor > 0 ? context.nexo.positive : context.nexo.negative);
    final base = (style ?? context.text.titleMedium)!;
    return Semantics(
      label: '${semanticPrefix ?? ''} ${minor < 0 ? 'menos ' : ''}${formatMinor(minor.abs(), currency, withSymbol: false)} ${currency.name}'.trim(),
      excludeSemantics: true,
      child: Text(s, style: base.copyWith(fontFeatures: NexoTokens.tabular, color: color ?? base.color), maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.child, this.title, this.action, this.padding = const EdgeInsets.all(16), this.onTap});
  final Widget child;
  final String? title;
  final Widget? action;
  final EdgeInsets padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: padding,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (title != null || action != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(children: [
                  if (title != null) Expanded(child: Semantics(header: true, child: Text(title!, style: context.text.titleMedium))),
                  ?action,
                ]),
              ),
            child,
          ]),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.action});
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Row(children: [
          Expanded(child: Semantics(header: true, child: Text(text, style: context.text.titleMedium))),
          ?action,
        ]),
      );
}

class CategoryBadge extends StatelessWidget {
  const CategoryBadge({super.key, this.category, this.size = 40, this.fallbackIcon = Icons.receipt_long_outlined});
  final Category? category;
  final double size;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    final color = category?.color ?? context.nexo.muted;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(size * 0.32)),
        child: Icon(category?.iconData ?? fallbackIcon, color: color, size: size * 0.52),
      ),
    );
  }
}

class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.name, this.size = 32, this.inactive = false});
  final String name;
  final double size;
  final bool inactive;

  static const _palette = [Color(0xFF0E7C66), Color(0xFF3E7CB1), Color(0xFFA5651E), Color(0xFF7A5C99), Color(0xFFB05E8F), Color(0xFF4F6D7A)];

  @override
  Widget build(BuildContext context) {
    final initials = Profile(id: '', displayName: name).initials;
    final color = inactive ? context.nexo.muted : _palette[name.codeUnits.fold(0, (a, b) => a + b) % _palette.length];
    return Semantics(
      label: name,
      excludeSemantics: true,
      child: CircleAvatar(
        radius: size / 2,
        backgroundColor: color.withValues(alpha: 0.18),
        child: Text(initials, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: size * 0.38)),
      ),
    );
  }
}

class AvatarStack extends StatelessWidget {
  const AvatarStack({super.key, required this.names, this.size = 26, this.max = 4});
  final List<String> names;
  final double size;
  final int max;

  @override
  Widget build(BuildContext context) {
    final shown = names.take(max).toList();
    return Semantics(
      label: names.join(', '),
      excludeSemantics: true,
      child: SizedBox(
        height: size,
        width: size + (shown.length - 1).clamp(0, max) * size * 0.62 + (names.length > max ? size * 0.62 : 0),
        child: Stack(children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * size * 0.62,
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: context.colors.surface, width: 2)),
                child: PersonAvatar(name: shown[i], size: size - 4),
              ),
            ),
          if (names.length > max)
            Positioned(
              left: shown.length * size * 0.62,
              child: CircleAvatar(radius: (size - 4) / 2, backgroundColor: context.nexo.surfaceSoft,
                  child: Text('+${names.length - max}', style: context.text.labelSmall)),
            ),
        ]),
      ),
    );
  }
}

/// Labelled progress with an explicit percentage text (not color only).
class LabeledProgress extends StatelessWidget {
  const LabeledProgress({super.key, required this.valueBp, this.alert = false, this.caption});
  final int valueBp;
  final bool alert;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final over = valueBp > 10000;
    final color = over ? context.colors.error : (alert ? context.nexo.warning : context.colors.primary);
    return Semantics(
      label: '${caption ?? ''} ${formatBp(valueBp)}${over ? ', excedido' : alert ? ', cerca del límite' : ''}',
      excludeSemantics: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: (valueBp / 10000).clamp(0, 1).toDouble(),
            minHeight: 8,
            color: color,
            backgroundColor: context.nexo.surfaceSoft,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 2, alignment: WrapAlignment.spaceBetween, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (over || alert) ...[Icon(over ? Icons.error_outline : Icons.warning_amber_rounded, size: 14, color: color), const SizedBox(width: 4)],
            Text('${formatBp(valueBp)}${over ? ' · excedido' : alert ? ' · cerca del límite' : ''}',
                style: context.text.labelMedium?.copyWith(color: over || alert ? color : context.nexo.muted)),
          ]),
          if (caption != null) Text(caption!, style: context.text.labelMedium?.copyWith(color: context.nexo.muted)),
        ]),
      ]),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.icon, this.color});
  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.nexo.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 13, color: c), const SizedBox(width: 4)],
        Text(label, style: context.text.labelSmall?.copyWith(color: c, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Money input with Colombian formatting and validation in minor units.
class MoneyField extends StatefulWidget {
  const MoneyField({super.key, required this.currency, this.initialMinor, required this.onChanged, this.label = 'Importe',
      this.autofocus = false, this.large = false, this.allowZero = false, this.helper});
  final Currency currency;
  final int? initialMinor;
  final ValueChanged<int?> onChanged;
  final String label;
  final bool autofocus;
  final bool large;
  final bool allowZero;
  final String? helper;

  @override
  State<MoneyField> createState() => _MoneyFieldState();
}

class _MoneyFieldState extends State<MoneyField> {
  late final TextEditingController _c = TextEditingController(
      text: widget.initialMinor == null ? '' : formatMinor(widget.initialMinor!, widget.currency, withSymbol: false));

  @override
  void didUpdateWidget(MoneyField old) {
    super.didUpdateWidget(old);
    if (widget.initialMinor != old.initialMinor && widget.initialMinor != parseAmountInput(_c.text, widget.currency)) {
      _c.text = widget.initialMinor == null ? '' : formatMinor(widget.initialMinor!, widget.currency, withSymbol: false);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final big = widget.large ? context.text.displaySmall : context.text.titleMedium;
    return TextFormField(
      controller: _c,
      autofocus: widget.autofocus,
      keyboardType: TextInputType.numberWithOptions(decimal: widget.currency.decimals > 0),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), _GroupingFormatter(widget.currency)],
      style: big?.copyWith(fontFeatures: NexoTokens.tabular),
      decoration: InputDecoration(
        labelText: widget.label,
        prefixText: '${widget.currency.symbol} ',
        helperText: widget.helper,
        suffixText: widget.currency.code,
      ),
      validator: (v) {
        final value = parseAmountInput(v ?? '', widget.currency);
        if (value == null) {
          return widget.currency.decimals == 0 ? 'Escribe un número entero de pesos' : 'Escribe un importe válido';
        }
        if (value == 0 && !widget.allowZero) return 'Debe ser mayor que cero';
        return null;
      },
      onChanged: (v) => widget.onChanged(parseAmountInput(v, widget.currency)),
    );
  }
}

/// Re-groups thousands with dots while typing (COP-friendly).
class _GroupingFormatter extends TextInputFormatter {
  _GroupingFormatter(this.currency);
  final Currency currency;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final raw = newValue.text;
    if (raw.isEmpty) return newValue;
    final commaIndex = raw.indexOf(',');
    if (currency.decimals == 0 && commaIndex >= 0) return oldValue;
    final intPart = (commaIndex >= 0 ? raw.substring(0, commaIndex) : raw).replaceAll('.', '');
    final frac = commaIndex >= 0 ? raw.substring(commaIndex) : '';
    if (frac.length > currency.decimals + 1 || intPart.length > 15) return oldValue;
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write('.');
      buf.write(intPart[i]);
    }
    final text = '$buf$frac';
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

class DateField extends StatelessWidget {
  const DateField({super.key, required this.value, required this.onChanged, this.label = 'Fecha', this.firstDate, this.lastDate});
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  final String label;
  final DateTime? firstDate;
  final DateTime? lastDate;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(NexoTokens.radiusS),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: value,
          firstDate: firstDate ?? DateTime(now.year - 10),
          lastDate: lastDate ?? DateTime(now.year + 1, now.month, now.day),
          helpText: label,
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, suffixIcon: const Icon(Icons.calendar_today_outlined, size: 20)),
        child: Text(formatDateLong(value)),
      ),
    );
  }
}

const _monthsEs = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
const _monthsShort = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

String monthName(int m) => _monthsEs[m - 1];
String monthShort(int m) => _monthsShort[m - 1];
String formatMonth(DateTime d) => '${monthName(d.month)[0].toUpperCase()}${monthName(d.month).substring(1)} ${d.year}';

String formatDateLong(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  if (day == today) return 'Hoy';
  if (day == today.subtract(const Duration(days: 1))) return 'Ayer';
  return '${d.day} de ${monthName(d.month)}${d.year != now.year ? ' de ${d.year}' : ''}';
}

String formatDateShort(DateTime d) => '${d.day} ${monthShort(d.month)}${d.year != DateTime.now().year ? ' ${d.year}' : ''}';
