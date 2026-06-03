#!/usr/bin/env bash
# pbrain habits helper — sourced by lib/vault.sh (after profile.sh and db.sh).
#
# Two-layer design, mirroring how goals/diet/fitness already split definition
# from data:
#   - The habits PROFILE (which habits to track, their kind / priority / cap)
#     is a vault markdown note carrying its structured data in a fenced ```json
#     block — same discipline as the goals profile, so pbrain_profile_json reads
#     it and it stays browsable/editable in Obsidian.
#   - The habit EVENT LOG lives in the shared SQLite DB (lib/db.sh), so weekly /
#     monthly counts and cap checks are a cheap query.
#
# This file bridges the two and provides the ride-along extraction emitter that
# the journaling commands call so habits get logged from ordinary sessions.
#
# Defines:
#   pbrain_habits_profile_file        echo resolved Habits Profile.md path
#   pbrain_habits_json                echo the profile JSON (or empty if none)
#   pbrain_habits_cmd                 echo abs path to commands/habits.sh
#   pbrain_habits_rollup [today]      text rollup: week/month counts vs caps per habit
#   pbrain_emit_habits_extract <cmd>  ride-along: tell Claude to log evidenced habits (silent if no profile)
#
# Resolution:
#   PBRAIN_HABITS_PROFILE_FILE  override (default $VAULT_DIR/life/Habits Profile.md)
#
# Never exits non-zero. Assumes lib/vault.sh has set VAULT_DIR and sourced
# profile.sh + db.sh first.

pbrain_habits_profile_file() {
  printf '%s\n' "${PBRAIN_HABITS_PROFILE_FILE:-${VAULT_DIR:-$HOME}/life/Habits Profile.md}"
}

pbrain_habits_json() {
  local f
  f="$(pbrain_habits_profile_file)"
  [[ -f "$f" ]] || return 0
  # pbrain_profile_json is defined in lib/profile.sh (sourced before this file).
  if declare -f pbrain_profile_json >/dev/null 2>&1; then
    pbrain_profile_json "$f"
  fi
  return 0
}

# Absolute path to the /habits command script (sibling of this lib dir).
pbrain_habits_cmd() {
  local lib_dir repo_dir
  lib_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  repo_dir="$(cd -P -- "$lib_dir/.." && pwd -P)"
  printf '%s\n' "$repo_dir/commands/habits.sh"
}

