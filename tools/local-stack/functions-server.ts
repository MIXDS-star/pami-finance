// Serves every Edge Function from one Deno process for local development.
// In production each function is deployed separately (`supabase functions deploy`).
const names = ['ai-status', 'parse-expense', 'extract-receipt', 'transcribe-audio', 'copilot', 'delete-account'];
const handlers = new Map<string, (req: Request) => Promise<Response>>();
for (const name of names) {
  const mod = await import(`../../supabase/functions/${name}/handler.ts`);
  handlers.set(name, mod.default);
}

const port = Number(Deno.env.get('FUNCTIONS_PORT') ?? 54329);
Deno.serve({ port, hostname: '127.0.0.1' }, (req) => {
  const url = new URL(req.url);
  const [, name, ...rest] = url.pathname.split('/');
  const handler = handlers.get(name);
  if (!handler) return Response.json({ error: { code: 'function_not_found' } }, { status: 404 });
  url.pathname = '/' + rest.join('/');
  return handler(new Request(url, req));
});
