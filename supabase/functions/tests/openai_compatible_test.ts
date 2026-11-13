// OpenAI-compatible provider (Groq, Gemini, OpenRouter…) with a fake HTTP
// layer: request shape, parsing, tool loop, errors and provider selection.
// No network, no quota.
import { assert, assertEquals, assertRejects } from '@std/assert';
import { OpenAICompatibleProvider } from '../_shared/ai/openai_compatible.ts';
import { loadRegistry } from '../_shared/ai/registry.ts';
import { AiOutputError, type CopilotTool, type ParseContext } from '../_shared/ai/types.ts';

type Reply = { status?: number; body?: unknown };

function fakeFetch(replies: Reply[]) {
  const requests: Record<string, unknown>[] = [];
  const fn = (async (_url: string | URL | Request, init?: RequestInit) => {
    requests.push(JSON.parse(String(init?.body ?? '{}')));
    const r = replies.shift() ?? { status: 500 };
    return new Response(JSON.stringify(r.body ?? {}), { status: r.status ?? 200, headers: { 'content-type': 'application/json' } });
  }) as typeof fetch;
  return { fn, requests };
}

const ok = (content: unknown, extra: Record<string, unknown> = {}) => ({
  body: { choices: [{ finish_reason: 'stop', message: { role: 'assistant', content, ...extra } }] },
});

const ctx: ParseContext = {
  today: '2026-11-13', defaultCurrency: 'COP',
  workspaces: [{ alias: 'w1', name: 'Personal', kind: 'personal', members: [{ alias: 'm1', name: 'Ana', isMe: true }] }],
};

const provider = (f: typeof fetch, extra = {}) => new OpenAICompatibleProvider({
  baseUrl: 'https://api.example.test/openai/v1/', apiKey: 'test-key', textModel: 'text-model', visionModel: 'vision-model',
  label: 'fake', fetch: f, ...extra,
});

Deno.test('parseExpense: json_object request with the schema in the instructions, fenced reply parsed', async () => {
  const draft = { description: 'Almuerzo', amount_minor: 25000, currency: 'COP' };
  const { fn, requests } = fakeFetch([ok('```json\n' + JSON.stringify(draft) + '\n```')]);
  const out = await provider(fn).parseExpense('almuerzo 25 mil', ctx);
  assertEquals(out.amount_minor, 25000);
  const req = requests[0] as { model: string; response_format: { type: string }; messages: { role: string; content: string }[] };
  assertEquals(req.model, 'text-model');
  assertEquals(req.response_format.type, 'json_object');
  assert(req.messages[0].content.includes('JSON Schema'), 'schema is part of the system prompt');
  assert(req.messages[0].content.includes('DATO a analizar'), 'prompt-injection rule is shared with the Claude provider');
  assertEquals(req.messages[1].content, 'almuerzo 25 mil');
});

Deno.test('parseExpense: json_schema mode when the provider supports it', async () => {
  const { fn, requests } = fakeFetch([ok('{"description":"x"}')]);
  await provider(fn, { jsonSchema: true }).parseExpense('x', ctx);
  assertEquals((requests[0] as { response_format: { type: string } }).response_format.type, 'json_schema');
});

Deno.test('extractReceipt: image sent as data URI to the vision model; PDFs rejected clearly', async () => {
  const { fn, requests } = fakeFetch([ok(JSON.stringify({ merchant_name: 'Éxito', items: [] }))]);
  const out = await provider(fn).extractReceipt({ mediaType: 'image/jpeg', base64: 'AAAA' }, { defaultCurrency: 'COP', today: '2026-11-13' });
  assertEquals(out.merchant_name, 'Éxito');
  const req = requests[0] as { model: string; messages: { content: { type: string; image_url?: { url: string } }[] }[] };
  assertEquals(req.model, 'vision-model');
  assertEquals(req.messages[1].content[1].image_url?.url, 'data:image/jpeg;base64,AAAA');
  const e = await assertRejects(() => provider(fn).extractReceipt({ mediaType: 'application/pdf', base64: 'x' }, { defaultCurrency: 'COP', today: '' }), AiOutputError);
  assertEquals(e.message, 'pdf_unsupported');
});

