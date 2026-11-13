#!/usr/bin/env bash
# Starts the Docker-less local stack: Postgres, Supabase Auth, PostgREST,
# Edge Functions (Deno) and the gateway on $PUBLIC_URL.
#   RESET=1 tools/local-stack/start.sh   # also recreate the database
set -euo pipefail
source "$(dirname "$0")/env.sh"
mkdir -p "$STACK_DIR"
eval "$(node "$PAMI_ROOT/tools/local-stack/keys.mjs" --env)"

bash "$PAMI_ROOT/tools/local-stack/start-postgres.sh"
bash "$PAMI_ROOT/tools/local-stack/stop.sh" >/dev/null 2>&1 || true
if [[ "${RESET:-0}" == "1" ]] || ! psql -X -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -lqt | cut -d'|' -f1 | grep -qw "$PAMI_DB"; then
  bash "$PAMI_ROOT/tools/local-stack/reset-db.sh"
fi

start() { # name, command...
  local name=$1; shift
  nohup "$@" >"$STACK_DIR/$name.log" 2>&1 &
  echo $! >"$STACK_DIR/$name.pid"
}

GOTRUE_DB_DRIVER=postgres \
DATABASE_URL="postgres://supabase_auth_admin:postgres@${PGHOST}:${PGPORT}/${PAMI_DB}" \
GOTRUE_API_HOST=127.0.0.1 PORT="$AUTH_PORT" \
API_EXTERNAL_URL="$PUBLIC_URL/auth/v1" GOTRUE_SITE_URL="${SITE_URL:-http://localhost:8080}" \
GOTRUE_URI_ALLOW_LIST="co.pamifinance://auth-callback,http://localhost:*,http://127.0.0.1:*" \
GOTRUE_JWT_SECRET="$JWT_SECRET" GOTRUE_JWT_EXP=3600 GOTRUE_JWT_AUD=authenticated \
GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated GOTRUE_JWT_ADMIN_ROLES=service_role \
GOTRUE_EXTERNAL_EMAIL_ENABLED=true GOTRUE_MAILER_AUTOCONFIRM="${MAILER_AUTOCONFIRM:-true}" \
GOTRUE_PASSWORD_MIN_LENGTH=8 GOTRUE_LOG_LEVEL=warn \
GOTRUE_RATE_LIMIT_EMAIL_SENT=1000 GOTRUE_RATE_LIMIT_TOKEN_REFRESH=1000 GOTRUE_RATE_LIMIT_VERIFY=1000 \
  start auth "$PAMI_BIN/auth"

cat >"$STACK_DIR/postgrest.conf" <<CONF
db-uri = "postgres://authenticator:postgres@${PGHOST}:${PGPORT}/${PAMI_DB}"
db-schemas = "public"
db-anon-role = "anon"
jwt-secret = "${JWT_SECRET}"
server-host = "127.0.0.1"
server-port = ${REST_PORT}
db-max-rows = 1000
CONF
start rest "$PAMI_BIN/postgrest" "$STACK_DIR/postgrest.conf"

SUPABASE_URL="$PUBLIC_URL" SUPABASE_ANON_KEY="$ANON_KEY" SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" \
FUNCTIONS_PORT="$FUNCTIONS_PORT" \
  start functions "$PAMI_BIN/deno" run --allow-net --allow-env --allow-read \
    --config "$PAMI_ROOT/supabase/functions/deno.json" "$PAMI_ROOT/tools/local-stack/functions-server.ts"

start gateway node "$PAMI_ROOT/tools/local-stack/gateway.mjs"

for i in $(seq 1 60); do
  if curl -sf "$PUBLIC_URL/health" >/dev/null && curl -sf "$PUBLIC_URL/auth/v1/health" >/dev/null \
     && curl -sf -H "apikey: $ANON_KEY" "$PUBLIC_URL/rest/v1/" >/dev/null \
     && curl -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL/functions/v1/ai-status" | grep -q 401; then
    echo "stack ready on $PUBLIC_URL"
    echo "SUPABASE_URL=$PUBLIC_URL"
    echo "SUPABASE_ANON_KEY=$ANON_KEY"
    exit 0
  fi
  sleep 1
done
echo "stack failed to start; logs in $STACK_DIR" >&2
tail -n 5 "$STACK_DIR"/*.log >&2
exit 1
