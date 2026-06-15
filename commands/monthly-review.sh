#!/usr/bin/env bash
set -euo pipefail

# monthly-review.sh
# Synthesizes the month across all weekly reviews, fitness/diet/habit aggregates.
# Drives monthly-goals versioning: commit closing month → mint next month's
# draft (derived from plans-profile, priority only) → walk goals 1-by-1.
# Optionally runs a plans-profile hygiene pass (archive completed items,
# refresh stale context).
#
# Default destination:  $VAULT_DIR/life/monthly-tracking/YYYY-MM.md
# Overrides:
#   PBRAIN_VAULT             — vault root
#   PBRAIN_MONTHLY_DIR       — where the monthly review writes
#   PBRAIN_WEEKLY_DIR        — weekly reviews (read for synthesis)
#   PBRAIN_JOURNAL_DIR       — daily journals (cross-ref)
#   PBRAIN_PLAN_DIR          — daily plans + profile store
#   PBRAIN_FITNESS_DIR       — fitness sessions + profile store
#   PBRAIN_DIET_DIR          — diet logs + profile store
#   PBRAIN_PLAN_PROFILE_FILE — explicit plans-profile override

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /monthly-review (emits nothing if none set).
pbrain_emit_prefs "monthly-review" || true

MONTHLY_DIR="${PBRAIN_MONTHLY_DIR:-$VAULT_DIR/life/monthly-tracking}"
WEEKLY_DIR="${PBRAIN_WEEKLY_DIR:-$VAULT_DIR/life/weekly-tracking}"
DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
DIET_DIR="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}"

# The versioned profile stores Step 4 reads (and proposes new versions of).
PLAN_STORE="$(pbrain_profile_store "$PLAN_DIR")"
FIT_STORE="$(pbrain_profile_store "$FITNESS_DIR")"
DIET_STORE="$(pbrain_profile_store "$DIET_DIR")"

TODAY="$(date +%Y-%m-%d)"
MONTH_YEAR="$(date +%Y-%m)"
NEXT_MONTH_YEAR="$(python3 -c "import datetime, calendar; t=datetime.date.today(); nxt=t.replace(day=1)+datetime.timedelta(days=calendar.monthrange(t.year, t.month)[1]); print(nxt.strftime('%Y-%m'))")"
OUT_FILE="$MONTHLY_DIR/$MONTH_YEAR.md"

mkdir -p "$MONTHLY_DIR"

if [[ -f "$OUT_FILE" ]]; then
  echo "This month's review already exists: $OUT_FILE"
  echo ""
  cat "$OUT_FILE"
  exit 0
fi

# Find all ISO weeks that fall in the current month.
MONTH_WEEKS="$(python3 - "$MONTH_YEAR" <<'PYEOF'
import sys, datetime, calendar
year_month = sys.argv[1]
year, month = int(year_month[:4]), int(year_month[5:7])
last_day = calendar.monthrange(year, month)[1]
seen = set()
for day in range(1, last_day+1):
    d = datetime.date(year, month, day)
    y, w, _ = d.isocalendar()
    seen.add(f"{y}-W{w:02d}")
for iso_week in sorted(seen):
    print(iso_week)
PYEOF
)"

# Cat the latest committed version of a profile base with a labelled header.
cat_profile() {
  local label="$1" store="$2" base="$3" f
  f="$(pbrain_profile_latest "$store" "$base")"
  echo ""
  echo "### $label [versioned: ${f:-no committed version yet}]"
  [[ -n "$f" ]] && cat "$f" || echo "(none)"
}

echo "MONTHLY_REVIEW_SESSION"
echo "month: $MONTH_YEAR"
echo "output_file: $OUT_FILE"
echo "commands_dir: $_SCRIPT_DIR"
echo "next_month_year: $NEXT_MONTH_YEAR"
echo ""
echo "--- WEEKLY REVIEWS FOR THE MONTH ---"
for wk in $MONTH_WEEKS; do
  echo ""
  echo "### $wk"
  if [[ -f "$WEEKLY_DIR/$wk.md" ]]; then
    cat "$WEEKLY_DIR/$wk.md"
  else
    echo "(no review for this week)"
  fi
