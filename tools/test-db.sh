#!/usr/bin/env bash
# Runs the database test-suite (supabase/tests/*.sql) against a fresh local DB.
set -uo pipefail
source "$(dirname "$0")/local-stack/env.sh"

if [[ "${SKIP_RESET:-0}" != "1" ]]; then
  bash "$NEXO_ROOT/tools/local-stack/reset-db.sh" >/dev/null || exit 1
fi
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$NEXO_DB")
"${PSQL[@]}" -f "$NEXO_ROOT/supabase/tests/_helpers.sql" >/dev/null || exit 1

pass=0; fail=0
for f in "$NEXO_ROOT"/supabase/tests/[0-9]*.sql; do
  name=$(basename "$f")
  out=$("${PSQL[@]}" -f "$f" 2>&1)
  if [[ $? -eq 0 ]]; then
    n=$(grep -c "ok - " <<<"$out")
    pass=$((pass + n))
    echo "PASS $name ($n assertions)"
    [[ "${VERBOSE:-0}" == "1" ]] && grep -o "ok - .*" <<<"$out" | sed 's/^/     /'
  else
    fail=$((fail + 1))
    echo "FAIL $name"
    grep -E "ERROR|FAIL" <<<"$out" | head -5 | sed 's/^/     /'
  fi
done
echo "----"
echo "assertions passed: $pass, failing files: $fail"
[[ $fail -eq 0 ]]
