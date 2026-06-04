#!/usr/bin/env bash
set -euo pipefail

# habits.sh — habit tracking.
#
# First run interviews the user to build a habits PROFILE — one question at a
# time. Each habit carries its OWN fulfillment criteria:
#   schedule_type : daily | weekly | monthly
#   direction     : at_least (build) | at_most (limit)
#   target_count  : integer N (or null)
#   priority      : low | medium | high
# (e.g. "brush at night" = daily/at_least/1; "nail cut" = weekly/at_least/2;
#  "long run" = monthly/at_least/5; "alcohol" = weekly/at_most/2.)
#
# The profile is a vault markdown note carrying its data in a fenced ```json
# block — same discipline as the goals profile, browsable in Obsidian. Each
# habit has a STABLE id (slug) minted once and never changed: renames touch only
# the display name, so event history (in SQLite, keyed by habit_id) stays
# attached. Removing a habit soft-archives it (history preserved).
#
# Every subsequent run shows a dashboard: per-habit progress vs each criteria
# (✅ met / ⏳ not yet / ⚠️ over), top 20 by priority. Events are logged into
# the shared SQLite DB (lib/db.sh) — both from /habits directly and, via the
# ride-along extraction emitter, from ordinary journaling commands.
#
# Subcommands:
#   habits.sh                        first run → setup; else → dashboard
#   habits.sh log --name "X" --date YYYY-MM-DD [--count N] [--source cmd] [--note "..."]
#   habits.sh add --name "X" --type daily|weekly|monthly --direction at_least|at_most
#                 [--target N] [--priority low|medium|high] [--notes "..."]
#   habits.sh edit --id <id> [--name ...] [--type ...] [--direction ...]
#                  [--target N] [--priority ...] [--notes ...]
#   habits.sh archive --id <id>      soft-delete (keeps history)
#   habits.sh history --name "X"     event history for one habit (newest first)
#   habits.sh rollup [--date YYYY-MM-DD]   text rollup (top 20 vs criteria)
#   habits.sh status [--date YYYY-MM-DD]   structured status JSON (machine)
#   habits.sh list                   list configured habits
#   habits.sh track [--date YYYY-MM-DD]  init today's tracking md from profile
#   habits.sh mark --name "X" [--date YYYY-MM-DD] [--count N] [--amount N] [--note "..."]
#   habits.sh sync [--days N] [--date YYYY-MM-DD]  mirror md → DB (default 7 days)
#   habits.sh consolidate [--date YYYY-MM-DD]  sync md → DB then prune unchecked rows
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
# and callable directly. Resolves --name (or --id) to the habit's STABLE id via
# the profile; REJECTS names that aren't a tracked habit (keeps the event log
# clean — every row maps to a defined habit). Idempotent per (habit_id, day).
# ---------------------------------------------------------------------------
if [[ "$SUB" == "log" ]]; then
  shift || true
  H_NAME=""; H_DATE="$TODAY"; H_COUNT="1"; H_SOURCE="habits"; H_NOTE=""; H_AMOUNT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--id) H_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --date)   H_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      --count)  H_COUNT="${2:-1}"; shift 2 2>/dev/null || shift ;;
      --amount) H_AMOUNT="${2:-}"; shift 2 2>/dev/null || shift ;;
      --source) H_SOURCE="${2:-habits}"; shift 2 2>/dev/null || shift ;;
      --note)   H_NOTE="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${H_NAME//[[:space:]]/}" ]]; then
    echo "habits: log requires --name" >&2
    exit 1
  fi
  python3 - "$PBRAIN_DB_FILE" "$PROFILE_FILE" "$H_NAME" "$H_DATE" "$H_COUNT" "$H_SOURCE" "$H_NOTE" "$(date '+%Y-%m-%d %H:%M')" "$H_AMOUNT" <<'PYEOF'
import sqlite3, sys, re, datetime, json
db, profile, name, date, count, source, note, created, amount = sys.argv[1:10]
name = name.strip()

# Resolve name (or id) -> stable habit_id via the profile. Only ACTIVE,
# tracked habits can be logged; unknown names are rejected so the event log
# never accumulates orphan rows that nothing displays.
data = {}
try:
    with open(profile) as fh:
        text = fh.read()
    m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
