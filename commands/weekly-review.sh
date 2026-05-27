#!/usr/bin/env bash
set -euo pipefail

# weekly-review.sh
# Gathers the last 7 days of journal, gratitude, plan, end-of-day,
# fitness, and diet entries; emits a context block for Claude to
# synthesize and walk a structured weekly review with the user.
#
# Default destination:  $VAULT_DIR/life/weekly-reviews/YYYY-Www.md (ISO week)
# Overrides:
#   PBRAIN_VAULT             — vault root
#   PBRAIN_WEEKLY_DIR        — where the weekly review writes
#   PBRAIN_JOURNAL_DIR       — daily journals
#   PBRAIN_GRATITUDE_DIR     — gratitude entries
#   PBRAIN_PLAN_DIR          — daily plans + close-of-day notes
#   PBRAIN_FITNESS_DIR       — fitness sessions
#   PBRAIN_DIET_DIR          — diet logs

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

WEEKLY_DIR="${PBRAIN_WEEKLY_DIR:-$VAULT_DIR/life/weekly-reviews}"
DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
GRATITUDE_DIR="${PBRAIN_GRATITUDE_DIR:-$VAULT_DIR/life/gratitude-journal}"
PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
DIET_DIR="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}"

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
  cat_section "Plan"       "$PLAN_DIR/$d.md"
  cat_section "End-of-day" "$PLAN_DIR/$d-close.md"
  cat_section "Fitness"    "$FITNESS_DIR/$d.md"
  cat_section "Diet"       "$DIET_DIR/$d.md"
done

echo ""
echo "--- END WEEK CONTEXT ---"
echo ""
cat <<PROMPT
INSTRUCTIONS: Walk a weekly review. You have a lot of context above — use it. Specifics or silence.

Step 1 — Read every day above. Look for: recurring themes (what kept coming up), real wins (what actually shipped or moved), friction (where the week stalled or repeated), shifts (how thinking changed), unfinished threads (open questions that didn't get resolved).

Step 2 — Present a TIGHT synthesis FIRST, then ask questions. Order:
  a) Say: "Here's what I'm seeing from your week:" then 3-5 bullets. Specific. Quote the user where you can. No generic positivity.
  b) Then ask, ONE at a time:
     1) "What did this week want to teach you?"
     2) "What's one thing you want to drop next week?"
     3) "What's one thing you want to double down on?"

Step 3 — Write to $OUT_FILE using exactly this format (no frontmatter):

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

Step 4 — Print the file path. One closing line, no fanfare.

Hard rules:
- Quote the user back to themselves in the synthesis. Their language, not yours.
- If a day has zero entries, note it once in your synthesis ("you were dark Thu-Fri") and move on. Do not moralize about missed days.
- Do NOT generate a generic "great week!" summary. Specifics or silence.
- Do NOT prescribe productivity systems or self-improvement frameworks. The user is reviewing their own life, not buying a course.
PROMPT
