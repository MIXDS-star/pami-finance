// Local API gateway (plays the role of Kong in a hosted Supabase project):
//   /auth/v1/*       -> Supabase Auth (GoTrue)
//   /rest/v1/*       -> PostgREST
//   /functions/v1/*  -> Deno Edge Functions server
//   /storage/v1/*    -> minimal Storage emulation (DEV ONLY, see below)
//
// The Storage emulation authorises every request by running it AS THE USER in
// Postgres (role `authenticated` + JWT claims), so the very same
// storage.objects RLS policies used in production decide who can upload,
// download or delete. Files live on local disk.
import http from 'node:http';
import { createHmac, randomUUID, timingSafeEqual } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import pg from 'pg';

const env = process.env;
const PORT = Number(env.GATEWAY_PORT ?? 54321);
const SECRET = env.JWT_SECRET;
const STORAGE_DIR = path.join(env.STACK_DIR ?? '/tmp/nexo-stack', 'storage');
const upstream = {
  auth: Number(env.AUTH_PORT ?? 9999),
  rest: Number(env.REST_PORT ?? 3001),
  functions: Number(env.FUNCTIONS_PORT ?? 54329),
};
const pool = new pg.Pool({
  host: env.PGHOST ?? '127.0.0.1', port: Number(env.PGPORT ?? 54322),
  user: 'postgres', database: env.NEXO_DB ?? 'nexo', max: 5,
});

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, x-client-info, apikey, content-type, x-upsert, prefer, range, accept-profile, content-profile, x-supabase-api-version',
  'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD',
  'access-control-expose-headers': 'content-range, x-total-count',
};

function send(res, status, body, headers = {}) {
  const isBuf = Buffer.isBuffer(body);
  res.writeHead(status, { ...CORS, 'content-type': isBuf ? 'application/octet-stream' : 'application/json', ...headers });
  res.end(isBuf ? body : JSON.stringify(body));
}

function verifyJwt(token) {
  const parts = (token ?? '').split('.');
  if (parts.length !== 3) return null;
  const expected = createHmac('sha256', SECRET).update(`${parts[0]}.${parts[1]}`).digest();
  const given = Buffer.from(parts[2], 'base64url');
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return null;
  const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString());
  if (claims.exp && claims.exp < Date.now() / 1000) return null;
  return claims;
}

function proxy(req, res, port, stripPrefix) {
  const target = req.url.slice(stripPrefix.length) || '/';
  const headers = { ...req.headers, host: `127.0.0.1:${port}` };
  // Like Kong: the apikey header authenticates as anon when no user JWT is sent.
  if (!headers.authorization && headers.apikey) headers.authorization = `Bearer ${headers.apikey}`;
  const up = http.request({ host: '127.0.0.1', port, path: target, method: req.method, headers }, (r) => {
    res.writeHead(r.statusCode ?? 502, { ...r.headers, ...CORS });
    r.pipe(res);
  });
  up.on('error', () => send(res, 502, { error: 'upstream_unavailable', upstream: stripPrefix }));
  req.pipe(up);
}

async function readBody(req, limit) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > limit) throw Object.assign(new Error('too large'), { status: 413 });
    chunks.push(c);
  }
  return Buffer.concat(chunks);
}

function parseMultipart(body, contentType) {
  const m = /boundary=(?:"([^"]+)"|([^;]+))/.exec(contentType ?? '');
  if (!m) return null;
  const boundary = Buffer.from(`--${m[1] ?? m[2]}`);
  let start = body.indexOf(boundary);
  while (start !== -1) {
    const next = body.indexOf(boundary, start + boundary.length);
    if (next === -1) break;
    const part = body.subarray(start + boundary.length + 2, next - 2);
    const sep = part.indexOf('\r\n\r\n');
    const head = part.subarray(0, sep).toString();
    if (/filename=/i.test(head)) {
      const ct = /content-type:\s*([^\r\n]+)/i.exec(head)?.[1]?.trim() ?? 'application/octet-stream';
      return { contentType: ct, data: part.subarray(sep + 4) };
    }
    start = next;
  }
  return null;
}

