// Claude implementation of the text, receipt and copilot capabilities.
// Uses the official Anthropic SDK. The API key only exists as a server secret.
import Anthropic from '@anthropic-ai/sdk';
import {
  AiOutputError, type CopilotAnswer, type CopilotModel, type CopilotTool, type CopilotTurn, type DocumentInput,
  type ExpenseDraft, type ExpenseParser, type ParseContext, type ReceiptExtraction, type ReceiptExtractor,
} from './types.ts';
import { expenseDraftSchema, receiptSchema } from './schemas.ts';
import { copilotSystemPrompt, expenseSystemPrompt, receiptSystemPrompt } from './prompts.ts';

export class AnthropicProvider implements ExpenseParser, ReceiptExtractor, CopilotModel {
  readonly id: string;
  private client: Anthropic;

  constructor(apiKey: string, private model: string) {
    this.client = new Anthropic({ apiKey, maxRetries: 2, timeout: 60_000 });
    this.id = `anthropic:${model}`;
  }

  // Server-side refusal fallback (routes a policy decline to another model in
  // the same call) and structured output on every structured request.
  private async structured<T>(system: string, content: Anthropic.Beta.BetaContentBlockParam[] | string,
                              schema: Record<string, unknown>, effort: 'low' | 'medium'): Promise<T> {
    let response: Anthropic.Beta.BetaMessage;
    try {
      response = await this.client.beta.messages.create({
        model: this.model,
        max_tokens: 16000,
        betas: ['server-side-fallback-2026-07-01'],
        // deno-lint-ignore no-explicit-any
        fallbacks: 'default' as any,
        system,
        output_config: { effort, format: { type: 'json_schema', schema } },
        messages: [{ role: 'user', content }],
      } as Anthropic.Beta.MessageCreateParamsNonStreaming);
    } catch (e) {
      throw this.mapError(e);
    }
    if (response.stop_reason === 'refusal') throw new AiOutputError('refused');
    if (response.stop_reason === 'max_tokens') throw new AiOutputError('truncated');
    const text = response.content.flatMap((b) => (b.type === 'text' ? [b.text] : [])).join('');
    try {
      return JSON.parse(text) as T;
    } catch {
      throw new AiOutputError('invalid_output');
    }
  }

  private mapError(e: unknown): AiOutputError {
    if (e instanceof Anthropic.RateLimitError) return new AiOutputError('provider_error', 'rate_limited');
    if (e instanceof Anthropic.AuthenticationError) return new AiOutputError('provider_error', 'invalid_credentials');
    if (e instanceof Anthropic.BadRequestError) return new AiOutputError('provider_error', 'bad_request');
    if (e instanceof Anthropic.APIError) return new AiOutputError('provider_error', `status_${e.status}`);
    return new AiOutputError('provider_error', 'network');
  }

  async parseExpense(text: string, ctx: ParseContext): Promise<ExpenseDraft> {
    const system = expenseSystemPrompt(ctx);
    const draft = await this.structured<ExpenseDraft>(system, text, expenseDraftSchema, 'low');
    return draft;
  }

  async extractReceipt(doc: DocumentInput, hint: { defaultCurrency: string; today: string }): Promise<ReceiptExtraction> {
    const system = receiptSystemPrompt(hint);
    const block: Anthropic.Beta.BetaContentBlockParam = doc.mediaType === 'application/pdf'
      ? { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: doc.base64 } }
      : { type: 'image', source: { type: 'base64', media_type: doc.mediaType, data: doc.base64 } };
    return await this.structured<ReceiptExtraction>(system,
      [block, { type: 'text', text: 'Extrae los datos de esta factura.' }], receiptSchema, 'medium');
  }

  async answer(history: CopilotTurn[], question: string, tools: CopilotTool[], systemContext: string): Promise<CopilotAnswer> {
    const system = copilotSystemPrompt(systemContext);

    const apiTools: Anthropic.Beta.BetaTool[] = tools.map((t) => ({
      name: t.name, description: t.description, strict: true,
      input_schema: t.input_schema as Anthropic.Beta.BetaTool.InputSchema,
    }));
    const messages: Anthropic.Beta.BetaMessageParam[] = [
      ...history.slice(-10).map((h) => ({ role: h.role, content: h.text })),
      { role: 'user', content: question },
    ];
    const toolCalls: CopilotAnswer['toolCalls'] = [];

    for (let step = 0; step < 8; step++) {
      let response: Anthropic.Beta.BetaMessage;
      try {
        response = await this.client.beta.messages.create({
          model: this.model,
          max_tokens: 16000,
          betas: ['server-side-fallback-2026-07-01'],
          // deno-lint-ignore no-explicit-any
          fallbacks: 'default' as any,
          output_config: { effort: 'medium' },
          system,
          tools: apiTools,
          messages,
        } as Anthropic.Beta.MessageCreateParamsNonStreaming);
      } catch (e) {
        throw this.mapError(e);
      }

      if (response.stop_reason === 'refusal') throw new AiOutputError('refused');
      if (response.stop_reason === 'max_tokens') throw new AiOutputError('truncated');
      messages.push({ role: 'assistant', content: response.content as Anthropic.Beta.BetaContentBlockParam[] });

      if (response.stop_reason === 'pause_turn') continue;
      const uses = response.content.filter((b): b is Anthropic.Beta.BetaToolUseBlock => b.type === 'tool_use');
      if (response.stop_reason !== 'tool_use' || uses.length === 0) {
        const text = response.content.flatMap((b) => (b.type === 'text' ? [b.text] : [])).join('\n').trim();
        return { text, toolCalls };
      }

      const results: Anthropic.Beta.BetaToolResultBlockParam[] = await Promise.all(uses.map(async (use) => {
        const tool = tools.find((t) => t.name === use.name);
        const input = (use.input ?? {}) as Record<string, unknown>;
        toolCalls.push({ name: use.name, input });
        if (!tool) return { type: 'tool_result' as const, tool_use_id: use.id, is_error: true, content: 'Herramienta desconocida' };
        try {
          return { type: 'tool_result' as const, tool_use_id: use.id, content: JSON.stringify(await tool.run(input)) };
        } catch (e) {
          return { type: 'tool_result' as const, tool_use_id: use.id, is_error: true,
                   content: e instanceof Error ? e.message : 'Error al consultar los datos' };
        }
      }));
      messages.push({ role: 'user', content: results });
    }
    throw new AiOutputError('truncated', 'too many tool steps');
  }
}
