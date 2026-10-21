import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/finance/projections.dart';
import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../ui/components.dart';
import '../../ui/states.dart';
import 'plan_screen.dart';

/// Financial education and HYPOTHETICAL simulations. No product
/// recommendations, no orders, no promised returns.
class EducationScreen extends ConsumerStatefulWidget {
  const EducationScreen({super.key});
  @override
  ConsumerState<EducationScreen> createState() => _EducationScreenState();
}

class _EducationScreenState extends ConsumerState<EducationScreen> {
  String? _horizon;
  String? _risk;
  String? _liquidity;
  bool? _highInterestDebt;
  int _monthly = 300000;
  int _months = 60;
  int _rateBp = 900;
  int _inflationBp = 500;

  @override
  Widget build(BuildContext context) {
    final currency = Currency.of(ref.watch(preferencesProvider).value?.defaultCurrency ?? 'COP');
    final goals = ref.watch(goalsProvider).value ?? const [];
    final emergency = goals.where((g) => g.$1.kind == 'emergency_fund').firstOrNull;
    final p = projectSavings(monthlyMinor: _monthly, months: _months, annualRateBp: _rateBp, annualInflationBp: _inflationBp);
    final p0 = projectSavings(monthlyMinor: _monthly, months: _months, annualInflationBp: _inflationBp);

    return Scaffold(
      appBar: AppBar(title: const Text('Aprender a invertir')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Notice(kind: NoticeKind.warning, message: 'Contenido educativo. NEXO no ofrece asesoría de inversión, no recomienda productos '
            'ni ejecuta órdenes. Toda inversión puede perder valor. Antes de invertir, verifica que la entidad esté vigilada por la '
            'Superintendencia Financiera de Colombia y considera asesoría profesional.'),
        const SectionTitle('Antes de invertir'),
        _check(context, emergency != null && (emergency.$2?.progressBp ?? 0) >= 10000,
            emergency == null ? 'Aún no tienes un fondo de emergencia. Suele recomendarse cubrir de 3 a 6 meses de gastos esenciales.'
                : 'Fondo de emergencia: ${formatBp(emergency.$2?.progressBp ?? 0, decimals: 0)} de tu meta.'),
        const SizedBox(height: 8),
        Text('¿Tienes deudas con intereses altos (tarjetas de crédito, créditos de consumo)?', style: context.text.bodyMedium),
        Wrap(spacing: 8, children: [
          ChoiceChip(label: const Text('Sí'), selected: _highInterestDebt == true, onSelected: (_) => setState(() => _highInterestDebt = true)),
          ChoiceChip(label: const Text('No'), selected: _highInterestDebt == false, onSelected: (_) => setState(() => _highInterestDebt = false)),
        ]),
        if (_highInterestDebt == true)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Notice(message: 'Pagar una deuda que cobra, por ejemplo, 25 % anual equivale a obtener ese rendimiento sin riesgo. '
                'Es difícil que una inversión lo supere de forma segura.'),
          ),
        const SectionTitle('Tu perfil (orientativo)'),
        _question(context, 'Horizonte: ¿cuándo necesitarías el dinero?', _horizon, const {'short': 'Menos de 1 año', 'medium': '1 a 5 años', 'long': 'Más de 5 años'},
            (v) => setState(() => _horizon = v)),
        _question(context, 'Si tu inversión cayera 15 % en un mes, ¿qué harías?', _risk,
            const {'low': 'Retiraría todo', 'medium': 'Esperaría', 'high': 'Aportaría más'}, (v) => setState(() => _risk = v)),
        _question(context, '¿Podrías necesitar este dinero de forma imprevista?', _liquidity,
            const {'high': 'Sí, probablemente', 'low': 'No'}, (v) => setState(() => _liquidity = v)),
        if (_horizon != null && _risk != null && _liquidity != null) ...[
          const SizedBox(height: 8),
          Notice(message: _profileText()),
        ],
        const SectionTitle('Simulador hipotético'),
        MoneyField(currency: currency, label: 'Aporte mensual', initialMinor: _monthly, onChanged: (v) => setState(() => _monthly = v ?? 0)),
        const SizedBox(height: 8),
        Text('Plazo: $_months meses (${(_months / 12).toStringAsFixed(1)} años)'),
        Slider(value: _months.toDouble(), min: 6, max: 360, divisions: 59, onChanged: (v) => setState(() => _months = v.round())),
        Text('Rentabilidad nominal anual supuesta: ${formatBp(_rateBp)}'),
        Slider(value: _rateBp.toDouble(), min: 0, max: 2000, divisions: 40, onChanged: (v) => setState(() => _rateBp = v.round())),
        Text('Inflación anual supuesta: ${formatBp(_inflationBp)}'),
        Slider(value: _inflationBp.toDouble(), min: 0, max: 1500, divisions: 30, onChanged: (v) => setState(() => _inflationBp = v.round())),
        SectionCard(
          title: 'Escenario hipotético',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _row(context, 'Aportado', p.contributedMinor, currency),
            _row(context, 'Saldo nominal estimado', p.nominalMinor, currency),
            _row(context, 'En poder de compra de hoy', p.realMinor, currency),
            _row(context, 'Sin rentabilidad (solo ahorro), en dinero de hoy', p0.realMinor, currency),
            const SizedBox(height: 8),
            Text('Nominal: lo que verías en la cuenta. Real: lo que podrías comprar hoy con ese dinero tras la inflación supuesta. '
                'No incluye comisiones, impuestos (p. ej. retención en la fuente) ni la volatilidad: el resultado real puede ser menor, '
                'incluso con pérdidas.', style: context.text.bodySmall?.copyWith(color: context.nexo.muted)),
          ]),
        ),
        const SectionTitle('Conceptos clave'),
        const _Concept('Riesgo y rentabilidad', 'A mayor rentabilidad esperada, mayor posibilidad de pérdidas y de variaciones fuertes.'),
        const _Concept('Liquidez', 'Qué tan rápido puedes convertir una inversión en efectivo sin perder valor. El fondo de emergencia debe ser líquido.'),
        const _Concept('Costos', 'Comisiones de administración, de transacción e impuestos reducen el rendimiento neto. Compáralos siempre.'),
        const _Concept('Diversificación', 'Repartir entre distintos activos reduce el impacto de que uno solo salga mal; no elimina el riesgo.'),
        const _Concept('Inflación', 'Si tu dinero rinde menos que la inflación, pierdes poder de compra aunque el saldo crezca.'),
      ]),
    );
  }

  String _profileText() {
    if (_horizon == 'short' || _liquidity == 'high') {
      return 'Con un horizonte corto o necesidad de liquidez, suelen priorizarse alternativas de bajo riesgo y fácil retiro. '
          'Esto es orientación general, no una recomendación personalizada.';
    }
    if (_risk == 'low') {
      return 'Tu respuesta sugiere baja tolerancia a caídas. Las alternativas volátiles podrían no encajar contigo. '
          'Esto es orientación general, no una recomendación personalizada.';
    }
    return 'Con horizonte largo y tolerancia a variaciones, podrías considerar exponerte a más riesgo de forma diversificada, '
        'entendiendo que puedes perder dinero. Esto es orientación general, no una recomendación personalizada.';
  }

  Widget _check(BuildContext context, bool ok, String text) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(ok ? Icons.check_circle_outline : Icons.radio_button_unchecked, color: ok ? context.nexo.positive : context.nexo.muted),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ]);

  Widget _question(BuildContext context, String q, String? value, Map<String, String> options, ValueChanged<String> onChanged) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(q, style: context.text.bodyMedium),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in options.entries) ChoiceChip(label: Text(e.value), selected: value == e.key, onSelected: (_) => onChanged(e.key)),
          ]),
        ]),
      );

  Widget _row(BuildContext context, String label, int v, Currency c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [Expanded(child: Text(label)), AmountText(v, c, style: context.text.titleSmall)]),
      );
}

class _Concept extends StatelessWidget {
  const _Concept(this.title, this.body);
  final String title;
  final String body;
  @override
  Widget build(BuildContext context) => ExpansionTile(tilePadding: EdgeInsets.zero, title: Text(title), children: [
        Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(body))),
      ]);
}
