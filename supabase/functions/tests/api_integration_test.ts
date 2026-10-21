// End-to-end API tests against a running stack (tools/local-stack/start.sh).
// Uses the real supabase-js client: Auth (GoTrue), PostgREST + RLS, Storage
// policies and Edge Functions, exactly like the mobile app does.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { assert, assertEquals, assertExists } from '@std/assert';

const URL = Deno.env.get('SUPABASE_URL') ?? 'http://127.0.0.1:54321';
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const run = crypto.randomUUID().slice(0, 8);

async function newUser(name: string): Promise<{ client: SupabaseClient; id: string; email: string }> {
  const client = createClient(URL, ANON, { auth: { persistSession: false, autoRefreshToken: false } });
  const email = `${name.toLowerCase()}.${run}@test.co`;
  const { data, error } = await client.auth.signUp({ email, password: 'Clave-segura-123', options: { data: { display_name: name } } });
  if (error) throw error;
  assertExists(data.session, 'local stack autoconfirms e-mail, so a session is returned');
  return { client, id: data.user!.id, email };
}

const ops = { sanitizeOps: false, sanitizeResources: false };
const ana = await newUser('Ana');
const bruno = await newUser('Bruno');
const eve = await newUser('Eve');
let casa = '';
let tx = '';

Deno.test('sign-up creates profile, preferences and a private personal workspace', ops, async () => {
  const { data: ws } = await ana.client.from('workspaces').select('kind, name');
  assertEquals(ws, [{ kind: 'personal', name: 'Personal' }]);
  const { data: prefs } = await ana.client.from('user_preferences').select('default_currency, timezone').single();
  assertEquals(prefs, { default_currency: 'COP', timezone: 'America/Bogota' });
});

Deno.test('shared workspace: invite, accept and per-item receipt split over HTTP', ops, async () => {
  const { data: id, error } = await ana.client.rpc('create_workspace', { p_name: 'Casa', p_kind: 'household', p_currency: 'COP' });
  assertEquals(error, null);
  casa = id;
  const { data: inv } = await ana.client.rpc('create_invitation', { p_workspace: casa, p_role: 'member', p_email: bruno.email });
  const { error: accErr } = await bruno.client.rpc('accept_invitation', { p_token: inv.token });
  assertEquals(accErr, null);

  const { data: saved, error: saveErr } = await ana.client.rpc('save_transaction', { p: {
    client_request_id: crypto.randomUUID(), workspace_id: casa, kind: 'expense', description: 'Mercado',
    occurred_on: new Date().toISOString().slice(0, 10), currency: 'COP', total_minor: 300000, split_method: 'by_item',
    payments: [{ payer_id: ana.id, amount_minor: 300000 }],
    splits: [{ user_id: ana.id, amount_minor: 155000 }, { user_id: bruno.id, amount_minor: 145000 }],
    receipt: { taxes_included: true, items: [
      { description: 'A', line_total_minor: 80000, allocation_method: 'single', allocations: [{ user_id: ana.id, amount_minor: 80000 }] },
      { description: 'B', line_total_minor: 70000, allocation_method: 'single', allocations: [{ user_id: bruno.id, amount_minor: 70000 }] },
      { description: 'Compartido', line_total_minor: 150000, allocation_method: 'equal',
        allocations: [{ user_id: ana.id, amount_minor: 75000 }, { user_id: bruno.id, amount_minor: 75000 }] },
    ] },
  } });
  assertEquals(saveErr, null);
  tx = saved.id;
  const { data: balances } = await bruno.client.rpc('workspace_balances', { p_workspace: casa });
  assertEquals(balances.find((b: { user_id: string }) => b.user_id === bruno.id).net_minor, -145000);
});

Deno.test('ledger violations come back as HTTP 422 with a stable code', ops, async () => {
  const { error } = await ana.client.rpc('save_transaction', { p: {
    client_request_id: crypto.randomUUID(), workspace_id: casa, kind: 'expense', description: 'Malo',
    occurred_on: '2026-10-01', currency: 'COP', total_minor: 1000, split_method: 'equal',
    payments: [{ payer_id: ana.id, amount_minor: 1000 }], splits: [{ user_id: ana.id, amount_minor: 900 }] } });
  assertEquals(error?.hint, 'ledger_splits_mismatch');
});

