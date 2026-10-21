#!/usr/bin/env bash
# Runs every automated test against the Docker-less local stack:
# database (SQL) · Edge Functions (Deno) · Flutter unit/widget · end-to-end (web + Playwright).
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/local-stack/env.sh
eval "$(node tools/local-stack/keys.mjs --env)"
export PATH="/opt/sdk/flutter/bin:$PATH"

echo "== Database"; tools/test-db.sh | tail -1
curl -sf "$PUBLIC_URL/health" >/dev/null || bash tools/local-stack/start.sh >/dev/null
# Recreating the test database can make PostgREST refresh its cache mid-way: reload it explicitly.
sleep 2
psql -X -q -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d nexo -c "notify pgrst, 'reload schema'" >/dev/null
for i in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$PUBLIC_URL/rest/v1/rpc/consume_rate_limit" -H "apikey: $ANON_KEY" \
    -H 'content-type: application/json' -d '{"p_bucket":"probe","p_max":1,"p_window_seconds":1}')
  [[ "$code" != "404" ]] && break   # 401/403 = function found (anon may not call it)
  sleep 0.5
done
echo "== Edge Functions"
LOCAL_STACK=1 SUPABASE_URL="$PUBLIC_URL" SUPABASE_ANON_KEY="$ANON_KEY" "$NEXO_BIN/deno" test -q --allow-net --allow-env \
  --config supabase/functions/deno.json supabase/functions/tests/ > /tmp/nexo-stack/deno-tests.log 2>&1; grep -E "passed|failed" /tmp/nexo-stack/deno-tests.log | tail -1
echo "== Flutter"
(cd app && flutter analyze | tail -1 && flutter test | tail -1)
if [[ "${E2E:-1}" == "1" ]]; then
  echo "== End-to-end"
  (cd app && flutter build web --release --dart-define=SUPABASE_URL="$PUBLIC_URL" --dart-define=SUPABASE_ANON_KEY="$ANON_KEY" \
     --dart-define=REALTIME_ENABLED=false --no-wasm-dry-run >/dev/null)
  curl -sf http://127.0.0.1:8080/ >/dev/null || (nohup python3 -m http.server 8080 -d app/build/web --bind 127.0.0.1 >/dev/null 2>&1 &)
  sleep 1
  (cd tools/e2e && [[ -d node_modules ]] || npm install --silent) && node tools/e2e/e2e.mjs | tail -2
fi
