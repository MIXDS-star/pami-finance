import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/failure.dart';
import '../../core/providers.dart';
import '../../core/theme/theme.dart';
import '../../ui/states.dart';

class _Msg {
  _Msg(this.role, this.text, {this.sources = const [], this.error = false});
  final String role;
  final String text;
  final List<Map<String, dynamic>> sources;
  final bool error;
}

const _toolLabels = {
  'get_period_summary': 'resumen del periodo',
  'get_spending_by_category': 'gasto por categoría',
  'get_monthly_trend': 'tendencia mensual',
  'get_top_merchants': 'principales comercios',
  'get_budget_status': 'estado de presupuestos',
  'get_shared_balances': 'saldos del espacio',
  'get_pending_shared_expenses': 'gastos compartidos',
  'get_goals': 'metas de ahorro',
  'simulate_savings': 'simulación hipotética',
};

/// Read-only financial assistant. Conversation stays in memory on this screen.
class CopilotScreen extends ConsumerStatefulWidget {
  const CopilotScreen({super.key, this.initialQuestion});
  final String? initialQuestion;
  @override
  ConsumerState<CopilotScreen> createState() => _CopilotScreenState();
}

class _CopilotScreenState extends ConsumerState<CopilotScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <_Msg>[];
  bool _busy = false;

  static const _suggestions = [
    '¿Cuánto gasté en restaurantes este mes?',
    '¿En qué categorías aumentaron mis gastos?',
    '¿Qué gastos compartidos siguen pendientes?',
    '¿Qué pasaría si ahorro 300 mil al mes durante 2 años?',
    '¿Cómo voy con mis metas?',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.initialQuestion != null) _input.text = widget.initialQuestion!;
  }

  Future<void> _send([String? text]) async {
    final q = (text ?? _input.text).trim();
    if (q.isEmpty || _busy) return;
    final history = [for (final m in _messages.where((m) => !m.error)) {'role': m.role, 'text': m.text}];
    setState(() {
      _messages.add(_Msg('user', q));
      _busy = true;
      _input.clear();
    });
    _toBottom();
    try {
      final r = await ref.read(aiRepositoryProvider).ask(q, history);
      setState(() => _messages.add(_Msg('assistant', r.answer, sources: r.sources)));
    } catch (e) {
      setState(() => _messages.add(_Msg('assistant', AppFailure.from(e).message, error: true)));
    } finally {
      setState(() => _busy = false);
      _toBottom();
    }
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: PamiTokens.motion, curve: Curves.easeOut);
      });

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(aiCapabilitiesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Copiloto financiero')),
      body: AsyncView(
        value: caps,
        data: (c) {
          if (!c.copilot) {
            return EmptyState(
              icon: Icons.auto_awesome_outlined,
              title: c.reachable ? 'Copiloto no configurado' : 'Copiloto no disponible',
              message: c.reachable
                  ? 'El servidor aún no tiene un proveedor de IA configurado. Mientras tanto, tus estadísticas, presupuestos e '
                      'informes mensuales funcionan con normalidad.'
                  : 'No pudimos contactar el servicio. Revisa tu conexión e inténtalo más tarde.',
              action: OutlinedButton(onPressed: () => ref.invalidate(aiCapabilitiesProvider), child: const Text('Reintentar')),
            );
          }
          return Column(children: [
            Expanded(
              child: ListView(controller: _scroll, padding: const EdgeInsets.all(16), children: [
                const Notice(message: 'Responde con tus datos registrados, calculados por el servidor. Distingue datos, estimaciones y '
                    'escenarios. No es asesoría financiera y no puede modificar tus datos.'),
                const SizedBox(height: 12),
                if (_messages.isEmpty)
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final s in _suggestions) ActionChip(label: Text(s), onPressed: () => _send(s)),
                  ]),
                for (final m in _messages) _Bubble(m: m),
                if (_busy)
                  const Padding(padding: EdgeInsets.all(12), child: Align(alignment: Alignment.centerLeft, child: LoadingState(compact: true, label: 'Pensando'))),
              ]),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 1000,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(hintText: 'Pregunta sobre tus finanzas', counterText: ''),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(tooltip: 'Enviar', onPressed: _busy ? null : _send, icon: const Icon(Icons.send)),
                ]),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.m});
  final _Msg m;

  @override
  Widget build(BuildContext context) {
    final mine = m.role == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.85),
        decoration: BoxDecoration(
          color: mine ? context.pami.brandSoft : (m.error ? context.colors.error.withValues(alpha: 0.08) : context.pami.surfaceSoft),
          borderRadius: BorderRadius.circular(PamiTokens.radiusM),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(m.text),
          if (m.sources.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Basado en: ${m.sources.map((s) {
              final label = _toolLabels[s['tool']] ?? s['tool'];
              final input = Map<String, dynamic>.from(s['input'] as Map? ?? const {});
              final range = input['from'] != null ? ' ${input['from']} a ${input['to']}' : '';
              final ws = input['workspace'] != null ? ' (${input['workspace']})' : '';
              return '$label$range$ws';
            }).toSet().join('; ')}', style: context.text.bodySmall?.copyWith(color: context.pami.muted)),
          ],
        ]),
      ),
    );
  }
}