// Real file type from magic bytes; the declared Content-Type is not trusted.
function sniff(buf) {
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf.length >= 8 && buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  if (buf.length >= 5 && buf.subarray(0, 5).toString() === '%PDF-') return 'application/pdf';
  if (buf.length >= 12 && buf.subarray(0, 4).toString() === 'RIFF' && buf.subarray(8, 12).toString() === 'WEBP') return 'image/webp';
  if (buf.length >= 12 && buf.subarray(4, 8).toString() === 'ftyp' && /hei|mif|msf/.test(buf.subarray(8, 12).toString())) return 'image/heic';
  return null;
}

async function asUser(claims, fn) {
  const client = await pool.connect();
  try {
    await client.query('begin');
    await client.query("select set_config('request.jwt.claims', $1, true), set_config('request.jwt.claim.sub', $2, true)",
      [JSON.stringify(claims), claims.sub ?? '']);
    await client.query(`set local role ${claims.role === 'service_role' ? 'service_role' : claims.role === 'authenticated' ? 'authenticated' : 'anon'}`);
    const out = await fn(client);
    await client.query('commit');
    return out;
  } catch (e) {
    await client.query('rollback').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

const signedTokens = new Map(); // token -> { bucket, name, exp }

function safeName(name) {
  const clean = path.posix.normalize(name);
  if (clean.startsWith('..') || clean.includes('/../') || path.posix.isAbsolute(clean)) return null;
  return clean;
}

async function storage(req, res) {
  const url = new URL(req.url, 'http://local');
  const p = url.pathname.replace(/^\/storage\/v1/, '');

  // Signed download (no Authorization header; token proves prior authorisation).
  let m = /^\/object\/sign\/([^/]+)\/(.+)$/.exec(p);
  if (m && req.method === 'GET') {
    const entry = signedTokens.get(url.searchParams.get('token') ?? '');
    const name = decodeURIComponent(m[2]);
    if (!entry || entry.exp < Date.now() || entry.bucket !== m[1] || entry.name !== name) {
      return send(res, 400, { statusCode: '400', error: 'InvalidSignature', message: 'Invalid or expired signature' });
    }
    const file = await fs.readFile(path.join(STORAGE_DIR, m[1], name)).catch(() => null);
    return file ? send(res, 200, file, { 'content-type': entry.mime ?? 'application/octet-stream' })
                : send(res, 404, { statusCode: '404', error: 'not_found', message: 'Object not found' });
  }

  const claims = verifyJwt((req.headers.authorization ?? '').replace(/^Bearer\s+/i, ''));
  if (!claims) return send(res, 401, { statusCode: '401', error: 'Unauthorized', message: 'Invalid JWT' });

  try {
    m = /^\/object\/sign\/([^/]+)\/(.+)$/.exec(p);
    if (m && req.method === 'POST') {
      const [bucket, name] = [m[1], decodeURIComponent(m[2])];
      const body = JSON.parse((await readBody(req, 4096)).toString() || '{}');
      const row = await asUser(claims, (c) => c.query('select metadata from storage.objects where bucket_id = $1 and name = $2', [bucket, name]));
      if (row.rowCount === 0) return send(res, 400, { statusCode: '404', error: 'not_found', message: 'Object not found' });
      const token = randomUUID();
      const expiresIn = Math.min(Math.max(Number(body.expiresIn) || 60, 1), 3600);
      signedTokens.set(token, { bucket, name, exp: Date.now() + expiresIn * 1000, mime: row.rows[0].metadata?.mimetype });
      return send(res, 200, { signedURL: `/object/sign/${bucket}/${encodeURI(name)}?token=${token}` });
    }

    m = /^\/object\/(?:authenticated\/)?([^/]+)\/(.+)$/.exec(p);
    if (m && (req.method === 'POST' || req.method === 'PUT')) {
      const bucket = m[1];
      const name = safeName(decodeURIComponent(m[2]));
      if (!name) return send(res, 400, { statusCode: '400', error: 'InvalidKey', message: 'Invalid key' });
      const cfg = (await pool.query('select file_size_limit, allowed_mime_types from storage.buckets where id = $1', [bucket])).rows[0];
      if (!cfg) return send(res, 404, { statusCode: '404', error: 'Bucket not found', message: 'Bucket not found' });
      const raw = await readBody(req, Number(cfg.file_size_limit ?? 50 * 1024 * 1024) + 64 * 1024);
      const part = parseMultipart(raw, req.headers['content-type']) ?? { contentType: req.headers['content-type'], data: raw };
      if (cfg.file_size_limit && part.data.length > Number(cfg.file_size_limit)) {
        return send(res, 413, { statusCode: '413', error: 'Payload too large', message: 'The object exceeded the maximum allowed size' });
      }
      const real = sniff(part.data);
      if (cfg.allowed_mime_types && (!cfg.allowed_mime_types.includes(part.contentType) || real !== part.contentType)) {
        return send(res, 415, { statusCode: '415', error: 'invalid_mime_type', message: `mime type ${part.contentType} is not supported or does not match the file content` });
      }
      const upsert = req.headers['x-upsert'] === 'true';
      await asUser(claims, (c) => c.query(
        `insert into storage.objects (bucket_id, name, owner, metadata) values ($1, $2, $3, $4)
         ${upsert ? 'on conflict (bucket_id, name) do update set metadata = excluded.metadata, updated_at = now()' : ''}`,
        [bucket, name, claims.sub ?? null, { mimetype: real, size: part.data.length }]));
      await fs.mkdir(path.dirname(path.join(STORAGE_DIR, bucket, name)), { recursive: true });
      await fs.writeFile(path.join(STORAGE_DIR, bucket, name), part.data);
      return send(res, 200, { Key: `${bucket}/${name}`, Id: randomUUID() });
    }

    if (m && req.method === 'GET') {
      const [bucket, name] = [m[1], decodeURIComponent(m[2])];
      const row = await asUser(claims, (c) => c.query('select metadata from storage.objects where bucket_id = $1 and name = $2', [bucket, name]));
      if (row.rowCount === 0) return send(res, 400, { statusCode: '404', error: 'not_found', message: 'Object not found' });
      const file = await fs.readFile(path.join(STORAGE_DIR, bucket, name));
      return send(res, 200, file, { 'content-type': row.rows[0].metadata?.mimetype ?? 'application/octet-stream' });
    }

    m = /^\/object\/([^/]+)$/.exec(p);
    if (m && req.method === 'DELETE') {
      const bucket = m[1];
      const { prefixes = [] } = JSON.parse((await readBody(req, 64 * 1024)).toString() || '{}');
      const deleted = await asUser(claims, (c) => c.query(
        'delete from storage.objects where bucket_id = $1 and name = any($2) returning name, id', [bucket, prefixes]));
      for (const r of deleted.rows) await fs.rm(path.join(STORAGE_DIR, bucket, r.name), { force: true });
      return send(res, 200, deleted.rows.map((r) => ({ name: r.name, id: r.id, bucket_id: bucket })));
    }
    return send(res, 404, { statusCode: '404', error: 'not_implemented_locally', message: `${req.method} ${p} is not emulated` });
  } catch (e) {
    if (e.status === 413) return send(res, 413, { statusCode: '413', error: 'Payload too large', message: e.message });
    if (e.code === '42501') return send(res, 403, { statusCode: '403', error: 'Unauthorized', message: 'new row violates row-level security policy' });
    if (e.code === '23505') return send(res, 409, { statusCode: '409', error: 'Duplicate', message: 'The resource already exists' });
    console.error('[storage]', e.message);
    return send(res, 500, { statusCode: '500', error: 'internal', message: 'storage emulation error' });
  }
}

http.createServer((req, res) => {
  if (req.method === 'OPTIONS') return send(res, 204, '');
  if (req.url.startsWith('/auth/v1')) return proxy(req, res, upstream.auth, '/auth/v1');
  if (req.url.startsWith('/rest/v1')) return proxy(req, res, upstream.rest, '/rest/v1');
  if (req.url.startsWith('/functions/v1')) return proxy(req, res, upstream.functions, '/functions/v1');
  if (req.url.startsWith('/storage/v1')) return storage(req, res);
  if (req.url.startsWith('/realtime/v1')) {
    return send(res, 503, { error: 'realtime_not_available_locally', message: 'Realtime is not part of the Docker-less stack; the app falls back to refresh.' });
  }
  if (req.url === '/health') return send(res, 200, { ok: true });
  return send(res, 404, { error: 'not_found' });
}).listen(PORT, '0.0.0.0', () => console.log(`gateway on :${PORT}`));
