#!/usr/bin/env bash
set -euo pipefail

# habits.sh — habit tracking.
#
# First run interviews the user to build a habits PROFILE (which habits to
# track, each with a kind [build/limit], a priority [low/medium/high], and a cap
# [max/target N times per week or month]). The profile is a vault markdown note
# carrying its data in a fenced ```json block — same shape discipline as the
# goals profile, browsable in Obsidian.
#
# Every subsequent run shows a dashboard: this-week / this-month counts vs caps,
# what's lagging, what's over. Events are logged into the shared SQLite DB
# (lib/db.sh) — both from /habits directly and, via the ride-along extraction
# emitter, from ordinary journaling commands.
#
# Subcommands:
#   habits.sh                              first run → setup; else → dashboard
#   habits.sh log --name "X" --date YYYY-MM-DD [--count N] [--source cmd] [--note "..."]
#   habits.sh rollup [--date YYYY-MM-DD]   text rollup (week/month vs caps)
#   habits.sh list                         list configured habits
#
# Default profile:  $VAULT_DIR/life/Habits Profile.md
# Event log:        shared SQLite DB (~/.config/pbrain/pbrain.db)
# Overrides:
#   PBRAIN_VAULT                  — vault root
#   PBRAIN_HABITS_PROFILE_FILE    — habits profile markdown path
#   PBRAIN_DB_FILE                — SQLite DB path

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

pbrain_emit_prefs "habits" || true
pbrain_db_init || true

PROFILE_FILE="$(pbrain_habits_profile_file)"
TODAY="$(date +%Y-%m-%d)"
SUB="${1:-}"

# ---------------------------------------------------------------------------
# log — append/update a habit event. Used by Claude (via the extraction emitter)
# and callable directly. Idempotent per (habit, day): re-logging updates the row.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "log" ]]; then
  shift || true
  H_NAME=""; H_DATE="$TODAY"; H_COUNT="1"; H_SOURCE="habits"; H_NOTE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)   H_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --date)   H_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      --count)  H_COUNT="${2:-1}"; shift 2 2>/dev/null || shift ;;
      --source) H_SOURCE="${2:-habits}"; shift 2 2>/dev/null || shift ;;
      --note)   H_NOTE="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${H_NAME//[[:space:]]/}" ]]; then
    echo "habits: log requires --name" >&2
    exit 1
  fi
  python3 - "$PBRAIN_DB_FILE" "$H_NAME" "$H_DATE" "$H_COUNT" "$H_SOURCE" "$H_NOTE" "$(date '+%Y-%m-%d %H:%M')" <<'PYEOF'
import sqlite3, sys, re, datetime
db, name, date, count, source, note, created = sys.argv[1:8]
name = name.strip()
# validate date; fall back to today on garbage
if not re.match(r"^\d{4}-\d{2}-\d{2}$", date or ""):
    date = datetime.date.today().isoformat()
try:
    count = max(1, int(count))
except (TypeError, ValueError):
    count = 1
note = (note or "").strip() or None
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    con.execute(
        "INSERT INTO habit_events (habit, occurred_on, count, source, note, created_at) "
        "VALUES (?,?,?,?,?,?) "
        "ON CONFLICT(habit, occurred_on) DO UPDATE SET "
        "  count=MAX(habit_events.count, excluded.count), "
        "  source=excluded.source, "
        "  note=COALESCE(excluded.note, habit_events.note)",
        (name, date, count, source, note, created),
    )
    con.commit()
    con.close()
    print(f"logged: {name} on {date} (x{count})")
except Exception as e:
    print(f"habits: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
  exit 0
fi

# ---------------------------------------------------------------------------
# rollup — text rollup of week/month counts vs caps (reused by plan-my-day/eod).
# ---------------------------------------------------------------------------
if [[ "$SUB" == "rollup" ]]; then
  shift || true
  R_DATE="$TODAY"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) R_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  ROLL="$(pbrain_habits_rollup "$R_DATE" || true)"
  if [[ -n "${ROLL//[[:space:]]/}" ]]; then
    echo "$ROLL"
  else
    echo "(no habit data — set up tracking with /habits)"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# PHASE 0 — first-run setup (no profile yet).
# ---------------------------------------------------------------------------
if [[ ! -f "$PROFILE_FILE" ]]; then
  cat <<SETUP
HABITS_SETUP_PROFILE
profile_file: $PROFILE_FILE

INSTRUCTIONS — first-time habits setup. Don't log anything yet. You're helping
the user define the small set of habits they want to track over time.

Step 1 — Tell the user this is a one-time setup (re-runnable by editing or
deleting the profile). Frame it: "Let's pick a handful of habits to track —
both ones you want to build and ones you want to keep a lid on. Keep it small;
5–8 is plenty."

