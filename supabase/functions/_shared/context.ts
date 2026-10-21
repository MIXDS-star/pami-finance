// Builds the pseudonymised context sent to AI providers: aliases (w1, m1)
// instead of database ids, first names only, nothing financial.
import type { UserContext } from './auth.ts';
import type { ParseContext } from './ai/types.ts';

export interface AliasMaps {
  context: ParseContext;
  workspaceIds: Map<string, string>;
  memberIds: Map<string, string>;
}

export async function userToday(ctx: UserContext): Promise<{ today: string; currency: string; timezone: string }> {
  const { data } = await ctx.db.from('user_preferences').select('timezone, default_currency').eq('user_id', ctx.user.id).maybeSingle();
  const timezone = data?.timezone ?? 'America/Bogota';
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  return { today, currency: data?.default_currency ?? 'COP', timezone };
}

export async function buildAliases(ctx: UserContext): Promise<AliasMaps> {
  const { today, currency } = await userToday(ctx);
  const { data: workspaces } = await ctx.db.from('workspaces').select('id, name, kind').is('archived_at', null).order('created_at');
  const { data: members } = await ctx.db.from('workspace_members').select('workspace_id, user_id').eq('status', 'active');
  const ids = [...new Set((members ?? []).map((m) => m.user_id as string))];
  const { data: profiles } = ids.length
    ? await ctx.db.from('profiles').select('id, display_name').in('id', ids)
    : { data: [] as { id: string; display_name: string }[] };
  const names = new Map((profiles ?? []).map((p) => [p.id as string, (p.display_name as string).split(' ')[0]]));

  const workspaceIds = new Map<string, string>();
  const memberIds = new Map<string, string>();
  const memberAlias = new Map<string, string>();
  const aliasFor = (uid: string) => {
    if (!memberAlias.has(uid)) {
      const a = `m${memberAlias.size + 1}`;
      memberAlias.set(uid, a);
      memberIds.set(a, uid);
    }
    return memberAlias.get(uid)!;
  };
  aliasFor(ctx.user.id);

  const list = (workspaces ?? []).map((w, i) => {
    const alias = `w${i + 1}`;
    workspaceIds.set(alias, w.id as string);
    return {
      alias, name: w.name as string, kind: w.kind as string,
      members: (members ?? []).filter((m) => m.workspace_id === w.id).map((m) => ({
        alias: aliasFor(m.user_id as string), name: names.get(m.user_id as string) ?? 'Miembro', isMe: m.user_id === ctx.user.id,
      })),
    };
  });
  return { context: { today, defaultCurrency: currency, workspaces: list }, workspaceIds, memberIds };
}
