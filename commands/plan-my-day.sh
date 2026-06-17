#!/usr/bin/env bash
set -euo pipefail

# plan-my-day.sh
# Adaptive daily planner anchored on your plans profile. The plans profile is
# the active focus view backed by two living libraries:
#
#   <plan-dir>/.profile/plans-profile.vN.md — current_focus (all active focus
#       items, work + life, with rich context) + working_style (session length,
#       breaks, work hours/day, focus hours, last-block ceiling) +
#       planning_guidelines + daily_anchors + anti_patterns +
#       personal_anchors. THE day-planning lens.
#   <plan-dir>/.profile/work-library.vN.md  — stable project reference cards
#       (id, shortcut, summary, metadata); enriched over time (LIVING document).
#   <plan-dir>/.profile/goals-library.vN.md — stable non-work goal cards;
#       LIVING document.
#
# Two daily verbs (smart-dispatched when none is given — `update` if today's plan
# exists, else `plan`):
#   plan   — lay out a FRESH day: wake time (from today's fitness entry when
#            present) → what's done since waking (backfilled, gap-free) → focus
#            hours derived from the skeleton → empty work blocks around the day's
#            anchors (meal times from the diet profile, today's fitness session,
#            habit reminders, calendar events) → confirm → write. Tasks are NOT
#            assigned here; /plan-my-work fills the blocks afterward. The planning
#            instructions live in templates/plan-my-day/plan.txt.
#   update — revise TODAY'S already-written plan in place (templates/.../update.txt):
#            tweak "How it went", add/move/drop a row, re-split blocks. Loads only
#            today's plan + the focus lens + this week's/month's goals.
# Context kept lean: the full text of recent plans is replaced by a 3-day shape
# digest, and the work/goals libraries are NOT loaded for planning (blocks are
# empty placeholders — libraries belong to /plan-my-work). Habit reconcile (scan
# today's entries → mark + realign one-shot reminders) is delegated to the habit
# module via pbrain_emit_habits_scan.
#
# `plan-my-day.sh profile show|new|commit [base]` manages versions: drafts
# are editable, committed versions are final. Rebuild flow 0002 rebuilds the
# old Goals Profile.md into this store.
#
# `plan-my-day.sh task …` is a redirect: task add/remove/list moved to
# /plan-my-work (the work layer). The script emits PLAN_MY_DAY_TASK_MOVED.
#
# `plan-my-day.sh focus list|add|archive|restore` manages current_focus items.
# `plan-my-day.sh library [work|goals] [show|edit <id|shortcut>]` views/edits
# a stable library card.
#
# Default destination:  $VAULT_DIR/life/daily-planning
# Overrides:
#   PBRAIN_VAULT             — vault root
#   PBRAIN_PLAN_DIR          — daily-plan dir (the .profile store lives inside)
#   PBRAIN_PLAN_PROFILE_FILE — explicit plans-profile file (bypasses the store)
#   PBRAIN_FITNESS_DIR       — today's fitness entry + fitness store (cross-ref)
#   PBRAIN_DIET_DIR          — diet store, for meal times (cross-ref)
#   PBRAIN_JOURNAL_DIR       — today's daily journal (cross-ref)
#   PBRAIN_WEEKLY_DIR        — weekly reviews (Monday nudge cross-ref)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /plan-my-day (emits nothing if none set).
pbrain_emit_prefs "plan-my-day" || true

PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
DIET_DIR="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}"
DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
WEEKLY_DIR="${PBRAIN_WEEKLY_DIR:-$VAULT_DIR/life/weekly-tracking}"
STORE="$(pbrain_profile_store "$PLAN_DIR")"
FIT_STORE="$(pbrain_profile_store "$FITNESS_DIR")"
DIET_STORE="$(pbrain_profile_store "$DIET_DIR")"

TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%A)"
DOW3="$(date +%a)"
NOW_TIME="$(date +%H:%M)"
ISO_WEEK="$(python3 -c "import datetime; t=datetime.date.today(); y,w,_=t.isocalendar(); print(f'{y}-W{w:02d}')")"
MONTH_YEAR="$(date +%Y-%m)"
OUT_FILE="$PLAN_DIR/$TODAY.md"

mkdir -p "$PLAN_DIR"

# Daily flow dispatch: `plan` (fresh day) vs `update` (revise today's plan). With
# no verb, smart-dispatch by file existence below (update if today's plan exists,
# else plan). The other verbs (profile|task|focus|library) match on $1 directly and
# are unaffected — they don't set MODE.
MODE=""
case "${1:-}" in
  plan|update) MODE="$1" ;;
esac

# Habit reconcile call site, shared by the update and plan paths. Wrapped so an
# UNLOADED scan helper surfaces LOUDLY as a NOTE block instead of vanishing behind
# `|| true`. The templates promise "a HABIT SCAN block appears below"; if habits.sh
# ever fails to source (or is mid-edit), a bare `pbrain_emit_habits_scan … || true`
# would swallow the `command not found` and leave that promise dangling with no
# block and no error — the exact silent-failure this guards against. Same delimiters
# as the real block so the reference still resolves; distinct NOTE text so it's
# clearly a fault, not a normal scan.
_pmd_habit_scan() {
  if declare -f pbrain_emit_habits_scan >/dev/null 2>&1; then
    pbrain_emit_habits_scan "plan-my-day" || true
  else
    printf '\n--- HABIT SCAN (plan-my-day) ---\n'
    printf 'NOTE: habit reconcile unavailable — pbrain_emit_habits_scan is not loaded\n'
    printf '(lib/habits.sh failed to source or is out of date). No habits were touched\n'
    printf 'this run; skip habit marking and flag this so it can be fixed.\n'
    printf -- '--- END HABIT SCAN ---\n'
  fi
}

