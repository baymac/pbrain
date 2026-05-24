#!/usr/bin/env bash
# Basic gbrain dashboard:
#  - Stuck processes (sync/query running > 5 min)
#  - Recent sync runs + duration
#  - Summary stats (p50, p95, fail rate)
#  - launchd status
#  - Brain stats (if not locked)
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_DIR="${VAULT_DIR:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault}"
LOG_FILE="$REPO_DIR/.logs/sync-runs.jsonl"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }

bold "=== gbrain dashboard ==="
echo

# 0. Upgrade status (banner if available)
UPGRADE_STATUS_FILE="$REPO_DIR/.logs/upgrade-status.json"
if [[ -f "$UPGRADE_STATUS_FILE" ]]; then
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
hint = d.get("upgrade_hint", "")
current = d.get("current_version", "?")
if d.get("update_available") and hint:
    print(f"\033[1;33m⬆ Upgrade available:  {hint}\033[0m")
    print(f"   Run:  bash scripts/gbrain-upgrade.sh")
    print(f"   (checked {d.get(\"checked_at\", \"\")})")
else:
    print(f"\033[32m✓ gbrain {current} — up to date\033[0m  (checked {d.get(\"checked_at\", \"\")})")
print()
' "$UPGRADE_STATUS_FILE"
fi

# 1. Stuck processes
bold "## Stuck processes (> 5 min)"
ps -eo pid,etime,command | awk '
  /gbrain (sync|query|extract|embed|think)/ && !/awk|grep/ {
    n = split($2, t, /[-:]/)
    if (n == 4) secs = (t[1]*86400 + t[2]*3600 + t[3]*60 + t[4])
    else if (n == 3) secs = (t[1]*3600 + t[2]*60 + t[3])
    else secs = (t[1]*60 + t[2])
    if (secs > 300) {
      cmd = ""
      for (i = 3; i <= NF; i++) cmd = cmd " " $i
      print "  PID " $1 " up " $2 ":" cmd
    }
  }
' > /tmp/.gbrain-stuck
if [[ -s /tmp/.gbrain-stuck ]]; then
  cat /tmp/.gbrain-stuck
  echo
  echo "  → kill with:  kill $(awk '{print $2}' /tmp/.gbrain-stuck | tr '\n' ' ')"
else
  echo "  (none)"
fi
rm -f /tmp/.gbrain-stuck
echo

# 2. Last 10 sync runs
bold "## Last 10 sync runs"
if [[ -f "$LOG_FILE" && -s "$LOG_FILE" ]]; then
  tail -10 "$LOG_FILE" | python3 -c '
import sys, json
from datetime import datetime, timezone
for line in sys.stdin:
    try:
        r = json.loads(line)
    except Exception:
        continue
    code = r["exit_code"]
    mark = "ok " if code == 0 else ("skip" if code == -1 else "ERR ")
    note = r.get("note", "")
    extra = "  [" + note + "]" if note and note != "ok" else ""
    # Convert UTC ISO string to local human-readable
    try:
        dt = datetime.strptime(r["start"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        ts = dt.astimezone().strftime("%b %d %I:%M:%S %p")
    except Exception:
        ts = r["start"]
    print("  {0}  {1}  {2:>4}s{3}".format(mark, ts, r["duration_sec"], extra))
'
else
  echo "  (no runs logged yet)"
fi
echo

# 3. Summary stats
bold "## Summary (last 50 runs)"
if [[ -f "$LOG_FILE" && -s "$LOG_FILE" ]]; then
  tail -50 "$LOG_FILE" | python3 -c '
import sys, json
runs = []
for line in sys.stdin:
    try:
        runs.append(json.loads(line))
    except Exception:
        pass
if not runs:
    print("  no runs")
else:
    durations = sorted(r["duration_sec"] for r in runs if r["exit_code"] == 0)
    fails = sum(1 for r in runs if r["exit_code"] > 0)
    skips = sum(1 for r in runs if r["exit_code"] == -1)
    n = len(durations)
    if n == 0:
        print("  no successful runs ({0} failures, {1} skipped)".format(fails, skips))
    else:
        p50 = durations[n // 2]
        p95 = durations[int(n * 0.95)] if n > 1 else durations[0]
        print("  successful: {0}    failed: {1}    skipped (lock): {2}".format(n, fails, skips))
        print("  p50: {0}s    p95: {1}s    max: {2}s".format(p50, p95, max(durations)))
'
else
  echo "  (no log)"
fi
echo

# 4. launchd status
bold "## launchd"
launchctl list | grep pbrain || echo "  (not loaded)"
echo

# 5. Brain stats
bold "## Brain"
cd "$VAULT_DIR" 2>/dev/null
if pgrep -f "gbrain sync" >/dev/null 2>&1; then
  echo "  (sync in progress — brain may be locked)"
else
  gbrain stats 2>&1 | head -8 || echo "  (gbrain stats failed — possible lock)"
fi
echo

bold "## Files"
echo "  timing log:   $LOG_FILE"
echo "  raw sync log: ~/Library/Logs/pbrain/sync.log"
echo "  error log:    ~/Library/Logs/pbrain/sync.error.log"
