// Natural-language (typed or transcribed) expense -> editable draft.
// Never writes data: the app shows the draft and saves only after confirmation.
import { handle, HttpError, json, readJson } from '../_shared/http.ts';
import { rateLimit, requireUser } from '../_shared/auth.ts';
import { loadRegistry, require, type AiRegistry } from '../_shared/ai/registry.ts';
import { AiOutputError } from '../_shared/ai/types.ts';
import { sanitizeDraft } from '../_shared/ai/validate.ts';
import { buildAliases } from '../_shared/context.ts';

export function createHandler(registry: () => AiRegistry = loadRegistry) {
  return handle(async (req) => {
    const ctx = await requireUser(req);
    const body = await readJson<{ text?: unknown }>(req);
    const text = typeof body.text === 'string' ? body.text.trim() : '';
    if (!text) throw new HttpError(422, 'text_required');
    if (text.length > 1000) throw new HttpError(422, 'text_too_long');

    const parser = require(registry().expenseParser, 'text parsing');
    await rateLimit(ctx, 'ai_parse', 20, 60);
    const maps = await buildAliases(ctx);

    let draft;
    try {
      draft = sanitizeDraft(await parser.parseExpense(text, maps.context), new Set([...maps.workspaceIds.keys(), ...maps.memberIds.keys()]));
    } catch (e) {
      if (e instanceof AiOutputError && e.message === 'rate_limited') throw new HttpError(429, 'ai_rate_limited');
      if (e instanceof AiOutputError) throw new HttpError(e.code === 'refused' ? 422 : 502, `ai_${e.code}`);
      throw e;
    }
    // Resolve aliases back to ids on the server; the model never saw them.
    const ws = (a: string | null) => (a ? maps.workspaceIds.get(a) ?? null : null);
    const member = (a: string | null) => (a ? maps.memberIds.get(a) ?? null : null);
    return json({
      provider: parser.id,
      draft: {
        ...draft,
        workspace_id: ws(draft.workspace_alias),
        payer_id: member(draft.payer_alias),
        participants: draft.participants.map((p) => ({ user_id: member(p.alias), share_type: p.share_type, value: p.value })),
        items: draft.items.map((i) => ({ description: i.description, amount_minor: i.amount_minor,
                                         participant_ids: i.participant_aliases.map(member).filter(Boolean) })),
        workspace_alias: undefined, payer_alias: undefined,
      },
    });
  });
}

export default createHandler();
