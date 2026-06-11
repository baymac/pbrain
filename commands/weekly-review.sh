#!/usr/bin/env bash
set -euo pipefail

# weekly-review.sh
# Gathers the last 7 days of journal, gratitude, plan, end-of-day,
# fitness, and diet entries; emits a context block for Claude to
# synthesize and walk a structured weekly review with the user.
#
# Step 4 builds a PER-COMMAND improvement list from the week's evidence and
# walks it one item at a time (approve/reject). Approved improvements update
# the VERSIONED PROFILES: each owning command's `profile new` mints a draft,
# the approved edits land in it, `profile commit` freezes the new version.
# Libraries (work/goals/food/fitness) are living documents — approved library
# edits apply in place, no version mint.
#
# Default destination:  $VAULT_DIR/life/weekly-tracking/YYYY-Www.md (ISO week)
# Overrides:
#   PBRAIN_VAULT             — vault root
#   PBRAIN_WEEKLY_DIR        — where the weekly review writes
#   PBRAIN_JOURNAL_DIR       — daily journals
#   PBRAIN_GRATITUDE_DIR     — gratitude entries
#   PBRAIN_PLAN_DIR          — daily plans (the plan profile store lives inside)
#   PBRAIN_FITNESS_DIR       — fitness sessions (+ fitness profile store)
#   PBRAIN_DIET_DIR          — diet logs (+ diet profile store)
#   PBRAIN_PLAN_PROFILE_FILE — explicit goals-profile file (bypasses the store)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /weekly-review (emits nothing if none set).
pbrain_emit_prefs "weekly-review" || true

WEEKLY_DIR="${PBRAIN_WEEKLY_DIR:-$VAULT_DIR/life/weekly-tracking}"
DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
GRATITUDE_DIR="${PBRAIN_GRATITUDE_DIR:-$VAULT_DIR/life/gratitude-journal}"
PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
DIET_DIR="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}"

# The versioned profile stores Step 4 reads (and proposes new versions of).
PLAN_STORE="$(pbrain_profile_store "$PLAN_DIR")"
FIT_STORE="$(pbrain_profile_store "$FITNESS_DIR")"
DIET_STORE="$(pbrain_profile_store "$DIET_DIR")"

# Migration: weekly reviews used to live in life/weekly-reviews. If we're at the
# default location, the new dir doesn't exist yet, and the legacy dir does,
# rename it so past reviews (and the Monday nudge that reads them) carry over.
_LEGACY_WEEKLY="$VAULT_DIR/life/weekly-reviews"
if [[ -z "${PBRAIN_WEEKLY_DIR:-}" && ! -d "$WEEKLY_DIR" && -d "$_LEGACY_WEEKLY" ]]; then
  mv "$_LEGACY_WEEKLY" "$WEEKLY_DIR" 2>/dev/null \
    && echo "Renamed life/weekly-reviews → life/weekly-tracking (past reviews moved)." || true
fi
unset _LEGACY_WEEKLY

mkdir -p "$WEEKLY_DIR"

TODAY="$(date +%Y-%m-%d)"

# ISO week (e.g. 2026-W22). Use python to stay portable across BSD/GNU date.
ISO_WEEK="$(python3 -c "import datetime; t=datetime.date.today(); y,w,_=t.isocalendar(); print(f'{y}-W{w:02d}')")"
MONTH_YEAR="$(date +%Y-%m)"
NEXT_ISO_WEEK="$(python3 -c "import datetime; t=datetime.date.today()+datetime.timedelta(weeks=1); y,w,_=t.isocalendar(); print(f'{y}-W{w:02d}')")"
NEXT_MONTH_YEAR="$(python3 -c "import datetime; t=datetime.date.today(); import calendar; nxt=t.replace(day=1)+datetime.timedelta(days=calendar.monthrange(t.year, t.month)[1]); print(nxt.strftime('%Y-%m'))")"
OUT_FILE="$WEEKLY_DIR/$ISO_WEEK.md"

# Last 7 dates: today and 6 days back, oldest first.
DATES="$(python3 - "$TODAY" <<'PY'
import sys, datetime
today = datetime.date.fromisoformat(sys.argv[1])
for i in range(6, -1, -1):
    print((today - datetime.timedelta(days=i)).isoformat())
PY
)"

FIRST_DATE="$(echo "$DATES" | head -1)"
LAST_DATE="$(echo "$DATES" | tail -1)"

if [[ -f "$OUT_FILE" ]]; then
  echo "This week's review already exists: $OUT_FILE"
  echo ""
  cat "$OUT_FILE"
  exit 0