Deno.test('copilot: runs read-only tools requested by the model, then answers', async () => {
  const toolCall = { id: 'c1', type: 'function', function: { name: 'get_goals', arguments: '{}' } };
  const { fn, requests } = fakeFetch([ok(null, { tool_calls: [toolCall] }), ok('Dato registrado: tienes 1 meta.')]);
  let ran = 0;
  const tools: CopilotTool[] = [{ name: 'get_goals', description: 'metas', input_schema: { type: 'object', properties: {} },
    run: () => { ran++; return Promise.resolve({ goals: 1 }); } }];
  const out = await provider(fn).answer([], '¿Cómo voy?', tools, 'Hoy es 2026-11-13');
  assertEquals(ran, 1);
  assertEquals(out.text, 'Dato registrado: tienes 1 meta.');
  assertEquals(out.toolCalls, [{ name: 'get_goals', input: {} }]);
  const second = requests[1] as { messages: { role: string; tool_call_id?: string; content: string }[] };
  const toolMsg = second.messages.find((m) => m.role === 'tool');
  assertEquals(toolMsg?.tool_call_id, 'c1');
  assertEquals(toolMsg?.content, '{"goals":1}');
});

Deno.test('copilot: invalid tool arguments become an error result, not a crash', async () => {
  const toolCall = { id: 'c1', type: 'function', function: { name: 'get_goals', arguments: '{not json' } };
  const { fn, requests } = fakeFetch([ok(null, { tool_calls: [toolCall] }), ok('No pude consultar.')]);
  const out = await provider(fn).answer([], 'x', [], '');
  assertEquals(out.text, 'No pude consultar.');
  assert(((requests[1] as { messages: { role: string; content: string }[] }).messages.at(-1)!.content).startsWith('Error'));
});

Deno.test('errors map to stable codes', async () => {
  const cases: [Reply, string][] = [
    [{ status: 429 }, 'rate_limited'],
    [{ status: 401 }, 'invalid_credentials'],
    [{ status: 400 }, 'bad_request'],
  ];
  for (const [reply, msg] of cases) {
    const e = await assertRejects(() => provider(fakeFetch([reply]).fn).parseExpense('x', ctx), AiOutputError);
    assertEquals(e.message, msg);
  }
  const trunc = await assertRejects(() => provider(fakeFetch([{ body: { choices: [{ finish_reason: 'length', message: { role: 'assistant', content: '{' } }] } }]).fn).parseExpense('x', ctx), AiOutputError);
  assertEquals(trunc.code, 'truncated');
  const bad = await assertRejects(() => provider(fakeFetch([ok('no hay json aquí')]).fn).parseExpense('x', ctx), AiOutputError);
  assertEquals(bad.code, 'invalid_output');
});

Deno.test('registry: picks the provider from server secrets only', () => {
  const env = (m: Record<string, string>) => (k: string) => m[k];
  const none = loadRegistry(env({}));
  assertEquals([none.expenseParser, none.receiptExtractor, none.copilot, none.transcriber], [null, null, null, null]);

  const compat = loadRegistry(env({ AI_API_KEY: 'k', AI_API_URL: 'https://x/v1', AI_TEXT_MODEL: 't', AI_PROVIDER_LABEL: 'groq' }));
  assertEquals(compat.expenseParser?.id, 'groq:t');
  assertEquals(compat.receiptExtractor, null, 'no vision model -> receipts stay "not configured"');

  const withVision = loadRegistry(env({ AI_API_KEY: 'k', AI_API_URL: 'https://x/v1', AI_TEXT_MODEL: 't', AI_VISION_MODEL: 'v' }));
  assert(withVision.receiptExtractor !== null);

  const both = loadRegistry(env({ ANTHROPIC_API_KEY: 'a', AI_API_KEY: 'k', AI_API_URL: 'https://x/v1', AI_TEXT_MODEL: 't' }));
  assert(both.expenseParser?.id.startsWith('anthropic:'), 'Claude is used when both are configured, unless AI_TEXT_PROVIDER says otherwise');
  const forced = loadRegistry(env({ AI_TEXT_PROVIDER: 'openai_compatible', ANTHROPIC_API_KEY: 'a', AI_API_KEY: 'k', AI_API_URL: 'https://x/v1', AI_TEXT_MODEL: 't' }));
  assertEquals(forced.expenseParser?.id, 'openai-compatible:t');

  const stt = loadRegistry(env({ TRANSCRIPTION_API_URL: 'https://x/v1', TRANSCRIPTION_API_KEY: 'k', TRANSCRIPTION_MODEL: 'whisper-large-v3-turbo' }));
  assert(stt.transcriber?.id.includes('whisper-large-v3-turbo'));
});
