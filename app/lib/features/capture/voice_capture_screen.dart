import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/finance/expense_draft.dart';
import '../../core/providers.dart';
import '../../core/util/file_ops.dart';
import '../../core/theme/theme.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';
import 'text_capture_screen.dart';

enum _Phase { idle, recording, recorded, transcribing }

/// Record -> listen/re-record -> transcribe -> interpret -> review -> confirm.
/// The audio stays on the device until sent for transcription and is deleted
/// right after; the server does not store it.
class VoiceCaptureScreen extends ConsumerStatefulWidget {
  const VoiceCaptureScreen({super.key});
  @override
  ConsumerState<VoiceCaptureScreen> createState() => _VoiceCaptureScreenState();
}

class _VoiceCaptureScreenState extends ConsumerState<VoiceCaptureScreen> with BusyState {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  _Phase _phase = _Phase.idle;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  String? _path;
  bool _playing = false;
  String? _permissionError;

  static const _maxDuration = Duration(minutes: 2);

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) => mounted ? setState(() => _playing = false) : null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _recorder.dispose();
    _player.dispose();
    _deleteAudio();
    super.dispose();
  }

  void _deleteAudio() {
    final p = _path;
    if (p != null) deleteLocalFile(p);
  }

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _permissionError = 'Necesitamos permiso de micrófono para grabar. Puedes activarlo en los ajustes del dispositivo.');
      return;
    }
    _deleteAudio();
    final dir = await getTemporaryDirectory();
    _path = '${dir.path}/nexo_nota_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1, sampleRate: 16000, bitRate: 64000), path: _path!);
    HapticFeedback.mediumImpact();
    setState(() {
      _permissionError = null;
      _phase = _Phase.recording;
      _elapsed = Duration.zero;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsed += const Duration(seconds: 1));
      if (_elapsed >= _maxDuration) _stop();
    });
  }

  Future<void> _stop() async {
    _timer?.cancel();
    await _recorder.stop();
    HapticFeedback.lightImpact();
    setState(() => _phase = _Phase.recorded);
  }

  Future<void> _cancel() async {
    _timer?.cancel();
    await _recorder.cancel();
    _deleteAudio();
    _path = null;
    setState(() => _phase = _Phase.idle);
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _player.stop();
    } else {
      await _player.play(DeviceFileSource(_path!));
    }
    setState(() => _playing = !_playing);
  }

  Future<void> _transcribe() async {
    setState(() => _phase = _Phase.transcribing);
    final text = await runBusy(() async {
      final bytes = await readLocalFile(_path!);
      return ref.read(aiRepositoryProvider).transcribe(bytes, 'audio/mp4');
    }, onError: (e) => showFailure(context, e));
    if (!mounted) return;
    if (text == null) {
      setState(() => _phase = _Phase.recorded);
      return;
    }
    _deleteAudio();
    _path = null;
    context.pushReplacement('/capture/text-from-voice', extra: text);
  }

  String _fmt(Duration d) => '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(aiCapabilitiesProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Registrar por voz')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          if (caps != null && !caps.transcription)
            const Notice(kind: NoticeKind.warning, message: 'La transcripción de voz no está configurada en el servidor. '
                'Puedes escribir el gasto en su lugar.'),
          if (_permissionError != null) Notice(kind: NoticeKind.error, message: _permissionError!),
          const Spacer(),
          Text(_phase == _Phase.idle ? 'Di algo como: «Pagué 120 mil de luz para la casa»' : _fmt(_elapsed),
              textAlign: TextAlign.center,
              style: _phase == _Phase.idle ? context.text.titleMedium : context.text.displaySmall),
          if (_phase == _Phase.recording)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text('Grabando… (máximo ${_maxDuration.inMinutes} min)', style: context.text.bodyMedium)),
          const SizedBox(height: 32),
          Semantics(
            button: true,
            onTap: busy || caps?.transcription != true ? null : (_phase == _Phase.recording ? _stop : (_phase == _Phase.transcribing ? null : _start)),
            label: _phase == _Phase.recording ? 'Detener grabación' : 'Empezar a grabar',
            excludeSemantics: true,
            child: GestureDetector(
              onTap: busy || caps?.transcription != true ? null : (_phase == _Phase.recording ? _stop : (_phase == _Phase.transcribing ? null : _start)),
              child: AnimatedContainer(
                duration: NexoTokens.motion,
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: _phase == _Phase.recording ? context.colors.error : context.colors.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(_phase == _Phase.recording ? Icons.stop : Icons.mic, color: Colors.white, size: 44),
              ),
            ),
          ),
          const SizedBox(height: 24),
          if (_phase == _Phase.recorded || _phase == _Phase.transcribing)
            Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
              OutlinedButton.icon(onPressed: busy ? null : _togglePlay, icon: Icon(_playing ? Icons.stop : Icons.play_arrow), label: Text(_playing ? 'Detener' : 'Escuchar')),
              OutlinedButton.icon(onPressed: busy ? null : _start, icon: const Icon(Icons.replay), label: const Text('Repetir')),
              TextButton(onPressed: busy ? null : _cancel, child: const Text('Descartar')),
            ]),
          const Spacer(),
          if (_phase == _Phase.recorded || _phase == _Phase.transcribing)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : _transcribe,
                child: busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)) : const Text('Transcribir e interpretar'),
              ),
            ),
          TextButton(onPressed: () => context.pushReplacement('/capture/text'), child: const Text('Prefiero escribirlo')),
        ]),
      ),
    );
  }
}

/// Transcribed text, editable before interpretation.
class VoiceTranscriptScreen extends StatelessWidget {
  const VoiceTranscriptScreen({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => TextCaptureScreen(initialText: text, source: TxSource.voice);
}