except Exception:
    data = {}

def slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "").strip().lower()).strip("-")
    return s or "habit"

habit_id = None
disp = name
nm_l = name.lower()
for h in (data.get("habits") or []):
    if h.get("archived"):
        continue
    if str(h.get("name", "")).strip().lower() == nm_l or str(h.get("id", "")).strip().lower() == nm_l:
        habit_id = str(h.get("id", "")).strip() or slug(name)
        disp = str(h.get("name", "")).strip() or name
        break

if not habit_id:
    print(f"not a tracked habit: {name} — add it with /habits (not logged)")
    sys.exit(0)

if not re.match(r"^\d{4}-\d{2}-\d{2}$", date or ""):
    date = datetime.date.today().isoformat()
try:
    count = max(1, int(float(count)))
except (TypeError, ValueError):
    count = 1
try:
    amount = float(amount) if str(amount).strip() else None
except (TypeError, ValueError):
    amount = None
note = (note or "").strip() or None
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    con.execute(
        "INSERT INTO habit_events (habit_id, habit, occurred_on, count, amount, source, note, created_at) "
        "VALUES (?,?,?,?,?,?,?,?) "
        "ON CONFLICT(habit_id, occurred_on) DO UPDATE SET "
        "  count=MAX(habit_events.count, excluded.count), "
        "  amount=COALESCE(excluded.amount, habit_events.amount), "
        "  habit=excluded.habit, "
        "  source=excluded.source, "
        "  note=COALESCE(excluded.note, habit_events.note)",
        (habit_id, disp, date, count, amount, source, note, created),
    )
    con.commit()
    con.close()
    tail = f" — amount {amount}" if amount is not None else ""
    print(f"logged: {disp} on {date} (x{count}){tail}")
except Exception as e:
    print(f"habits: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
  exit 0
fi

# ---------------------------------------------------------------------------
# add — define a new habit: mint a stable id, append to the profile JSON.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "add" ]]; then
  shift || true
  A_NAME=""; A_TYPE="daily"; A_DIR="at_least"; A_TARGET=""; A_PRIO="medium"; A_NOTES=""
  A_UNIT=""; A_MEASURE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)           A_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --type)           A_TYPE="${2:-daily}"; shift 2 2>/dev/null || shift ;;
      --direction)      A_DIR="${2:-at_least}"; shift 2 2>/dev/null || shift ;;
      --target)         A_TARGET="${2:-}"; shift 2 2>/dev/null || shift ;;
      --priority)       A_PRIO="${2:-medium}"; shift 2 2>/dev/null || shift ;;
      --unit)           A_UNIT="${2:-}"; shift 2 2>/dev/null || shift ;;
      --measure-target) A_MEASURE="${2:-}"; shift 2 2>/dev/null || shift ;;
      --notes)          A_NOTES="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${A_NAME//[[:space:]]/}" ]]; then
    echo "habits: add requires --name" >&2
    exit 1
  fi
  case "$A_TYPE" in daily|weekly|monthly) ;; *) echo "habits: --type must be daily|weekly|monthly" >&2; exit 1 ;; esac
  case "$A_DIR" in at_least|at_most) ;; *) echo "habits: --direction must be at_least|at_most" >&2; exit 1 ;; esac
  case "$A_PRIO" in low|medium|high) ;; *) A_PRIO="medium" ;; esac

  # Ensure the profile exists with a json block before appending.
  if [[ ! -f "$PROFILE_FILE" ]]; then
    mkdir -p "$(dirname "$PROFILE_FILE")"
    cat > "$PROFILE_FILE" <<EOF
---
type: habits-profile
date: $TODAY
tags: []
---

# Habits profile