# ---------------------------------------------------------------------------
# `profile` subcommand — manage the versioned planning profiles.
#   profile show | profile new [base] | profile commit [base]
#   base ∈ plans-profile (default) | work-library | goals-library
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "profile" ]]; then
  ACTION="${2:-show}"
  BASE="${3:-plans-profile}"
  case "$ACTION" in
    show)
      echo "PLAN_PROFILE_SHOW"
      for b in plans-profile work-library goals-library monthly-goals weekly-goals; do
        f="$(pbrain_profile_latest "$STORE" "$b")"
        d="$(pbrain_profile_draft "$STORE" "$b")"
        echo ""
        echo "=== $b (committed: ${f:-none}; draft: ${d:-none}) ==="
        [[ -n "$f" ]] && cat "$f"
      done
      echo ""
      echo "---"
      echo "INSTRUCTIONS: Present the profiles above as a short human-readable summary"
      echo "(work goals with deadlines, life goals, working-style numbers, anchors)."
      echo "Do not dump raw JSON. Committed profiles are final — to change one:"
      echo "  /plan-my-day profile new [plans-profile|work-library|goals-library]"
      exit 0
      ;;
    new)
      DRAFT="$(pbrain_profile_draft "$STORE" "$BASE")"
      if [[ -n "$DRAFT" ]]; then
        echo "PLAN_PROFILE_DRAFT_OPEN"
        echo "draft: $DRAFT"
        echo "A draft of $BASE is already open. Iterate on it with the user and, when they"
        echo "confirm, finalize with: bash \"$_SCRIPT_DIR/plan-my-day.sh\" profile commit $BASE"
        exit 0
      fi
      NEW_PATH="$(pbrain_profile_new "$STORE" "$BASE")" || exit 1
      echo "PLAN_PROFILE_NEW"
      echo "draft: $NEW_PATH"
      echo ""
      echo "INSTRUCTIONS: A new DRAFT version of $BASE was minted (copied from the"
      echo "previous version when one existed). Walk the user through what they want to"
      echo "change, edit the draft file directly (keep the fenced JSON block valid and"
      echo "the frontmatter version/committed lines intact), iterate until they are"
      echo "happy, then finalize with:"
      echo "  bash \"$_SCRIPT_DIR/plan-my-day.sh\" profile commit $BASE"
      echo "Once committed the version is FINAL — further changes mint the next version."
      exit 0
      ;;
    commit)
      OUT="$(pbrain_profile_commit "$STORE" "$BASE")" || exit 1
      echo "PLAN_PROFILE_COMMITTED"
      echo "file: $OUT"
      echo "This version is now final. Future changes: /plan-my-day profile new $BASE"
      exit 0
      ;;
    *)
      echo "usage: plan-my-day.sh profile show|new|commit [plans-profile|work-library|goals-library|monthly-goals|weekly-goals]" >&2
      exit 2
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# `task` MOVED to /plan-my-work. /plan-my-day now lays out the day's life
# anchors + EMPTY work blocks; /plan-my-work fills the blocks with Plane tasks
# and owns the mid-day task add|remove|list revision. Redirect early (before any
# setup/migration guard) so a `task` verb never triggers a profile interview.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "task" ]]; then
  echo "PLAN_MY_DAY_TASK_MOVED"
  echo "action: ${2:-list}"
  echo ""
  echo "INSTRUCTIONS: The task verb moved to /plan-my-work (the work layer). Tell the"
  echo "user to run \"/plan-my-work task ${2:-list}\" instead — /plan-my-day no longer"
  echo "assigns or edits tasks; it only lays out the day's anchors + empty work blocks."
  echo "Stop here."
  exit 0
fi

# ---------------------------------------------------------------------------
# Rebuild flow 0002 — (re)build the plans profile from the old Goals
# Profile.md (or legacy plan-profile.json). An EXPLICIT profile override
# pointing at a real file wins outright — the user told us which file to use.
# ---------------------------------------------------------------------------
if [[ ! -f "${PBRAIN_PLAN_PROFILE_FILE:-/nonexistent}" ]] \
   && declare -F pbrain_migration_pending >/dev/null \
   && pbrain_migration_pending 0002_plans_profile_rebuild; then
  OLD_PROFILE="$VAULT_DIR/life/Goals Profile.md"
  OLD_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/plan-profile.json"
  echo "PLAN_MY_DAY_REBUILD"
  echo "store: $STORE"
  echo "backup_dir: $VAULT_DIR/.pbrain/backup"
  echo ""
  echo "=== OLD GOALS PROFILE ($OLD_PROFILE) ==="
  cat "$OLD_PROFILE" 2>/dev/null || echo "(none)"
  echo ""
  echo "=== LEGACY JSON PROFILE ($OLD_JSON) ==="
  cat "$OLD_JSON" 2>/dev/null || echo "(none)"
  echo ""
  echo "=== RECENT DAY PLANS (project names for the libraries) ==="
  python3 - "$PLAN_DIR" <<'PYEOF' 2>/dev/null || true
import glob, os, sys
d = sys.argv[1]
for f in sorted(glob.glob(os.path.join(d, "*.md")))[-10:]:
    try:
        with open(f) as fh:
            print(f"=== {os.path.basename(f)} ===")
            print(fh.read())
    except Exception:
        pass
PYEOF
  envsubst < "$_SCRIPT_DIR/templates/plan-my-day/rebuild.txt"
  echo ""
  echo "=== PROFILE SCHEMA (JSON shape reference) ==="
  cat "$_SCRIPT_DIR/templates/plan-my-day/profile-schema.txt"
  exit 0
fi

