#!/usr/bin/env bash
set -euo pipefail

# weekly-review.sh
# Gathers the last 7 days of journal, gratitude, plan, end-of-day,
# fitness, and diet entries; emits a context block for Claude to
# synthesize and walk a structured weekly review with the user.
#
# Default destination:  $VAULT_DIR/life/weekly-tracking/YYYY-Www.md (ISO week)
# Overrides:
#   PBRAIN_VAULT             — vault root
#   PBRAIN_WEEKLY_DIR        — where the weekly review writes
#   PBRAIN_JOURNAL_DIR       — daily journals
#   PBRAIN_GRATITUDE_DIR     — gratitude entries
#   PBRAIN_PLAN_DIR          — daily plans (end-of-day close is written into the plan file in place)
#   PBRAIN_FITNESS_DIR       — fitness sessions
#   PBRAIN_DIET_DIR          — diet logs
#
# Core plans read for the Step 4 enrichment pass (proposes updates at week's end).
# All are user-owned vault files — proposed into the review, not auto-written:
#   PBRAIN_PLAN_PROFILE_FILE — goals profile markdown (Goals Profile.md)
#   PBRAIN_DIET_PLAN_FILE    — Diet Plan.md
#   PBRAIN_FITNESS_PLANS_DIR — per-activity fitness plans
#   PBRAIN_GYM_PLAN_FILE     — primary gym plan

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

# Core plans for the Step 4 enrichment pass.
PROFILE_FILE="${PBRAIN_PLAN_PROFILE_FILE:-$VAULT_DIR/life/Goals Profile.md}"
DIET_PLAN_FILE="${PBRAIN_DIET_PLAN_FILE:-$VAULT_DIR/fitness/Diet Plan.md}"
FITNESS_PLANS_DIR="${PBRAIN_FITNESS_PLANS_DIR:-$VAULT_DIR/fitness/plans}"
GYM_PLAN_FILE="${PBRAIN_GYM_PLAN_FILE:-}"

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

echo "WEEKLY_REVIEW_SESSION"
echo "iso_week: $ISO_WEEK"
echo "output_file: $OUT_FILE"
echo "date_range: $FIRST_DATE → $LAST_DATE"
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

# Core plans, for the Step 4 enrichment pass. All are user-owned vault files:
# enrichment proposes changes into the review and edits a plan file only on an
# explicit per-change yes.
echo ""
echo "--- CORE PLANS (for Step 4 enrichment) ---"
echo ""
echo "### Goals profile [vault-owned: $PROFILE_FILE]"
if [[ -f "$PROFILE_FILE" ]]; then cat "$PROFILE_FILE"; else echo "(no profile yet)"; fi
echo ""
echo "### Diet Plan [vault-owned: $DIET_PLAN_FILE]"
if [[ -f "$DIET_PLAN_FILE" ]]; then cat "$DIET_PLAN_FILE"; else echo "(no diet plan)"; fi
echo ""
echo "### Fitness plans [vault-owned: $FITNESS_PLANS_DIR]"
if [[ -n "$GYM_PLAN_FILE" && -f "$GYM_PLAN_FILE" ]]; then
  echo "# $GYM_PLAN_FILE"
  cat "$GYM_PLAN_FILE"
fi
if [[ -d "$FITNESS_PLANS_DIR" ]]; then
  for pf in "$FITNESS_PLANS_DIR"/*.md; do
    [[ -f "$pf" ]] || continue
    echo "# $pf"
    cat "$pf"
    echo ""
  done
else
  echo "(no fitness plans)"
fi
echo ""
echo "--- END CORE PLANS ---"
echo ""
cat <<PROMPT
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

## Proposed plan changes
{filled in by Step 4 — the concrete plan enrichments you proposed and what the
user decided. If you proposed nothing, write "None this week."}

## Habit review
{filled in by Step 4b — a one-paragraph read of how habits went this week (from
the HABITS rollup: what's sticking, what's lagging or over) plus any add/remove
proposals and what the user decided. If habit tracking isn't set up, write
"No habits tracked." If set up but nothing to change, give the read and write
"No habit changes."}

Step 4 — Plan enrichment. Using the CORE PLANS context above and the week's data,
propose concrete updates to the user's plans. Be specific and evidence-based — tie
each proposal to something that actually happened this week (e.g. "you skipped legs
twice", "protein landed under target 5/7 days", "current_focus 'X' wasn't mentioned
in any plan"). Propose nothing if the week gives no clear signal — do not invent
changes.

All three plans — the goals profile ($PROFILE_FILE), the diet plan ($DIET_PLAN_FILE),
and the fitness plans ($FITNESS_PLANS_DIR) — are user-owned vault files. Treat them
the same: do NOT edit any of them by default. Write each proposed change into the
"## Proposed plan changes" section of THIS review file. Only edit an actual plan file
if the user explicitly says yes to that specific change in this session (their yes is
the explicit instruction that authorizes the write). When editing the goals profile,
keep its fenced JSON block valid. Default is propose-in-review, not write-in-place.

Record in "## Proposed plan changes" what you proposed and what the user decided
(written into the relevant plan / left as a proposal / declined).

Step 4b — Habit review (only if a HABITS rollup is present above). Give a short
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
# raised this session (silent unless there was genuine feedback).
pbrain_emit_self_improve "weekly-review" || true
