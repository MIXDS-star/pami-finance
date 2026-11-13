// Conversational copilot. Read-only: answers come from server aggregations
// (copilot/tools.ts) executed with the user's own permissions.
import { handle, HttpError, json, readJson } from '../_shared/http.ts';
import { rateLimit, requireUser } from '../_shared/auth.ts';
import { loadRegistry, require, type AiRegistry } from '../_shared/ai/registry.ts';
import { AiOutputError, type CopilotTurn } from '../_shared/ai/types.ts';
import { buildAliases } from '../_shared/context.ts';
import { assertQuestion, buildTools } from './tools.ts';

export function createHandler(registry: () => AiRegistry = loadRegistry) {
  return handle(async (req) => {
    const ctx = await requireUser(req);
    const body = await readJson<{ question?: unknown; history?: unknown }>(req);
    const question = assertQuestion(body.question);
    const history: CopilotTurn[] = (Array.isArray(body.history) ? body.history : []).flatMap((h) =>
      h && (h.role === 'user' || h.role === 'assistant') && typeof h.text === 'string'
        ? [{ role: h.role, text: h.text.slice(0, 4000) }] : []).slice(-10);

    const model = require(registry().copilot, 'copilot');
    await rateLimit(ctx, 'ai_copilot', 15, 60);
    const maps = await buildAliases(ctx);
    const systemContext =
      `Hoy es ${maps.context.today}. Moneda principal: ${maps.context.defaultCurrency}. ` +
      `Espacios del usuario (alias para las herramientas): ${JSON.stringify(maps.context.workspaces.map((w) => ({ alias: w.alias, name: w.name, kind: w.kind })))}. ` +
      'Para preguntas sobre las finanzas privadas del usuario usa los resúmenes personales; usa datos de un espacio compartido solo si la pregunta se refiere a ese espacio.';

    try {
      const answer = await model.answer(history, question, buildTools(ctx, maps.workspaceIds), systemContext);
      const aliasToName = new Map(maps.context.workspaces.map((w) => [w.alias, w.name]));
      return json({
        provider: model.id,
        answer: answer.text,
        // What the answer was based on, shown to the user as "Basado en…".
        sources: answer.toolCalls.map((c) => ({
          tool: c.name,
          input: { ...c.input, ...(typeof c.input.workspace_alias === 'string' ? { workspace: aliasToName.get(c.input.workspace_alias) } : {}) },
        })),
      });
    } catch (e) {
      if (e instanceof AiOutputError && e.message === 'rate_limited') throw new HttpError(429, 'ai_rate_limited');
      if (e instanceof AiOutputError) throw new HttpError(e.code === 'refused' ? 422 : 502, `ai_${e.code}`);
      throw e;
    }
  });
}

export default createHandler();
