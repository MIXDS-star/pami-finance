// Text, receipt and copilot capabilities through any provider that exposes the
// widely used `POST {base}/chat/completions` contract (Groq, Google Gemini's
// OpenAI-compatible endpoint, OpenRouter, a self-hosted model…). Lets Pami run
// on providers with free tiers. Output is still re-validated by validate.ts.
import {
  AiOutputError, type CopilotAnswer, type CopilotModel, type CopilotTool, type CopilotTurn, type DocumentInput,
  type ExpenseDraft, type ExpenseParser, type ParseContext, type ReceiptExtraction, type ReceiptExtractor,
} from './types.ts';
import { expenseDraftSchema, receiptSchema } from './schemas.ts';
import { copilotSystemPrompt, expenseSystemPrompt, receiptSystemPrompt } from './prompts.ts';

export interface OpenAICompatibleConfig {
  baseUrl: string;
  apiKey: string;
  textModel: string;
  /** Model able to read images; defaults to textModel. */
  visionModel?: string;
  /** true if the provider honours response_format json_schema; otherwise json_object is used. */
  jsonSchema?: boolean;
  /** Short name shown in ai-status, e.g. "groq". */
  label?: string;
  fetch?: typeof fetch;
}

type ContentPart = { type: 'text'; text: string } | { type: 'image_url'; image_url: { url: string } };
interface ToolCall { id: string; type: 'function'; function: { name: string; arguments: string } }
interface ChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string | ContentPart[] | null;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
}
interface ChatResponse {
  choices?: { message?: ChatMessage; finish_reason?: string }[];
}

export class OpenAICompatibleProvider implements ExpenseParser, ReceiptExtractor, CopilotModel {
  readonly id: string;
  private fetcher: typeof fetch;

  constructor(private cfg: OpenAICompatibleConfig) {
    this.id = `${cfg.label ?? 'openai-compatible'}:${cfg.textModel}`;
    this.fetcher = cfg.fetch ?? fetch;
  }

  private async chat(body: Record<string, unknown>): Promise<ChatResponse> {
    let res: Response;
    try {
      res = await this.fetcher(`${this.cfg.baseUrl.replace(/\/$/, '')}/chat/completions`, {
        method: 'POST',
        headers: { authorization: `Bearer ${this.cfg.apiKey}`, 'content-type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(90_000),
      });
    } catch {
      throw new AiOutputError('provider_error', 'network');
    }
    if (!res.ok) {
      await res.body?.cancel();
      if (res.status === 429) throw new AiOutputError('provider_error', 'rate_limited');
      if (res.status === 401 || res.status === 403) throw new AiOutputError('provider_error', 'invalid_credentials');
      if (res.status === 400 || res.status === 422) throw new AiOutputError('provider_error', 'bad_request');
      throw new AiOutputError('provider_error', `status_${res.status}`);
    }
    try {
      return await res.json() as ChatResponse;
    } catch {
      throw new AiOutputError('invalid_output');
    }
  }

  private static finish(r: ChatResponse): { message: ChatMessage; reason?: string } {
    const choice = r.choices?.[0];
    if (!choice?.message) throw new AiOutputError('invalid_output');
    if (choice.finish_reason === 'length') throw new AiOutputError('truncated');
    if (choice.finish_reason === 'content_filter') throw new AiOutputError('refused');
    return { message: choice.message, reason: choice.finish_reason };
  }

  /** Extracts the JSON object from a reply, tolerating ```json fences. */
  static parseJson<T>(text: string | null | ContentPart[] | undefined): T {
    const raw = typeof text === 'string' ? text : Array.isArray(text) ? text.map((p) => (p.type === 'text' ? p.text : '')).join('') : '';
    const fenced = /```(?:json)?\s*([\s\S]*?)```/.exec(raw);
    const candidate = (fenced ? fenced[1] : raw).trim();
    const start = candidate.indexOf('{');
    const end = candidate.lastIndexOf('}');
    if (start < 0 || end <= start) throw new AiOutputError('invalid_output');
    try {
      return JSON.parse(candidate.slice(start, end + 1)) as T;
    } catch {
      throw new AiOutputError('invalid_output');
    }
  }

  private async structured<T>(system: string, user: string | ContentPart[], schema: Record<string, unknown>, model: string): Promise<T> {
    const format = this.cfg.jsonSchema
      ? { type: 'json_schema', json_schema: { name: 'result', schema, strict: false } }
      : { type: 'json_object' };
    const r = await this.chat({
      model,
      temperature: 0,
      response_format: format,
      messages: [
        { role: 'system', content: `${system}\n\nResponde ÚNICAMENTE con un objeto JSON válido que cumpla este JSON Schema ` +
          `(todas las propiedades son obligatorias; usa null cuando no aplique):\n${JSON.stringify(schema)}` },
        { role: 'user', content: user },
      ],
    });
    return OpenAICompatibleProvider.parseJson<T>(OpenAICompatibleProvider.finish(r).message.content);
  }

  parseExpense(text: string, ctx: ParseContext): Promise<ExpenseDraft> {
    return this.structured<ExpenseDraft>(expenseSystemPrompt(ctx), text, expenseDraftSchema, this.cfg.textModel);
  }

  extractReceipt(doc: DocumentInput, hint: { defaultCurrency: string; today: string }): Promise<ReceiptExtraction> {
    if (doc.mediaType === 'application/pdf') {
      // Chat-completions providers accept images, not PDF documents.
      return Promise.reject(new AiOutputError('provider_error', 'pdf_unsupported'));
    }
    return this.structured<ReceiptExtraction>(receiptSystemPrompt(hint), [
      { type: 'text', text: 'Extrae los datos de esta factura.' },
      { type: 'image_url', image_url: { url: `data:${doc.mediaType};base64,${doc.base64}` } },
    ], receiptSchema, this.cfg.visionModel ?? this.cfg.textModel);
  }

  async answer(history: CopilotTurn[], question: string, tools: CopilotTool[], systemContext: string): Promise<CopilotAnswer> {
    const messages: ChatMessage[] = [
      { role: 'system', content: copilotSystemPrompt(systemContext) },
      ...history.slice(-10).map((h) => ({ role: h.role, content: h.text }) as ChatMessage),
      { role: 'user', content: question },
    ];
    const apiTools = tools.map((t) => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.input_schema } }));
    const toolCalls: CopilotAnswer['toolCalls'] = [];

    for (let step = 0; step < 8; step++) {
      const r = await this.chat({ model: this.cfg.textModel, temperature: 0.2, tools: apiTools, tool_choice: 'auto', messages });
      const { message } = OpenAICompatibleProvider.finish(r);
      const calls = message.tool_calls ?? [];
      messages.push({ role: 'assistant', content: message.content ?? null, ...(calls.length ? { tool_calls: calls } : {}) });
      if (calls.length === 0) {
        const text = typeof message.content === 'string' ? message.content.trim() : '';
        if (!text) throw new AiOutputError('invalid_output');
        return { text, toolCalls };
      }
      for (const call of calls) {
        const tool = tools.find((t) => t.name === call.function?.name);
        let input: Record<string, unknown> = {};
        let content: string;
        try {
          input = JSON.parse(call.function?.arguments || '{}');
          toolCalls.push({ name: call.function.name, input });
          content = tool ? JSON.stringify(await tool.run(input)) : 'Error: herramienta desconocida';
        } catch (e) {
          content = `Error: ${e instanceof Error ? e.message : 'argumentos no válidos'}`;
        }
        messages.push({ role: 'tool', tool_call_id: call.id, content });
      }
    }
    throw new AiOutputError('truncated', 'too many tool steps');
  }
}
