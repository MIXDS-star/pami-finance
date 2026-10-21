import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money/money.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../ui/components.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';

/// Progressive setup. Only the display name is essential (and already set at
/// sign-up); every other step can be skipped and completed later in Profile.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> with BusyState {
  final _page = PageController();
  int _step = 0;
  final _name = TextEditingController();
  String _country = 'CO';
  String _currency = 'COP';
  String _theme = 'system';
  String? _incomeFrequency;
  int? _incomeDay;
  final Map<String, int?> _budgets = {};
  final Set<String> _goals = {};

  static const _steps = 6;

  @override
  void initState() {
    super.initState();
    ref.read(profileProvider.future).then((p) {
      if (mounted && _name.text.isEmpty) _name.text = p.displayName;
    }).catchError((_) {});
  }

  void _go(int step) {
    setState(() => _step = step);
    _page.animateToPage(step, duration: NexoTokens.motion, curve: Curves.easeOutCubic);
  }

  Future<void> _finish() async {
    await runBusy(() async {
      final profiles = ref.read(profileRepositoryProvider);
      if (_name.text.trim().isNotEmpty) await profiles.updateName(_name.text);
      await profiles.updatePreferences({
        'country_code': _country,
        'default_currency': _currency,
        'theme': _theme,
        'income_frequency': _incomeFrequency,
        'income_day': _incomeDay,
        'financial_goals': _goals.toList(),
      });
      final personal = await ref.read(personalWorkspaceProvider.future);
      if (personal.baseCurrency.code != _currency) {
        await ref.read(workspaceRepositoryProvider).setCurrency(personal.id, _currency);
      }
      final plan = ref.read(planRepositoryProvider);
      for (final e in _budgets.entries.where((e) => (e.value ?? 0) > 0)) {
        final cats = await ref.read(categoriesProvider.future);
        final cat = cats.firstWhere((c) => c.id == e.key);
        await plan.saveBudget(workspaceId: personal.id, name: cat.name, currency: _currency, amountMinor: e.value,
            alertThresholdBp: 8000, categoryIds: [e.key]);
      }
      await profiles.completeOnboarding();
      ref.invalidate(preferencesProvider);
      ref.invalidate(profileProvider);
      ref.read(spacesRevisionProvider.notifier).bump();
      ref.read(ledgerRevisionProvider.notifier).bump();
      if (mounted) context.go('/home');
    }, onError: (e) => showFailure(context, e));
  }

  @override
  Widget build(BuildContext context) {
    final currency = Currency.of(_currency);
    return Scaffold(
      appBar: AppBar(
        leading: _step == 0 ? null : IconButton(tooltip: 'Atrás', icon: const Icon(Icons.arrow_back), onPressed: () => _go(_step - 1)),
        title: Semantics(label: 'Paso ${_step + 1} de $_steps', child: ExcludeSemantics(child: Text('${_step + 1} de $_steps'))),
        actions: [
          if (_step > 0 && _step < _steps - 1)
            TextButton(onPressed: () => _go(_step + 1), child: const Text('Omitir')),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(value: (_step + 1) / _steps, minHeight: 3),
        ),
      ),
      body: SafeArea(
        child: PageView(
          controller: _page,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _StepPage(
              title: '¿Cómo quieres que te llamen?',
              subtitle: 'Es el nombre que verán las personas con quienes compartas un espacio.',
              child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nombre visible'),
                  textCapitalization: TextCapitalization.words),
            ),
            _StepPage(
              title: 'País y moneda',
              subtitle: 'Puedes cambiar la moneda de tu espacio personal mientras no tenga movimientos.',
              child: Column(children: [
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _country,
                  decoration: const InputDecoration(labelText: 'País'),
                  items: const [DropdownMenuItem(value: 'CO', child: Text('Colombia'))],
                  onChanged: (v) => setState(() => _country = v ?? 'CO'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _currency,
                  decoration: const InputDecoration(labelText: 'Moneda principal'),
                  items: [for (final c in Currency.all) DropdownMenuItem(value: c.code, child: Text('${c.name} (${c.code})'))],
                  onChanged: (v) => setState(() => _currency = v ?? 'COP'),
                ),
                const SizedBox(height: 12),
                const Notice(message: 'Por ahora NEXO está disponible en español para Colombia. Zona horaria: America/Bogota.'),
              ]),
            ),
            _StepPage(
              title: 'Apariencia',
              child: RadioGroup<String>(
                groupValue: _theme,
                onChanged: (v) => setState(() => _theme = v!),
                child: Column(children: [
                  for (final t in const [('system', 'Igual que el dispositivo', Icons.brightness_auto_outlined),
                    ('light', 'Claro', Icons.light_mode_outlined), ('dark', 'Oscuro', Icons.dark_mode_outlined)])
                    RadioListTile<String>(value: t.$1, title: Text(t.$2), secondary: Icon(t.$3)),
                ]),
              ),
            ),
            _StepPage(
              title: 'Tus ingresos',
              subtitle: 'Nos ayuda a recordarte cuándo registrarlos. No pedimos importes aquí.',
              child: Column(children: [
                DropdownButtonFormField<String?>(
                  isExpanded: true,
                  initialValue: _incomeFrequency,
                  decoration: const InputDecoration(labelText: 'Frecuencia'),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Prefiero no decirlo')),
                    DropdownMenuItem(value: 'monthly', child: Text('Mensual')),
                    DropdownMenuItem(value: 'biweekly', child: Text('Quincenal')),
                    DropdownMenuItem(value: 'weekly', child: Text('Semanal')),
                    DropdownMenuItem(value: 'irregular', child: Text('Variable')),
                  ],
                  onChanged: (v) => setState(() => _incomeFrequency = v),
                ),
                if (_incomeFrequency == 'monthly' || _incomeFrequency == 'biweekly') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int?>(
                    isExpanded: true,
                    initialValue: _incomeDay,
                    decoration: const InputDecoration(labelText: 'Día habitual de pago'),
                    items: [const DropdownMenuItem(value: null, child: Text('Sin día fijo')),
                      for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('Día $d'))],
                    onChanged: (v) => setState(() => _incomeDay = v),
                  ),
                ],
              ]),
            ),
            _StepPage(
              title: 'Presupuestos iniciales',
              subtitle: 'Elige en qué categorías quieres un límite mensual. Puedes dejarlo para después.',
              child: AsyncView(
                value: ref.watch(categoriesProvider),
                compact: true,
                data: (cats) => Column(children: [
                  for (final c in cats.where((c) => c.kind == 'expense' && c.workspaceId == null).take(8))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Checkbox(
                          value: _budgets.containsKey(c.id),
                          onChanged: (v) => setState(() => v == true ? _budgets[c.id] = null : _budgets.remove(c.id)),
                        ),
                        CategoryBadge(category: c, size: 32),
                        const SizedBox(width: 10),
                        Expanded(child: Text(c.name)),
                        if (_budgets.containsKey(c.id))
                          SizedBox(
                            width: 150,
                            child: MoneyField(currency: currency, label: 'Límite', onChanged: (v) => _budgets[c.id] = v),
                          ),
                      ]),
                    ),
                ]),
              ),
            ),
            _StepPage(
              title: 'Todo listo',
              subtitle: '¿Qué te gustaría lograr? (opcional)',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final g in const [('emergency_fund', 'Fondo de emergencia'), ('debt', 'Salir de deudas'), ('travel', 'Viajar'),
                    ('housing', 'Vivienda'), ('education', 'Estudios'), ('invest', 'Aprender a invertir'), ('control', 'Controlar gastos')])
                    FilterChip(
                      label: Text(g.$2),
                      selected: _goals.contains(g.$1),
                      onSelected: (v) => setState(() => v ? _goals.add(g.$1) : _goals.remove(g.$1)),
                    ),
                ]),
                const SizedBox(height: 24),
                Text('Cómo empezar', style: context.text.titleMedium),
                const SizedBox(height: 8),
                const _Tip(icon: Icons.add_circle, text: 'Toca el botón + en la barra inferior para registrar tu primer gasto: '
                    'escribe una frase, dicta una nota de voz o fotografía la factura.'),
                const _Tip(icon: Icons.group_add_outlined, text: 'En Espacios crea un hogar, pareja o viaje e invita a otras personas. '
                    'Solo verán lo que registren en ese espacio.'),
              ]),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: FilledButton(
            onPressed: busy ? null : () => _step == _steps - 1 ? _finish() : _go(_step + 1),
            child: Text(_step == _steps - 1 ? 'Empezar' : 'Continuar'),
          ),
        ),
      ),
    );
  }
}

class _StepPage extends StatelessWidget {
  const _StepPage({required this.title, this.subtitle, required this.child});
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(24), children: [
        Semantics(header: true, child: Text(title, style: context.text.headlineSmall)),
        if (subtitle != null) ...[const SizedBox(height: 8), Text(subtitle!, style: context.text.bodyLarge?.copyWith(color: context.nexo.muted))],
        const SizedBox(height: 24),
        child,
      ]);
}

class _Tip extends StatelessWidget {
  const _Tip({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: context.colors.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ]),
      );
}