done
echo ""
echo "--- END WEEKLY REVIEWS ---"

# Habit rollup (this month vs each habit's criteria). Empty if habit tracking
# isn't set up. Sync a broader window first so the rollup is accurate.
pbrain_habits_sync_range 35 || true
HABITS_ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
HABITS_CMD="$(pbrain_habits_cmd 2>/dev/null || true)"
if [[ -n "${HABITS_ROLLUP//[[:space:]]/}" ]]; then
  echo ""
  echo "--- HABITS (this month vs each habit's criteria) ---"
  echo "$HABITS_ROLLUP"
  echo "habits_cmd: $HABITS_CMD"
  echo "--- END HABITS ---"
fi

# Core profiles, for the Step 4 improvements pass.
echo ""
echo "--- CORE PROFILES (for Step 4 improvements) ---"
if [[ -n "${PBRAIN_PLAN_PROFILE_FILE:-}" && -f "${PBRAIN_PLAN_PROFILE_FILE:-}" ]]; then
  echo ""
  echo "### Plans profile [override: $PBRAIN_PLAN_PROFILE_FILE]"
  cat "$PBRAIN_PLAN_PROFILE_FILE"
else
  cat_profile "Plans profile" "$PLAN_STORE" plans-profile
fi
cat_profile "Work library"    "$PLAN_STORE" work-library
cat_profile "Goals library"   "$PLAN_STORE" goals-library
cat_profile "Diet profile"    "$DIET_STORE" diet-profile
cat_profile "Food library"    "$DIET_STORE" food-library
cat_profile "Fitness profile" "$FIT_STORE"  fitness-profile
cat_profile "Fitness library" "$FIT_STORE"  fitness-library
echo ""
echo "### Activity profiles [versioned: $FIT_STORE/activities]"
python3 - "$FIT_STORE/activities" <<'PYEOF' 2>/dev/null || echo "(none)"
import glob, os, re, sys
act_store = sys.argv[1]
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
    if re.search(r"^committed:\s*false\s*$", text[:400], re.MULTILINE):
        continue
    if slug not in best or ver > best[slug][0]:
        best[slug] = (ver, f, text)
if not best:
    print("(none)")
for slug, (_v, f, text) in sorted(best.items()):
    print(f"# {f}")
    print(text)
    print()
PYEOF
echo ""
echo "### Habits profile [$(pbrain_habits_profile_file)]"
if [[ -f "$(pbrain_habits_profile_file)" ]]; then cat "$(pbrain_habits_profile_file)"; else echo "(no habits profile)"; fi
echo ""
echo "--- END CORE PROFILES ---"

# Monthly goals for the current month.
MONTHLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$PLAN_STORE" monthly-goals "$MONTH_YEAR" || true)"
echo ""
echo "--- MONTHLY GOALS ($MONTH_YEAR) ---"
if [[ -n "$MONTHLY_GOALS_FILE" ]]; then
  echo "monthly_goals_file: $MONTHLY_GOALS_FILE"
  cat "$MONTHLY_GOALS_FILE"
else
  echo "(none — not set up yet)"
  echo "monthly_goals_file: (not set up)"
fi
echo "--- END MONTHLY GOALS ---"

echo ""
echo "--- PROJECT REGISTRY (registry_json) ---"
echo "plane_configured: $(pbrain_plane_configured 2>/dev/null && echo yes || echo no)"
pbrain_projects_registry_json 2>/dev/null || echo "[]"
echo "--- END PROJECT REGISTRY ---"

MONTH_FIRST_DAY="$(python3 -c "import datetime; t=datetime.date.today(); print(t.replace(day=1).isoformat())" 2>/dev/null || echo "$TODAY")"

