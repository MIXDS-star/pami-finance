// HTTP helpers shared by every Edge Function.
export const corsHeaders: Record<string, string> = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, x-client-info, apikey, content-type',
  'access-control-allow-methods': 'POST, GET, OPTIONS',
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  });
}

/** Stable machine-readable error. `code` is translated by the app. */
export class HttpError extends Error {
  constructor(public status: number, public code: string, message?: string) {
    super(message ?? code);
  }
}

export function errorResponse(e: unknown): Response {
  if (e instanceof HttpError) {
    return json({ error: { code: e.code, message: e.message } }, e.status);
  }
  // Never echo internals, document contents or tokens back or into logs.
  console.error('[function] unexpected error:', e instanceof Error ? e.name : typeof e);
  return json({ error: { code: 'internal_error', message: 'Unexpected error' } }, 500);
}

export async function readJson<T>(req: Request, maxBytes = 64 * 1024): Promise<T> {
  const text = await req.text();
  if (text.length > maxBytes) throw new HttpError(413, 'payload_too_large');
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new HttpError(400, 'invalid_json');
  }
}

export type Handler = (req: Request) => Promise<Response>;

/** Wraps a handler with CORS preflight, method check and error mapping. */
export function handle(fn: Handler, methods: string[] = ['POST']): Handler {
  return async (req) => {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders });
    if (!methods.includes(req.method)) return json({ error: { code: 'method_not_allowed' } }, 405);
    try {
      return await fn(req);
    } catch (e) {
      return errorResponse(e);
    }
  };
}
