#!/usr/bin/env bash
# Starts (initialising if needed) a local PostgreSQL 16 cluster for the stack.
set -euo pipefail
source "$(dirname "$0")/env.sh"

if [[ ! -f "$PGDATA_DIR/PG_VERSION" ]]; then
  mkdir -p "$PGDATA_DIR" && chown postgres:postgres "$PGDATA_DIR"
  su postgres -c "$PGBIN/initdb -D $PGDATA_DIR -A trust -U postgres" >/dev/null
  # Logical WAL so a future local Realtime server can subscribe.
  echo "wal_level = logical" >> "$PGDATA_DIR/postgresql.conf"
fi
if ! su postgres -c "$PGBIN/pg_ctl -D $PGDATA_DIR status" >/dev/null 2>&1; then
  su postgres -c "$PGBIN/pg_ctl -D $PGDATA_DIR -l $PGDATA_DIR/log -o '-p $PGPORT -k /tmp' -w start" >/dev/null
fi
echo "postgres listening on $PGHOST:$PGPORT"
