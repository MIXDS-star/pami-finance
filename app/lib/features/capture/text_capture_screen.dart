import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/finance/expense_draft.dart';
import '../../core/theme/theme.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';
import 'interpretation.dart';
import 'interpretation_preview.dart';

class TextCaptureScreen extends ConsumerStatefulWidget {
  const TextCaptureScreen({super.key, this.initialText, this.source = TxSource.text});
  final String? initialText;
  final TxSource source;

  @override
  ConsumerState<TextCaptureScreen> createState() => _TextCaptureScreenState();
}

class _TextCaptureScreenState extends ConsumerState<TextCaptureScreen> with BusyState {
  late final _text = TextEditingController(text: widget.initialText);
  Interpretation? _result;

  static const _examples = [
    'Compré mercado por 280.000 pesos, pagué con mi tarjeta y es para mi casa',
    'Almuerzo 25 mil en efectivo',
    'Taxi al aeropuerto 48.000 ayer, a medias',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.initialText != null && widget.initialText!.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _interpret());
    }
  }

  Future<void> _interpret() async {
    if (_text.text.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    final r = await runBusy(() => interpretExpense(ref, _text.text.trim(), widget.source), onError: (e) => showFailure(context, e));
    if (mounted && r != null) setState(() => _result = r);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.source == TxSource.voice ? 'Nota de voz' : 'Escribir un gasto')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            controller: _text,
            autofocus: widget.initialText == null,
            minLines: 3,
            maxLines: 6,
            maxLength: 1000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: '¿Qué compraste?', hintText: 'Ej.: Almuerzo con Bruno 64 mil, a medias'),
            onChanged: (_) => setState(() => _result = null),
          ),
          if (_result == null && widget.initialText == null) ...[
            Text('Ejemplos', style: context.text.labelLarge),
            const SizedBox(height: 8),
            for (final e in _examples)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ActionChip(label: Text(e), onPressed: () => setState(() => _text.text = e)),
              ),
          ],
          const SizedBox(height: 12),
          if (_result == null)
            FilledButton.icon(
              onPressed: busy ? null : _interpret,
              icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome_outlined),
              label: const Text('Interpretar'),
            )
          else
            InterpretationPreview(result: _result!),
          const SizedBox(height: 12),
          const Notice(message: 'Nada se guarda hasta que confirmes en el siguiente paso.'),
        ]),
      );
}
