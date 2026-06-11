#!/usr/bin/env bash
set -euo pipefail

# plan-my-day.sh
# Adaptive daily planner anchored on your goals. The goals profile is the
# COMBINATION VIEW over two living libraries:
#
#   <plan-dir>/.profile/goals-profile.vN.md — work_goals + life_goals (refs
#       into the libraries) + working_style (session length, breaks, work
#       hours/day, focus hours, last-block ceiling) + daily_anchors +
#       anti_patterns + personal_anchors. THE day-planning lens.
#   <plan-dir>/.profile/work-library.vN.md  — every project/thing worked on,
#       with rich context; enriched over time (LIVING document).
#   <plan-dir>/.profile/goals-library.vN.md — non-work goals (health,
#       creative, relationships…); LIVING document.
#
# Daily flow: wake time (read from today's fitness entry when present) →
# what's done since waking (backfilled, gap-free) → how many focus hours from
# now → block layout around the day's anchors (meal times from the diet
# profile, today's fitness session, habit reminders, calendar events) →
# allocate work from the goals onto the blocks → confirm → write.
#
# `plan-my-day.sh profile show|new|commit [base]` manages versions: drafts
# are editable, committed versions are final. Migration 0002 rebuilds the old
# Goals Profile.md into this store.
#
# `plan-my-day.sh task add|remove|list` revises TODAY'S already-written plan
# without rebuilding it: add/remove a task-log row and re-flow "Today at a
# glance" around the fixed anchors (both tables rewritten together). A no-op
# pointing at /plan-my-day when today's plan doesn't exist yet.
#
# Default destination:  $VAULT_DIR/life/daily-planning
# Overrides:
#   PBRAIN_VAULT             — vault root
#   PBRAIN_PLAN_DIR          — daily-plan dir (the .profile store lives inside)
#   PBRAIN_PLAN_PROFILE_FILE — explicit goals-profile file (bypasses the store)
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

# ---------------------------------------------------------------------------
# `profile` subcommand — manage the versioned planning profiles.
#   profile show | profile new [base] | profile commit [base]
#   base ∈ goals-profile (default) | work-library | goals-library
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "profile" ]]; then
  ACTION="${2:-show}"
  BASE="${3:-goals-profile}"
  case "$ACTION" in
    show)
      echo "PLAN_PROFILE_SHOW"
      for b in goals-profile work-library goals-library monthly-goals weekly-goals; do
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
      echo "  /plan-my-day profile new [goals-profile|work-library|goals-library]"
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
      echo "usage: plan-my-day.sh profile show|new|commit [goals-profile|work-library|goals-library|monthly-goals|weekly-goals]" >&2
      exit 2
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# `task` on a day with no plan yet is a clean no-op — handle it BEFORE the
# staged-migration / first-run-setup guards below, so a `task` verb never
# surprises the user with a setup interview or migration block. (When the plan
# DOES exist, a committed profile must too, and the full task handler runs
# after profile resolution — see further down.)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "task" && ! -f "$OUT_FILE" ]]; then
  echo "PLAN_MY_DAY_TASK_NO_PLAN"
  echo "action: ${2:-list}"
  echo "file: $OUT_FILE"
  echo ""
  echo "INSTRUCTIONS: There is no day plan for $TODAY yet, so there is nothing to"
  echo "edit. Tell the user to run /plan-my-day first to lay down today's plan —"
  echo "the task verb only revises an existing day, it never creates one. Stop here."
  exit 0
fi

# ---------------------------------------------------------------------------
# Staged migration 0002 — rebuild the old Goals Profile.md (or legacy
# plan-profile.json) into the store. An EXPLICIT profile override that points
# at a real file wins outright — the user told us which file to use.
# ---------------------------------------------------------------------------
if [[ ! -f "${PBRAIN_PLAN_PROFILE_FILE:-/nonexistent}" ]] \
   && declare -F pbrain_migration_pending >/dev/null \
   && pbrain_migration_pending 0002_goals_profile_restructure; then
  OLD_PROFILE="$VAULT_DIR/life/Goals Profile.md"
  OLD_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/plan-profile.json"
  echo "PLAN_MY_DAY_MIGRATION"
  echo "store: $STORE"
  echo "backup_dir: $VAULT_DIR/.pbrain/backup"
  echo ""
  echo "=== OLD GOALS PROFILE ($OLD_PROFILE) ==="
  cat "$OLD_PROFILE" 2>/dev/null || echo "(none)"
  echo ""
  echo "=== LEGACY JSON PROFILE ($OLD_JSON) ==="
  cat "$OLD_JSON" 2>/dev/null || echo "(none)"
  echo ""
  echo "=== RECENT DAY PLANS (project names for the work library) ==="
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
  cat <<MIGRATE

---
INSTRUCTIONS — one-time migration to the new planning profile store. Do not
plan any day yet. Tell the user: pbrain now splits the goals lens into a
goals profile + a work library + a goals library, all versioned; you'll walk
their existing profile across (a few minutes, their data carries over — plus
a few new questions).

Step 1 — Validate the old data PART BY PART (not in one go):
  - Each old horizon goal: confirm, update, or drop — quote it back. Classify
    every kept goal as WORK (projects, career, money) or LIFE (health, body,
    creative, relationships, inner work). For each kept goal, ask the user to
    assign a priority (1 = most important, higher = lower priority).
  - Note: the old "current focus" concept is GONE — the goals profile itself
    is the focus now. Do not carry it over.
  - working_style: confirm what exists, then ASK what the old data lacks:
      - preferred work-session length (minutes) if not present
      - break preference: how long between sessions, and what break
        activities they actually like (the menu the plan rotates through)
      - total work hours per day they realistically want
      - the important focus hours of their day (e.g. "9-12, 15-17")
      - the LAST block time of day — when the final work block must end
  - daily_anchors: carry over what exists (wake/workout/lunch/dinner/walk/
    bed); confirm briefly.
  - anti_patterns + personal_anchors: confirm, prune anything stale.

