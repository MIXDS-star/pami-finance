#!/usr/bin/env bash
# Recreates the local database: Supabase-like bootstrap -> Auth migrations ->
# NEXO migrations. Equivalent to `supabase db reset` on a Docker-less machine.
set -euo pipefail
source "$(dirname "$0")/env.sh"

PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER")

"${PSQL[@]}" -d postgres -c "drop database if exists ${NEXO_DB} with (force)" >/dev/null
"${PSQL[@]}" -d postgres -c "create database ${NEXO_DB}" >/dev/null
"${PSQL[@]}" -d "$NEXO_DB" -f "$NEXO_ROOT/tools/local-stack/bootstrap.sql" >/dev/null

# Supabase Auth owns the `auth` schema and runs its own migrations.
GOTRUE_DB_DRIVER=postgres \
DATABASE_URL="postgres://supabase_auth_admin:postgres@${PGHOST}:${PGPORT}/${NEXO_DB}" \
GOTRUE_JWT_SECRET="$JWT_SECRET" API_EXTERNAL_URL="$PUBLIC_URL/auth/v1" GOTRUE_SITE_URL="$PUBLIC_URL" \
GOTRUE_LOG_LEVEL=error "$NEXO_BIN/auth" migrate >/dev/null 2>&1 \
  || (cd "$NEXO_BIN" && GOTRUE_DB_DRIVER=postgres \
      DATABASE_URL="postgres://supabase_auth_admin:postgres@${PGHOST}:${PGPORT}/${NEXO_DB}" \
      GOTRUE_JWT_SECRET="$JWT_SECRET" API_EXTERNAL_URL="$PUBLIC_URL/auth/v1" GOTRUE_SITE_URL="$PUBLIC_URL" \
      ./auth migrate)

for f in "$NEXO_ROOT"/supabase/migrations/*.sql; do
  "${PSQL[@]}" -d "$NEXO_DB" -f "$f" >/dev/null
done

if [[ "${WITH_SEED:-0}" == "1" && -f "$NEXO_ROOT/supabase/seed.sql" ]]; then
  "${PSQL[@]}" -d "$NEXO_DB" -f "$NEXO_ROOT/supabase/seed.sql" >/dev/null
fi
echo "database ${NEXO_DB} ready ($(ls "$NEXO_ROOT"/supabase/migrations/*.sql | wc -l) migrations)"
