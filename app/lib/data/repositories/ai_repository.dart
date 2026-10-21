import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'guard.dart';

class AiCapabilities {
  const AiCapabilities({this.textParsing = false, this.receiptExtraction = false, this.transcription = false, this.copilot = false,
      this.reachable = true});
  final bool textParsing;
  final bool receiptExtraction;
  final bool transcription;
  final bool copilot;

  /// False when the status endpoint itself could not be reached.
  final bool reachable;

  static const unknown = AiCapabilities(reachable: false);
}

/// Thin client for the AI Edge Functions. Nothing here writes financial data:
/// results are drafts the person reviews and confirms.
class AiRepository {
  AiRepository(this._client);
  final SupabaseClient _client;

  Future<AiCapabilities> status() async {
    try {
      final res = await _client.functions.invoke('ai-status', method: HttpMethod.get);
      final caps = Map<String, dynamic>.from((res.data as Map)['capabilities'] as Map);
      bool on(String k) => (caps[k] as Map?)?['configured'] == true;
      return AiCapabilities(
          textParsing: on('text_parsing'), receiptExtraction: on('receipt_extraction'), transcription: on('transcription'), copilot: on('copilot'));
    } catch (_) {
      return AiCapabilities.unknown;
    }
  }

  Future<Map<String, dynamic>> parseExpense(String text) => guard(() async {
        final res = await _client.functions.invoke('parse-expense', body: {'text': text});
        return Map<String, dynamic>.from((res.data as Map)['draft'] as Map);
      });

  Future<({Map<String, dynamic> extraction, String provider})> extractReceipt(String storagePath) => guard(() async {
        final res = await _client.functions.invoke('extract-receipt', body: {'storage_path': storagePath});
        final data = Map<String, dynamic>.from(res.data as Map);
        return (extraction: Map<String, dynamic>.from(data['extraction'] as Map), provider: data['provider'] as String);
      });

  Future<String> transcribe(Uint8List audio, String mimeType) => guard(() async {
        final res = await _client.functions.invoke('transcribe-audio', body: audio, headers: {'content-type': mimeType});
        return (res.data as Map)['text'] as String;
      });

  Future<({String answer, List<Map<String, dynamic>> sources})> ask(String question, List<Map<String, String>> history) =>
      guard(() async {
        final res = await _client.functions.invoke('copilot', body: {'question': question, 'history': history});
        final data = Map<String, dynamic>.from(res.data as Map);
        return (
          answer: data['answer'] as String,
          sources: ((data['sources'] as List?) ?? const []).map((s) => Map<String, dynamic>.from(s as Map)).toList(),
        );
      });
}
