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
# Daily flow: wake time (read from today's fitness entry when present) →
# what's done since waking (backfilled, gap-free) → how many focus hours from
# now → block layout around the day's anchors (meal times from the diet
# profile, today's fitness session, habit reminders, calendar events) →
# allocate work from the focus onto the blocks → confirm → write.
#
# `plan-my-day.sh profile show|new|commit [base]` manages versions: drafts
# are editable, committed versions are final. Rebuild flow 0002 rebuilds the
# old Goals Profile.md into this store.
#
# `plan-my-day.sh task add|remove|list` revises TODAY'S already-written plan
# without rebuilding it: add/remove a task-log row and re-flow "Today at a
# glance" around the fixed anchors (both tables rewritten together). A no-op
# pointing at /plan-my-day when today's plan doesn't exist yet.
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
  # NOTE: the typical_day + variation_rules JSON below must stay identical with
  # the other build block (PLAN_MY_DAY_SETUP_PROFILE) — exactly two copies, by
  # the self-contained-heredoc convention.
  cat <<REBUILD

---
INSTRUCTIONS — let's rebuild your planning foundation. Do not plan any day yet.
Tell the user: "Let's (re)build your plan — I'll carry your existing data across
and set up a plans profile (what you're focused on, your working style), a work
library (project cards), and a goals library (non-work goals). We'll also lock
in this month's and this week's focus while we're here."

Part A — Overall plans profile. Walk PART BY PART (not all at once):

  1. Working style. Confirm what the old profile has, then ask for anything
     missing:
     - preferred work-session length (minutes)
     - break preference: how long between sessions, what break activities they
       actually like (the rotation the plan uses)
     - total work hours per day they realistically want
     - their important focus hours (e.g. "9-12, 15-17")
     - the LAST block time of day — when the final work block must end
     - energy peak (morning/afternoon/night/mixed), day wreckers, and any other
       /plan-my-day preferences (e.g. "always surface carry-forward tasks first")
     Then confirm a short planning_guidelines paragraph — "Here's how I'll plan
     your day: [block sizing, anchor philosophy, what it optimises for]."

  2. current_focus. Walk each old goal PART BY PART — quote it back, confirm /
     update / drop. For each kept item:
     - classify as work (lib: "work") or life (lib: "goals")
     - track: professional | personal
     - horizon: short (3–6 months) | long (6+ months)
     - priority (1 = most important), deadline (YYYY-MM or "ongoing")
     - success_looks_like (short phrase)
     - context (working-notes paragraph — what it is, where it stands, what kind
       of effort it needs)
     Write the item into plans-profile current_focus AND register a short library
     card in work-library or goals-library:
       work-library card: id, name, shortcut (suggest a 2-3-letter alias,
         e.g. "lt" → Lettuce), category: "work", one-line summary, stable
         metadata (repo, stack, links), timeline: null
       goals-library card: id, name, shortcut, category (health|creative|
         relationships|financial|personal), one-line summary, timeline: null
     Old "current_focus" this-week-move entries are NOT carried (now weekly
     focus, Part C).

  3. Typical day. "Let's flesh your flat anchors into full padded workday +
     rest-day timelines." Walk the user through an average WORKDAY wake→bed,
     every activity with its time (wake/prep, workout, each meal, work blocks,
     walk, wind-down, bed), being GENEROUS with each block so real days leave
     slack to do EXTRA, never a deficit. Capture each segment as
     {slot, start, end, duration_min, category, flex} where category ∈
     wake|fitness|meal|work|movement|rest|bed and flex ∈ fixed (meals/wake/bed)
     | flex (work, walk, wind-down) | skippable (fitness). These are CEILINGS
     the planner may compress, never expand. Read it back; then repeat for a
     typical REST/weekend day. Ask which weekdays are rest days →
     typical_day.rest_days. Set typical_day.padded: true. DERIVE daily_anchors
     from the workday segments (wake←wake.start, workout←fitness.start,
     lunch/dinner←meal slots, walk←movement.start, bed_target←bed.start) — no
     separate anchors question. Then capture variation_rules once: non-gym
     fitness days → ask duration INCLUDING buffer + shift meals to fit; late
     wake-ups → shift the whole timeline but keep ≥30 min wake→first work block;
     and the invariants — keep meal COUNT, protect meals + fitness, WORK is the
     flex variable, and only *suggest* skipping fitness when meals run late AND
     recent days were already active (priority_order events_and_nonnegotiables >
     meals_and_fitness > work).
  4. anti_patterns + personal_anchors: confirm, prune anything stale.

Part B — Monthly focus. Mint this month's monthly goals:
  bash "$_SCRIPT_DIR/plan-my-day.sh" profile new monthly-goals
  Set "period": "$MONTH_YEAR", then derive from current_focus (priority only;
  one item at a time: "Include '[name]' in $MONTH_YEAR goals? If yes — what's
  the one-month milestone?"). Commit when confirmed:
  bash "$_SCRIPT_DIR/plan-my-day.sh" profile commit monthly-goals

Part C — Weekly focus. Mint this ISO week's weekly goals:
  bash "$_SCRIPT_DIR/plan-my-day.sh" profile new weekly-goals
  Set "period": "$ISO_WEEK", derive from the monthly focus (priority +
  difficulty, one at a time). Commit when confirmed:
  bash "$_SCRIPT_DIR/plan-my-day.sh" profile commit weekly-goals

Write THREE profile files into $STORE (mkdir -p first), all committed v1:

  $STORE/plans-profile.v1.md:
  ---
  type: plans-profile
  date: $TODAY
  tags: []
  version: 1
  committed: true
  ---

  # Plans profile

  \`\`\`json
  {"created": "$TODAY",
   "working_style": {"session_length_min": 90, "break_min": 30,
     "break_activities": ["..."], "work_hours_per_day": 7,
     "focus_hours": "9-12,15-17", "last_block_end": "HH:MM",
     "energy_peak": "...", "day_wreckers": ["..."], "other_prefs": ["..."]},
   "planning_guidelines": "Prose: how /plan-my-day will plan the day...",
   "current_focus": [
     {"id": "<library-id>", "lib": "work|goals", "name": "...",
      "track": "professional|personal", "horizon": "short|long",
      "priority": 1, "deadline": "YYYY-MM | ongoing",
      "success_looks_like": "...", "context": "...", "status": "active"}],
   "daily_anchors": {"wake_time": "HH:MM", "workout_time": "HH:MM",
     "lunch_time": "HH:MM", "dinner_time": "HH:MM",
     "walk_time": "HH:MM or null", "bed_target": "HH:MM"},
   "typical_day": {
     "padded": true,
     "note": "Generous baseline — each block padded so real days leave slack, never a deficit. The planner may COMPRESS these segments but should never need to expand them.",
     "rest_days": ["sat", "sun"],
     "workday": [
       {"slot": "wake",      "start": "07:00", "end": "07:30", "duration_min": 30,  "category": "wake",     "flex": "fixed"},
       {"slot": "workout",   "start": "08:00", "end": "09:15", "duration_min": 75,  "category": "fitness",  "flex": "skippable"},
       {"slot": "breakfast", "start": "09:15", "end": "09:45", "duration_min": 30,  "category": "meal",     "flex": "fixed"},
       {"slot": "work_am",   "start": "10:00", "end": "13:00", "duration_min": 180, "category": "work",     "flex": "flex"},
       {"slot": "lunch",     "start": "13:00", "end": "13:45", "duration_min": 45,  "category": "meal",     "flex": "fixed"},
       {"slot": "work_pm",   "start": "14:00", "end": "18:00", "duration_min": 240, "category": "work",     "flex": "flex"},
       {"slot": "walk",      "start": "18:30", "end": "19:00", "duration_min": 30,  "category": "movement", "flex": "flex"},
       {"slot": "dinner",    "start": "19:30", "end": "20:15", "duration_min": 45,  "category": "meal",     "flex": "fixed"},
       {"slot": "wind_down", "start": "22:30", "end": "23:00", "duration_min": 30,  "category": "rest",     "flex": "flex"},
       {"slot": "bed",       "start": "23:00", "end": "23:00", "duration_min": 0,   "category": "bed",      "flex": "fixed"}],
     "rest_day": [
       {"slot": "wake",   "start": "08:30", "end": "09:00", "duration_min": 30, "category": "wake", "flex": "fixed"},
       {"slot": "...rest of the user's weekend rhythm, same segment shape...", "start": "", "end": "", "duration_min": 0, "category": "rest", "flex": "flex"}]},
   "variation_rules": {
     "priority_order": ["events_and_nonnegotiables", "meals_and_fitness", "work"],
     "work_is_flex": true,
     "keep_meal_count": true,
     "min_wake_to_work_gap_min": 30,
     "non_gym_fitness": {"ask_duration_including_buffer": true, "shift_meals_to_fit": true},
     "late_wake": {"shift_timeline": true},
     "skip_fitness_when": "Suggest (never silently drop) skipping today's fitness only when meals are running late AND the last few days have already been active — judge both in context."},
   "anti_patterns": ["..."],
   "personal_anchors": {"relationships": ["..."],
     "creative_pursuits": ["..."], "health_habits": ["..."]},
   "notes": "..."}
  \`\`\`

  $STORE/work-library.v1.md (type: work-library):
  \`\`\`json
  {"created": "$TODAY", "projects": [
    {"id": "<slug>", "name": "...", "shortcut": "<2-3 letters>",
     "summary": "...", "category": "work",
     "metadata": {"repo": "...", "stack": "...", "links": []},
     "timeline": null}]}
  \`\`\`

  $STORE/goals-library.v1.md (type: goals-library):
  \`\`\`json
  {"created": "$TODAY", "goals": [
    {"id": "<slug>", "name": "...", "shortcut": "<2-3 letters>",
     "category": "health|creative|relationships|financial|personal",
     "summary": "...", "timeline": null}]}
  \`\`\`

  Every current_focus entry references a library card by id (lib: "work" →
  work-library; lib: "goals" → goals-library).

Park the old profile so nothing is lost (do NOT delete):
  mkdir -p "$VAULT_DIR/.pbrain/backup"
  mv "$OLD_PROFILE" "$VAULT_DIR/.pbrain/backup/" 2>/dev/null
  (Leave $OLD_JSON in place if it exists — superseded, not harmful.)

Record so this never re-runs:
  bash "$_SCRIPT_DIR/../lib/migrations.sh" record 0002_plans_profile_rebuild

Confirm: "Plans profile rebuilt → $STORE (plans profile + work library +
goals library + this month's + this week's focus). Re-run /plan-my-day
to plan today." Stop here.
REBUILD
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
  cat <<REFRAME

---
INSTRUCTIONS — reframe your goals to PROJECT level. Do not plan any day yet.
Tell the user: "Your weekly/monthly goals are moving from task-level to a CEO
overview — which Plane PROJECTS are in play, at what priority, and what % of
your importance/time each gets. The real tasks now live in Plane. Let's reframe
your CURRENT open goals."

Scope: edit ONLY the CURRENT open period's draft(s) shown above (this week's
weekly-goals and, if set, this month's monthly-goals). Leave any older committed
period files alone — readers tolerate the absence of allocation_percent, and the
next /weekly-review mints fresh files in the new shape.

For EACH goals file with a real path above, walk its goals ONE AT A TIME:
  1. Quote the goal back. When plane_configured: yes (registry_json non-empty),
     ask which **Plane project** it maps to — offer the names from registry_json
     above. If the project isn't in the registry yet, tell the user to run
     "/project-manager projects --sync" (or add it in Plane), then pick it.
     Record both "plane_project" (the uuid) and "project_name" (the friendly
     name). If they truly have no Plane project for it yet, leave plane_project
     as "" and keep the goal text. When plane_configured: no, SKIP the project
     question entirely — leave "plane_project": "" and keep the goal as a
     focus-area; the reframe to allocation_percent still applies (task-pull +
     progress just need Plane, which isn't set up).
  2. Keep "priority" as-is (display order).
  3. Ask for "allocation_percent" — this goal's share of the week's/month's
     importance. After all goals are assigned, **balance them to sum to 100**
     across active goals (show the user the split and adjust until it sums to
     100). Drop "tie" (task-level) — it's superseded by plane_project.
  4. Keep success_looks_like, status, and difficulty (difficulty is now
     secondary but retained).

Rewrite each file's fenced JSON so every active goal item is:
  {"id": "<slug>", "goal": "...", "plane_project": "<uuid or ''>",
   "project_name": "...", "priority": 1, "allocation_percent": 40,
   "success_looks_like": "...", "status": "active", "difficulty": "normal"}
Keep the frontmatter (version/committed) and the "period"/"created"/"derived_from"
keys intact. Edit the draft in place (these are the open period's files — if a
file is already committed for the current period, that's fine to edit in place
for this one-time historical fixup).

When done (or if there are no open goals files to reframe — vacuous), record so
this never re-runs:
  bash "$_SCRIPT_DIR/../lib/migrations.sh" record 0007_goals_project_reframe

Confirm: "Goals reframed to project level → allocation balanced to 100%.
Re-run /plan-my-day to lay out today, then /plan-my-work to fill the blocks."
Stop here.
REFRAME
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
  # NOTE: the typical_day + variation_rules JSON below must stay identical with
  # the other build block (PLAN_MY_DAY_REBUILD Part A, ~the rebuild heredoc) —
  # there are exactly two copies, by the self-contained-heredoc convention.
  cat <<SETUP
PLAN_MY_DAY_SETUP_PROFILE
store: $STORE

INSTRUCTIONS — first-time setup. Do not generate any plan yet. You're helping
the user build the plans profile that every future /plan-my-day will use: a
detailed focus list + working-style contract, backed by a work library and a
goals library.

Step 1 — Frame it warmly: "Let's get a clear picture of what you're pushing
forward right now — that way each daily plan is anchored on what matters to
you, not just a generic to-do list."

Step 2 — Interview the user. Ask in 2–3 batches, not all at once:

  Working style
  - Typical weekday: which hours are your IMPORTANT focus hours?
  - How many total work hours per day do you realistically want?
  - Preferred work-session length? (45 / 60 / 90 / 120 min)
  - Break preference: how long between sessions, what restful activities
    do you actually like (the rotation the plan uses)?
  - When must the LAST work block of the day end?
  - Energy peak: morning / afternoon / night / mixed?
  - Anything that wrecks your day if it slips?
  - Any other /plan-my-day preferences (e.g. "always surface carry-forward
    tasks first", "keep Sundays block-free")?
  Once you have the above, draft a short planning_guidelines paragraph:
  "Here's how I'll plan your day: [block sizing, anchor philosophy, what
  it optimises for]." Read it back and confirm with the user.

  Current focus — what are you actively trying to build or achieve?
  Work focus (projects, career, money) and life focus (health/body, creative
  pursuits, relationships, inner work, finances). For each item:
  - classify: lib = "work" (project/career) | "goals" (life goal)
  - track: professional | personal
  - horizon: short (3–6 months) | long (6+ months)
  - priority (1 = most important), deadline or "ongoing"
  - success_looks_like — short phrase
  - context — a working-notes paragraph (what it is, where it stands, what
    kind of effort it needs)
  Register each as a short library card too:
    work-library card — id, name, shortcut (2-3 letters, e.g. "pb" → pbrain),
      category: "work", one-line summary, stable metadata (repo/stack/links)
    goals-library card — id, name, shortcut, category (health|creative|
      relationships|financial|personal), one-line summary

  Typical day breakup (×2 — workday + rest day). This is the heart of the
  schedule. Ask: "Walk me through an average WORKDAY from wake to bed — every
  activity with its time: wake/prep, workout, each meal, your work blocks, the
  walk, wind-down, bed. I'll be GENEROUS with each block so real days leave
  slack to do EXTRA, never a deficit." Capture each segment as
  {slot, start, end, duration_min, category, flex}:
    - category ∈ wake|fitness|meal|work|movement|rest|bed
    - flex ∈ fixed (meals/wake/bed) | flex (work, walk, wind-down) | skippable
      (fitness) — this encodes what the planner may shrink vs protect.
  PAD each duration generously — the template is a set of CEILINGS the planner
  may compress, never expand. Read the padded timeline back and confirm.
  Then repeat for a typical REST / weekend day (same segment shape, their
  weekend rhythm). Ask which weekdays are rest days → typical_day.rest_days
  (e.g. ["sat","sun"]). Set typical_day.padded: true.
  DERIVE daily_anchors from the workday segments (no separate question):
  wake_time←wake.start, workout_time←fitness.start, lunch_time/dinner_time←
  the meal slots, walk_time←movement.start, bed_target←bed.start.

  Variation preferences (ask once, plainly):
    - Non-gym fitness days (football, Apple Fitness, a class): "On those days
      give me the activity's duration INCLUDING travel/buffer so I can shift
      meals around it." → variation_rules.non_gym_fitness.
    - Late wake-ups: "If you wake up late I'll shift the whole timeline later,
      but always keep ≥30 min between waking and your first work block." →
      variation_rules.late_wake + min_wake_to_work_gap_min.
    - State the invariants: "Across any variation I keep your meal COUNT the
      same and protect meals + fitness; WORK is what I shrink first. The one
      exception: I may *suggest* skipping fitness if meals run late AND you've
      already been very active the last few days." → keep_meal_count,
      work_is_flex, skip_fitness_when, priority_order
      (events_and_nonnegotiables > meals_and_fitness > work).

  Anti-patterns — behaviours that sabotage you (doomscrolling, late nights…).

  Personal anchors — relationships to stay close to, creative pursuits,
    health non-negotiables.

Step 3 — Write THREE files into $STORE (mkdir -p first), all committed v1,
each with frontmatter (type, date: $TODAY, tags: [], version: 1,
committed: true), a heading, and a fenced json block:

  plans-profile.v1.md — json:
  {"created": "$TODAY",
   "working_style": {"session_length_min": 90, "break_min": 30,
     "break_activities": ["..."], "work_hours_per_day": 7,
     "focus_hours": "...", "last_block_end": "HH:MM",
     "energy_peak": "...", "day_wreckers": ["..."], "other_prefs": ["..."]},
   "planning_guidelines": "...",
   "current_focus": [
     {"id": "<library-id>", "lib": "work|goals", "name": "...",
      "track": "professional|personal", "horizon": "short|long",
      "priority": 1, "deadline": "...", "success_looks_like": "...",
      "context": "...", "status": "active"}],
   "daily_anchors": {"wake_time": "", "workout_time": "", "lunch_time": "",
     "dinner_time": "", "walk_time": null, "bed_target": ""},
   "typical_day": {
     "padded": true,
     "note": "Generous baseline — each block padded so real days leave slack, never a deficit. The planner may COMPRESS these segments but should never need to expand them.",
     "rest_days": ["sat", "sun"],
     "workday": [
       {"slot": "wake",      "start": "07:00", "end": "07:30", "duration_min": 30,  "category": "wake",     "flex": "fixed"},
       {"slot": "workout",   "start": "08:00", "end": "09:15", "duration_min": 75,  "category": "fitness",  "flex": "skippable"},
       {"slot": "breakfast", "start": "09:15", "end": "09:45", "duration_min": 30,  "category": "meal",     "flex": "fixed"},
       {"slot": "work_am",   "start": "10:00", "end": "13:00", "duration_min": 180, "category": "work",     "flex": "flex"},
       {"slot": "lunch",     "start": "13:00", "end": "13:45", "duration_min": 45,  "category": "meal",     "flex": "fixed"},
       {"slot": "work_pm",   "start": "14:00", "end": "18:00", "duration_min": 240, "category": "work",     "flex": "flex"},
       {"slot": "walk",      "start": "18:30", "end": "19:00", "duration_min": 30,  "category": "movement", "flex": "flex"},
       {"slot": "dinner",    "start": "19:30", "end": "20:15", "duration_min": 45,  "category": "meal",     "flex": "fixed"},
       {"slot": "wind_down", "start": "22:30", "end": "23:00", "duration_min": 30,  "category": "rest",     "flex": "flex"},
       {"slot": "bed",       "start": "23:00", "end": "23:00", "duration_min": 0,   "category": "bed",      "flex": "fixed"}],
     "rest_day": [
       {"slot": "wake",   "start": "08:30", "end": "09:00", "duration_min": 30, "category": "wake", "flex": "fixed"},
       {"slot": "...rest of the user's weekend rhythm, same segment shape...", "start": "", "end": "", "duration_min": 0, "category": "rest", "flex": "flex"}]},
   "variation_rules": {
     "priority_order": ["events_and_nonnegotiables", "meals_and_fitness", "work"],
     "work_is_flex": true,
     "keep_meal_count": true,
     "min_wake_to_work_gap_min": 30,
     "non_gym_fitness": {"ask_duration_including_buffer": true, "shift_meals_to_fit": true},
     "late_wake": {"shift_timeline": true},
     "skip_fitness_when": "Suggest (never silently drop) skipping today's fitness only when meals are running late AND the last few days have already been active — judge both in context."},
   "anti_patterns": ["..."],
   "personal_anchors": {"relationships": ["..."], "creative_pursuits": ["..."],
     "health_habits": ["..."]},
   "notes": "free-form anything important not captured above"}

  work-library.v1.md — json:
  {"created": "$TODAY", "projects": [
    {"id": "<slug>", "name": "...", "shortcut": "<2-3 letters>",
     "summary": "...", "category": "work",
     "metadata": {"repo": "...", "stack": "...", "links": []},
     "timeline": null}]}

  goals-library.v1.md — json:
  {"created": "$TODAY", "goals": [
    {"id": "<slug>", "name": "...", "shortcut": "<2-3 letters>",
     "category": "...", "summary": "...", "timeline": null}]}

  - Every current_focus entry references a library card by id.
  - Libraries are LIVING documents: entries appended/enriched in place;
    versions only mint on structural rebuilds.
  - Use the user's actual words — don't sanitize their voice.

Step 4 — Confirm: "Plans profile saved → $STORE (plans profile + work library
+ goals library). Edit any time with /plan-my-day profile new. Now re-run
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

# Weekly and monthly goals — resolved by period (draft or committed).
WEEKLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$STORE" weekly-goals "$ISO_WEEK" || true)"
MONTHLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$STORE" monthly-goals "$MONTH_YEAR" || true)"
WEEKLY_GOALS_CONTENT="(not set up — /weekly-review creates this week's goals)"
MONTHLY_GOALS_CONTENT="(not set up — /monthly-review creates this month's goals)"
[[ -n "$WEEKLY_GOALS_FILE" ]] && WEEKLY_GOALS_CONTENT="$(cat "$WEEKLY_GOALS_FILE" 2>/dev/null || true)"
[[ -n "$MONTHLY_GOALS_FILE" ]] && MONTHLY_GOALS_CONTENT="$(cat "$MONTHLY_GOALS_FILE" 2>/dev/null || true)"

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
    cat <<FOCUSINSTR
---
INSTRUCTIONS — focus $FOCUS_ACTION. You are managing the user's current_focus
list in their plans profile ($PROFILE_FILE). The plans profile is a LIVING
document — amend the latest version in place (do NOT mint a new version unless
the user explicitly asks for a structural redesign). Keep the fenced JSON block
valid and the frontmatter intact throughout.

FOCUSINSTR
    if [[ "$FOCUS_ACTION" == "list" ]]; then
      cat <<'FOCUSLIST'
Show the user's current_focus entries as a numbered list. For each entry show:
  name (shortcut from library if set) | track | horizon | priority | deadline | status
  context (one-line summary)
If current_focus is empty, say so and suggest /plan-my-day focus add. Stop here.
FOCUSLIST
    elif [[ "$FOCUS_ACTION" == "add" ]]; then
      cat <<'FOCUSADD'
The user's message describes a new focus item to add. Gather:
  - name + one-line description
  - lib: "work" (project/career/money) or "goals" (health/creative/
    relationships/financial/personal)
  - track: professional | personal
  - horizon: short (3–6 months) | long (6+ months)
  - priority (1 = most important; ask if not obvious — show current list)
  - deadline: YYYY-MM or "ongoing"
  - success_looks_like (short phrase)
  - context (working-notes paragraph — what it is, where it stands, what effort
    it needs — the rich detail that makes plan blocks useful)
Suggest a 2-3-letter shortcut (e.g. "lt" for Lettuce); confirm with the user.
After gathering:
1. APPEND the new entry to current_focus in the profile file (in-place edit).
2. REGISTER a short library card in the appropriate library:
   lib: "work" → work-library: {id, name, shortcut, category:"work",
     summary, metadata:{}, timeline:null}
   lib: "goals" → goals-library: {id, name, shortcut, category, summary,
     timeline:null}
   Edit the library file in place (living document).
3. AUTO-APPEND OFFER: if there is no existing library card, remind the user
   that the shortcut can be used to reference this item tersely in any entry.
4. Confirm: "Added '[name]' (shortcut: xx) to current_focus and registered a
   card in the [work|goals] library."
FOCUSADD
    elif [[ "$FOCUS_ACTION" == "archive" ]]; then
      cat <<'FOCUSARCHIVE'
The user named an item to archive (id or shortcut in their message). Identify it
from the current_focus list, quote it back to confirm, then:
1. Remove the entry from current_focus in the profile file (in-place edit).
2. In the library card (work-library or goals-library per lib), set
   "timeline": {"started": "<created date or best estimate>", "ended": "$TODAY"}
3. Confirm: "Archived '[name]' — library card stamped with end date."
FOCUSARCHIVE
    else
      cat <<'FOCUSRESTORE'
The user named an item to restore (id or shortcut). Find it in the work-library
or goals-library (a card with a non-null timeline), quote it back to confirm:
1. Clear its timeline: set "timeline": null in the library file.
2. Ask the user for updated context + any field changes (priority, deadline).
3. APPEND a new entry to current_focus in the profile with status: "active".
4. Confirm: "Restored '[name]' to current_focus."
FOCUSRESTORE
    fi
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
      cat <<'LIBSHOW'
---
INSTRUCTIONS — library show. Present the library cards as a readable list.
For each card: shortcut (if set) | name | category | summary | metadata
(key facts only) | timeline status (active or archived with date). Stop here.
LIBSHOW
    else
      cat <<LIBEDIT
---
INSTRUCTIONS — library edit. The user wants to update a card in the $LIB_TARGET
library (${LIB_FILE:-(no library yet)}). If no library file exists, say so and stop.
Find the card by id or shortcut (item: $LIB_ID if set; otherwise the user's
message names it). Display its current fields, ask what to change, then edit
the library file in place (living document — no version mint). Keep the fenced
JSON valid. Confirm what changed.
LIBEDIT
    fi
    exit 0
  fi
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
km = re.search(r"^focus:\s*(.+?)\s*$", m.group(1), re.MULTILINE)
if km:
    val = km.group(1).strip().strip(chr(34) + chr(39))   # strip " and ' without a literal apostrophe
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
[[ -n "${DIET_MEAL_TIMES//[[:space:]]/}" ]] || DIET_MEAL_TIMES="(no diet profile — use the plans-profile daily_anchors / timing signal)"

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
# in Step 2b.5 ("have the last few days already been active?"). A compact
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
# Step 2b.5's graceful degradation (fall back to from-scratch planning + a soft
# one-time nudge when absent). Grep-based to add no extra heredoc.
if printf '%s' "$PROFILE_JSON" | grep -q '"workday"'; then
  TYPICAL_DAY_PRESENT=yes
else
  TYPICAL_DAY_PRESENT=no
fi

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
diet_today_exists: $DIET_TODAY_EXISTS
fitness_today_schedule: $TODAY_FITNESS_SCHEDULE
fitness_today_activity: ${TODAY_FITNESS_ACTIVITY:-(no fitness entry / focus not set)}
typical_day_present: $TYPICAL_DAY_PRESENT

=== PLANS PROFILE ===
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

=== RECENT FITNESS ACTIVITY (last ~4 days — context for the skip-fitness judgment) ===
$RECENT_FITNESS_ACTIVITY

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
  - FITNESS NUDGE (soft, non-blocking — like the daily-journal nudge):
    PREFERENCE OVERRIDE (check FIRST): if the injected USER PREFERENCES block
    (global or per-command) says to skip the fitness-journal nudge, SKIP this
    entirely. A standing preference always wins.
      - If TODAY'S FITNESS JOURNAL == "MISSING": mention it ONCE, folded into
        the same first message as the other Step 0 nudges — e.g. "Heads up:
        today's /fitness-journal isn't done. Running it captures your wake time
        and slots your workout into the day — want to? Either way I'll plan
        now." Do NOT make it a separate turn; do NOT STOP and wait; do NOT ask
        whether any session is complete/logged (that's /end-of-day's job, not
        the planner's). Just plan. If you genuinely need the workout time and
        \`fitness_today_schedule\` is empty, ask it inline in Step 2c, not here.
      - If TODAY'S FITNESS JOURNAL exists: say nothing about it; still read its
        \`sleep_*\` fields (Step 2a) and treat its scheduled session as today's.
        Its \`focus:\` field is surfaced as \`fitness_today_activity\` above —
        when it's set, pbrain has ALREADY reconciled the fitness-habit reminders
        to it (the chosen activity's reminder kept, the scheduled-but-not-chosen
        ones cancelled + auto-skipped). So in Step 5c, do NOT touch the fitness
        habits' reminders — only the non-fitness timed habits. When
        \`fitness_today_activity\` is "(no fitness entry / focus not set)" and the
        workout matters for the day's timing, you may ask inline (Step 2c).
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
  - NON-NEGOTIABLES — right after surfacing the calendar, ask ONCE: "Anything
    ELSE today that's non-negotiable — a fixed commitment, hard deadline, or
    something that can't move?" Today's calendar items + this answer together
    are the day's FIXED points: they come FIRST and drive preponing/postponing
    the routine (workout, work, meals shift around them). Feed both into Step
    2b.5 and Step 3 rule (a). If the user names nothing, move on — don't press.
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
  - If neither: fall back to current_focus items (priority order).
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
  2b.5 — TODAY'S SHAPE (skeleton + variation detection). Read
    \`typical_day_present\` above.
    • If \`no\`: there is no STRUCTURED typical_day template — but the plans
      profile's \`planning_guidelines\` very often spells out a SAMPLE / DEFAULT
      DAILY SKELETON in prose: an ordered wake→bed sequence with explicit times,
      e.g. "...11:30-13:30 gym -> 13:30-14:00 get ready + prep food -> 14:00
      lunch -> 14:30-15:00 nap -> 15:00-16:30 work -> ...". IF planning_guidelines
      contains such a skeleton, it is AUTHORITATIVE — treat it exactly like a
      typical_day template, do NOT "plan from scratch":
      1. Lay its segments as today's baseline (wake→bed), and FOLLOW THE EXACT
         GAPS / DURATIONS it shows between anchors. The segment lengths are
         deliberate and load-bearing — a 2-hour gym slot already bundles
         commute + the session, a 30-min "get ready + prep food" slot sits
         between gym and lunch, etc. Do NOT shrink, merge, skip, or substitute
         your own guess for any segment's duration. (Concretely: a "11:30-13:30
         gym -> 13:30-14:00 get ready + prep food -> 14:00 lunch" skeleton means
         the gym START to lunch is 2.5h — reserve that whole span before lunch,
         regardless of how short the fitness journal's training time is.)
      2. Anchor today's non-negotiables (calendar + the Step 0 ask) and today's
         actual wake time FIRST, then prepone/postpone the whole skeleton around
         them — SHIFT each segment's start but PRESERVE its duration. If the gym
         moved from 11:30 to 14:30, the get-ready+prep and lunch slide with it
         at the same lengths (14:30-16:30 gym -> 16:30-17:00 get ready + prep ->
         17:00 lunch), they do not compress.
      3. Apply the variation guidance the guidelines themselves state (non-gym
         fitness day → ask the activity duration incl. buffer and shift meals;
         late-wake day → ≥30 min between wake and first work block; keep the
         meal count; work is the flex variable that shrinks to absorb pressure).
      ONLY if planning_guidelines carries NO such skeleton: plan today from
      scratch, and ONCE, non-blocking, add: "Want to add a typical-day template?
      It makes daily planning sharper — run /plan-my-day profile new
      plans-profile." Do not block; do not repeat.
    • If \`yes\`: the plans profile carries typical_day (padded workday +
      rest_day segment arrays) + variation_rules. Build today's skeleton:
      1. Pick \`workday\` vs \`rest_day\`: compare today (\`day_of_week\`)
         against typical_day.rest_days. Confirm in one line ("Treating today as
         a workday — yes?"), overridable for a one-off day off. Lay that
         template as today's baseline, wake→bed. WORK (\`flex\`) segments are
         PADDED CEILINGS you may COMPRESS, never expand. But \`fixed\` and
         \`fitness\` segments keep their stated duration — in particular the
         gym/fitness slot already BUNDLES commute + get-ready + prep, so do NOT
         shrink it to the fitness journal's training time (a ~60-min session
         still occupies its 2h slot). When the session time shifts off the
         template (e.g. gym at 14:30 vs the 11:30 slot), slide the slot AND the
         segments that follow it (get-ready/prep, lunch) by the same offset,
         preserving each one's duration.
      2. ANCHOR today's non-negotiables FIRST (calendar events + the Step 0
         ask). Prepone/postpone the \`flex\`/\`skippable\` segments around them;
         keep \`fixed\` (meal/wake/bed) segments within their normal diet/
         profile variance (15–30 min).
      3. DETECT + APPLY variations:
         - Non-gym fitness day (\`fitness_today_schedule\` is non-gym — e.g.
           football, Apple Fitness, a class): ask its duration INCLUDING
           travel/buffer, then shift the nearby meal slots to fit — meal COUNT
           unchanged (variation_rules.non_gym_fitness).
         - Late wake-up (today's wake from 2a is later than the template's wake
           slot): shift the timeline later, ENFORCING ≥30 min between wake and
           the first work block (variation_rules.min_wake_to_work_gap_min).
         - Invariants every day: keep the meal COUNT (keep_meal_count); absorb
           time pressure by SHRINKING work blocks (work_is_flex); protect meals
           + fitness slots.
         - SKIP-FITNESS (conditional, a judgment call — never silent): ONLY if
           meals are running late AND the RECENT FITNESS ACTIVITY block shows
           the last few days were already active, *suggest* skipping today's
           fitness as a question ("Meals are running late and you've trained
           hard the last few days — want to skip today's workout?"). Never drop
           it without the user's yes.
      4. THEN propose your reshaped day vs the usual baseline for the user to
         accept or change: "Here's how I'd reshape today vs your usual — workout
         moved to X for the 3pm call, lunch nudged to Y. Good, or change it?"
      Carry this skeleton into 2c (it defines the fixed/flex gaps work fills).
  2c — FOCUS HOURS. Do NOT ask the user how many focused hours they want.
    DERIVE the available focus hours from today's skeleton: the gaps the LIFE
    anchors leave (typical_day work segments + variation_rules + daily_anchors),
    capped by working_style.work_hours_per_day and minus any work already
    banked in the 2b backfill. The user will give feedback if they want it
    different — don't make them supply the number. COMPUTE the block layout
    from those gaps and SHOW it before going further:
      - blocks of working_style.session_length_min, separated by
        working_style.break_min breaks (rotate break_activities; never the
        same one back-to-back; respect anti_patterns),
      - laid around today's FIXED anchors: today's skeleton from 2b.5 (the
        typical_day template OR the planning_guidelines sample skeleton — its
        segments and their EXACT durations are where work fits and must be
        preserved), calendar events (zero variance), the fitness session
        (\`fitness_today_schedule\` or the user's stated time) — NOTE: the
        fitness journal's duration is the TRAINING time only; the workout's
        PLANNING slot is the skeleton's gym/activity slot, which bundles
        commute + get-ready + post-workout prep around it (so a ~60-min
        session can occupy a 2h+ slot), and the skeleton's own get-ready/prep
        segment then sits between the workout and lunch — meal times
        (\`diet_meal_times\`, shifted around the workout per the diet profile),
        habit reminder times (🔔 in the rollup), working_style.focus_hours
        preferred, nothing past working_style.last_block_end,
      - capped by working_style.work_hours_per_day (minus work already banked
        in the 2b backfill).
    Present: "That gives you N blocks: {compact list with times}. Want to add
    or reduce?" Adjust until they're happy — but lead with the derived layout,
    never with a question about how many hours they want.
  2d — WORK BLOCKS STAY EMPTY. /plan-my-day no longer proposes or assigns tasks —
    that's /plan-my-work's job (it pulls real tasks from Plane and packs them).
    Lay the work blocks 2c computed as GENERIC PLACEHOLDERS ("Block N — focus
    work"); do NOT pull from weekly/monthly goals or current_focus, do NOT build
    a task slate, do NOT write a Task log. AFTER the layout, collect in passing
    (not before it): any locked-in commitments not already on the calendar, and
    anything to specifically avoid today (defaults to profile anti_patterns) —
    these shape the day's SHAPE, not its tasks.

Step 3 — Generate the full day plan draft in memory (do NOT write to disk yet).
  STRUCTURE: lead with a consolidated **Today at a glance** table (time range
  + action + tie). All subjective detail comes AFTER the table as supporting
  sections. The table is the operating doc.

  Table rules — LIFE-ANCHORS-FIRST:
  ANCHORS are LIFE structure ONLY — calendar events, the fitness session, meal
  slots, the walk / wind-down / bed, and any habit reminder times. Work and
  tasks are NEVER anchors; they are allocated into the gaps the life anchors
  leave. Build the life-anchor skeleton first, then place work blocks around it.
  a. CALENDAR EVENTS + explicit user-stated times are absolute — never shift
     them. Calendar items sit at their exact window. Two overlapping calendar
     items → keep both, flag the conflict. Today's explicit NON-NEGOTIABLES
     from Step 0 are equally absolute — the routine prepones/postpones the rest
     of the day around them. (Locked-in WORK commitments are also fixed in
     time, but they are work in the gaps, not life anchors.)
  b. The day's LIFE ANCHORS — fitness session, meal slots (at the diet-profile
     times, workout-shifted), walk, wind-down, bed, habit reminder times — are
     the skeleton, scheduled around (a). Work blocks are placed AROUND these,
     never among them. Maximum 15–30 min variance from a profile/diet anchor
     time; prefer the TIMING SIGNAL average when a needed anchor has no profile
     time.
     SKELETON & FLEX (from 2b.5, whenever a skeleton exists — a typical_day
     template OR a planning_guidelines sample skeleton): the skeleton is the
     one reshaped in 2b.5. FOLLOW ITS EXACT SEGMENT DURATIONS / GAPS — a 2h gym
     slot stays 2h, the get-ready+prep segment between the workout and lunch
     stays at its stated length; you shift segment START times to fit today but
     never silently compress or drop a segment. Keep the meal COUNT, protect
     meal + fitness slots, and absorb time pressure by SHRINKING work blocks
     (work is the flex variable), never by collapsing a skeleton segment or
     dropping a meal. Fitness may be dropped ONLY via the explicit 2b.5 skip
     suggestion the user accepted.
  c. The table ALWAYS starts at the user's actual wake time today (from 2a) —
     NEVER at current_time. Everything from 2b is backfilled as ✓ rows at its
     real time. The plan spans wake → bed.
  d. GAP-FREE & OVERLAP-FREE: every span from wake to bed is accounted for —
     no gaps, no overlapping rows. Fill holes with explicit rest / transition
     / meal / decompress rows. Backfilled rows tile cleanly too.
  e. WORK BLOCKS: as many session_length_min blocks as 2c settled on, placed
     into the gaps the life anchors leave, each a GENERIC PLACEHOLDER row
     ("Block N — focus work", Tie "—"), break rows woven between consecutive
     blocks (rotating break_activities). No break before the first block or
     after the last. Work is never an anchor row. /plan-my-work labels these
     blocks with real tasks later — do NOT name tasks here.
  f. 24h times (HH:MM–HH:MM) on every row. REQUIRED rows: wake/morning-start,
     workout (if any), every meal slot, walk (if anchored), wind-down, bed.
  g. Every row's Tie column maps to a current_focus item name, a category
     (Fit body, Rest, Eating, Relationships, Creative, Social), or "—".

  ---
  type: plan
  date: $TODAY
  day_of_week: $DOW
  week_period: $ISO_WEEK
  status: planned
  energy: {1-10 from 2b}
  sleep_hours: {from fitness_sleep or 2a — omit if unknown}
  focus_today: [{the current_focus item names today's blocks tie back to — empty array if none}]
  tags: []
  ---

  # Day Plan — $TODAY ($DOW)

  > {one short coaching note tuned to today's energy, the top block, fitness
  intent, and sleep if short (< 7h). 1-2 sentences. No platitudes.}

  ## Today at a glance

  | Time | Action | Tie |
  |---|---|---|
  | {HH:MM–HH:MM} | {concrete action for anchors; work blocks are generic "Block N — focus work"; ✓ prefix for backfilled done rows} | {tie} |
  | ... | ... | ... |

  _(Work blocks are placeholders — run /plan-my-work to fill them with real
  tasks from Plane and write the "## Work tracker". /plan-my-day no longer
  writes a task log.)_

  ## Today's focus

  - {bullet per PROJECT in play this week (from the WEEKLY/MONTHLY project goals)
  — name + why it matters this week. This is the CEO read; the concrete tasks get
  pulled into the blocks by /plan-my-work. If no project goals are set, one line:
  "No project goals set for the week — run /weekly-review (or just /plan-my-work
  to pull from Plane directly)."}

  (Sections below are supporting detail — the schedule lives in the table.)

  ## Anchors

  (LIFE structure only — fitness, meals, walk, calendar events. NEVER work.)
  - {fitness session — focus + intensity from the fitness journal, not the time}
  - {meal slots worth surfacing, the walk / wind-down — skip any not worth a line}
  - {each calendar event with brief context — skip if none}

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
  Show the table, briefly name how you laid out the LIFE anchors + empty work
  blocks (the blocks are placeholders), then ask: "Does this look right? Re-split
  blocks, change times, swap or drop anchor rows — just tell me. Say 'looks good'
  to save." Apply requested edits; repeat the updated table if changes were made.
  Once confirmed, write the complete plan — table + all sections — to $OUT_FILE.

Step 5 — After writing, confirm: "Saved → $OUT_FILE" and nudge once: "Blocks laid
  out — run /plan-my-work to fill them with today's tasks from Plane."

Step 5c — Reschedule habit reminders to planned times (silent, best-effort):
  For any table row whose action corresponds to a NON-FITNESS habit from today's
  tracker AND has an explicit start time, align that habit's one-shot Apple
  Reminder:
    bash "$HABITS_CMD" reminders-reschedule --habit "<name>" --time "HH:MM" --date $TODAY
  Only for habits at a specific clock time. NOT_LINKED / NOT_FOUND → skip
  silently. No user output for this step. SKIP the fitness habits (Gym, Apple
  Fitness, Football, …) — pbrain already reconciled their reminders to
  \`fitness_today_activity\` before this prompt (see Step 0); re-touching them
  here would fight that.

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

Step 8 — Diet nudge (the very end, non-blocking). Read \`diet_today_exists\` above:
  PREFERENCE OVERRIDE: if the injected USER PREFERENCES block says to skip the
  diet nudge, skip this step.
  - If \`no\`: one short line — "Today's /diet-journal isn't logged yet — want to
    capture your meals? Otherwise the day's all set." Don't block; don't ask
    whether anything is complete. Just the offer.
  - If \`yes\`: say nothing.
PROMPT

# Habit extraction (silent if no habits profile): logs the tracked habits the
# user said they did / will do today. Self-improvement capture runs after.
pbrain_emit_habits_extract "plan-my-day" || true
pbrain_emit_self_improve "plan-my-day" "$PROFILE_FILE" "plans profile" || true
