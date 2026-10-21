// Every function acts AS THE CALLING USER: database access goes through a
// client carrying the user's JWT, so Row Level Security applies exactly as it
// does for the app. The service role is only used where documented.
import { createClient, type SupabaseClient, type User } from '@supabase/supabase-js';
import { HttpError } from './http.ts';

export interface UserContext {
  user: User;
  db: SupabaseClient;
}

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new HttpError(500, 'server_misconfigured', `${name} is not set`);
  return v;
}

export async function requireUser(req: Request): Promise<UserContext> {
  const authorization = req.headers.get('authorization') ?? '';
  const token = authorization.replace(/^Bearer\s+/i, '');
  if (!token) throw new HttpError(401, 'auth_required');

  const db = createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await db.auth.getUser(token);
  if (error || !data.user) throw new HttpError(401, 'session_invalid');
  return { user: data.user, db };
}

export function serviceClient(): SupabaseClient {
  return createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Per-user rate limit backed by public.consume_rate_limit (runs as the user). */
export async function rateLimit(ctx: UserContext, bucket: string, max: number, windowSeconds: number) {
  const { data, error } = await ctx.db.rpc('consume_rate_limit', {
    p_bucket: bucket, p_max: max, p_window_seconds: windowSeconds,
  });
  if (error) throw new HttpError(503, 'rate_limit_unavailable');
  if (data !== true) throw new HttpError(429, 'rate_limited', 'Too many requests, try again in a minute');
}
