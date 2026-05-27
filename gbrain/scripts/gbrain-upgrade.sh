#!/usr/bin/env bash
# gbrain-upgrade.sh — orchestrate a safe gbrain upgrade.
#
# Two cases:
#   1. gbrain serve is DOWN (Claude closed):
#        → run the full upgrade in one shot (git pull + bun install + migrations).
#        → next invocation gets the new binary.
#
#   2. gbrain serve is UP (Claude open):
#        → pre-stage the new source (git pull on ~/code/gbrain).
#        → DB migrations apply automatically through MCP usage.
#        → binary swap cannot happen until the user restarts Claude — print a
#          one-line action item and exit cleanly.
#
# This is intentionally safe to run from a scheduled job or interactively.
# Exits 0 in all expected cases; non-zero only on actual failure (git pull
# failed, gbrain upgrade crashed, etc.).

set -uo pipefail

GBRAIN_SRC="${GBRAIN_SRC:-$HOME/code/gbrain}"

log()  { printf '\033[36m[upgrade]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[upgrade]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[upgrade]\033[0m %s\n' "$*" >&2; }

current_version() {
  gbrain --version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown"
}

CURRENT="$(current_version)"
log "Current version: $CURRENT"

# --- 1. Check for updates ---
CHECK_JSON="$(gbrain check-update --json 2>/dev/null || echo '{}')"
UPDATE_AVAILABLE="$(echo "$CHECK_JSON" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read() or '{}')
    print('true' if d.get('update_available') else 'false')
except Exception:
    print('false')
")"
LATEST="$(echo "$CHECK_JSON" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read() or '{}')
    print(d.get('latest_version') or '(unknown)')
except Exception:
    print('(unknown)')
")"

# Also check if the source clone is ahead of installed (covers bun-link installs
# where the release feed lags behind the actual git source).
SRC_AHEAD="false"
if [[ -d "$GBRAIN_SRC/.git" ]]; then
  if (cd "$GBRAIN_SRC" && git fetch --quiet origin) 2>/dev/null; then
    if [[ -n "$(cd "$GBRAIN_SRC" && git log HEAD..origin/HEAD --oneline 2>/dev/null | head -1)" ]]; then
      SRC_AHEAD="true"
    fi
  fi
fi

if [[ "$UPDATE_AVAILABLE" != "true" && "$SRC_AHEAD" != "true" ]]; then
  log "No upgrade available. Already on latest ($CURRENT)."
  exit 0
fi

if [[ "$UPDATE_AVAILABLE" == "true" ]]; then
  log "Release feed reports update: $CURRENT → $LATEST"
fi
if [[ "$SRC_AHEAD" == "true" ]]; then
  log "Source clone ($GBRAIN_SRC) has unmerged commits on origin."
fi

# --- 2. Branch on serve state ---
if pgrep -f "gbrain serve" >/dev/null 2>&1; then
  SERVE_PIDS="$(pgrep -f "gbrain serve" | tr '\n' ' ')"
  log "gbrain serve is running (PID(s): $SERVE_PIDS) — pre-staging only."

  # Pre-stage: git pull on the source clone. Safe while serve is up.
  if [[ -d "$GBRAIN_SRC/.git" ]]; then
    log "Pulling new source into $GBRAIN_SRC ..."
    if ! (cd "$GBRAIN_SRC" && git pull --ff-only --quiet); then
      err "git pull failed in $GBRAIN_SRC. Resolve manually."
      exit 1
    fi
    log "✓ Source pre-staged."
  else
    warn "No git clone at $GBRAIN_SRC — cannot pre-stage binary."
  fi

  cat <<EOF

╭─ Upgrade pre-staged ─────────────────────────────────╮
│ ✓ New source pulled into $GBRAIN_SRC
│ ✓ DB migrations will apply automatically via MCP
│ ⚠ Binary swap needs gbrain serve to restart
│
│ ACTION: restart Claude Code at your convenience.
│ The next session will spawn a fresh gbrain serve
│ on the new version. Your data is safe; nothing
│ else to do.
╰──────────────────────────────────────────────────────╯

EOF
  exit 0
fi

# --- 3. Serve is down — run the full upgrade ---
log "gbrain serve is not running — running full upgrade."

if ! gbrain upgrade; then
  err "gbrain upgrade failed. Inspect output above."
  exit 1
fi

NEW="$(current_version)"
log "✓ Upgrade complete. $CURRENT → $NEW"
exit 0
