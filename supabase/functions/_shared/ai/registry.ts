// Resolves which provider serves each capability from server secrets.
// A capability without credentials is reported as not configured — never faked.
import { AnthropicProvider } from './anthropic.ts';
import { HttpTranscriber } from './transcription.ts';
import type { CopilotModel, ExpenseParser, ReceiptExtractor, Transcriber } from './types.ts';
import { HttpError } from '../http.ts';

export interface AiRegistry {
  expenseParser: ExpenseParser | null;
  receiptExtractor: ReceiptExtractor | null;
  transcriber: Transcriber | null;
  copilot: CopilotModel | null;
}

export function loadRegistry(env: (k: string) => string | undefined = (k) => Deno.env.get(k)): AiRegistry {
  const anthropicKey = env('ANTHROPIC_API_KEY');
  const textProvider = (env('AI_TEXT_PROVIDER') ?? (anthropicKey ? 'anthropic' : 'none')).toLowerCase();
  const claude = textProvider === 'anthropic' && anthropicKey
    ? new AnthropicProvider(anthropicKey, env('ANTHROPIC_MODEL') ?? 'claude-opus-5-5')
    : null;

  const sttUrl = env('TRANSCRIPTION_API_URL');
  const sttKey = env('TRANSCRIPTION_API_KEY');
  const transcriber = sttUrl && sttKey ? new HttpTranscriber(sttUrl, sttKey, env('TRANSCRIPTION_MODEL') ?? 'whisper-1') : null;

  return { expenseParser: claude, receiptExtractor: claude, transcriber, copilot: claude };
}

export function capabilities(reg: AiRegistry) {
  return {
    text_parsing: reg.expenseParser ? { configured: true, provider: reg.expenseParser.id } : { configured: false },
    receipt_extraction: reg.receiptExtractor ? { configured: true, provider: reg.receiptExtractor.id } : { configured: false },
    transcription: reg.transcriber ? { configured: true, provider: reg.transcriber.id } : { configured: false },
    copilot: reg.copilot ? { configured: true, provider: reg.copilot.id } : { configured: false },
  };
}

export function require<T>(value: T | null, capability: string): T {
  if (!value) throw new HttpError(503, 'ai_not_configured', `${capability} provider is not configured on the server`);
  return value;
}