Step 2 — From the recent day plans above + the old work goals, seed the WORK
LIBRARY: one entry per project/initiative the user actually works on — id,
name, one-line summary, status, and a context paragraph rich enough that a
future plan can pull it in for block descriptions. Confirm the list with the
user.

Step 3 — Write THREE files into $STORE (mkdir -p first), all committed v1:

  $STORE/goals-profile.v1.md:
  ---
  type: goals-profile
  date: $TODAY
  tags: []
  version: 1
  committed: true
  ---

  # Goals profile

  \`\`\`json
  {"created": "$TODAY",
   "work_goals": [{"id": "<work-library id>", "goal": "...",
                   "deadline": "YYYY-MM or ongoing", "success_looks_like": "...",
                   "priority": 1}],
   "life_goals": [{"id": "<goals-library id>", "goal": "...",
                   "deadline": "ongoing", "success_looks_like": "...",
                   "priority": 1}],
   "maintenance_mode": [],
   "working_style": {"session_length_min": 90, "break_min": 30,
     "break_activities": ["..."], "work_hours_per_day": 7,
     "focus_hours": "9-12,15-17", "last_block_end": "HH:MM",
     "energy_peak": "...", "day_wreckers": ["..."]},
   "daily_anchors": {"wake_time": "HH:MM", "workout_time": "HH:MM",
     "lunch_time": "HH:MM", "dinner_time": "HH:MM",
     "walk_time": "HH:MM or null", "bed_target": "HH:MM"},
   "anti_patterns": ["..."],
   "personal_anchors": {"relationships": ["..."],
     "creative_pursuits": ["..."], "health_habits": ["..."]},
   "notes": "..."}
  \`\`\`

  $STORE/work-library.v1.md (type: work-library):
  \`\`\`json
  {"created": "$TODAY", "projects": [
    {"id": "<slug>", "name": "...", "summary": "...", "status": "active",
     "context": "rich working context, enriched over time",
     "last_worked": "YYYY-MM-DD"}]}
  \`\`\`

  $STORE/goals-library.v1.md (type: goals-library):
  \`\`\`json
  {"created": "$TODAY", "goals": [
    {"id": "<slug>", "goal": "...",
     "category": "health|creative|relationships|financial|personal",
     "deadline": "ongoing", "success_looks_like": "..."}]}
  \`\`\`

  Every work_goals entry references a work-library project id; every
  life_goals entry references a goals-library goal id. The profile is the
  combination view over the two libraries.

Step 4 — Park the old profile so nothing is lost (do NOT delete):
  mkdir -p "$VAULT_DIR/.pbrain/backup"
  mv "$OLD_PROFILE" "$VAULT_DIR/.pbrain/backup/" 2>/dev/null
  (Leave $OLD_JSON in place if it exists — superseded, not harmful.)

Step 5 — Record the migration so it never re-runs:
  bash "$_SCRIPT_DIR/../lib/migrations.sh" record 0002_goals_profile_restructure

Step 6 — Confirm: "Goals profile migrated → $STORE (profile + work library +
goals library). Re-run /plan-my-day to plan today." Stop here.
MIGRATE
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolution — explicit override file, else latest committed in the store.
# ---------------------------------------------------------------------------
PROFILE_FILE="${PBRAIN_PLAN_PROFILE_FILE:-}"
if [[ -n "$PROFILE_FILE" && ! -f "$PROFILE_FILE" ]]; then PROFILE_FILE=""; fi
[[ -n "$PROFILE_FILE" ]] || PROFILE_FILE="$(pbrain_profile_latest "$STORE" goals-profile)"

# ---------------------------------------------------------------------------
# PHASE 0 — first-run setup (no committed goals profile anywhere).
# ---------------------------------------------------------------------------
if [[ -z "$PROFILE_FILE" ]]; then
  DRAFT="$(pbrain_profile_draft "$STORE" goals-profile)"
  if [[ -n "$DRAFT" ]]; then
    echo "PLAN_PROFILE_DRAFT_OPEN"
    echo "draft: $DRAFT"
    echo ""
    cat "$DRAFT"
    echo ""
    echo "---"
    echo "A goals-profile draft is already open (shown above). Review it with the user,"
    echo "apply any edits they want (keep the fenced JSON valid), then finalize with:"
    echo "  bash \"$_SCRIPT_DIR/plan-my-day.sh\" profile commit goals-profile"
    echo "Daily planning starts once the profile is committed."
    exit 0
  fi
  cat <<SETUP
PLAN_MY_DAY_SETUP_PROFILE
store: $STORE

INSTRUCTIONS — first-time setup. Do not generate any plan yet. You're helping
the user lay down the goals lens that every future /plan-my-day will use:
a goals profile (the lens) built on a work library + a goals library.

Step 1 — Tell the user this is a one-time setup (changeable later with
/plan-my-day profile new). Frame it warmly: "Let's get a clear picture of
what you're trying to push forward right now — that way each daily plan is
actually anchored on what matters to you, not just a generic to-do list."

Step 2 — Interview the user. Ask in 2–3 batches (not all at once, not one at
a time). Cover everything below — skip a sub-question only if it clearly
doesn't apply.

  Work goals (projects, career, money — 3–12 months out)
  - What are the 1–5 things you're actively trying to build or achieve?
    Phrase each as a concrete outcome. For each: rough deadline or "ongoing",
    what success looks like, and a priority (1 = most important).
  - For each, capture the PROJECT behind it for the work library: a one-line
    summary plus a short context paragraph (what it is, where it stands,
    what kind of work it needs).

  Life goals (the non-work side)
  - Health/body, creative pursuits, relationships, inner work, finances —
    what are you building there? Each with a category and what success
    looks like. These seed the goals library.

  Working style
  - Typical weekday: when do you actually do focused work? Which hours of
    the day are your IMPORTANT focus hours (e.g. "9-12, 15-17")?
  - How many total work hours per day do you realistically want?
  - Preferred work-session length? (45 / 60 / 90 / 120 min)
  - Break preference: how long between sessions, and what restful break
    activities do you actually like (short walk, a couple of games, snack
    prep, stretch — the menu the plan rotates through)?
  - When must the LAST work block of the day end?
  - Energy peak: morning / afternoon / night / mixed?
  - Anything that wrecks your day if it slips?

  Daily time anchors (the fixed skeleton)
  - Usual wake time, workout time, lunch time, dinner time, walk (if any),
    bed target.

  Anti-patterns to actively avoid
  - What behaviours sabotage you? (doomscrolling, late nights, gaming
    benders, …) These feed the "Avoiding today" block when relevant.

  Personal anchors
  - Relationships to stay close to (first names/labels), creative pursuits,
    health/movement non-negotiables.

Step 3 — Write THREE files into $STORE (mkdir -p first), all committed v1,
each with frontmatter (type, date: $TODAY, tags: [], version: 1,
committed: true), a heading, and a fenced json block:

  goals-profile.v1.md — json:
  {"created": "$TODAY",
   "work_goals": [{"id": "<work-library id>", "goal": "...", "deadline": "...",
                   "success_looks_like": "...", "priority": 1}],
   "life_goals": [{"id": "<goals-library id>", "goal": "...", "deadline": "...",
                   "success_looks_like": "...", "priority": 1}],
   "maintenance_mode": [],
   "working_style": {"session_length_min": 90, "break_min": 30,
     "break_activities": ["..."], "work_hours_per_day": 7,
     "focus_hours": "...", "last_block_end": "HH:MM",
     "energy_peak": "...", "day_wreckers": ["..."]},
   "daily_anchors": {"wake_time": "", "workout_time": "", "lunch_time": "",
     "dinner_time": "", "walk_time": null, "bed_target": ""},
   "anti_patterns": ["..."],
   "personal_anchors": {"relationships": ["..."], "creative_pursuits": ["..."],
     "health_habits": ["..."]},
   "notes": "free-form anything important not captured above"}

  work-library.v1.md — json:
  {"created": "$TODAY", "projects": [
    {"id": "<slug>", "name": "...", "summary": "...", "status": "active",
     "context": "...", "last_worked": null}]}

  goals-library.v1.md — json:
  {"created": "$TODAY", "goals": [
    {"id": "<slug>", "goal": "...", "category": "...", "deadline": "...",
     "success_looks_like": "..."}]}

  - Every work_goals/life_goals entry references a library id — the profile
    is the combination view over the two libraries.
  - Use the user's actual words where possible — don't sanitize their voice.
  - Fewer goals than the maximum is fine. Don't pad.
  - The libraries are LIVING documents: entries are appended/enriched in
    place over time; versions only mint on structural rebuilds.

Step 4 — Confirm: "Goals profile saved → $STORE (profile + work library +
goals library). Edit any time with /plan-my-day profile new. Now re-run
/plan-my-day and I'll plan today against these goals."
SETUP
  exit 0
fi

# Extract + validate the profile JSON (carried in a fenced JSON block).
PROFILE_JSON="$(pbrain_profile_json "$PROFILE_FILE")"

if [[ -z "$PROFILE_JSON" ]]; then
  cat <<ERR
PLAN_MY_DAY_CONFIG_ERROR
profile_file: $PROFILE_FILE

The goals profile at $PROFILE_FILE has no readable JSON block (or it is
malformed). Fix the fenced JSON manually, or mint a fresh version with
/plan-my-day profile new goals-profile.
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

# Weekly and monthly goals — resolved by period (draft or committed).
WEEKLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$STORE" weekly-goals "$ISO_WEEK" || true)"
MONTHLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$STORE" monthly-goals "$MONTH_YEAR" || true)"
WEEKLY_GOALS_CONTENT="(not set up — /weekly-review creates this week's goals)"
MONTHLY_GOALS_CONTENT="(not set up — /monthly-review creates this month's goals)"
[[ -n "$WEEKLY_GOALS_FILE" ]] && WEEKLY_GOALS_CONTENT="$(cat "$WEEKLY_GOALS_FILE" 2>/dev/null || true)"
[[ -n "$MONTHLY_GOALS_FILE" ]] && MONTHLY_GOALS_CONTENT="$(cat "$MONTHLY_GOALS_FILE" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# `task` subcommand — revise an EXISTING day's plan without rebuilding it.
#   task add | task remove | task list
# Mirrors the `profile` dispatch. It ONLY edits a day that already exists —
# a clear no-op (pointing at /plan-my-day) when today's plan file is absent,
# so it never creates a day. Needs the resolved profile + weekly/monthly
# goals above (tie resolution, suggest-tier) so it sits after that block.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "task" ]]; then
  TASK_ACTION="${2:-list}"
  case "$TASK_ACTION" in
    add|remove|list) ;;
    *)
      echo "usage: plan-my-day.sh task add|remove|list" >&2
      exit 2
      ;;
  esac

  # The no-plan-yet case was already handled up top (before the migration /
  # first-run guards); reaching here means today's plan file exists.
  TASK_HABITS_CMD="$(pbrain_habits_cmd 2>/dev/null || true)"

  echo "PLAN_MY_DAY_TASK"
  echo "action: $TASK_ACTION"
  echo "file: $OUT_FILE"
  echo "today: $TODAY"
  echo "now_time: $NOW_TIME"
  echo "weekly_goals_file: ${WEEKLY_GOALS_FILE:-(not set up yet)}"
  echo "monthly_goals_file: ${MONTHLY_GOALS_FILE:-(not set up yet)}"
  echo "habits_cmd: ${TASK_HABITS_CMD:-(unavailable)}"
  echo ""
  echo "=== TODAY'S PLAN ($OUT_FILE) ==="
  cat "$OUT_FILE"
  echo ""
  echo "=== GOALS PROFILE (working_style + work/life goals) ==="
  echo "$PROFILE_JSON"
  echo ""
  echo "=== WEEKLY GOALS ==="
  echo "$WEEKLY_GOALS_CONTENT"
  echo ""
  echo "=== MONTHLY GOALS ==="
  echo "$MONTHLY_GOALS_CONTENT"
  echo ""

  if [[ "$TASK_ACTION" == "list" ]]; then
    cat <<'TASKLIST'
---
INSTRUCTIONS — task list. Show the user the rows of today's "## Task log"
table above as a short numbered list: number, task, tie, priority,
difficulty, and status (planned / done / partial / dropped / carried).
Do NOT rewrite the file and do NOT touch "Today at a glance". If the table
has no task rows yet, say so in one line. Stop here.
TASKLIST
    exit 0
  fi

  cat <<TASKEDIT
---
INSTRUCTIONS — task $TASK_ACTION. You are revising TODAY'S EXISTING plan
($OUT_FILE), not rebuilding it. The user's request (in the conversation) names
the task to $TASK_ACTION; map their natural language to the row(s) below. Keep
the user's voice; do not re-plan the whole day.

The plan carries TWO tables that must stay in sync:
  • "## Today at a glance" — the gap-free, overlap-free schedule (wake → bed),
    24h HH:MM–HH:MM rows. FIXED anchors already placed here: calendar events,
    meal slots, the fitness session, habit 🔔 reminder rows, and ✓ backfilled
    done rows. Work blocks flow AROUND those anchors.
  • "## Task log" — one row per task: Task | Tie | Priority | Difficulty |
    Done at | Status | Notes. /end-of-day fills Done at + Status.

WORKING STYLE (from the goals profile above): use working_style.session_length_min
for block size, working_style.break_min for the gap between blocks (rotate
working_style.break_activities, never the same one back-to-back, respect
anti_patterns), and NEVER schedule a work block past working_style.last_block_end.
TASKEDIT

  if [[ "$TASK_ACTION" == "add" ]]; then
    cat <<'TASKADD'

For `task add`:
1. TIE the new task to a goal. Default menu = this week's WEEKLY GOALS (above),
   ordered priority then difficulty; fall back to MONTHLY GOALS, then the
   profile's work_goals/life_goals. Set Tie to the matched goal id/name.
2. SUGGEST-TIER when the task ties to no weekly goal (same flow as a normal
   plan):
     • A clear, scoped, one-week piece of work → offer once: "This isn't in
       your weekly goals — add it to this week's weekly-goals draft?" On yes,
       edit the file at weekly_goals_file IN PLACE (append a goal entry with the
       next available priority, difficulty: normal, status: active; keep the
       fenced JSON valid). If weekly_goals_file is "(not set up yet)", say they
       can run /weekly-review to set the week up — don't block.
     • A broader new direction → offer: "add it to this month's monthly goals
       (profile new monthly-goals) or the goals profile (profile new
       goals-profile)?" Take their pick. One sentence, never block.
   A task tied to nothing is fine: Tie = "—", priority = "—", difficulty = "—".
3. PRIORITY + DIFFICULTY. Inherit priority from the tied goal when there is one;
   otherwise ask (1 = most important). Ask for difficulty
   (easy/normal/hard/nightmare) if you can't infer it.
4. APPEND a row to "## Task log": Task | Tie | Priority | Difficulty | (Done at
   blank) | planned | (Notes optional). Leave existing rows untouched.
5. RE-FLOW "Today at a glance": slot ONE new work block (session_length_min,
   with a break_min break separating it from an adjacent block) into the next
   free gap that fits, honoring the fixed anchors and the last_block_end ceiling.
   - If it fits: insert the block; keep the table gap-free and overlap-free
     (adjust neighbouring rest/transition rows as needed).
   - If NOTHING fits before last_block_end: do NOT silently overflow. Tell the
     user it doesn't fit and offer to (a) place it tomorrow, (b) drop/shrink an
     existing block to make room, or (c) extend past last_block_end just today.
6. If a re-flowed block lands at a specific clock time AND corresponds to a
   habit with a linked one-shot reminder, realign it (best-effort, silent on
   failure), using habits_cmd above:
     bash "<habits_cmd>" reminders-reschedule --habit "<name>" --time "HH:MM" --date $TODAY
   Skip silently on NOT_LINKED / NOT_FOUND / (unavailable).
TASKADD
  else
    cat <<'TASKREMOVE'

For `task remove`:
1. IDENTIFY the row the user means in "## Task log" (by name or by its number in
   the list — quote it back so there's no ambiguity).
2. CONFIRM-ON-CLOSED-ROW: if that row's Status is already filled (anything other
   than "planned" — done / partial / dropped / carried, or it has a Done at
   time), ask the user to confirm before removing it, because /end-of-day's goal
   rollup would otherwise silently lose a closed task. On a plain "planned" row,
   remove without the extra prompt.
3. DROP the row from "## Task log".
4. RE-FLOW "Today at a glance": free the removed task's block. Either pull the
   following work blocks earlier to close the gap, OR leave the freed span as a
   rest/buffer row — pick whichever keeps the day sensible and SAY which you did.
   Keep the table gap-free and overlap-free; never disturb the fixed anchors
   (calendar, meals, fitness, habit 🔔) or ✓ done rows.
TASKREMOVE
  fi

  cat <<TASKWRITE

After editing, REWRITE BOTH TABLES TOGETHER and save the full plan back to
$OUT_FILE (the two tables must never drift apart). Then show the updated
"Today at a glance" + "Task log" and confirm in one line what changed (e.g.
"Added 'ship diet refactor' → Block 3 (15:30–17:00), tied to lettuce-algo.").
Do not re-run the full daily check-in. Stop here.
TASKWRITE
  exit 0
fi

# ---------------------------------------------------------------------------
# PHASE 1 — today's plan already exists → review/update mode.
# ---------------------------------------------------------------------------
if [[ -f "$OUT_FILE" ]]; then
  echo "PLAN_MY_DAY_EXISTING"
  echo "file: $OUT_FILE"
  echo ""
  cat "$OUT_FILE"
  echo ""
  echo "---"
  echo "Today's day plan already exists. Show it to the user and ask if they want to update the 'How it went' section, add more items, or revise blocks."
  exit 0
fi

# ---------------------------------------------------------------------------
# PHASE 2 — daily flow.
# ---------------------------------------------------------------------------
FITNESS_TODAY="$(cat "$FITNESS_DIR/$TODAY.md" 2>/dev/null || echo "MISSING")"
DAILY_TODAY="$(cat "$DAILY_DIR/$TODAY.md" 2>/dev/null || echo "MISSING")"

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
[[ -n "${DIET_MEAL_TIMES//[[:space:]]/}" ]] || DIET_MEAL_TIMES="(no diet profile — use the goals-profile daily_anchors / timing signal)"

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

RECENT_PLANS="$(python3 - "$PLAN_DIR" <<'PYEOF'
import os, glob, sys
d = sys.argv[1]
files = sorted(glob.glob(os.path.join(d, "*.md")))[-7:]
parts = []
for f in files:
    try:
        with open(f) as fh:
            parts.append(f"=== {os.path.basename(f)} ===\n{fh.read()}")
    except Exception:
        pass
print("\n\n".join(parts) if parts else "(no previous plans)")
PYEOF
)"

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

# Learned anchor times from past plans — the FALLBACK when the profiles have
# no explicit time for an anchor.
TIMING_SIGNAL="$(python3 - "$PLAN_DIR" <<'PYEOF'
import os, glob, re, sys, collections
plan_dir = sys.argv[1]
files = sorted(glob.glob(os.path.join(plan_dir, "*.md")))[-21:]
categories = {
    "workout": [r"\b(gym|workout|fitness|apple fitness|lower body|upper body|push|pull|legs|cardio|football)\b"],
    "lunch": [r"\blunch\b"],
    "dinner": [r"\bdinner\b"],
    "walk": [r"\b(outdoor walk|night walk|evening walk|morning walk)\b"],
    "wind_down": [r"\b(wind-down|low-light close|hygiene, bed|bed)\b"],
}
times = collections.defaultdict(list)
for f in files:
    try:
        fh = open(f)
        text = fh.read()
        fh.close()
    except Exception:
        continue
    for m in re.finditer(r"\|\s*(\d{1,2}):(\d{2})[^|]*\|([^|]+)\|", text):
        start_h, start_m, action = m.group(1), m.group(2), m.group(3).lower()
        start_min = int(start_h) * 60 + int(start_m)
        for cat, patterns in categories.items():
            if any(re.search(p, action) for p in patterns):
                times[cat].append(start_min)
                break
def fmt(cat):
    lst = times.get(cat, [])
    if not lst:
        return "unknown"
    avg = sum(lst) / len(lst)
    h = int(avg) // 60
    m_val = int(avg) % 60
    spread = (max(lst) - min(lst)) // 60 if len(lst) > 1 else 0
    return "%02d:%02d (+/-%dh from %d plans)" % (h, m_val, spread, len(lst))
for cat in ["workout", "lunch", "dinner", "walk", "wind_down"]:
    print("- %s: %s" % (cat, fmt(cat)))
PYEOF
)"

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
iso_week: $ISO_WEEK
weekly_goals_file: ${WEEKLY_GOALS_FILE:-(not set up yet)}
monthly_goals_file: ${MONTHLY_GOALS_FILE:-(not set up yet)}
habits_setup_needed: $HABITS_SETUP_NEEDED
habits_track_file: $HABITS_TRACK_FILE
habits_track_created: $HABITS_TRACK_CREATED
laptop_tracking_state: $LAPTOP_TRACKING_STATE
laptop_tracking_cmd: $LAPTOP_CMD
fitness_sleep: $FITNESS_SLEEP
diet_meal_times: $DIET_MEAL_TIMES
fitness_today_schedule: $TODAY_FITNESS_SCHEDULE

=== GOALS PROFILE ===
$PROFILE_JSON

=== WORK LIBRARY (project context for block descriptions) ===
$WORK_LIB_CONTENT

=== GOALS LIBRARY (non-work goals) ===
$GOALS_LIB_CONTENT

=== WEEKLY GOALS (current week: $ISO_WEEK) ===
$WEEKLY_GOALS_CONTENT

=== MONTHLY GOALS (current month: $MONTH_YEAR) ===
$MONTHLY_GOALS_CONTENT

=== TODAY'S FITNESS JOURNAL ===
$FITNESS_TODAY

=== TODAY'S DAILY JOURNAL ===
$DAILY_TODAY

=== TIMING SIGNAL (learned anchor times from last 21 plans — FALLBACK when profiles lack a time) ===
$TIMING_SIGNAL

=== RECENT DAY PLANS (last 7) ===
$RECENT_PLANS

=== CARRY-FORWARD (unfinished tasks from the last day plan — offer as candidates today) ===
$CARRY_FORWARD

=== TODAY'S CALENDAR (Apple Calendar — hard time anchors for today) ===
$CALENDAR_TODAY

=== HABITS (this week / month vs each habit's criteria) ===
$HABITS_ROLLUP

=== TODAY'S HABIT TRACKER ===
$HABITS_TODAY_MD

---
INSTRUCTIONS — follow these steps in order. Keep the tone warm and concise.

Step 0 — Preflight checks (do these silently, then surface in one short message):
  - PREFERENCE OVERRIDE (check FIRST): if the injected USER PREFERENCES block
    (global or per-command) says to skip the fitness-journal gate/nudge, SKIP
    the FITNESS GATE entirely — go straight to Step 1/Step 2 and just ask once
    "Roughly when's your physical activity today, and what is it?" if you need
    it for the plan. A standing preference always overrides this gate.
  - FITNESS GATE (do this BEFORE anything in Step 1 or Step 2): If TODAY'S
    FITNESS JOURNAL == "MISSING", your first message must be ONLY about the
    fitness journal — do NOT show the Step 1 lens or start the Step 2 check-in
    yet. Ask: "Your fitness journal isn't done yet — running /fitness-journal
    first means I can slot your workout into the day (and it captures your
    wake time for me). Want to do that first, or plan around it?" Then STOP
    and wait for their answer.
      - If they choose the fitness journal first: let them run it. When they
        come back (the fitness file now exists), proceed to Step 1 + Step 2.
      - If they say plan around it: ask once "Roughly when's your physical
        activity today, and what is it? (e.g. gym 4pm, football 7pm, rest
        day)", take their answer, and proceed.
    The daily-journal nudge and weekly-review nudge below may ride along in
    this same first message; the Step 1 lens and Step 2 questions never do.
  - If TODAY'S FITNESS JOURNAL exists, there is no gate — go straight through.
  - If TODAY'S DAILY JOURNAL == "MISSING": gently mention "Heads up: today's
    /journal is empty too — you can fill it in later." Do not block.
  - WEEKLY REVIEW (Mondays only) — read \`weekly_review_signal\` above:
      - \`none\` → not a Monday, or nothing to review yet: say nothing.
      - \`current\` → fewer than 7 days since the last weekly review: say nothing.
      - \`due <days> <plans> <last_date|never>\` → suggest once, don't block:
        "It's Monday and it's been <days> days since your last weekly review
        (\`<last_date>\`), with <plans> day-plans since — want to run
        /weekly-review first? Or I plan now and you do it later." If
        \`<last_date>\` is \`never\`, say it's been <days> days of planning with
        no weekly review yet. If they say plan now, continue; offer to remind
        them at the end.
  - MONTH BOUNDARY — read \`month_boundary_signal\` above:
      - \`none\` → not near a month boundary: say nothing.
      - \`near_start <days>\` → first 1–3 days of a new month: suggest ONCE,
        don't block: "It's the start of a new month — want to run
        /monthly-review to set your monthly goals before planning today?
        Or I'll plan now and you can do it later." Skip if the user's
        preferences say not to nudge about monthly-review.
      - \`near_end <days>\` → last 1–3 days of the month: suggest ONCE:
        "Month's almost done — want to close it out with /monthly-review
        first? Or plan the day now." Skip if preferences say not to nudge.
  - CALENDAR — read the TODAY'S CALENDAR block above. These are HARD ANCHORS —
    the day is built around them. Surface today's TIMED items in your first
    message as fixed points. Note ALLDAY items as context; mention FREQUENT
    pings once, briefly. If "(none)", say nothing. They feed Step 3 as
    non-negotiable rows — do NOT ask the user to restate them.
  - HABITS — read the HABITS block + \`habits_setup_needed\` above:
      - If \`habits_setup_needed\` == yes: mention ONCE, don't block — "You
        haven't set up habit tracking yet — /habits lets you pick a few habits
        to build or cap, and I'll surface them here. Want to set it up later?"
        Skip if the user's preferences say not to nag about habits. A "stop
        asking about habits" is a GLOBAL standing preference — capture it in
        the global prefs via the self-improve loop.
      - If a HABITS rollup is present: note anything that needs attention
        today — a limit habit at/over cap (⚠️), a high-priority build habit
        lagging, or a recurring touchpoint going stale (a relationship call,
        a creative session, a walk — IF the user tracks it as a habit; habits
        are the ONLY cadence source now) — and factor it into the plan. One
        line, not a lecture.
  - LAPTOP TRACKING — read \`laptop_tracking_state\` above. It's OFF by default:
      - \`not_setup\` → mention ONCE, don't block — "Want me to track where
        your laptop time goes (which apps, which sites)? /laptop-tracking
        start turns on a quiet background tracker and you'll get a daily
        breakdown. Or say no and I won't ask again." If yes → tell them to run
        \`/laptop-tracking start\` (then \`/laptop-tracking access\`). If no /
        stop asking → run \`bash "\$laptop_tracking_cmd" decline\`. Skip the
        nudge entirely if preferences say not to nag about it.
      - \`active\` or \`declined\` → say NOTHING about laptop tracking.

Step 1 — Show the user their current week's lens, briefly:
  Print 2-4 lines max. Frame as the anchor for today, NOT as a quiz.
  - If WEEKLY GOALS are set (weekly_goals_file is not "(not set up yet)"):
    show those goals as bullets ordered by priority (1 = most important),
    noting difficulty where relevant. One line: the week (iso_week).
  - If no weekly goals but MONTHLY GOALS are set: show monthly goals bullets.
  - If neither: fall back to work_goals (priority order) + life_goals.
  Example:
    "Week W24 — anchoring on:
     • Ship Lettuce VC application — algo module (normal)
     • Meloro landing page (easy)
     Life: fit body · DJing · present for family"

Step 2 — Run the check-in as a SHORT CONVERSATION (not an exam, not a form).
  One thing (or a tight pair) per turn; let each answer steer the next.

  2a — WAKE TIME. Read \`fitness_sleep\` above:
    - If it has sleep_wake: do NOT ask — confirm in passing ("Up at
      {sleep_wake} per your fitness check-in — {sleep_hours}h of sleep.").
      If sleep_hours < 7, add one watch-out line.
    - If "(not recorded — ask the user)": open with "Before we plan — what
      time did you wake up?" (compute hours if they volunteer bed time too;
      flag < 7h).
  2b — BACKFILL. Ask: "What have you done since waking until now?" Take
    whatever they say (work, meals, errands, scrolling — all of it) and slot
    it into time ranges YOURSELF, marked ✓ — gap-free, no overlaps, from wake
    time to now. Fill unexplained spans with honest rest/transition rows. Do
    NOT interrogate them range by range — you place things, they correct.
    Fold a light energy read into this turn ("and how's the energy — rough
    number out of 10?").
  2c — FOCUS HOURS. Ask: "How many focused hours are you planning from now?"
    Then COMPUTE the block layout and SHOW it before going further:
      - blocks of working_style.session_length_min, separated by
        working_style.break_min breaks (rotate break_activities; never the
        same one back-to-back; respect anti_patterns),
      - laid around today's FIXED anchors: calendar events (zero variance),
        the fitness session (\`fitness_today_schedule\` or the user's stated
        time), meal times (\`diet_meal_times\`, shifted around the workout per
        the diet profile), habit reminder times (🔔 in the rollup),
        working_style.focus_hours preferred, nothing past
        working_style.last_block_end,
      - capped by the user's stated focus hours AND
        working_style.work_hours_per_day.
    Present: "That gives you N blocks: {compact list with times}. Want to add
    or reduce?" Adjust until they're happy.
  2d — WHAT TO WORK ON. Ask what goes into the blocks.
    FIRST, if the CARRY-FORWARD section above is not "(none)": surface those
    unfinished tasks up top — "Carried from {date}: {tasks}. Pull any of these
    into today?" Let the user keep, drop, or re-scope each. Carried tasks the
    user keeps go into the blocks (and the Task log) like any other task,
    inheriting their original tie/priority where known.
    THEN the menu, in priority order:
      1. WEEKLY GOALS (from the WEEKLY GOALS section), sorted by priority
         then difficulty (nightmare → hard → normal → easy). This is the
         default menu when the week is set up.
      2. If no weekly goals: fall back to MONTHLY GOALS (if set), then the
         profile's work_goals + life_goals (priority order).
    Pull CONTEXT from the WORK LIBRARY for block descriptions (what the
    project is, where it stands). Allocate tasks to blocks proportional to
    complexity/priority — a deep task gets 2–3 blocks, small things share one.
    Honor any explicit time the user states. Also collect, in passing: any
    locked-in commitments not already on the calendar, and anything to
    specifically avoid today (defaults to profile anti_patterns).
    SUGGEST-TIER: When the user names a task that ties to no weekly goal:
      - A clear, scoped, one-week piece of work → offer briefly: "This isn't
        in your weekly goals — want me to add it to this week's weekly-goals
        draft?" If yes, edit the draft at weekly_goals_file in place (add an
        entry with the next available priority, difficulty: normal). If no
        weekly-goals file exists yet, say they can run /weekly-review to set
        that up.
      - A broader new direction → offer: "This sounds like a new direction —
        add it to the goals profile (profile new goals-profile) or to this
        month's monthly goals (profile new monthly-goals)?" Take their pick.
      Keep the offer short — one sentence. Never block the planning on it.

Step 3 — Generate the full day plan draft in memory (do NOT write to disk yet).
  STRUCTURE: lead with a consolidated **Today at a glance** table (time range
  + action + tie). All subjective detail comes AFTER the table as supporting
  sections. The table is the operating doc.

  Table rules — ANCHOR-FIRST:
  a. CALENDAR EVENTS + locked-in commitments + explicit user-stated times are
     absolute — never shift them. Calendar items sit at their exact window.
     Two overlapping calendar items → keep both, flag the conflict.
  b. The day's anchors — fitness session, meal slots (at the diet-profile
     times, workout-shifted), walk, wind-down, bed — are the skeleton,
     scheduled around (a). Maximum 15–30 min variance from a profile/diet
     anchor time; prefer the TIMING SIGNAL average when a needed anchor has
     no profile time.
  c. The table ALWAYS starts at the user's actual wake time today (from 2a) —
     NEVER at current_time. Everything from 2b is backfilled as ✓ rows at its
     real time. The plan spans wake → bed.
  d. GAP-FREE & OVERLAP-FREE: every span from wake to bed is accounted for —
     no gaps, no overlapping rows. Fill holes with explicit rest / transition
     / meal / decompress rows. Backfilled rows tile cleanly too.
  e. Blocks: as many session_length_min blocks as 2c settled on, each labeled
     with its task(s), break rows woven between consecutive blocks (rotating
     break_activities). No break before the first block or after the last.
  f. 24h times (HH:MM–HH:MM) on every row. REQUIRED rows: wake/morning-start,
     workout (if any), every meal slot, walk (if anchored), wind-down, bed.
  g. Every row's Tie column maps to a work_goal/life_goal name, a category
     (Fit body, Rest, Eating, Relationships, Creative, Social), or "—".

  ---
  type: plan
  date: $TODAY
  day_of_week: $DOW
  week_period: $ISO_WEEK
  status: planned
  energy: {1-10 from 2b}
  sleep_hours: {from fitness_sleep or 2a — omit if unknown}
  focus_today: [{the work_goal/life_goal names today's blocks tie back to — empty array if none}]
  tags: []
  ---

  # Day Plan — $TODAY ($DOW)

  > {one short coaching note tuned to today's energy, the top block, fitness
  intent, and sleep if short (< 7h). 1-2 sentences. No platitudes.}

  ## Today at a glance

  | Time | Action | Tie |
  |---|---|---|
  | {HH:MM–HH:MM} | {concrete action; ✓ prefix for backfilled done rows} | {tie} |
  | ... | ... | ... |

  ## Task log

  | Task | Tie | Priority | Difficulty | Done at | Status | Notes |
  |---|---|---|---|---|---|---|
  | {task from 2d} | {weekly goal id or profile goal name} | {priority from the goal} | {difficulty: easy/normal/hard/nightmare} | | planned | |

  _(Done at and Status are filled by /end-of-day. One row per task. Tasks not tied to a goal: priority = — , difficulty = — .)_

  ## Anchoring on

  - {bullet per goal today's blocks tie back to — name + why it matters this
  week. If none tie back, one line: "Today's work isn't tied to a standing
  goal — that's fine, just noting it."}

  (Sections below are supporting detail — the schedule lives in the table.)

  ## Anchors

  - {fitness session — focus + intensity from the fitness journal, not the time}
  - {each locked-in commitment with brief context — skip if none}

  ## Blocks

  - {ONE bullet per block: **Block N (HH:MM–HH:MM):** task(s), concrete
  description + what "done" looks like — pull project context from the WORK
  LIBRARY. Annotate "→ <goal>" where it ties back.}
  - {one line on the break rhythm, e.g. "30-min breaks between blocks (walk /
  games / snack prep rotation)."}
  - Cap on intentional block time today: {from 2c}h — ceiling, not floor.

  ## Breaks & movement

  - {2-4 bullets: posture, short walks, sunlight, stretches — the move, not the clock}

  ## Eating

  - {breakfast/lunch/dinner — what to eat, not when; note the workout-shifted
  slot if today trains}
  - Hydration: {target}

  ## Rest

  - {1-2 lines on what NOT to do in the wind-down, tied to anti_patterns}

  ## Avoiding today

  - {union of what the user said in 2d + relevant profile anti_patterns, deduped}

  ## Notes

  - {1-3 bullets: fitness-work interactions, journal carryovers, day-wrecker
  signals, short-sleep flag}

  ---

  ## How it went (fill at end of day)

  ### Executive summary
  -

  ### Goal progress (vs the focus_today goals above)
  -

  ### Sleep
  -

  ### Carry-forward
  -

Step 4 — Show the full **Today at a glance** table and ask for confirmation:
  Show the table, briefly name how you split the tasks into blocks, then ask:
  "Does this look right? Re-split blocks, change times, swap or drop rows —
  just tell me. Say 'looks good' to save." Apply requested edits; repeat the
  updated table if changes were made. Once confirmed, write the complete
  plan — table + all sections — to $OUT_FILE.

Step 5 — After writing, confirm: "Saved → $OUT_FILE"

Step 5c — Reschedule habit reminders to planned times (silent, best-effort):
  For any table row whose action corresponds to a habit from today's tracker
  AND has an explicit start time, align that habit's one-shot Apple Reminder:
    bash "$HABITS_CMD" reminders-reschedule --habit "<name>" --time "HH:MM" --date $TODAY
  Only for habits at a specific clock time. NOT_LINKED / NOT_FOUND → skip
  silently. No user output for this step.

Step 6 — Reminders (only if relevant — don't force it):
  If anything time-bound came up while planning (a call at a set time, "pay X
  today") and it isn't already a pending reminder, offer ONCE to set it:
    bash "$REMIND_CMD" add --text "<clean text>" --due "<YYYY-MM-DD HH:MM>" [--repeat daily|weekdays|weekly|monthly]
  Resolve the due time relative to today ($TODAY) + the current time. Set it
  only on a yes. At most one short offer covering all of them.

Step 7 — Habit check-in (only if \`habits_setup_needed\` == no). At the very end:
  PREFERENCE OVERRIDE: if the injected USER PREFERENCES block says not to nag /
  ask about habits, skip this whole step.
  a) Today's tracker is ALREADY created — nothing to offer. One line: if
     \`habits_track_created\` == yes, "Set up today's habit tracker."; if
     \`no\`, "Today's habit tracker is ready."
  b) Show today's habit checklist from TODAY'S HABIT TRACKER — just the table
     rows, concise. Then ask ONCE:
       "Any you've already done today? Name them and I'll mark them now. Or
        skip — run /habits anytime, or /end-of-day consolidates."
  c) On any named habits, mark each one:
       bash "$HABITS_CMD" mark --habit "<name>" --date $TODAY
     Then push marks to Apple Reminders (best-effort, silent on failure):
       bash "$HABITS_CMD" reminders-sync --date $TODAY
     Confirm what was marked. One round only — don't loop asking for more.
PROMPT

# Habit extraction (silent if no habits profile): logs the tracked habits the
# user said they did / will do today. Self-improvement capture runs after.
pbrain_emit_habits_extract "plan-my-day" || true
pbrain_emit_self_improve "plan-my-day" "$PROFILE_FILE" "goals profile" || true
