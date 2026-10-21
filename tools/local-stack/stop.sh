#!/usr/bin/env bash
# Stops the local stack processes (Postgres keeps running).
source "$(dirname "$0")/env.sh"
for f in "$STACK_DIR"/*.pid; do
  [[ -f "$f" ]] || continue
  kill "$(cat "$f")" 2>/dev/null || true
  rm -f "$f"
done
echo "stack stopped"