# Text rollup of every tracked habit: this-week and this-month counts against
# the configured cap, last-done date, and an over/under flag. ISO week (Mon–Sun)
# contains today; month is the calendar month. Prints nothing if there's no
# profile (caller treats empty as "habit tracking not set up").
pbrain_habits_rollup() {
  command -v python3 >/dev/null 2>&1 || return 0
  local today profile db
  today="${1:-$(date +%Y-%m-%d)}"
  profile="$(pbrain_habits_profile_file)"
  db="$PBRAIN_DB_FILE"
  [[ -f "$profile" ]] || return 0
  python3 - "$profile" "$db" "$today" <<'PYEOF' 2>/dev/null || true
import json, re, sys, sqlite3, datetime
profile, db, today_s = sys.argv[1], sys.argv[2], sys.argv[3]

# --- pull habit definitions out of the profile's fenced json block ---
try:
    with open(profile) as fh:
        text = fh.read()
except Exception:
    sys.exit(0)
m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
raw = m.group(1).strip() if m else text.strip()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
habits = data.get("habits") or []
if not habits:
    sys.exit(0)

today = datetime.date.fromisoformat(today_s)
week_start = today - datetime.timedelta(days=today.weekday())   # Monday
week_end = week_start + datetime.timedelta(days=6)
month_start = today.replace(day=1)

def count_between(con, habit, start, end):
    row = con.execute(
        "SELECT COALESCE(SUM(count),0) FROM habit_events "
        "WHERE habit=? AND occurred_on>=? AND occurred_on<=?",
        (habit, start.isoformat(), end.isoformat()),
    ).fetchone()
    return row[0] if row else 0

def last_done(con, habit):
    row = con.execute(
        "SELECT MAX(occurred_on) FROM habit_events WHERE habit=?", (habit,)
    ).fetchone()
    return row[0] if row and row[0] else None

con = None
try:
    import os
    if os.path.exists(db):
        con = sqlite3.connect(db, timeout=5)
        con.execute("PRAGMA busy_timeout=5000")
except Exception:
    con = None

lines = []
for h in habits:
    name = str(h.get("name", "")).strip()
    if not name:
        continue
    kind = str(h.get("kind", "build")).lower()
    prio = str(h.get("priority", "medium")).lower()
    # Normalise the cap period to exactly week|month so a typo'd value
    # ("weekly", "wk", "") doesn't silently bucket as month. Only an explicit
    # month/monthly counts as month; everything else defaults to week.
    period = "month" if str(h.get("cap_period", "week")).lower().startswith("month") else "week"
    cap = h.get("cap_count")
    if con is not None:
        wk = count_between(con, name, week_start, week_end)
        mo = count_between(con, name, month_start, today)
        last = last_done(con, name)
    else:
        wk = mo = 0
        last = None
    used = wk if period == "week" else mo
    label = "max" if kind == "limit" else "target"
    cap_txt = f"{label} {cap}/{period}" if cap not in (None, "") else "no cap"
    # status flag
    flag = ""
    try:
        capn = float(cap) if cap not in (None, "") else None
    except (TypeError, ValueError):
        capn = None
    if capn is not None:
        if kind == "limit":
            if used > capn:
                flag = " — OVER cap ⚠️"
            elif used == capn:
                flag = " — at cap"
        else:  # build
            if used >= capn:
                flag = " — target met ✅"
            elif period == "week" and used == 0 and prio == "high":
                flag = " — nothing logged this week ⚠️"
    last_txt = f"last {last}" if last else "never logged"
    lines.append(
        f"- {name} ({kind}, {prio}, {cap_txt}): {wk} this week, {mo} this month, {last_txt}{flag}"
    )

if con is not None:
    con.close()
if lines:
    print("\n".join(lines))
PYEOF
}

# Ride-along emitter: when a habits profile exists, append a compact block at
# the end of a command's output telling Claude to log any habits the user
# actually evidenced this session via the /habits log subcommand. Silent when no
# profile exists (so it costs nothing until the user opts into habit tracking —
# setup is only nudged by /habits, /plan-my-day, and /end-of-day).
pbrain_emit_habits_extract() {
  local cmd json names today cmd_path
  cmd="${1:-}"
  [[ -n "$cmd" ]] || return 0
  json="$(pbrain_habits_json)"
  [[ -n "${json//[[:space:]]/}" ]] || return 0

  names="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
out = []
for h in data.get("habits") or []:
    n = str(h.get("name", "")).strip()
    if not n:
        continue
    kind = str(h.get("kind", "build")).strip().lower()
    out.append(f"{n} [{kind}]")
print(" | ".join(out))
' 2>/dev/null || true)"
  [[ -n "$names" ]] || return 0

  today="$(date +%Y-%m-%d)"
  cmd_path="$(pbrain_habits_cmd)"

  printf '%s\n' ""
  printf '%s\n' "--- HABIT EXTRACTION ($cmd) ---"
  printf '%s\n' "Run this AFTER the command's main work, silently. Tracked habits:"
  printf '%s\n' "  $names"
  printf '%s\n' ""
  printf '%s\n' "If — and only if — the user evidenced any of these habits this session"
  printf '%s\n' "(did it, is about to, or explicitly skipped it), log each ONE TIME with:"
  printf '%s\n' "  bash \"$cmd_path\" log --name \"<exact habit name>\" --date $today --source $cmd [--count N] [--note \"...\"]"
  printf '%s\n' "Match the user's words to a habit name above; don't invent or infer habits"
  printf '%s\n' "they didn't actually mention. Logging is idempotent (one row per habit per"
  printf '%s\n' "day), so re-running is safe and won't double-count. If nothing was evidenced,"
  printf '%s\n' "do nothing and stay silent."
  printf '%s\n' "Surface at most one short line summarising what you logged (or nothing)."
  printf '%s\n' "--- END HABIT EXTRACTION ---"
  return 0
}