Step 2 — Interview the user, in 1–2 batches:
  - Which habits do you want to BUILD (do regularly)? e.g. meditate, read,
    gym, call family, journal, walk, deep work, instrument practice.
  - Which do you want to LIMIT (cap)? e.g. alcohol, doomscrolling, takeout,
    late-night screens, gaming.
  - For EACH habit:
      • priority — low / medium / high (how much it matters right now)?
      • cap — how many times per WEEK or per MONTH? For build habits this is a
        target (at least N); for limit habits it's a ceiling (at most N).
      • a short note if useful (e.g. "10 min morning", "weekends only").
  - Don't force a cap if the user genuinely has none — leave cap_count null.

Step 3 — Write the profile to:
  $PROFILE_FILE

  An Obsidian note in EXACTLY this shape — standard frontmatter, a short intro,
  then the structured data in a fenced JSON block (this is what the dashboard +
  extraction read):

  ---
  type: habits-profile
  date: $TODAY
  tags: []
  ---

  # Habits profile

  The habits /habits tracks. Edit freely; the structured data lives in the JSON
  block below. \`build\` = do at least cap_count per period; \`limit\` = stay at or
  under cap_count per period.

  \`\`\`json
  {
    "created": "$TODAY",
    "habits": [
      {
        "name": "Meditate",
        "kind": "build",
        "priority": "high",
        "cap_period": "week",
        "cap_count": 7,
        "notes": "10 min, morning"
      },
      {
        "name": "Alcohol",
        "kind": "limit",
        "priority": "medium",
        "cap_period": "week",
        "cap_count": 2,
        "notes": ""
      }
    ]
  }
  \`\`\`

  - mkdir -p the parent dir before writing.
  - kind is "build" or "limit"; priority is "low"/"medium"/"high";
    cap_period is "week" or "month"; cap_count is an integer or null.
  - Keep the fenced JSON valid — the dashboard and every command's habit
    extraction parse it.
  - Use the user's own habit names.

Step 4 — Confirm: "Habits profile saved at $PROFILE_FILE. From now on I'll log
these from your journals and planning sessions, and /habits will show your
patterns. Re-run /habits any time to see where you stand."
SETUP
  exit 0
fi

# Validate the profile JSON.
PROFILE_JSON="$(pbrain_habits_json || true)"
if [[ -z "${PROFILE_JSON//[[:space:]]/}" ]]; then
  cat <<ERR
HABITS_CONFIG_ERROR
profile_file: $PROFILE_FILE

The habits profile at $PROFILE_FILE has no readable JSON block (or it's
malformed). Fix the fenced \`\`\`json block manually, or delete the file and
re-run /habits to redo the setup.
ERR
  exit 1
fi

# ---------------------------------------------------------------------------
# list — just the configured habits.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "list" ]]; then
  echo "HABITS_LIST"
  printf '%s' "$PROFILE_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for h in data.get("habits") or []:
    name = h.get("name", "?")
    kind = h.get("kind", "build")
    prio = h.get("priority", "medium")
    cap = h.get("cap_count")
    period = h.get("cap_period", "week")
    print("- %s (%s, %s, %s/%s)" % (name, kind, prio, cap, period))
' 2>/dev/null || echo "(could not parse habits)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Default — dashboard.
# ---------------------------------------------------------------------------
ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
[[ -n "${ROLLUP//[[:space:]]/}" ]] || ROLLUP="(no events logged yet)"

cat <<DASH
HABITS_DASHBOARD
date: $TODAY
profile_file: $PROFILE_FILE

=== HABITS PROFILE ===
$PROFILE_JSON

=== ROLLUP (this week / month vs caps) ===
$ROLLUP

---
INSTRUCTIONS — present the user's habit standing and offer to update.

Step 1 — Give a tight read of the ROLLUP above (don't just dump it). Lead with
what needs attention: limit habits at/over cap (⚠️), high-priority build habits
lagging or untouched this week, and any nice streaks worth naming. 3–6 lines.

Step 2 — Ask: "Anything to log for today, or want to tweak the habit list?"
  - To LOG today's habits, run for each one the user did/skipped:
      bash "$_SCRIPT_DIR/habits.sh" log --name "<exact name>" --date $TODAY --source habits
  - To EDIT the habit set (add/remove a habit, change a priority or cap), edit
    the fenced JSON block in $PROFILE_FILE directly, keeping it valid. Show the
    change and get an explicit yes before writing.

Step 3 — Keep it brief. This is a dashboard, not a coaching session.
DASH

pbrain_emit_self_improve "habits" "$PROFILE_FILE" "habits profile" || true
