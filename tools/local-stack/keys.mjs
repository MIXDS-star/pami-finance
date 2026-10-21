// Prints local anon/service JWTs signed with JWT_SECRET (dev stack only).
import { createHmac } from 'node:crypto';

const secret = process.env.JWT_SECRET;
if (!secret) throw new Error('JWT_SECRET is required');

const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
const sign = (payload) => {
  const head = b64({ alg: 'HS256', typ: 'JWT' });
  const body = b64(payload);
  const sig = createHmac('sha256', secret).update(`${head}.${body}`).digest('base64url');
  return `${head}.${body}.${sig}`;
};

const iat = 1700000000;
const exp = 2000000000;
const anon = sign({ iss: 'supabase-local', role: 'anon', iat, exp });
const service = sign({ iss: 'supabase-local', role: 'service_role', iat, exp });

if (process.argv[2] === '--env') {
  console.log(`export ANON_KEY=${anon}\nexport SERVICE_ROLE_KEY=${service}`);
} else {
  console.log(JSON.stringify({ anon, service }));
}