# ---------------------------------------------------------------------------
# Reframe flow 0007 — move weekly/monthly goals from TASK-level to PROJECT-level
# (plane_project + allocation_percent). Runs only after the plans profile + goals
# files exist (so it never collides with the 0002 rebuild, which exits above).
# ---------------------------------------------------------------------------
if declare -F pbrain_migration_pending >/dev/null \
   && pbrain_migration_pending 0007_goals_project_reframe; then
  REFRAME_WEEKLY="$(pbrain_profile_latest_for_period "$STORE" weekly-goals "$ISO_WEEK" 2>/dev/null || true)"
  REFRAME_MONTHLY="$(pbrain_profile_latest_for_period "$STORE" monthly-goals "$MONTH_YEAR" 2>/dev/null || true)"
  REGISTRY_JSON="$(pbrain_projects_registry_json 2>/dev/null || echo '[]')"
  echo "PLAN_MY_DAY_GOALS_REFRAME"
  echo "store: $STORE"
  echo "plane_configured: $(pbrain_plane_configured && echo yes || echo no)"
  echo ""
  echo "=== PROJECT REGISTRY (registry_json) ==="
  echo "$REGISTRY_JSON"
  echo ""
  echo "=== CURRENT WEEKLY GOALS DRAFT ($ISO_WEEK) ==="
  if [[ -n "$REFRAME_WEEKLY" ]]; then echo "file: $REFRAME_WEEKLY"; cat "$REFRAME_WEEKLY"; else echo "(none for this period)"; fi
  echo ""
  echo "=== CURRENT MONTHLY GOALS DRAFT ($MONTH_YEAR) ==="
  if [[ -n "$REFRAME_MONTHLY" ]]; then echo "file: $REFRAME_MONTHLY"; cat "$REFRAME_MONTHLY"; else echo "(none for this period)"; fi
  echo ""
  for _f in "$STORE"/weekly-goals.v*.md "$STORE"/monthly-goals.v*.md; do
    [[ -f "$_f" ]] || continue
    echo "store_goal_file: $_f"
  done
  envsubst < "$_SCRIPT_DIR/templates/plan-my-day/reframe.txt"
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolution — explicit override file, else latest committed in the store.
# ---------------------------------------------------------------------------
PROFILE_FILE="${PBRAIN_PLAN_PROFILE_FILE:-}"
if [[ -n "$PROFILE_FILE" && ! -f "$PROFILE_FILE" ]]; then PROFILE_FILE=""; fi
[[ -n "$PROFILE_FILE" ]] || PROFILE_FILE="$(pbrain_profile_latest "$STORE" plans-profile)"

# ---------------------------------------------------------------------------
# PHASE 0 — first-run setup (no committed plans profile anywhere).
# ---------------------------------------------------------------------------
if [[ -z "$PROFILE_FILE" ]]; then
  DRAFT="$(pbrain_profile_draft "$STORE" plans-profile)"
  if [[ -n "$DRAFT" ]]; then
    echo "PLAN_PROFILE_DRAFT_OPEN"
    echo "draft: $DRAFT"
    echo ""
    cat "$DRAFT"
    echo ""
    echo "---"
    echo "A plans-profile draft is already open (shown above). Review it with the user,"
    echo "apply any edits they want (keep the fenced JSON valid), then finalize with:"
    echo "  bash \"$_SCRIPT_DIR/plan-my-day.sh\" profile commit plans-profile"
    echo "Daily planning starts once the profile is committed."
    exit 0
  fi
  envsubst < "$_SCRIPT_DIR/templates/plan-my-day/setup.txt"
  echo ""
  echo "=== PROFILE SCHEMA (JSON shape reference) ==="
  cat "$_SCRIPT_DIR/templates/plan-my-day/profile-schema.txt"
  exit 0
fi

# Extract + validate the profile JSON (carried in a fenced JSON block).
PROFILE_JSON="$(pbrain_profile_json "$PROFILE_FILE")"

if [[ -z "$PROFILE_JSON" ]]; then
  cat <<ERR
PLAN_MY_DAY_CONFIG_ERROR
profile_file: $PROFILE_FILE

The plans profile at $PROFILE_FILE has no readable JSON block (or it is
malformed). Fix the fenced JSON manually, or mint a fresh version with
/plan-my-day profile new plans-profile.
ERR
  exit 1
fi

