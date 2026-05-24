#!/usr/bin/env bash
# Wraps gbrain sync with:
#  - lockfile (skips run if previous sync still alive — prevents zombie syncs)
#  - JSONL timing log per run for the dashboard
#  - serve-safe sync via 'gbrain call' (proxies through MCP, no PGLite lock contention)
#  - binary pre-staging when 'gbrain serve' is up; full upgrade only when serve is down
#
# Expects $VAULT_DIR env var, otherwise defaults to the Obsidian iCloud container.
#
# WHY 'gbrain call' INSTEAD OF 'gbrain sync':
#   PGLite is an embedded Postgres — single-writer, OS file lock on
#   ~/.gbrain/brain.pglite/. The Claude MCP process ('gbrain serve') holds
#   that lock for its entire lifetime. A direct 'gbrain sync' CLI invocation
#   opens its own DB connection and hangs forever waiting for the lock.
#   'gbrain call sync_brain' instead proxies the request via stdio MCP to
#   the running serve, which executes in-process. No second connection,
#   no lock conflict. Works whether or not Claude/MCP is up.
#
# WHY UPGRADE IS SPLIT:
#   'gbrain upgrade' = git pull on the source clone + bun install + restart.
#   The DB-migration side already happens automatically through MCP usage.
#   The binary swap can't take effect while serve is running (Bun can't
#   hot-swap a loaded binary). So when serve is up we only PRE-STAGE the
#   new source (git pull); the next Claude restart picks it up. When serve
#   is down we run the full upgrade.
#
# See docs/gbrain-sync.md for the full architecture + Postgres migration path.
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

[[ -d "$VAULT_DIR" ]] || { log_run -1 "vault dir not found"; exit 1; }

# Upgrade strategy (non-fatal in all branches):
#   serve UP   → pre-stage new binary only (git pull on source clone). Takes
#                effect at next Claude restart. Schema migrations run
#                automatically via MCP when serve sees them.
#   serve DOWN → run the full upgrade (git pull + bun install + migrations).
if pgrep -f "gbrain serve" >/dev/null 2>&1; then
  if [[ -d "$HOME/code/gbrain/.git" ]]; then
    (cd "$HOME/code/gbrain" && git pull --quiet --ff-only) >/dev/null 2>&1 || true
  fi
else
  (gbrain check-update && gbrain upgrade) >/dev/null 2>&1 || true
fi

# Sync via 'gbrain call' which routes through the running gbrain serve (if any)
# via in-process IPC, avoiding PGLite single-writer lock contention. Works
# whether or not Claude/MCP is open.
sync_output=$(gbrain call sync_brain "{\"repo\":\"$VAULT_DIR\"}" 2>&1)
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
  # Extract a short summary from the JSON tail for the log note
  note=$(echo "$sync_output" | python3 -c "
import sys, json, re
text = sys.stdin.read()
m = re.search(r'\{.*\}', text, re.DOTALL)
if m:
    d = json.loads(m.group(0))
    print(f\"{d.get('status','?')} +{d.get('added',0)} ~{d.get('modified',0)} -{d.get('deleted',0)} R{d.get('renamed',0)}\")
else:
    print('ok (no json)')
" 2>/dev/null || echo "ok")
else
  note="error: $(echo "$sync_output" | tail -1 | tr -d '\"' | cut -c1-120)"
fi

log_run "$exit_code" "$note"

# --- Update upgrade-status.json for the dashboard ---
# Checks the release feed AND whether the source clone has unpulled commits.
# Cheap to run; non-fatal if the check fails. The dashboard reads this file
# and surfaces "Upgrade available: X -> Y" so the user knows to run the
# upgrade script.
UPGRADE_STATUS_FILE="$LOG_DIR/upgrade-status.json"
GBRAIN_SRC="${GBRAIN_SRC:-$HOME/code/gbrain}"

current_v="$(gbrain --version 2>/dev/null | head -1 | awk '{print $2}' || echo unknown)"
check_json="$(gbrain check-update --json 2>/dev/null || echo '{}')"

src_ahead="false"
src_diff=""
if [[ -d "$GBRAIN_SRC/.git" ]]; then
  if (cd "$GBRAIN_SRC" && git fetch --quiet origin) 2>/dev/null; then
    src_diff="$(cd "$GBRAIN_SRC" && git log HEAD..origin/HEAD --oneline 2>/dev/null | head -1)"
    [[ -n "$src_diff" ]] && src_ahead="true"
  fi
fi

python3 - "$UPGRADE_STATUS_FILE" "$current_v" "$src_ahead" "$src_diff" "$check_json" <<'PYEOF' || true
import sys, json
from datetime import datetime, timezone

out_path, current, src_ahead, src_diff, check_json_str = sys.argv[1:6]
try:
    chk = json.loads(check_json_str or '{}')
except Exception:
    chk = {}

latest = chk.get('latest_version') or ''
feed_update = bool(chk.get('update_available'))
ahead = src_ahead == 'true'

if feed_update and latest:
    hint = f"{current} -> {latest}"
elif ahead:
    hint = f"{current} -> source ahead ({src_diff[:60]})"
else:
    hint = ""

data = {
    "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "current_version": current,
    "latest_version": latest,
    "update_available": feed_update or ahead,
    "source_ahead": ahead,
    "source_ahead_diff": src_diff,
    "upgrade_hint": hint,
}
with open(out_path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

exit "$exit_code"