The habits /habits tracks. Edit names/notes freely; structure lives in the JSON
block below. Each habit has a stable \`id\` — don't change it (history is keyed
to it). \`schedule_type\` = daily|weekly|monthly; \`direction\` = at_least (build)
or at_most (limit); \`target_count\` = times per period.

\`\`\`json
{
  "created": "$TODAY",
  "habits": []
}
\`\`\`
EOF
  fi

  # DRY: mint the slug via the shared pbrain_habit_slug, feeding it the ids
  # already taken so collisions get a -2/-3 suffix.
  EXISTING_IDS="$(pbrain_habits_json | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("\n".join(str(h.get("id","")).strip() for h in (d.get("habits") or []) if h.get("id")))
' 2>/dev/null || true)"
  NEW_ID="$(pbrain_habit_slug "$A_NAME" "$EXISTING_IDS")"

  python3 - "$PROFILE_FILE" "$NEW_ID" "$A_NAME" "$A_TYPE" "$A_DIR" "$A_TARGET" "$A_PRIO" "$A_NOTES" "$A_UNIT" "$A_MEASURE" <<'PYEOF'
import json, re, sys
path, hid, name, st, direction, target, priority, notes, unit, measure = sys.argv[1:11]
with open(path) as fh:
    text = fh.read()
m = re.search(r"(```json\s*\n)(.*?)(```)", text, re.DOTALL)
data = json.loads(m.group(2)) if m else {"habits": []}
habits = data.setdefault("habits", [])
try:
    tv = int(target) if str(target).strip() else None
except (TypeError, ValueError):
    tv = None
# Optional measure: a unit + numeric target makes the habit amount-based.
try:
    mv = float(measure) if str(measure).strip() else None
    if mv is not None and mv.is_integer():
        mv = int(mv)
except (TypeError, ValueError):
    mv = None
habits.append({
    "id": hid, "name": name.strip(), "schedule_type": st, "direction": direction,
    "target_count": tv, "priority": priority, "unit": unit.strip(),
    "measure_target": mv, "archived": False, "notes": notes.strip(),
})
new_json = json.dumps(data, indent=2)
if m:
    text = text[:m.start()] + m.group(1) + new_json + "\n" + m.group(3) + text[m.end():]
else:
    text = text.rstrip() + f"\n\n```json\n{new_json}\n```\n"
with open(path, "w") as fh:
    fh.write(text)
measure_note = f", {mv} {unit.strip()}".rstrip() if mv is not None else ""
print(f"added: {name.strip()} [{hid}] ({st}, {direction}, target {tv}, {priority}{measure_note})")
PYEOF
  exit 0
fi

# ---------------------------------------------------------------------------
# edit — change a habit's fields by id. Renaming keeps the id (history intact).
# ---------------------------------------------------------------------------
if [[ "$SUB" == "edit" ]]; then
  shift || true
  E_ID=""; E_NAME="__keep__"; E_TYPE="__keep__"; E_DIR="__keep__"; E_TARGET="__keep__"; E_PRIO="__keep__"; E_NOTES="__keep__"
  E_UNIT="__keep__"; E_MEASURE="__keep__"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)             E_ID="${2:-}"; shift 2 2>/dev/null || shift ;;
      --name)           E_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --type)           E_TYPE="${2:-}"; shift 2 2>/dev/null || shift ;;
      --direction)      E_DIR="${2:-}"; shift 2 2>/dev/null || shift ;;
      --target)         E_TARGET="${2:-}"; shift 2 2>/dev/null || shift ;;
      --priority)       E_PRIO="${2:-}"; shift 2 2>/dev/null || shift ;;
      --unit)           E_UNIT="${2:-}"; shift 2 2>/dev/null || shift ;;
      --measure-target) E_MEASURE="${2:-}"; shift 2 2>/dev/null || shift ;;
      --notes)          E_NOTES="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${E_ID//[[:space:]]/}" || ! -f "$PROFILE_FILE" ]]; then
    echo "habits: edit requires --id and an existing profile" >&2
    exit 1
  fi
  python3 - "$PROFILE_FILE" "$E_ID" "$E_NAME" "$E_TYPE" "$E_DIR" "$E_TARGET" "$E_PRIO" "$E_NOTES" "$E_UNIT" "$E_MEASURE" <<'PYEOF'
import json, re, sys
path, hid, name, st, direction, target, priority, notes, unit, measure = sys.argv[1:11]
KEEP = "__keep__"
with open(path) as fh:
    text = fh.read()
m = re.search(r"(```json\s*\n)(.*?)(```)", text, re.DOTALL)
if not m:
    print("habits: no json block in profile", file=sys.stderr); sys.exit(1)
data = json.loads(m.group(2))
found = None
for h in (data.get("habits") or []):
    if str(h.get("id", "")).strip() == hid:
        found = h
        break
if found is None:
    print(f"habits: no habit with id {hid}", file=sys.stderr); sys.exit(1)
if name != KEEP and name.strip():
    found["name"] = name.strip()
if st != KEEP and st in ("daily", "weekly", "monthly"):
    found["schedule_type"] = st
if direction != KEEP and direction in ("at_least", "at_most"):
    found["direction"] = direction
if target != KEEP:
    try:
        found["target_count"] = int(target) if str(target).strip() else None
    except (TypeError, ValueError):
        found["target_count"] = None
if priority != KEEP and priority in ("low", "medium", "high"):
    found["priority"] = priority
if unit != KEEP:
    found["unit"] = unit.strip()
if measure != KEEP:
    # empty string clears the measure (back to occurrence-based); a number sets it
    if str(measure).strip():
        try:
            mv = float(measure)
            found["measure_target"] = int(mv) if mv.is_integer() else mv
        except (TypeError, ValueError):
            found["measure_target"] = None
    else:
        found["measure_target"] = None
if notes != KEEP:
    found["notes"] = notes.strip()
new_json = json.dumps(data, indent=2)
text = text[:m.start()] + m.group(1) + new_json + "\n" + m.group(3) + text[m.end():]
with open(path, "w") as fh:
    fh.write(text)
print(f"edited: {found.get('name')} [{hid}]")
PYEOF
  exit 0
fi

# ---------------------------------------------------------------------------
# archive — soft-delete a habit by id. Events are preserved (history queryable).
# ---------------------------------------------------------------------------
if [[ "$SUB" == "archive" ]]; then
  shift || true
  AR_ID=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) AR_ID="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${AR_ID//[[:space:]]/}" || ! -f "$PROFILE_FILE" ]]; then
    echo "habits: archive requires --id and an existing profile" >&2
    exit 1
  fi
  python3 - "$PROFILE_FILE" "$AR_ID" <<'PYEOF'
import json, re, sys
path, hid = sys.argv[1], sys.argv[2]
with open(path) as fh:
    text = fh.read()
m = re.search(r"(```json\s*\n)(.*?)(```)", text, re.DOTALL)
if not m:
    print("habits: no json block in profile", file=sys.stderr); sys.exit(1)
data = json.loads(m.group(2))
found = None
for h in (data.get("habits") or []):
    if str(h.get("id", "")).strip() == hid:
        h["archived"] = True
        found = h
        break
if found is None:
    print(f"habits: no habit with id {hid}", file=sys.stderr); sys.exit(1)
new_json = json.dumps(data, indent=2)
text = text[:m.start()] + m.group(1) + new_json + "\n" + m.group(3) + text[m.end():]
with open(path, "w") as fh:
    fh.write(text)
print(f"archived: {found.get('name')} [{hid}] (history kept)")
PYEOF
  exit 0
fi

# ---------------------------------------------------------------------------
# history — event history for one habit (newest first). Resolves --name/--id.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "history" ]]; then
  shift || true
  HI_NAME=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--id) HI_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${HI_NAME//[[:space:]]/}" ]]; then
    echo "habits: history requires --name" >&2
    exit 1
  fi
  python3 - "$PBRAIN_DB_FILE" "$PROFILE_FILE" "$HI_NAME" <<'PYEOF'
import sqlite3, sys, re, json, os
db, profile, name = sys.argv[1], sys.argv[2], sys.argv[3].strip()

def slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "").strip().lower()).strip("-")
    return s or "habit"

# resolve to a habit_id via the profile, falling back to the slug of the input
habit_id, disp = None, name
try:
    with open(profile) as fh:
        m = re.search(r"```json\s*\n(.*?)```", fh.read(), re.DOTALL)
        data = json.loads(m.group(1)) if m else {}
except Exception:
    data = {}
nm_l = name.lower()
for h in (data.get("habits") or []):
    if str(h.get("name", "")).strip().lower() == nm_l or str(h.get("id", "")).strip().lower() == nm_l:
        habit_id = str(h.get("id", "")).strip() or slug(name)
        disp = str(h.get("name", "")).strip() or name
        break
if not habit_id:
    habit_id = slug(name)

print(f"HISTORY: {disp} [{habit_id}]")
rows = []
if os.path.exists(db):
    try:
        con = sqlite3.connect(db, timeout=5)
        con.execute("PRAGMA busy_timeout=5000")
        rows = con.execute(
            "SELECT occurred_on, count, source, note FROM habit_events "
            "WHERE habit_id=? ORDER BY occurred_on DESC", (habit_id,)
        ).fetchall()
        con.close()
    except Exception:
        rows = []
if not rows:
    print("(no history yet)")
else:
    for d, c, src, note in rows:
        extra = f" x{c}" if (c or 1) != 1 else ""
        tail = f" — {note}" if note else ""
        print(f"- {d}{extra} ({src or '?'}){tail}")
    print(f"({len(rows)} day(s) logged)")
PYEOF
  exit 0
fi

# ---------------------------------------------------------------------------
# rollup — text rollup (top 20 vs criteria). Reused by plan-my-day/eod/weekly.
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
# status — structured per-habit status JSON (machine-readable).
# ---------------------------------------------------------------------------
if [[ "$SUB" == "status" ]]; then
  shift || true
  S_DATE="$TODAY"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) S_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  pbrain_habits_status "$S_DATE"
  exit 0
fi

# ---------------------------------------------------------------------------
# track — create/refresh the dated tracking markdown (the human-facing log).
# Generated from the profile: a row per active habit with empty Done cells.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "track" || "$SUB" == "track-init" ]]; then
  shift || true
  T_DATE="$TODAY"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) T_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "habits: no profile yet — run /habits to set up your habits first" >&2
    exit 1
  fi
  FILE="$(pbrain_habit_track_init "$T_DATE")"
  echo "HABITS_TRACK_FILE"
  echo "file: $FILE"
  echo "date: $T_DATE"
  echo "(today's habit checklist — mark 'x' in the Done column as you do each one;"
  echo " /end-of-day consolidates it to the DB and prunes what you didn't do)"
  exit 0
fi

# ---------------------------------------------------------------------------
# mark — mark a habit done in the dated tracking md (the primary write path).
# Resolves --name to a tracked habit; rejects unknown names.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "mark" ]]; then
  shift || true
  M_NAME=""; M_DATE="$TODAY"; M_COUNT="1"; M_NOTE=""; M_AMOUNT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--id) M_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --date)   M_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      --count)  M_COUNT="${2:-1}"; shift 2 2>/dev/null || shift ;;
      --amount) M_AMOUNT="${2:-}"; shift 2 2>/dev/null || shift ;;
      --note)   M_NOTE="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${M_NAME//[[:space:]]/}" ]]; then
    echo "habits: mark requires --name" >&2
    exit 1
  fi
  if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "not a tracked habit: $M_NAME — add it with /habits (not marked)"
    exit 0
  fi
  pbrain_habit_mark "$M_DATE" "$M_NAME" "$M_COUNT" "$M_NOTE" "$M_AMOUNT"
  exit 0
fi

# ---------------------------------------------------------------------------
# sync — mirror the last N days of tracking md into the DB (default 7). Run by
# read commands so the analysis store reflects the markdown before querying.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "sync" ]]; then
  shift || true
  S_DAYS="7"
  S_DATE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) S_DAYS="${2:-7}"; shift 2 2>/dev/null || shift ;;
      --date) S_DATE="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  pbrain_habits_sync_range "$S_DAYS" "$S_DATE"
  echo "synced last $S_DAYS day(s) of habit tracking into the DB"
  exit 0
fi

# ---------------------------------------------------------------------------
# consolidate — sync one date's md into the DB, then prune that file to only the
# habits actually done. Run by /end-of-day.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "consolidate" ]]; then
  shift || true
  C_DATE="$TODAY"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) C_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "(no habits profile — nothing to consolidate)"
    exit 0
  fi
  pbrain_habit_consolidate "$C_DATE"
  exit 0
fi

# ---------------------------------------------------------------------------
# suggest-seen — record that a new-habit candidate was suggested, so the
# cross-command nudge doesn't re-suggest it for a while. Called by the agent.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "suggest-seen" ]]; then
  shift || true
  SS_NAME=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--id) SS_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${SS_NAME//[[:space:]]/}" ]]; then
    echo "habits: suggest-seen requires --name" >&2
    exit 1
  fi
  pbrain_habit_suggest_record "$(pbrain_habit_slug "$SS_NAME")" "$TODAY"
  echo "noted: won't re-suggest '$SS_NAME' for a while"
  exit 0
fi

# ---------------------------------------------------------------------------
# PHASE 0 — first-run setup (no profile yet).
# ---------------------------------------------------------------------------
if [[ ! -f "$PROFILE_FILE" ]]; then
  cat <<SETUP
HABITS_SETUP_PROFILE
profile_file: $PROFILE_FILE
seed_dirs: ${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking} | ${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning} | ${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking} | ${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}
add_cmd: bash "$_SCRIPT_DIR/habits.sh" add --name "<X>" --type daily|weekly|monthly --direction at_least|at_most [--target N] [--unit "L"] [--measure-target N] [--priority low|medium|high] [--notes "..."]

INSTRUCTIONS — first-time habits setup. Don't log anything yet. You're helping
the user define the habits they want to track. Ask ONE question at a time; wait
for each answer before the next. Do NOT batch questions, and do NOT ask about
caps/limits as an opening "pattern" question. There is no 5–8 limit — a person
can track many habits.

STEP 1 — Ask exactly this first, and nothing else:
  "Want me to suggest habits from your recent pbrain entries, or would you
   rather tell me the habits you want to track?"

STEP 2a — IF "suggest from entries":
  - Read the last ~30 days of files under the seed_dirs above (journals, daily
    plans, fitness, diet). Grep/scan for recurring activities the user actually
    did or mentioned repeatedly (e.g. "walked", "meditated", "gym", "read",
    "skipped X"). Ground every candidate in real entries — do NOT invent habits.
  - Present the candidate list ONCE for a quick yes/no per item. Then go through
    the ACCEPTED ones one at a time for their criteria (Step 3).

STEP 2b — IF "I'll specify":
  - Ask for the habits one at a time. After each habit name, immediately gather
    that habit's criteria (Step 3) before moving to the next habit.

STEP 3 — For EACH habit, gather its OWN criteria, one short question at a time:
  - schedule_type: is this DAILY (every day, e.g. brush at night, 4L water),
    WEEKLY (N times a week, e.g. nail cut twice), or MONTHLY (N times a month,
    e.g. a long run 5x)?
  - direction: are you trying to DO it (at_least) or KEEP IT UNDER a limit
    (at_most, e.g. alcohol)?
  - target_count: how many times per period? (For a plain daily habit this is
    just 1 — every day. Ask only if not obvious.)
  - measure (optional): does this habit have a NATURAL AMOUNT you'd rather track
    than a yes/no? (e.g. "4L water", "30 min meditation", "20 km/week running").
    If so, capture a unit (--unit "L") and the per-period target (--measure-target
    4); fulfillment then checks the summed amount vs target ("2.5/4 L") instead of
    done/not-done. Most habits are plain yes/no — only ask/set this when the user
    frames it as a quantity. A measured habit's --target is then irrelevant.
  - priority: low / medium / high — how much it matters right now.
  - notes: optional short note (e.g. "10 min morning", "weekends only").
  Then create it immediately by running the add_cmd above with those values.
  The command mints a stable id and writes valid JSON — never hand-edit the file.

STEP 4 — When done, run \`bash "$_SCRIPT_DIR/habits.sh"\` once more to show the
dashboard, and confirm: "Habits profile saved. I'll log these from your journals
and planning sessions; re-run /habits any time to see where you stand, add or
remove habits, or check a habit's history."
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
import json, sys, re
data = json.load(sys.stdin)
for h in data.get("habits") or []:
    name = str(h.get("name", "?"))
    hid = str(h.get("id", "")) or re.sub(r"[^a-z0-9]+","-",name.strip().lower()).strip("-")
    st = h.get("schedule_type") or ("monthly" if str(h.get("cap_period","")).startswith("month") else ("weekly" if str(h.get("cap_period","")).startswith("week") else "daily"))
    direction = h.get("direction") or ("at_most" if h.get("kind")=="limit" else "at_least")
    prio = h.get("priority", "medium")
    target = h.get("target_count", h.get("cap_count"))
    arch = " [archived]" if h.get("archived") else ""
    mt = h.get("measure_target")
    measure = ""
    if mt is not None:
        unit = str(h.get("unit", "")).strip()
        measure = ", measure %s%s" % (mt, (" " + unit) if unit else "")
    print("- %s [%s] (%s, %s, target %s, %s%s)%s" % (name, hid, st, direction, target, prio, measure, arch))
' 2>/dev/null || echo "(could not parse habits)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Default — dashboard (structured status → tight read + offer to update).
# Sync recent tracking md into the DB first so today's marks are reflected.
# ---------------------------------------------------------------------------
pbrain_habits_sync_range 35 || true
TRACK_FILE="$(pbrain_habit_track_file "$TODAY")"
STATUS_JSON="$(pbrain_habits_status "$TODAY" || true)"
ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
[[ -n "${ROLLUP//[[:space:]]/}" ]] || ROLLUP="(no events logged yet)"

cat <<DASH
HABITS_DASHBOARD
date: $TODAY
profile_file: $PROFILE_FILE
track_file: $TRACK_FILE

=== STATUS (structured; top 20 by priority shown in rollup) ===
$STATUS_JSON

=== ROLLUP (per habit vs its criteria) ===
$ROLLUP

---
INSTRUCTIONS — present the user's habit standing and offer to update.

Habit data lives in a dated markdown log you (and I) edit — today's is at
track_file above. The DB you see in the rollup is synced from those files.

Step 1 — Give a tight read of the ROLLUP (don't dump it). Lead with what needs
attention: limit habits over cap (⚠️), high-priority habits not yet fulfilled
this period (⏳), nice streaks worth naming. The list is the top 20 by priority;
if a "+N more" line shows, mention there are more lower-priority habits. 3–6 lines.

Step 2 — Ask: "Want to open today's tracker, mark something, add or change a habit?"
Use these commands — never hand-edit the profile JSON or the tracking table directly:
  - TRACK today: bash "$_SCRIPT_DIR/habits.sh" track --date $TODAY   (create/refresh today's checklist md)
  - MARK done:   bash "$_SCRIPT_DIR/habits.sh" mark --name "<exact name>" --date $TODAY [--count N] [--amount X] [--note "..."]
                 (for a measured habit — one with a unit — pass --amount, e.g. --amount 2.5)
  - ADD habit:   bash "$_SCRIPT_DIR/habits.sh" add --name "<X>" --type daily|weekly|monthly --direction at_least|at_most [--target N] [--unit "L"] [--measure-target N] [--priority low|medium|high] [--notes "..."]
  - EDIT habit:  bash "$_SCRIPT_DIR/habits.sh" edit --id <id> [--name ...] [--type ...] [--direction ...] [--target N] [--unit ...] [--measure-target N] [--priority ...] [--notes ...]
  - ARCHIVE:     bash "$_SCRIPT_DIR/habits.sh" archive --id <id>   (removes it from the dashboard, keeps history)
  - HISTORY:     bash "$_SCRIPT_DIR/habits.sh" history --name "<X>"
  For add/edit/archive, show the user what you'll run and get an explicit yes first.
  The user can also just open today's track_file in Obsidian and tick cells by hand.

Step 3 — Keep it brief. This is a dashboard, not a coaching session.
DASH

pbrain_emit_self_improve "habits" "$PROFILE_FILE" "habits profile" || true
