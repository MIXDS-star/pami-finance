#!/usr/bin/env bash
# Recreates the local database: Supabase-like bootstrap -> Auth migrations ->
# Pami migrations. Equivalent to `supabase db reset` on a Docker-less machine.
set -euo pipefail
source "$(dirname "$0")/env.sh"

PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER")

"${PSQL[@]}" -d postgres -c "drop database if exists ${PAMI_DB} with (force)" >/dev/null
"${PSQL[@]}" -d postgres -c "create database ${PAMI_DB}" >/dev/null
"${PSQL[@]}" -d "$PAMI_DB" -f "$PAMI_ROOT/tools/local-stack/bootstrap.sql" >/dev/null

# Supabase Auth owns the `auth` schema and runs its own migrations.
GOTRUE_DB_DRIVER=postgres \
DATABASE_URL="postgres://supabase_auth_admin:postgres@${PGHOST}:${PGPORT}/${PAMI_DB}" \
GOTRUE_JWT_SECRET="$JWT_SECRET" API_EXTERNAL_URL="$PUBLIC_URL/auth/v1" GOTRUE_SITE_URL="$PUBLIC_URL" \
GOTRUE_LOG_LEVEL=error "$PAMI_BIN/auth" migrate >/dev/null 2>&1 \
  || (cd "$PAMI_BIN" && GOTRUE_DB_DRIVER=postgres \
      DATABASE_URL="postgres://supabase_auth_admin:postgres@${PGHOST}:${PGPORT}/${PAMI_DB}" \
      GOTRUE_JWT_SECRET="$JWT_SECRET" API_EXTERNAL_URL="$PUBLIC_URL/auth/v1" GOTRUE_SITE_URL="$PUBLIC_URL" \
      ./auth migrate)

for f in "$PAMI_ROOT"/supabase/migrations/*.sql; do
  "${PSQL[@]}" -d "$PAMI_DB" -f "$f" >/dev/null
done

if [[ "${WITH_SEED:-0}" == "1" && -f "$PAMI_ROOT/supabase/seed.sql" ]]; then
  "${PSQL[@]}" -d "$PAMI_DB" -f "$PAMI_ROOT/supabase/seed.sql" >/dev/null
fi
echo "database ${PAMI_DB} ready ($(ls "$PAMI_ROOT"/supabase/migrations/*.sql | wc -l) migrations)"
