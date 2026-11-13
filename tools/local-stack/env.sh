# Local development stack settings. DEV ONLY — these values are public and
# must never be used for a real project (see docs/DEPLOYMENT.md).
export PAMI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PAMI_BIN="${PAMI_BIN:-/opt/sdk/bin}"
export PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
export PGDATA_DIR="${PGDATA_DIR:-/opt/pgdata}"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-54322}"
export PGUSER="${PGUSER:-postgres}"
export PAMI_DB="${PAMI_DB:-pami}"
export STACK_DIR="${STACK_DIR:-/tmp/pami-stack}"

export JWT_SECRET="${JWT_SECRET:-super-secret-jwt-token-with-at-least-32-characters-long}"
export GATEWAY_PORT="${GATEWAY_PORT:-54321}"
export AUTH_PORT="${AUTH_PORT:-9999}"
export REST_PORT="${REST_PORT:-3001}"
export FUNCTIONS_PORT="${FUNCTIONS_PORT:-54329}"
export PUBLIC_URL="${PUBLIC_URL:-http://127.0.0.1:${GATEWAY_PORT}}"