# The two libraries (latest committed; living documents).
WORK_LIB_FILE="$(pbrain_profile_latest "$STORE" work-library)"
GOALS_LIB_FILE="$(pbrain_profile_latest "$STORE" goals-library)"
WORK_LIB_CONTENT="(no work library yet — block context comes from the profile alone)"
GOALS_LIB_CONTENT="(no goals library yet)"
[[ -n "$WORK_LIB_FILE" ]] && WORK_LIB_CONTENT="$(cat "$WORK_LIB_FILE" 2>/dev/null || true)"
[[ -n "$GOALS_LIB_FILE" ]] && GOALS_LIB_CONTENT="$(cat "$GOALS_LIB_FILE" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# `focus` subcommand — manage current_focus items in the plans profile.
# `library` subcommand — view/amend a stable library card.
#   focus list | focus add | focus archive <id|shortcut>
#   focus restore <id|shortcut>
#   library [work|goals] [show | edit <id|shortcut>]
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "focus" || "${1:-}" == "library" ]]; then
  FOCUS_VERB="${1:-focus}"
  FOCUS_ACTION="${2:-list}"

  if [[ "$FOCUS_VERB" == "focus" ]]; then
    case "$FOCUS_ACTION" in
      list|add|archive|restore) ;;
      *)
        echo "usage: plan-my-day.sh focus list|add|archive|restore" >&2
        exit 2
        ;;
    esac
    echo "PLAN_MY_DAY_FOCUS"
    echo "action: $FOCUS_ACTION"
    echo "profile_file: $PROFILE_FILE"
    echo "work_library_file: ${WORK_LIB_FILE:-(none)}"
    echo "goals_library_file: ${GOALS_LIB_FILE:-(none)}"
    echo ""
    echo "=== PLANS PROFILE (current_focus + working_style) ==="
    echo "$PROFILE_JSON"
    echo ""
    echo "=== WORK LIBRARY ==="
    echo "$WORK_LIB_CONTENT"
    echo ""
    echo "=== GOALS LIBRARY ==="
    echo "$GOALS_LIB_CONTENT"
    echo ""
    echo "---"
    echo "INSTRUCTIONS — focus $FOCUS_ACTION. You are managing the user's current_focus"
    echo "list in their plans profile ($PROFILE_FILE). The plans profile is a LIVING"
    echo "document — amend the latest version in place (do NOT mint a new version unless"
    echo "the user explicitly asks for a structural redesign). Keep the fenced JSON block"
    echo "valid and the frontmatter intact throughout."
    echo ""
    case "$FOCUS_ACTION" in
      list)    cat "$_SCRIPT_DIR/templates/plan-my-day/focus-list.txt" ;;
      add)     cat "$_SCRIPT_DIR/templates/plan-my-day/focus-add.txt" ;;
      archive) envsubst < "$_SCRIPT_DIR/templates/plan-my-day/focus-archive.txt" ;;
      restore) cat "$_SCRIPT_DIR/templates/plan-my-day/focus-restore.txt" ;;
    esac
    exit 0
  else
    # library subcommand
    LIB_TARGET="${2:-work}"
    LIB_OP="${3:-show}"
    LIB_ID="${4:-}"
    case "$LIB_TARGET" in
      work|goals) ;;
      *) echo "usage: plan-my-day.sh library [work|goals] [show|edit <id|shortcut>]" >&2; exit 2 ;;
    esac
    case "$LIB_OP" in
      show|edit) ;;
      *) echo "usage: plan-my-day.sh library [work|goals] [show|edit <id|shortcut>]" >&2; exit 2 ;;
    esac

    LIB_FILE=""
    LIB_CONTENT=""
    if [[ "$LIB_TARGET" == "work" ]]; then
      LIB_FILE="${WORK_LIB_FILE:-}"
      LIB_CONTENT="$WORK_LIB_CONTENT"
    else
      LIB_FILE="${GOALS_LIB_FILE:-}"
      LIB_CONTENT="$GOALS_LIB_CONTENT"
    fi

    echo "PLAN_MY_DAY_LIBRARY"
    echo "target: $LIB_TARGET"
    echo "action: $LIB_OP"
    echo "library_file: ${LIB_FILE:-(none)}"
    [[ -n "$LIB_ID" ]] && echo "item: $LIB_ID"
    echo ""
    echo "=== $(echo "$LIB_TARGET" | tr '[:lower:]' '[:upper:]') LIBRARY ==="
    echo "$LIB_CONTENT"
    echo ""
    if [[ "$LIB_OP" == "show" ]]; then
      echo "---"
      echo "INSTRUCTIONS — library show. Present the library cards as a readable list."
      echo "For each card: shortcut (if set) | name | category | summary | metadata"
      echo "(key facts only) | timeline status (active or archived with date). Stop here."
    else
      echo "---"
      echo "INSTRUCTIONS — library edit. The user wants to update a card in the $LIB_TARGET"
      echo "library (${LIB_FILE:-(no library yet)}). If no library file exists, say so and stop."
      echo "Find the card by id or shortcut (item: $LIB_ID if set; otherwise the user's"
      echo "message names it). Display its current fields, ask what to change, then edit"
      echo "the library file in place (living document — no version mint). Keep the fenced"
      echo "JSON valid. Confirm what changed."
    fi
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# UPDATE path — revise today's already-written plan (light, in-place). Triggered
# by an explicit `update` verb, or by a bare invocation when today's plan exists.
# Loads ONLY today's plan + the focus lens + this week's/month's goals — no
# libraries, no recent-day digest, no planning prompt.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "update" || ( -z "$MODE" && -f "$OUT_FILE" ) ]]; then
  if [[ ! -f "$OUT_FILE" ]]; then
    echo "PLAN_MY_DAY_NO_PLAN_YET"
    echo "date: $TODAY"
    echo ""
    echo "There's no plan for $TODAY yet, so there's nothing to update. Tell the user"
    echo "to run /plan-my-day (or /plan-my-day plan) to lay out the day first."
    exit 0
  fi
  UPD_WEEKLY="$(pbrain_profile_latest_for_period "$STORE" weekly-goals "$ISO_WEEK" 2>/dev/null || true)"
  UPD_MONTHLY="$(pbrain_profile_latest_for_period "$STORE" monthly-goals "$MONTH_YEAR" 2>/dev/null || true)"
  echo "PLAN_MY_DAY_UPDATE"
  echo "date: $TODAY"
  echo "day_of_week: $DOW"
  echo "output_file: $OUT_FILE"
  echo "profile_file: $PROFILE_FILE"
  echo ""
  echo "=== TODAY'S PLAN (current) ==="
  cat "$OUT_FILE"
  echo ""
  echo "=== PLANS PROFILE (current_focus lens) ==="
  echo "$PROFILE_JSON"
  echo ""
  echo "=== WEEKLY GOALS ($ISO_WEEK) ==="
  if [[ -n "$UPD_WEEKLY" ]]; then cat "$UPD_WEEKLY"; else echo "(none for this week)"; fi
  echo ""
  echo "=== MONTHLY GOALS ($MONTH_YEAR) ==="
  if [[ -n "$UPD_MONTHLY" ]]; then cat "$UPD_MONTHLY"; else echo "(none for this month)"; fi
  echo ""
  echo "---"
  cat "$_SCRIPT_DIR/templates/plan-my-day/update.txt"
  # Habit reconcile + self-improvement capture (silent without their profiles).
  _pmd_habit_scan
  pbrain_emit_self_improve "plan-my-day" "$PROFILE_FILE" "plans profile" || true
  exit 0
fi

# ---------------------------------------------------------------------------
# PLAN path — lay out a fresh day (MODE==plan, or a bare invocation with no plan
# for today yet). Gathers the day's context (profile is the lens; libraries and
# the full recent plans are deliberately NOT loaded — see plan.txt) and hands the
# planning instructions to the model from the externalized plan.txt template.
# ---------------------------------------------------------------------------
FITNESS_TODAY="$(cat "$FITNESS_DIR/$TODAY.md" 2>/dev/null || echo "MISSING")"
DAILY_TODAY="$(cat "$DAILY_DIR/$TODAY.md" 2>/dev/null || echo "MISSING")"

# Existence-only flag for the end-of-session diet nudge — we only need yes/no,
# not the file contents.
DIET_TODAY_EXISTS="$([[ -f "$DIET_DIR/$TODAY.md" ]] && echo yes || echo no)"

# Sleep data recorded by today's fitness check-in (frontmatter sleep_* fields)
# — when present, the wake-time question is skipped (confirm in passing).
FITNESS_SLEEP="$(python3 - "$FITNESS_DIR/$TODAY.md" <<'PYEOF' 2>/dev/null || true
import re, sys
try:
    with open(sys.argv[1]) as fh:
        head = fh.read(2000)
except Exception:
    sys.exit(0)
m = re.match(r"^---\n(.*?)\n---", head, re.DOTALL)
if not m:
    sys.exit(0)
fm = m.group(1)
out = []
for key in ("sleep_wake", "sleep_bed", "sleep_hours", "sleep_quality"):
    km = re.search(r"^" + key + r":\s*(.+?)\s*$", fm, re.MULTILINE)
    if km:
        val = km.group(1).strip()
        if val and val not in ("''", '""'):
            out.append(f"{key}={val}")