cat <<PROMPT
monthly_goals_file: ${MONTHLY_GOALS_FILE:-(not set up)}
next_month_year: $NEXT_MONTH_YEAR
month_year: $MONTH_YEAR

INSTRUCTIONS: Walk a monthly review. You have all this month's weekly reviews + core profiles above. Use them. Specifics or silence.

Step 1 — Read every weekly review from this month above. Look for: recurring themes (what dominated the month), real wins, friction, habits that trended up or down, goals progress across the month. Weave in habit/fitness/diet patterns if relevant data is present. If a week has no review, note it briefly and move on.

Step 2 — Present a tight synthesis FIRST (3-5 bullets), then ask ONE question at a time:
  a) "What was this month really about?"
  b) "What's one thing you want to be different next month?"
  c) "What's one thing you want to keep or deepen?"

Step 3 — Write to $OUT_FILE using exactly this format (frontmatter included):

---
type: monthly
date: $MONTH_FIRST_DAY
month: $MONTH_YEAR
tags: []
---

# Monthly review — $MONTH_YEAR

Weeks: $MONTH_WEEKS

## What I'm seeing
{your bullets from Step 2a, verbatim}

## What this month was really about
{verbatim answer to Q1}

## Change next month
{verbatim answer to Q2}

## Keep or deepen
{verbatim answer to Q3}

## Monthly goals — $MONTH_YEAR
{filled by Step 4 — goal status for each monthly goal; or "Monthly goals not configured."}

## Improvements
{filled by Step 4b — improvement proposals + decisions}

## Habit review
{filled by Step 4c — month-level habit read + any add/archive proposals + decisions}

Step 4 — Monthly goals lifecycle. Walk this for every monthly review.

  i) Show current monthly goals with their status (from MONTHLY GOALS above).
     If none, ask: "Want to set up monthly goals? It's optional — they let
     /weekly-review derive its weekly goals from something more focused than
     the whole plans profile. One-minute setup."
  ii) COMMIT the closing month: if monthly_goals_file is a real path, commit it:
        bash "$_SCRIPT_DIR/plan-my-day.sh" profile commit monthly-goals
  iii) MINT next month's draft for $NEXT_MONTH_YEAR:
        bash "$_SCRIPT_DIR/plan-my-day.sh" profile new monthly-goals
       Monthly goals are now a CEO overview — which Plane PROJECTS are in play
       next month, at what priority, and at what % of importance/time
       (allocation_percent summing to 100). NOT task-level. Edit the file to set
       "period": "$NEXT_MONTH_YEAR", then derive goals from the plans-profile's
       current_focus list. Walk goals ONE BY ONE:
         "Include '{goal}' next month? (yes/no) If yes — what's your one-month
          milestone for it?"
       When the PROJECT REGISTRY above shows plane_configured: yes, ALSO ask
       which **Plane project** it maps to (pick from the registry; if missing,
       /project-manager projects --sync first) and record "plane_project" +
       "project_name". When plane_configured: no, SKIP the project-mapping
       question — leave "plane_project": "" and keep the goal as a focus-area +
       allocation_percent only (task-pull + progress need Plane).
       Allow adding goals not in the profile. Keep "status": "active" for all new
       goals. Then set allocation_percent per goal: DERIVE an initial split from
       priority (higher priority → bigger share — e.g. inverse-rank weighting),
       show it to the user, and adjust until it sums to exactly 100 across active
       goals.
       Final JSON shape:
       {"created": "$TODAY", "period": "$NEXT_MONTH_YEAR",
        "derived_from": "plans-profile vN",
        "goals": [{"id": "<slug>", "goal": "...", "plane_project": "<uuid or ''>",
                   "project_name": "...", "priority": 1, "allocation_percent": 40,
                   "success_looks_like": "...", "status": "active"}]}
       Commit the draft once confirmed:
        bash "$_SCRIPT_DIR/plan-my-day.sh" profile commit monthly-goals
  iv) PLANS-PROFILE HYGIENE PASS. Offer once, don't force:
       "Want a quick hygiene pass on your plans profile? We can archive completed
        items and refresh context on anything stale."
       If yes → mint a new plans-profile version:
         bash "$_SCRIPT_DIR/plan-my-day.sh" profile new plans-profile
       For each current_focus entry:
         - Completed / shipped? → set status: "done" in the draft, note the end
           date; the library card keeps the history via timeline stamping.
         - Still active but stale context? → update the context paragraph.
         - Still active, unchanged → keep as-is.
       Commit the hygiene-passed profile:
         bash "$_SCRIPT_DIR/plan-my-day.sh" profile commit plans-profile
  v) OPTIONAL path: if the user declines monthly goals entirely → lighter synthesis
     only. Write "Monthly goals not configured." in the "## Monthly goals" section.
     /weekly-review will fall back to the plans profile for weekly-goal derivation.
  Record in "## Monthly goals — $MONTH_YEAR" what goals were set up (or "not configured").