fi

cat_section() {
  local label="$1"
  local f="$2"
  echo ""
  echo "### $label"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo "(no entry)"
  fi
}

# Cat the latest committed version of a profile base with a labelled header.
cat_profile() {
  local label="$1" store="$2" base="$3" f
  f="$(pbrain_profile_latest "$store" "$base")"
  echo ""
  echo "### $label [versioned: ${f:-no committed version yet}]"
  [[ -n "$f" ]] && cat "$f" || echo "(none)"
}

echo "WEEKLY_REVIEW_SESSION"
echo "iso_week: $ISO_WEEK"
echo "output_file: $OUT_FILE"
echo "date_range: $FIRST_DATE → $LAST_DATE"
echo "commands_dir: $_SCRIPT_DIR"
echo "dates_covered:"
for d in $DATES; do echo "  - $d"; done
echo ""
echo "--- WEEK CONTEXT (oldest first) ---"

for d in $DATES; do
  echo ""
  echo "============================================================"
  echo "## $d"
  echo "============================================================"
  cat_section "Gratitude"  "$GRATITUDE_DIR/$d.md"
  cat_section "Journal"    "$DAILY_DIR/$d.md"
  cat_section "Plan & close" "$PLAN_DIR/$d.md"
  cat_section "Fitness"    "$FITNESS_DIR/$d.md"
  cat_section "Diet"       "$DIET_DIR/$d.md"
done

echo ""
echo "--- END WEEK CONTEXT ---"

# Habit rollup (this week / month vs each habit's criteria). Empty if habit
# tracking isn't set up. HABITS_CMD lets Step 4 add/archive habits on a yes.
# Sync the week's tracking md into the DB first so the rollup is accurate.
pbrain_habits_sync_range 8 || true
HABITS_ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
HABITS_CMD="$(pbrain_habits_cmd 2>/dev/null || true)"
if [[ -n "${HABITS_ROLLUP//[[:space:]]/}" ]]; then
  echo ""
  echo "--- HABITS (this week / month vs each habit's criteria) ---"
  echo "$HABITS_ROLLUP"
  echo "habits_cmd: $HABITS_CMD"
  echo "--- END HABITS ---"
fi

# Core profiles, for the Step 4 improvements pass. All versioned (committed =
# final; changes mint the next version through the owning command's `profile`
# subcommand). The explicit goals-profile override is respected.
echo ""
echo "--- CORE PROFILES (for Step 4 improvements) ---"
if [[ -n "${PBRAIN_PLAN_PROFILE_FILE:-}" && -f "${PBRAIN_PLAN_PROFILE_FILE:-}" ]]; then
  echo ""
  echo "### Goals profile [override: $PBRAIN_PLAN_PROFILE_FILE]"
  cat "$PBRAIN_PLAN_PROFILE_FILE"
else
  cat_profile "Goals profile" "$PLAN_STORE" goals-profile
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

# Weekly and monthly goal files — resolved by period.
WEEKLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$PLAN_STORE" weekly-goals "$ISO_WEEK" || true)"
MONTHLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$PLAN_STORE" monthly-goals "$MONTH_YEAR" || true)"
WEEKLY_GOALS_CONTENT=""
MONTHLY_GOALS_CONTENT=""
[[ -n "$WEEKLY_GOALS_FILE" ]] && WEEKLY_GOALS_CONTENT="$(cat "$WEEKLY_GOALS_FILE" 2>/dev/null || true)"
[[ -n "$MONTHLY_GOALS_FILE" ]] && MONTHLY_GOALS_CONTENT="$(cat "$MONTHLY_GOALS_FILE" 2>/dev/null || true)"

# Read this week's task logs from day-plan files to show goal progress.
TASK_LOG_DATA="$(python3 - "$PLAN_DIR" "$FIRST_DATE" "$LAST_DATE" <<'PYEOF' 2>/dev/null || echo "(no task logs)"
import glob, os, re, sys
plan_dir, first_date, last_date = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
for f in sorted(glob.glob(os.path.join(plan_dir, "*.md"))):
    date_str = os.path.basename(f)[:-3]
    if not (first_date <= date_str <= last_date):
        continue
    try:
        with open(f) as fh:
            text = fh.read()
    except Exception:
        continue
    m = re.search(r"## Task log\n+(.*?)(?=\n## |\Z)", text, re.DOTALL)
    if not m:
        continue
    section = m.group(1).strip()
    if section and "| Task |" in section:
        rows.append(f"=== {date_str} ===")
        rows.append(section)