print(" ".join(out))
PYEOF
)"
[[ -n "${FITNESS_SLEEP//[[:space:]]/}" ]] || FITNESS_SLEEP="(not recorded — ask the user)"

# Today's CHOSEN fitness activity, from the fitness entry's `focus:` frontmatter
# field (the workout the user actually logged for today — may differ from what
# the schedule says). Drives the deterministic habit-reminder reconciliation
# (fitness-reconcile) below: the chosen activity's habit gets its reminder, the
# scheduled-but-not-chosen ones get cancelled + auto-skipped. Run via a temp
# file (heredoc OUTSIDE $()) on purpose — this script is past macOS bash 3.2's
# stacked-$()-heredoc threshold (see _RF_PY), so a new "$(python3 - <<EOF …)"
# block here would break bash -n.
_FA_PY="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/pbrain-fitact.$$.py")"
cat > "$_FA_PY" <<'PYEOF'
import re, sys
try:
    with open(sys.argv[1]) as fh:
        head = fh.read(2000)
except Exception:
    sys.exit(0)
m = re.match(r"^---\n(.*?)\n---", head, re.DOTALL)
if not m:
    sys.exit(0)
fm = m.group(1)
# Prefer `activity:` (gym sessions use focus: for muscle groups, activity: for the library slug/name)
val = None
for key in ("activity", "focus"):
    km = re.search(r"^" + key + r":\s*(.+?)\s*$", fm, re.MULTILINE)
    if km:
        v = km.group(1).strip().strip(chr(34) + chr(39))
        if v:
            val = v
            break
if val:
    print(val)
PYEOF
TODAY_FITNESS_ACTIVITY="$(python3 "$_FA_PY" "$FITNESS_DIR/$TODAY.md" 2>/dev/null || true)"
rm -f "$_FA_PY"

# Meal times from the committed diet profile (rest-day defaults; the fitness
# session shifts the nearby slots).
DIET_MEAL_TIMES="$(python3 - "$(pbrain_profile_latest "$DIET_STORE" diet-profile)" <<'PYEOF' 2>/dev/null || true
import json, re, sys
path = sys.argv[1] if len(sys.argv) > 1 else ""
if not path:
    sys.exit(0)
try:
    with open(path) as fh:
        text = fh.read()
except Exception:
    sys.exit(0)
m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
try:
    p = json.loads(m.group(1) if m else text)
except Exception:
    sys.exit(0)
times = p.get("meal_times") or {}
print(", ".join(f"{k} {v}" for k, v in times.items()))
PYEOF
)"
[[ -n "${DIET_MEAL_TIMES//[[:space:]]/}" ]] || DIET_MEAL_TIMES="(no diet profile — use the plans-profile daily_anchors / typical_day meal times)"

# Today's scheduled fitness activity + its typical time, from the fitness
# store (activity profiles carry fixed days; the library carries times).
TODAY_FITNESS_SCHEDULE="$(python3 - "$FIT_STORE" "$DOW3" <<'PYEOF' 2>/dev/null || true
import glob, json, os, re, sys
fit_store, dow = sys.argv[1], sys.argv[2]
dow3 = dow.strip().lower()[:3]
act_store = os.path.join(fit_store, "activities")

meta = {}
lib_best = None
for f in glob.glob(os.path.join(fit_store, "fitness-library.v*.md")):
    m = re.match(r".*\.v(\d+)\.md$", f)
    if m and (lib_best is None or int(m.group(1)) > lib_best[0]):
        lib_best = (int(m.group(1)), f)
if lib_best:
    try:
        with open(lib_best[1]) as fh:
            jm = re.search(r"```json\s*\n(.*?)```", fh.read(), re.DOTALL)
        data = json.loads(jm.group(1)) if jm else {}
        for a in data.get("activities", []):
            slug = a.get("id") or re.sub(r"[^a-z0-9]+", "-", str(a.get("name", "")).lower()).strip("-")
            meta[slug] = (str(a.get("name", slug)), a.get("typical_time"), a.get("duration_min"))
    except Exception:
        pass

# Highest COMMITTED version per slug — an open draft (higher version,
# committed: false) must NOT shadow the committed version below it.
best = {}
for f in glob.glob(os.path.join(act_store, "*.v*.md")):
    m = re.match(r"(.+)\.v(\d+)\.md$", os.path.basename(f))
    if not m:
        continue
    slug, ver = m.group(1), int(m.group(2))
    try:
        with open(f) as fh:
            text = fh.read()
    except Exception:
        continue
    fm = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
    if not fm or re.search(r"^committed:\s*false\s*$", fm.group(1), re.MULTILINE):
        continue
    if slug not in best or ver > best[slug][0]:
        best[slug] = (ver, fm.group(1))

for slug, (_v, front) in sorted(best.items()):
    dm = re.search(r"^days:\s*\[(.*?)\]\s*$", front, re.MULTILINE)
    if not dm:
        continue
    days = [d.strip().strip("\"").lower()[:3] for d in dm.group(1).split(",") if d.strip()]
    if dow3 in days:
        name, ttime, dur = meta.get(slug, (slug, None, None))
        bits = [name]
        if ttime:
            bits.append(f"typically {ttime}")
        if dur:
            bits.append(f"~{dur} min")
        print(" — ".join(bits))
PYEOF
)"
[[ -n "${TODAY_FITNESS_SCHEDULE//[[:space:]]/}" ]] || TODAY_FITNESS_SCHEDULE="(nothing scheduled today)"

# Recent fitness ACTIVITY (last ~4 days) — context for the skip-fitness judgment
# in Step 1b.5 ("have the last few days already been active?"). A compact
# session count + activity names from the dated fitness files. Run via a temp
# file (heredoc OUTSIDE $()) on purpose — this script sits past macOS bash 3.2's
# stacked-command-substitution-heredoc threshold (see the CARRY_FORWARD note
# below), so a new `"$(python3 - <<'EOF' … )"` block here would break bash -n.
_RF_PY="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/pbrain-recentfit.$$.py")"
cat > "$_RF_PY" <<'PYEOF'
import os, glob, re, sys, datetime
fit_dir, today = sys.argv[1], sys.argv[2]
try:
    t = datetime.date.fromisoformat(today)
except ValueError:
    print("(unknown)"); sys.exit(0)