Step 4b — Improvements. Build a PER-COMMAND improvement list from the month's
evidence, using the CORE PROFILES above as the baseline. One list per command:

  - plan-my-day  → plans-profile / work-library / goals-library
  - diet-journal → diet-profile (food-library for library rows)
  - fitness-journal → fitness-profile / fitness-library / activity profiles
  - habits → the habit set (handled in Step 4c below)

Month-level bar: propose improvements ONLY when month-long patterns are clear —
not week-to-week noise. Each improvement must be tied to something that actually
recurred or trended across the full month. Propose NOTHING without a clear signal.

Walk the list ONE BY ONE: present an improvement, ask approve / reject, record the
decision. No batch approvals.

After the walk, apply the approved improvements:
  - For each PROFILE with at least one approved improvement, mint a NEW VERSION via
    the owning command:
      bash "$_SCRIPT_DIR/plan-my-day.sh"    profile new [plans-profile]
      bash "$_SCRIPT_DIR/diet-journal.sh"   profile new
      bash "$_SCRIPT_DIR/fitness-journal.sh" profile new [fitness-profile|fitness-library|activity <name>]
      bash "$_SCRIPT_DIR/habits.sh"          profile new
    Edit the minted DRAFT file applying ONLY the approved changes (keep the
    fenced JSON valid and the frontmatter version/committed lines intact),
    then freeze it:
      bash "$_SCRIPT_DIR/<cmd>.sh" profile commit [base]
  - LIBRARIES (work-library, goals-library, food-library, fitness-library)
    are living documents — apply approved library edits IN PLACE on the
    latest version; no version mint.
Record in "## Improvements" what landed where (including the new version
file path for each committed profile). If nothing to improve, write "None this month."

Step 4c — Habit month review (only if a HABITS rollup is present above). Give a
one-paragraph read of how the month's habits trended — what stuck, what lagged,
what hit the cap. Evidence-based proposals only: propose adding a habit the user
has been doing but isn't tracking, or archiving one that's clearly gone stale.
Only run a command if the user explicitly says yes this session:
  - add:     bash "$HABITS_CMD" add --name "<X>" --type daily|weekly|monthly --direction at_least|at_most [--target N] [--priority low|medium|high]
  - archive: bash "$HABITS_CMD" archive --id <id>   (keeps history)
Write the read + proposals + what the user decided into "## Habit review".
If habit tracking isn't set up, write "No habits tracked."

Step 5 — Print the file path. One line, no fanfare.

Hard rules:
- Quote the user back to themselves. Their language.
- Specifics or silence. No generic "great month!" summaries.
- Do NOT prescribe productivity systems or self-improvement frameworks.
PROMPT

# Self-improvement: capture standing preferences / quality fixes the user
# raised this session (silent unless there was genuine feedback). No plan args:
# Step 4 above owns profile updates with its richer approve-per-item flow.
pbrain_emit_habits_extract "monthly-review" || true
pbrain_emit_self_improve "monthly-review" || true