if rows:
    print("\n".join(rows))
else:
    print("(no task logs this week)")
PYEOF
)"

echo ""
echo "--- WEEKLY GOALS ($ISO_WEEK) ---"
if [[ -n "$WEEKLY_GOALS_CONTENT" ]]; then
  echo "weekly_goals_file: $WEEKLY_GOALS_FILE"
  echo "$WEEKLY_GOALS_CONTENT"
else
  echo "(none — not set up for this week)"
fi
echo "--- END WEEKLY GOALS ---"

echo ""
echo "--- MONTHLY GOALS ($MONTH_YEAR) ---"
if [[ -n "$MONTHLY_GOALS_CONTENT" ]]; then
  echo "monthly_goals_file: $MONTHLY_GOALS_FILE"
  echo "$MONTHLY_GOALS_CONTENT"
else
  echo "(none — not set up for this month)"
fi
echo "--- END MONTHLY GOALS ---"

echo ""
echo "--- THIS WEEK'S TASK LOGS ---"
echo "$TASK_LOG_DATA"
echo "--- END TASK LOGS ---"

echo ""
cat <<PROMPT
weekly_goals_file: ${WEEKLY_GOALS_FILE:-(not set up)}
monthly_goals_file: ${MONTHLY_GOALS_FILE:-(not set up)}
iso_week: $ISO_WEEK
next_iso_week: $NEXT_ISO_WEEK
month_year: $MONTH_YEAR

INSTRUCTIONS: Walk a weekly review. You have a lot of context above — use it. Specifics or silence.

Step 1 — Read every day above. Look for: recurring themes (what kept coming up), real wins (what actually shipped or moved), friction (where the week stalled or repeated), shifts (how thinking changed), unfinished threads (open questions that didn't get resolved). If a HABITS rollup is present, weave its standouts into your synthesis — limit habits over cap, high-priority build habits that lagged, streaks worth naming. Don't dump the table; surface what matters.

Step 2 — Present a TIGHT synthesis FIRST, then ask questions. Order:
  a) Say: "Here's what I'm seeing from your week:" then 3-5 bullets. Specific. Quote the user where you can. No generic positivity.
  b) Then ask, ONE at a time:
     1) "What did this week want to teach you?"
     2) "What's one thing you want to drop next week?"
     3) "What's one thing you want to double down on?"

Step 3 — Write to $OUT_FILE using exactly this format (frontmatter included):

---
type: weekly
date: $FIRST_DATE
week: $ISO_WEEK
tags: []
---

# Weekly review — $ISO_WEEK

Dates: $FIRST_DATE → $LAST_DATE

## What I'm seeing
{your bullets from Step 2a, verbatim}

## What this week wanted to teach me
{verbatim answer to Q1}

## Drop next week
{verbatim answer to Q2}

## Double down on
{verbatim answer to Q3}

## Weekly goals — $ISO_WEEK
{filled in by Step 4b below — the closing week's goals with their Done at/Status
from the task logs (completed / partial / not started for each goal). If no
weekly goals were set up, write "Weekly goals not configured."}

## Improvements
{filled in by Step 4 — every improvement you proposed, per command, with the
user's decision (approved → which profile version it landed in; rejected;
deferred). If you proposed nothing, write "None this week."}

## Habit review
{filled in by Step 4d — a one-paragraph read of how habits went this week (from
the HABITS rollup: what's sticking, what's lagging or over) plus any add/remove
proposals and what the user decided. If habit tracking isn't set up, write
"No habits tracked." If set up but nothing to change, give the read and write
"No habit changes."}

Step 4 — Improvements. Build a PER-COMMAND improvement list from the week's
evidence, using the CORE PROFILES above as the baseline. One list per command:

  - plan-my-day  → goals-profile / work-library / goals-library
  - diet-journal → diet-profile (food-library for library rows)
  - fitness-journal → fitness-profile / fitness-library / activity profiles
  - habits → the habit set (handled in Step 4d below)

