#!/usr/bin/env bash
# Wraps gbrain sync with:
#  - lockfile (skips run if previous sync still alive — prevents zombie syncs)
#  - JSONL timing log per run for the dashboard
#  - auto-upgrade attempt before each sync
#
# Expects $VAULT_DIR env var, otherwise defaults to the Obsidian iCloud container.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_DIR="${VAULT_DIR:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault}"
LOG_DIR="$REPO_DIR/.logs"
LOG_FILE="$LOG_DIR/sync-runs.jsonl"
LOCK_FILE="$LOG_DIR/sync.lock"
mkdir -p "$LOG_DIR"

start_ts=$(date -u +%s)
start_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

log_run() {
  local exit_code="$1"
  local note="$2"
  local end_ts duration
  end_ts=$(date -u +%s)
  duration=$((end_ts - start_ts))
  printf '{"start":"%s","duration_sec":%d,"exit_code":%d,"note":"%s"}\n' \
    "$start_iso" "$duration" "$exit_code" "$note" >> "$LOG_FILE"
}

# Lock check — skip if prior run still alive
if [[ -f "$LOCK_FILE" ]]; then
  lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    log_run -1 "skipped: prior sync PID $lock_pid still running"
    exit 0
  fi
  rm -f "$LOCK_FILE"
fi

echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

cd "$VAULT_DIR" || { log_run -1 "vault dir not found"; exit 1; }

# Auto-upgrade attempt (non-fatal)
(gbrain check-update && gbrain upgrade) >/dev/null 2>&1 || true

# The actual sync
gbrain sync --repo . --skip-failed
exit_code=$?

log_run "$exit_code" "ok"
exit "$exit_code"