lines = []
for f in sorted(glob.glob(os.path.join(fit_dir, "*.md"))):
    base = os.path.basename(f)[:-3]
    try:
        d = datetime.date.fromisoformat(base)
    except ValueError:
        continue
    gap = (t - d).days
    if gap < 1 or gap > 4:   # last ~4 days, excluding today
        continue
    try:
        with open(f) as fh:
            text = fh.read()
    except Exception:
        continue
    # Activity name: the first H1, else the `activity:`/`type:` frontmatter.
    name = None
    hm = re.search(r"^#\s+(.+?)\s*$", text, re.MULTILINE)
    if hm:
        name = hm.group(1).strip()
    if not name:
        fm = re.search(r"^(?:activity|type):\s*(.+?)\s*$", text, re.MULTILINE)
        name = fm.group(1).strip() if fm else "session"
    lines.append(f"- {base} ({gap}d ago): {name}")
if not lines:
    print("(no fitness logged in the last 4 days)"); sys.exit(0)
print(f"{len(lines)} session(s) in the last 4 days:")
print("\n".join(lines))
PYEOF
RECENT_FITNESS_ACTIVITY="$(python3 "$_RF_PY" "$FITNESS_DIR" "$TODAY" 2>/dev/null || true)"
rm -f "$_RF_PY"
[[ -n "${RECENT_FITNESS_ACTIVITY//[[:space:]]/}" ]] || RECENT_FITNESS_ACTIVITY="(no fitness logged in the last 4 days)"

# Whether the committed plans profile carries a typical_day template — drives
# Step 1b.5's graceful degradation (fall back to from-scratch planning + a soft
# one-time nudge when absent). Grep-based to add no extra heredoc.
if printf '%s' "$PROFILE_JSON" | grep -q '"workday"'; then
  TYPICAL_DAY_PRESENT=yes
else
  TYPICAL_DAY_PRESENT=no
fi

# Recent days — a COMPACT one-line-per-day digest (last 3), NOT the full plans.
# The model only needs the day's SHAPE (wake, #blocks, meal times, energy) for
# pattern context; the full text of past plans was the single biggest context
# bloat and is dropped. Carry-forward (below) still surfaces unfinished work.
# Run via a temp file (heredoc OUTSIDE $()) on purpose — this script sits past
# macOS bash 3.2's stacked-$()-heredoc threshold (see _CF_PY / _RF_PY).
_RD_PY="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/pbrain-recentdays.$$.py")"
cat > "$_RD_PY" <<'PYEOF'
import os, glob, re, sys, datetime
plan_dir, today = sys.argv[1], sys.argv[2]
prior = [f for f in sorted(glob.glob(os.path.join(plan_dir, "*.md")))
         if os.path.basename(f)[:-3] < today][-3:]
if not prior:
    print("(no previous plans)"); sys.exit(0)
lines = []
for f in prior:
    base = os.path.basename(f)[:-3]
    try:
        with open(f) as fh:
            text = fh.read()
    except Exception:
        continue
    dow = ""
    try:
        dow = datetime.date.fromisoformat(base).strftime("%a")
    except ValueError:
        pass
    fm = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
    front = fm.group(1) if fm else ""
    def fval(key):
        m = re.search(r"^" + key + r":\s*(.+?)\s*$", front, re.MULTILINE)
        return m.group(1).strip() if m else ""
    energy = fval("energy")
    sleep_h = fval("sleep_hours")
    # Table rows: count generic work blocks; pull wake + meal times by keyword.
    rows = re.findall(r"^\|\s*(\d{1,2}:\d{2})[^|]*\|([^|]+)\|", text, re.MULTILINE)
    blocks = sum(1 for _t, a in rows if re.search(r"\bblock\s*\d", a, re.I))
    wake = rows[0][0] if rows else ""
    def meal(name):
        for t, a in rows:
            if re.search(r"\b" + name + r"\b", a, re.I):
                return t
        return ""
    bits = []
    if wake:
        bits.append(f"wake {wake}")
    if blocks:
        bits.append(f"{blocks} blocks")
    for nm, lbl in (("lunch", "lunch"), ("dinner", "dinner")):
        mt = meal(nm)
        if mt:
            bits.append(f"{lbl} {mt}")
    if energy:
        bits.append(f"energy {energy}")
    if sleep_h:
        bits.append(f"sleep {sleep_h}h")
    label = f"{base} ({dow})" if dow else base
    lines.append(f"- {label}: " + (" · ".join(bits) if bits else "(no table)"))
print("\n".join(lines))
PYEOF
RECENT_DAY_DIGEST="$(python3 "$_RD_PY" "$PLAN_DIR" "$TODAY" 2>/dev/null || true)"
rm -f "$_RD_PY"
[[ -n "${RECENT_DAY_DIGEST//[[:space:]]/}" ]] || RECENT_DAY_DIGEST="(no previous plans)"

# Carry-forward from the most recent PRIOR day plan — /end-of-day writes a
# "### Carry-forward" list (not-done tasks) + leaves "## Task log" rows whose
# Status is "not started"/"partial". Surface those as candidate tasks for today
# so unfinished work actually flows forward instead of getting lost.
# NOTE: written to a temp file and run via `python3 <file>` rather than an
# inline `"$(python3 - <<'EOF' … )"` heredoc on purpose — macOS bash 3.2's
# parser miscounts parens when several command-substitution-nested heredocs
# stack up in one script, and this block sits past that threshold (it would
# fail `bash -n` with a spurious "syntax error near `('"). Keeping the heredoc
# OUTSIDE the `$()` sidesteps the bug.
_CF_PY="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/pbrain-carryfwd.$$.py")"
cat > "$_CF_PY" <<'PYEOF'
import os, glob, re, sys
d, today = sys.argv[1], sys.argv[2]
prior = [f for f in sorted(glob.glob(os.path.join(d, "*.md")))
         if os.path.basename(f)[:-3] < today]
if not prior:
    print("(none)"); sys.exit(0)
src = prior[-1]
day = os.path.basename(src)[:-3]
try:
    with open(src) as fh:
        text = fh.read()
except Exception:
    print("(none)"); sys.exit(0)