Deno.test('an outsider cannot read the shared expense or its balances', ops, async () => {
  const { data } = await eve.client.from('transactions').select('id').eq('id', tx);
  assertEquals(data, []);
  const { data: bal } = await eve.client.rpc('workspace_balances', { p_workspace: casa });
  assertEquals(bal, []);
  const { error } = await eve.client.from('workspace_members').update({ role: 'owner' }).eq('workspace_id', casa);
  assert(error, 'role escalation through the API is rejected');
});

Deno.test('storage: members upload/download receipts; outsiders and bad files are rejected', ops, async () => {
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1]);
  const path = `${casa}/${crypto.randomUUID()}/factura.jpg`;
  const up = await ana.client.storage.from('receipts').upload(path, jpeg, { contentType: 'image/jpeg' });
  assertEquals(up.error, null);
  const down = await bruno.client.storage.from('receipts').download(path);
  assertEquals(down.error, null);
  assertEquals(new Uint8Array(await down.data!.arrayBuffer()), jpeg);

  const stolen = await eve.client.storage.from('receipts').download(path);
  assert(stolen.error, 'outsider cannot download by guessing the path');
  const intrude = await eve.client.storage.from('receipts').upload(`${casa}/${crypto.randomUUID()}/x.jpg`, jpeg, { contentType: 'image/jpeg' });
  assert(intrude.error, 'outsider cannot upload into the workspace folder');
  // Byte-level type checks at upload time are done by the local storage
  // emulation. Hosted Supabase Storage only checks the declared type, so in
  // production the bytes are verified by extract-receipt before any use
  // (see docs/LIMITATIONS.md).
  if (Deno.env.get('LOCAL_STACK') === '1') {
    const fake = await ana.client.storage.from('receipts').upload(`${casa}/${crypto.randomUUID()}/x.jpg`,
      new TextEncoder().encode('<script>alert(1)</script>'), { contentType: 'image/jpeg' });
    assert(fake.error, 'a file whose bytes are not an image is rejected even if labelled image/jpeg');
  }
});

Deno.test('AI functions report honest "not configured" state without credentials', ops, async () => {
  const { data } = await ana.client.functions.invoke('ai-status', { method: 'GET' });
  if (Deno.env.get('ANTHROPIC_API_KEY')) return; // configured environments are covered elsewhere
  assertEquals(data.capabilities.text_parsing.configured, false);
  assertEquals(data.capabilities.transcription.configured, false);
  const res = await fetch(`${URL}/functions/v1/parse-expense`, {
    method: 'POST', headers: { authorization: `Bearer ${(await ana.client.auth.getSession()).data.session!.access_token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ text: 'Mercado 280 mil' }),
  });
  assertEquals(res.status, 503);
  assertEquals((await res.json()).error.code, 'ai_not_configured');
});

Deno.test('functions reject anonymous callers', ops, async () => {
  const res = await fetch(`${URL}/functions/v1/copilot`, { method: 'POST', headers: { apikey: ANON }, body: '{}' });
  assertEquals(res.status, 401);
  await res.body?.cancel();
});

Deno.test('delete-account erases personal data, keeps shared history anonymised', ops, async () => {
  const { data, error } = await bruno.client.functions.invoke('delete-account', { body: { confirm: 'ELIMINAR' } });
  assertEquals(error, null);
  assertEquals(data.deleted, true);
  const { data: prof } = await ana.client.from('profiles').select('display_name').eq('id', bruno.id).single();
  assertEquals(prof?.display_name, 'Usuario eliminado');
  const { data: balances } = await ana.client.rpc('workspace_balances', { p_workspace: casa });
  assertEquals(balances.find((b: { user_id: string }) => b.user_id === ana.id).net_minor, 145000, 'Ana still sees what is owed to her');
  const relogin = await createClient(URL, ANON, { auth: { persistSession: false } }).auth.signInWithPassword({ email: bruno.email, password: 'Clave-segura-123' });
  assert(relogin.error, 'the deleted identity can no longer sign in');
});
