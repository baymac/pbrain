#!/usr/bin/env bash
set -euo pipefail

# end-of-day.sh
# Bookend to /plan-my-day. Gathers today's plan, journal, fitness, and diet
# entries; emits a context block instructing Claude to walk a structured
# close-of-day reflection and write a sibling close-of-day note.
#
# Default destination:  $VAULT_DIR/life/daily-planning/YYYY-MM-DD-close.md
# Overrides:
#   PBRAIN_VAULT             — vault root
#   PBRAIN_PLAN_DIR          — daily-plan dir (read + write target)
#   PBRAIN_JOURNAL_DIR       — today's daily journal (cross-ref)
#   PBRAIN_FITNESS_DIR       — today's fitness session (cross-ref)
#   PBRAIN_DIET_DIR          — today's diet log (cross-ref)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
DIET_DIR="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}"

TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%A)"

PLAN_FILE="$PLAN_DIR/$TODAY.md"
JOURNAL_FILE="$DAILY_DIR/$TODAY.md"
FITNESS_FILE="$FITNESS_DIR/$TODAY.md"
DIET_FILE="$DIET_DIR/$TODAY.md"
CLOSE_FILE="$PLAN_DIR/$TODAY-close.md"

mkdir -p "$PLAN_DIR"

read_or_missing() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo "(no entry for today)"
  fi
}

exists() {
  [[ -f "$1" ]] && echo yes || echo no
}

if [[ -f "$CLOSE_FILE" ]]; then
  echo "Today's close already exists: $CLOSE_FILE"
  echo ""
  cat "$CLOSE_FILE"
  exit 0
fi

cat <<PROMPT
END_OF_DAY_SESSION
date: $TODAY ($DOW)
output_file: $CLOSE_FILE
plan_file: $PLAN_FILE (exists: $(exists "$PLAN_FILE"))
journal_file: $JOURNAL_FILE (exists: $(exists "$JOURNAL_FILE"))
fitness_file: $FITNESS_FILE (exists: $(exists "$FITNESS_FILE"))
diet_file: $DIET_FILE (exists: $(exists "$DIET_FILE"))

--- PLAN ---
$(read_or_missing "$PLAN_FILE")

--- JOURNAL ---
$(read_or_missing "$JOURNAL_FILE")

--- FITNESS ---
$(read_or_missing "$FITNESS_FILE")

--- DIET ---
$(read_or_missing "$DIET_FILE")
--- END CONTEXT ---

INSTRUCTIONS: Walk the user through a close-of-day reflection. Be warm but tight. Specifics or silence.

Step 0 — If the plan file does not exist, tell the user once: "No /plan-my-day for today — we'll do a free-form close instead." Then proceed.

Step 1 — Skim every section above. Don't summarize generically. Note specific items the user planned, what their journal mentioned, whether they trained, whether they logged meals.

Step 2 — Ask, ONE question at a time. Wait for each answer before asking the next.
  1) "What actually got done today?" (If the plan exists, anchor explicitly to it: "Against today's plan — what got done?")
  2) "What got dropped, and was that the right call?"
  3) "What surprised you today — good or bad?"
  4) "One thing to carry into tomorrow."

If Q1's answer makes it clear the day went sideways (illness, crisis, just-rough), skip Q2 and soften Q3 to: "What's one thing worth remembering from today, even if it was rough?"

Step 3 — Write to $CLOSE_FILE using exactly this format (no frontmatter):

# $TODAY end-of-day

## What got done
{verbatim answer to Q1}

## What got dropped
{verbatim answer to Q2 — omit this whole section if you skipped Q2}

## Surprises
{verbatim answer to Q3}

## Carry forward
{verbatim answer to Q4}

Step 4 — Print the file path and ONE line of warmth. Examples:
  "Locked in. Sleep well."
  "Tomorrow's already lighter for having closed today."
  "That's a real day. Rest up."
Do not write three paragraphs of reflection at the user. The user already reflected — your job is to record, not pile on.

Hard rules:
- Quote the user's own words in the file. Don't paraphrase into corporate voice.
- Do NOT prescribe action items, accountability frameworks, or pep talks.
- Do NOT call the day a "win" or a "loss." Neutral language only.
PROMPT