items = []
flags = re.MULTILINE | re.DOTALL
# first: explicit "### Carry-forward" bullets
m = re.search(r"^###\s+Carry-forward[ \t]*\n(.*?)(?=^#{2,3}\s|\Z)", text, flags)
if m:
    for ln in m.group(1).splitlines():
        ln = ln.strip()
        if ln.startswith("-"):
            b = ln.lstrip("-").strip()
            if b and not b.lower().startswith("(nothing"):
                items.append(b)
# then: unfinished "## Task log" rows with Status not started / partial
tm = re.search(r"^##\s+Task log[ \t]*\n(.*?)(?=^#{2,3}\s|\Z)", text, flags)
if tm:
    for row in tm.group(1).splitlines():
        cells = [c.strip() for c in row.strip().strip("|").split("|")]
        if len(cells) < 6:
            continue
        status = cells[-1].lower() if len(cells) == 6 else cells[5].lower()
        if status in ("not started", "partial"):
            task = cells[0]
            if task and task.lower() != "task" and not task.startswith("--"):
                if all(task not in it for it in items):
                    items.append(f"{task} (was {status})")
if not items:
    print("(none)"); sys.exit(0)
print(f"from {day}:")
for it in items[:12]:
    print(f"- {it}")
PYEOF
CARRY_FORWARD="$(python3 "$_CF_PY" "$PLAN_DIR" "$TODAY" 2>/dev/null || true)"
rm -f "$_CF_PY"
[[ -n "${CARRY_FORWARD//[[:space:]]/}" ]] || CARRY_FORWARD="(none)"

# Weekly-review nudge: Mondays only. Measures the calendar span since the last
# weekly review covered through (parsed from the review's "Dates: X → Y" line,
# falling back to the ISO-week Sunday of the filename) and nudges once >= 7 days
# have elapsed. The span is calendar-based, so plan-my-day days you skipped
# still count toward the 7 — a sparse planning week won't under-count. With no
# prior review, it anchors on your oldest plan-my-day entry instead. The plan
# count in the window is reported for the message but isn't a hard gate.
WEEKLY_REVIEW_SIGNAL="$(python3 - "$WEEKLY_DIR" "$PLAN_DIR" <<'PYEOF'
import os, sys, re, glob, datetime
weekly_dir, plan_dir = sys.argv[1], sys.argv[2]
today = datetime.date.today()
if today.weekday() != 0:  # 0 == Monday
    print("none")
    sys.exit(0)

THRESHOLD = 7  # days of elapsed span (gaps included) before nudging

def week_sunday(label):
    m = re.match(r"(\d{4})-W(\d{2})$", label)
    if not m:
        return None
    try:
        monday = datetime.date.fromisocalendar(int(m.group(1)), int(m.group(2)), 1)
    except ValueError:
        return None
    return monday + datetime.timedelta(days=6)

# Latest date any weekly review covered through.
last_review = None
for f in glob.glob(os.path.join(weekly_dir, "*.md")):
    covered = None
    try:
        with open(f) as fh:
            m = re.search(r"Dates:\s*\d{4}-\d{2}-\d{2}\s*→\s*(\d{4}-\d{2}-\d{2})", fh.read())
        if m:
            covered = datetime.date.fromisoformat(m.group(1))
    except (OSError, ValueError):
        covered = None
    if covered is None:  # fall back to the ISO-week Sunday from the filename
        covered = week_sunday(os.path.basename(f)[:-3])
    if covered and (last_review is None or covered > last_review):
        last_review = covered

# Plan-my-day entries (YYYY-MM-DD.md), and which fall after the last review.
plan_dates = []
for f in glob.glob(os.path.join(plan_dir, "*.md")):
    try:
        plan_dates.append(datetime.date.fromisoformat(os.path.basename(f)[:-3]))
    except ValueError:
        pass
plan_dates.sort()
unreviewed = [d for d in plan_dates if last_review is None or d > last_review]

# Anchor the span on the last review covered-through date, else oldest plan.
anchor = last_review if last_review is not None else (unreviewed[0] if unreviewed else None)
if anchor is None:
    print("none")  # nothing reviewed and nothing planned yet
    sys.exit(0)

days = (today - anchor).days
count = len(unreviewed)
last_label = last_review.isoformat() if last_review is not None else "never"
if days >= THRESHOLD or (last_review is None and count >= THRESHOLD):
    print(f"due {days} {count} {last_label}")
else:
    print("current")  # < 7 days since the last review — too soon to nudge
PYEOF
)"

# Month-boundary nudge signal: suggest /monthly-review in the first or last 3
# days of a month so the user sets (or closes) their monthly goals.
MONTH_BOUNDARY_SIGNAL="$(python3 - "$TODAY" <<'PYEOF'
import sys, datetime
today = datetime.date.fromisoformat(sys.argv[1])
day = today.day
import calendar
last_day = calendar.monthrange(today.year, today.month)[1]
if day <= 3:
    print(f"near_start {day}")
elif day >= last_day - 2:
    days_left = last_day - day
    print(f"near_end {days_left}")
else:
    print("none")
PYEOF
)"

