// Resolves which provider serves each capability from server secrets.
// A capability without credentials is reported as not configured — never faked.
import { AnthropicProvider } from './anthropic.ts';
import { OpenAICompatibleProvider } from './openai_compatible.ts';
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
  const compatKey = env('AI_API_KEY');
  const compatUrl = env('AI_API_URL');
  const compatModel = env('AI_TEXT_MODEL');
  // Explicit choice wins; otherwise use whichever provider has credentials.
  const textProvider = (env('AI_TEXT_PROVIDER') ??
    (anthropicKey ? 'anthropic' : compatKey ? 'openai_compatible' : 'none')).toLowerCase();

  let text: (ExpenseParser & ReceiptExtractor & CopilotModel) | null = null;
  if (textProvider === 'anthropic' && anthropicKey) {
    text = new AnthropicProvider(anthropicKey, env('ANTHROPIC_MODEL') ?? 'claude-opus-5-5');
  } else if (textProvider === 'openai_compatible' && compatKey && compatUrl && compatModel) {
    text = new OpenAICompatibleProvider({
      baseUrl: compatUrl,
      apiKey: compatKey,
      textModel: compatModel,
      visionModel: env('AI_VISION_MODEL') || undefined,
      jsonSchema: env('AI_JSON_SCHEMA') === 'true',
      label: env('AI_PROVIDER_LABEL') || undefined,
    });
  }

  const sttUrl = env('TRANSCRIPTION_API_URL');
  const sttKey = env('TRANSCRIPTION_API_KEY');
  const transcriber = sttUrl && sttKey ? new HttpTranscriber(sttUrl, sttKey, env('TRANSCRIPTION_MODEL') ?? 'whisper-1') : null;

  // A provider without a vision model is not offered for receipts.
  const canSeeImages = text instanceof AnthropicProvider || !!env('AI_VISION_MODEL');
  return { expenseParser: text, receiptExtractor: canSeeImages ? text : null, transcriber, copilot: text };
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
