#!/usr/bin/env bash
set -euo pipefail

# end-of-day.sh
# Bookend to /plan-my-day. Gathers today's plan, journal, fitness, and diet
# entries; emits a context block instructing Claude to walk a structured
# close-of-day reflection and fill the existing "How it went" section of the
# plan-my-day file in place. No sibling files — the plan file is the single
# record for the day.
#
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

# Detect whether the plan's "How it went" section is still on its template
# placeholders (single "-" bullets and empty energy curve lines) so we can
# warn the user if they're about to overwrite a filled close.
already_closed() {
  local f="$1"
  [[ -f "$f" ]] || { echo no; return; }
  awk '
    /^## How it went/ {in_sec=1; next}
    /^---$/ && in_sec {exit}
    in_sec {
      # any non-empty line that is not a header, not the placeholder "-",
      # and not a bare "Morning:"/"Afternoon:"/"Evening:" energy template
      gsub(/^[ \t]+|[ \t]+$/, "", $0)
      if ($0 == "" || $0 ~ /^#/ || $0 == "-" || $0 ~ /^- (Morning|Afternoon|Evening):$/) next
      print "filled"
      exit
    }
  ' "$f" | grep -q filled && echo yes || echo no
}

CLOSED="$(already_closed "$PLAN_FILE")"

cat <<PROMPT
END_OF_DAY_SESSION
date: $TODAY ($DOW)
plan_file: $PLAN_FILE (exists: $(exists "$PLAN_FILE"), already_closed: $CLOSED)
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

INSTRUCTIONS: Walk the user through a close-of-day reflection and fill the
existing "## How it went" section of the plan file in place. The plan file
is the single record for the day — no sibling close files.

Step 0 — Preflight:
  - If plan_file exists == no: tell the user "No /plan-my-day for today — I'll
    write a free-form close at the top of a new $PLAN_FILE." Then proceed.
  - If already_closed == yes: tell the user "Today's plan already has a
    filled-in 'How it went'. Want me to overwrite, append a note, or skip?"
    Wait for direction.

Step 1 — Skim every section above. Don't summarize generically. Note specific
items the user planned, what their journal mentioned, whether they trained,
whether they logged meals, whether the cross-ref files corroborate the day.

Step 2 — Ask, ONE question at a time. Wait for each answer before asking the next.
  1) "Against today's plan — what got done?" (anchor explicitly to the plan
     items so the user can confirm/deny each)
  2) "What got dropped, and was that the right call?"
  3) "Energy curve — morning / afternoon / evening? (1–10 each, or a word each)"
  4) "One thing to carry into tomorrow."

If Q1's answer makes it clear the day went sideways (illness, crisis,
just-rough), skip Q2 and soften the rest.

Step 3 — Use the Edit tool to replace the existing "## How it went" section
of $PLAN_FILE in place. Match the section exactly as it appears in the file
(headers may be "## How it went" or "## How it went (fill at end of day)").
The new section must follow this shape:

  ## How it went

  ### What I actually did
  - {bullets from Q1, in the user's voice}

  ### Wins
  - {1–4 bullets derived from Q1 + cross-ref files — real wins only, no padding}

  ### What slipped
  - {bullets from Q2, in the user's voice}

  ### Goal progress (vs the focus_today goals above)
  - {one bullet per focus_today goal — net positive / flat / negative with a sentence of why,
     drawing from Q1 + Q2 + cross-ref files}

  ### Energy curve
  - Morning: {from Q3}
  - Afternoon: {from Q3}
  - Evening: {from Q3}

  ### Tomorrow seed
  - {verbatim from Q4}

Step 4 — Also surface any obvious follow-ups in the OTHER files when relevant:
  - If diet_file dinner was "planned" but the user described what they actually ate,
    update the diet log meals table to "eaten" with the real items + recompute totals.
  - If fitness_file is "planned" but the user trained, you may flip status: completed.
  - Don't go beyond what the user said — these updates are bookkeeping, not analysis.

Step 5 — Print the plan file path and ONE line of warmth. Examples:
  "Locked in. Sleep well."
  "Tomorrow's already lighter for having closed today."
  "That's a real day. Rest up."

Do NOT write three paragraphs of reflection at the user. The user already
reflected — your job is to record, not pile on.

Hard rules:
- Quote the user's own words where possible — don't paraphrase into corporate voice.
- Do NOT prescribe action items, accountability frameworks, or pep talks.
- Do NOT call the day a "win" or a "loss." Neutral language only.
- Do NOT create a sibling close file. The plan file is the record.
PROMPT
