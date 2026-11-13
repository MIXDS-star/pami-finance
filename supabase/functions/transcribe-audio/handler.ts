// Voice note -> text. The audio is processed in memory and never stored.
import { handle, HttpError, json } from '../_shared/http.ts';
import { rateLimit, requireUser } from '../_shared/auth.ts';
import { loadRegistry, require, type AiRegistry } from '../_shared/ai/registry.ts';
import { AiOutputError } from '../_shared/ai/types.ts';

const MAX_BYTES = 10 * 1024 * 1024;
const ALLOWED = ['audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/aac', 'audio/wav', 'audio/x-wav', 'audio/webm', 'audio/mpeg', 'audio/ogg'];

export function createHandler(registry: () => AiRegistry = loadRegistry) {
  return handle(async (req) => {
    const ctx = await requireUser(req);
    const mime = (req.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase();
    if (!ALLOWED.includes(mime)) throw new HttpError(415, 'audio_type_invalid');
    const transcriber = require(registry().transcriber, 'transcription');
    await rateLimit(ctx, 'ai_transcribe', 10, 60);
    const audio = new Uint8Array(await req.arrayBuffer());
    if (audio.length === 0) throw new HttpError(422, 'audio_empty');
    if (audio.length > MAX_BYTES) throw new HttpError(413, 'audio_too_large');
    try {
      const result = await transcriber.transcribe(audio, mime, 'es');
      if (!result.text) throw new HttpError(422, 'audio_no_speech');
      return json({ provider: transcriber.id, text: result.text, duration_seconds: result.durationSeconds ?? null });
    } catch (e) {
      if (e instanceof AiOutputError && e.message === 'rate_limited') throw new HttpError(429, 'ai_rate_limited');
      if (e instanceof AiOutputError) throw new HttpError(502, `ai_${e.code}`);
      throw e;
    }
  });
}

export default createHandler();