Each improvement is ONE line, tied to something that actually happened this
week (e.g. "you skipped legs twice — drop gym to 3 fixed days", "protein
landed under target 5/7 days — bump the lunch protein anchor", "the Lettuce
goal wasn't touched in any plan — re-scope or re-prioritise it"). Propose
NOTHING without a clear signal — do not invent changes.

Then walk the list ONE BY ONE: present an improvement, ask approve / reject,
record the decision. No batch approvals.

After the walk, apply the approved improvements:
  - For each PROFILE with at least one approved improvement, mint a NEW
    VERSION via the owning command (paths use commands_dir above):
      bash "<commands_dir>/plan-my-day.sh"    profile new [goals-profile]
      bash "<commands_dir>/diet-journal.sh"   profile new
      bash "<commands_dir>/fitness-journal.sh" profile new [fitness-profile|fitness-library|activity <name>]
      bash "<commands_dir>/habits.sh"          profile new
    Edit the minted DRAFT file applying ONLY the approved changes (keep the
    fenced JSON valid and the frontmatter version/committed lines intact),
    then freeze it:
      bash "<commands_dir>/<cmd>.sh" profile commit [base]
  - LIBRARIES (work-library, goals-library, food-library, fitness-library)
    are living documents — apply approved library edits IN PLACE on the
    latest version; no version mint.
Record in "## Improvements" what landed where (including the new version
file path for each committed profile).

Step 4b — Weekly Goals lifecycle. Walk this for every weekly review.
  i) GOAL PROGRESS: Read THIS WEEK'S TASK LOGS above. For each goal in the
     WEEKLY GOALS section, determine its status: completed (Done at filled,
     Status=done), partial (some done), or not started. Show a brief summary
     before committing.
  ii) COMMIT the closing week: if weekly_goals_file is a real path (not "(not
     set up)"), commit it:
       bash "\$commands_dir/plan-my-day.sh" profile commit weekly-goals
  iii) MINT next week's draft: mint a fresh weekly-goals draft for next_iso_week:
       bash "\$commands_dir/plan-my-day.sh" profile new weekly-goals
       This creates the file. Edit it to set:
       - "period": "$NEXT_ISO_WEEK" in the JSON block
       - Derive the goals:
         * If monthly_goals_file is set and its period is the current month
           ($MONTH_YEAR): derive from monthly goals (copy goal text/tie/priority,
           ask user to confirm each + set difficulty: easy|normal|hard|nightmare).
         * Else: derive from the goals-profile's work_goals + life_goals (use their
           priority, ask difficulty).
       Walk goals ONE BY ONE — each round ask: "Include '{goal}' next week?
       If yes, what difficulty? (easy/normal/hard/nightmare)". Allow adding new
       goals not in the profile.
       The final JSON shape is:
       {"created": "TODAY", "period": "NEXT_ISO_WEEK",
        "derived_from": "monthly-goals MONTH_YEAR or goals-profile vN",
        "goals": [{"id": "<slug>", "goal": "...", "tie": "<profile/monthly id>",
                   "priority": 1, "difficulty": "normal",
                   "success_looks_like": "...", "status": "active"}]}
  iv) Commit the new next-week draft:
       bash "\$commands_dir/plan-my-day.sh" profile commit weekly-goals
  v) Record in "## Weekly goals — $ISO_WEEK" the closing week's goal progress.
  Skip this whole step silently if weekly_goals_file is "(not set up)" AND the
  user doesn't want to start using weekly goals.

Step 4c — Monthly goal progress (only if monthly_goals_file is set):
  Show a brief one-paragraph read: how many monthly goals were touched this
  week (from task logs), which are on track, which lagged. Don't force action.
  If the month is ending (last 3 days): suggest /monthly-review once.

Step 4d — Habit review (only if a HABITS rollup is present above). Give a short
read of how the week's habits went, then — if the week clearly warrants it —
propose adding a habit the user has been doing but isn't tracking, or archiving
one that's gone stale / no longer serves them. Evidence-based only; propose
nothing if there's no signal. These are user-owned: do NOT change the habit set
by default. Only run a command if the user explicitly says yes this session:
  - add:     bash "$HABITS_CMD" add --name "<X>" --type daily|weekly|monthly --direction at_least|at_most [--target N] [--priority low|medium|high]
  - archive: bash "$HABITS_CMD" archive --id <id>   (keeps history)
Write the read + proposals + what the user decided into "## Habit review".

Step 5 — Print the file path. One closing line, no fanfare.

Hard rules:
- Quote the user back to themselves in the synthesis. Their language, not yours.
- If a day has zero entries, note it once in your synthesis ("you were dark Thu-Fri") and move on. Do not moralize about missed days.
- Do NOT generate a generic "great week!" summary. Specifics or silence.
- Do NOT prescribe productivity systems or self-improvement frameworks. The user is reviewing their own life, not buying a course.
PROMPT

# Self-improvement: capture standing preferences / quality fixes the user
# raised this session (silent unless there was genuine feedback). No plan args:
# Step 4 above owns profile updates with its richer approve-per-item flow.
pbrain_emit_self_improve "weekly-review" || true