# Habits surfacing. Every helper is a no-op (empty output) when the user hasn't
# set anything up, so this costs nothing until they opt in. (Reminders are NOT
# surfaced or fired here: /remind creates Apple Reminders (EKReminder), which are
# NOT Calendar events and are not read here; /remind-blocking overlays are
# time-sensitive and stay self-contained in their own poller, by design.)
# Today's Apple Calendar events (any commitments the user placed on the calendar),
# recurrences expanded for today. These are HARD time anchors the day is built
# around. No-op (empty) if osascript/Calendar is unavailable.
CALENDAR_TODAY="$(pbrain_calendar_today "$TODAY" || true)"
[[ -n "${CALENDAR_TODAY//[[:space:]]/}" ]] || CALENDAR_TODAY="(none)"
# Sync recent habit-tracking md into the DB so the rollup reflects them.
pbrain_habits_sync_range 7 || true
HABITS_ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
[[ -n "${HABITS_ROLLUP//[[:space:]]/}" ]] || HABITS_ROLLUP="(no habit data)"
if [[ -f "$(pbrain_habits_profile_file)" ]]; then HABITS_SETUP_NEEDED=no; else HABITS_SETUP_NEEDED=yes; fi
HABITS_CMD="$(pbrain_habits_cmd 2>/dev/null || true)"
HABITS_TRACK_FILE="$(pbrain_habit_track_file "$TODAY" 2>/dev/null || echo "$VAULT_DIR/life/habit-tracking/$TODAY.md")"
# If a habits profile exists, today's tracker is created automatically (no offer).
# track-init is idempotent — re-running on an existing file is a no-op.
HABITS_TRACK_CREATED=no
if [[ "$HABITS_SETUP_NEEDED" == no ]]; then
  if [[ ! -f "$HABITS_TRACK_FILE" ]]; then HABITS_TRACK_CREATED=yes; fi
  pbrain_habit_track_init "$TODAY" >/dev/null 2>&1 || true
  # Habit↔reminder upkeep (best-effort, silent, degrades without Reminders access):
  # ensure today's one-shots exist for linked habits, then pull any the user
  # already ticked off in the Reminders app back into today's tracker.
  if [[ -n "${HABITS_CMD//[[:space:]]/}" ]]; then
    bash "$HABITS_CMD" reminders-ensure --date "$TODAY" >/dev/null 2>&1 || true
    bash "$HABITS_CMD" reminders-sync   --date "$TODAY" >/dev/null 2>&1 || true
    # Activity-aware reconciliation (deterministic, best-effort, silent): when
    # today's fitness entry names a chosen activity, align the matching habit's
    # reminder and cancel + auto-skip the scheduled-but-not-chosen fitness habits
    # (e.g. the blanket reminders-ensure above just created the Gym 12:30 one-shot
    # because Monday=Gym, but the user logged Apple Fitness → drop Gym, set Apple
    # Fitness). No fitness entry / no focus → no-op (NO_MATCH), schedule stands.
    if [[ -n "${TODAY_FITNESS_ACTIVITY//[[:space:]]/}" ]]; then
      bash "$HABITS_CMD" fitness-reconcile --activity "$TODAY_FITNESS_ACTIVITY" --date "$TODAY" >/dev/null 2>&1 || true
    fi
    pbrain_habits_sync_range 1 >/dev/null 2>&1 || true   # re-mirror any pulled marks
    HABITS_ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
    [[ -n "${HABITS_ROLLUP//[[:space:]]/}" ]] || HABITS_ROLLUP="(no habit data)"
  fi
fi
HABITS_TODAY_MD="$(cat "$HABITS_TRACK_FILE" 2>/dev/null || echo "MISSING")"
REMIND_CMD="$(pbrain_reminders_cmd)"

# Laptop-tracking opt-in state (the tracker is OFF by default). active = the
# LaunchAgent has been installed; declined = the user said no (or disabled it),
# recorded in the nudge-off marker; not_setup = never touched → nudge ONCE.
LAPTOP_CMD="$_SCRIPT_DIR/laptop-tracking.sh"
LAPTOP_PLIST="$HOME/Library/LaunchAgents/com.pbrain.tracker.plist"
LAPTOP_NUDGE_OFF="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/tracker-nudge-off"
if [[ -f "$LAPTOP_PLIST" ]]; then
  LAPTOP_TRACKING_STATE=active
elif [[ -f "$LAPTOP_NUDGE_OFF" ]]; then
  LAPTOP_TRACKING_STATE=declined
else
  LAPTOP_TRACKING_STATE=not_setup
fi

cat <<PROMPT
PLAN_MY_DAY_SESSION
date: $TODAY
day_of_week: $DOW
current_time: $NOW_TIME (24h, local)
output_file: $OUT_FILE
profile_file: $PROFILE_FILE
weekly_review_signal: $WEEKLY_REVIEW_SIGNAL
month_boundary_signal: $MONTH_BOUNDARY_SIGNAL
habits_setup_needed: $HABITS_SETUP_NEEDED
habits_track_file: $HABITS_TRACK_FILE
habits_track_created: $HABITS_TRACK_CREATED
laptop_tracking_state: $LAPTOP_TRACKING_STATE
laptop_tracking_cmd: $LAPTOP_CMD
fitness_sleep: $FITNESS_SLEEP
diet_meal_times: $DIET_MEAL_TIMES
diet_today_exists: $DIET_TODAY_EXISTS
fitness_today_schedule: $TODAY_FITNESS_SCHEDULE
fitness_today_activity: ${TODAY_FITNESS_ACTIVITY:-(no fitness entry / focus not set)}
typical_day_present: $TYPICAL_DAY_PRESENT

=== PLANS PROFILE (the planning lens — current_focus, working_style, typical_day, daily_anchors, variation_rules, anti_patterns) ===
$PROFILE_JSON

=== TODAY'S FITNESS JOURNAL ===
$FITNESS_TODAY

=== RECENT FITNESS ACTIVITY (last ~4 days — context for the skip-fitness judgment) ===
$RECENT_FITNESS_ACTIVITY

=== TODAY'S DAILY JOURNAL ===
$DAILY_TODAY

=== RECENT DAYS (last 3 — compact shape digest, not full plans) ===
$RECENT_DAY_DIGEST

=== CARRY-FORWARD (unfinished tasks from the last day plan — offer as candidates today) ===
$CARRY_FORWARD

=== TODAY'S CALENDAR (Apple Calendar — hard time anchors for today) ===
$CALENDAR_TODAY

=== HABITS (this week / month vs each habit's criteria) ===
$HABITS_ROLLUP

=== TODAY'S HABIT TRACKER ===
$HABITS_TODAY_MD

---
PROMPT

# Planning instructions (the judgment layer) live in the externalized plan.txt,
# loaded only on this path. envsubst fills the date/command vars via an explicit
# allow-list; every other $-token (context field names, etc.) stays literal.
export TODAY DOW ISO_WEEK OUT_FILE REMIND_CMD
envsubst '$TODAY $DOW $ISO_WEEK $OUT_FILE $REMIND_CMD' < "$_SCRIPT_DIR/templates/plan-my-day/plan.txt"

# Habit reconcile (silent if no habits profile): scan today's entries across the
# vault for evidence, mark states, and realign today's one-shot reminders to the
# planned times — the habit module owns this logic. Self-improvement runs after.
_pmd_habit_scan
pbrain_emit_self_improve "plan-my-day" "$PROFILE_FILE" "plans profile" || true
