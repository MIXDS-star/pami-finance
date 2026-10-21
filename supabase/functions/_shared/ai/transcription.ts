// Speech-to-text through any provider exposing the widely used
// `POST {base}/audio/transcriptions` multipart contract (configurable URL,
// key and model). Claude does not transcribe audio, so this is separate.
import { AiOutputError, type Transcriber } from './types.ts';

export class HttpTranscriber implements Transcriber {
  readonly id: string;

  constructor(private baseUrl: string, private apiKey: string, private model: string) {
    this.id = `stt:${new URL(baseUrl).host}:${model}`;
  }

  async transcribe(audio: Uint8Array, mimeType: string, language: string) {
    const form = new FormData();
    const ext = mimeType.includes('mp4') || mimeType.includes('m4a') ? 'm4a' : mimeType.includes('webm') ? 'webm' : 'wav';
    form.append('file', new Blob([audio], { type: mimeType }), `nota.${ext}`);
    form.append('model', this.model);
    form.append('language', language);
    form.append('response_format', 'json');
    let res: Response;
    try {
      res = await fetch(`${this.baseUrl.replace(/\/$/, '')}/audio/transcriptions`, {
        method: 'POST', headers: { authorization: `Bearer ${this.apiKey}` }, body: form,
        signal: AbortSignal.timeout(60_000),
      });
    } catch {
      throw new AiOutputError('provider_error', 'network');
    }
    if (!res.ok) throw new AiOutputError('provider_error', `status_${res.status}`);
    const body = await res.json() as { text?: string; duration?: number };
    if (typeof body.text !== 'string') throw new AiOutputError('invalid_output');
    return { text: body.text.trim(), durationSeconds: body.duration };
  }
}
