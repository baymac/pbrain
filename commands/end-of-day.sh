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

# Surface this user's standing preferences for /end-of-day (emits nothing if none set).
pbrain_emit_prefs "end-of-day" || true

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

# Reminders + habits surfacing. No-ops (empty output) until the user opts in.
# Firing due reminders here is deduped by fired_at, so it won't double-ping.
pbrain_reminders_tick || true
REMINDERS_PENDING="$(pbrain_reminders_pending_text || true)"
[[ -n "${REMINDERS_PENDING//[[:space:]]/}" ]] || REMINDERS_PENDING="(none)"
# Sync recent habit-tracking md into the DB so the rollup reflects today's marks.
pbrain_habits_sync_range 7 || true
HABITS_ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
[[ -n "${HABITS_ROLLUP//[[:space:]]/}" ]] || HABITS_ROLLUP="(no habit data)"
if [[ -f "$(pbrain_habits_profile_file)" ]]; then HABITS_SETUP_NEEDED=no; else HABITS_SETUP_NEEDED=yes; fi
HABITS_CMD="$(pbrain_habits_cmd 2>/dev/null || true)"
HABITS_TRACK_FILE="$(pbrain_habit_track_file "$TODAY" 2>/dev/null || true)"
REMIND_CMD="$(pbrain_reminders_cmd)"

cat <<PROMPT
END_OF_DAY_SESSION
date: $TODAY ($DOW)
plan_file: $PLAN_FILE (exists: $(exists "$PLAN_FILE"), already_closed: $CLOSED)
journal_file: $JOURNAL_FILE (exists: $(exists "$JOURNAL_FILE"))
fitness_file: $FITNESS_FILE (exists: $(exists "$FITNESS_FILE"))
diet_file: $DIET_FILE (exists: $(exists "$DIET_FILE"))
habits_setup_needed: $HABITS_SETUP_NEEDED

--- PLAN ---
$(read_or_missing "$PLAN_FILE")

--- JOURNAL ---
$(read_or_missing "$JOURNAL_FILE")

--- FITNESS ---
$(read_or_missing "$FITNESS_FILE")

--- DIET ---
$(read_or_missing "$DIET_FILE")

--- PENDING REMINDERS ---
$REMINDERS_PENDING

--- HABITS (this week / month vs each habit's criteria) ---
$HABITS_ROLLUP
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
  5) DECLUTTER — ask ONLY IF the plan above has a "## Declutter" section with an
     unchecked item ("- [ ]"): "Did you get to the declutter task — {item}?"
     SKIP this question entirely if there's no declutter item, it's already
     ticked ("- [x]"), or the user's preferences (top of session) say not to ask
     about decluttering.

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

Step 4 — Propagate the close into the cross-ref files. This is bookkeeping
the user expects to be automatic — do all of these whenever the inputs apply,
without re-asking. Use the Edit tool on each file.

4a) DIET FILE (\$DIET_FILE) — if Q1 mentions food, OR diet_file has any meal
    row with status != "eaten":

  • For every meal row whose status is "planned"/"planned (revise)"/"proposed":
    - If the user described what they actually ate for that slot → replace
      Items + recompute Cals/P/C/F/Fiber against the new items, flip Status to
      "eaten". Add new rows for snacks/shakes the user mentioned that aren't
      in the table yet (e.g. an 8 PM protein shake).
    - If the user skipped that meal entirely → flip Status to "skipped" and
      zero out the macros.
  • Recompute the **Total (actual)** row and the **Net vs target** row.
    Header for that row should read "Total (actual)" — not "Total (so far)".
  • Update the **Hydration** / **Late eating (after 9pm)** lines from Q1.
  • REBUILD the **Nutrition Analysis** table against actuals — don't leave
    stale notes referencing the planned dinner. Each row's note must reflect
    what actually happened today, with ✅/⚠️/❌ recalibrated to actual numbers.
    Add a **Calorie total** row if the day finished significantly under/over.
  • REMOVE any "Suggested next meal(s)" / "Suggested improvement" section
    entirely — that section was forward-looking and is stale at close. Replace
    it with a short "## Carry-forward for tomorrow" list (3–5 bullets) drawn
    from the actual day's gaps.
  • Update the **Coach note** at the bottom to reflect the day that actually
    happened — name the real wins + the real gaps, not the projected ones.

4b) FITNESS FILE (\$FITNESS_FILE) — if Q1 mentions any movement at all:

  • If the planned session happened → flip frontmatter "status: planned" to
    "status: completed". Don't touch the logged sets the user already filled.
  • If the planned session was skipped → frontmatter "status: skipped" with a
    one-line reason in the body.
  • If Q1 mentions ADDITIONAL movement beyond the planned session (walks,
    ring closes, extra cardio, yoga, kickboxing, etc.) → append a section
    titled "## Other movement today" at the bottom with bullets for each
    item. Include rough timing if the user said it. Don't invent items.

4c) JOURNAL FILE (\$JOURNAL_FILE) — leave alone. The journal is the user's
    own raw voice from earlier in the day; the close does not edit it.

4d) DECLUTTER — if you asked Q5 and the user did the task, tick its checkbox in
    the plan file: "- [ ] {item}" → "- [x] {item}". If they didn't get to it,
    leave it unchecked (it surfaces in /loose-ends). No new section, just the
    tick.

4e) REMINDERS — read the PENDING REMINDERS block above:
    - If any are OVERDUE or were due today, ask once which (if any) the user
      handled, and mark those done: \`bash "$REMIND_CMD" done <id>\` (id = [#N]).
    - Offer once to set a reminder for anything that should resurface tomorrow
      (often the "carry into tomorrow" answer or a dropped item worth not
      losing): \`bash "$REMIND_CMD" add --text "<text>" --due "<YYYY-MM-DD HH:MM>"\`.
      Write only on a yes. Don't pester — one short offer.

4f) HABITS — read the HABITS block + \`habits_setup_needed\`:
    - If \`habits_setup_needed\` == yes: mention ONCE (unless prefs say not to
      nag) — "You haven't set up habit tracking yet — /habits picks a few habits
      to build or cap. Worth a look." Don't block the close.
    - If a rollup is present: note standouts in one line (a limit habit over
      cap, a high-priority build habit that lagged). Marking today's habits in
      the tracking md is handled by the HABIT EXTRACTION block below — do that
      FIRST (mark everything the day's PLAN/JOURNAL/FITNESS/DIET above shows the
      user did), THEN consolidate the day:
        bash "$HABITS_CMD" consolidate --date $TODAY
      Consolidate syncs today's tracking file ($HABITS_TRACK_FILE) into the
      analysis DB and prunes the habits you didn't do from the day's entry, so
      weekly/monthly reviews have accurate data. Run it once, after marking.

Do these silently as part of writing the close — surface one short summary
line per file you touched in your final message. Do NOT skip 4a/4b because
they feel like extra work; this is the entire point of the new flow.

Don't go beyond what the user said — these updates are bookkeeping, not
new analysis or new prescriptions.

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

# Habit extraction (silent if no habits profile): logs the tracked habits the
# user evidenced doing/skipping today. Self-improvement capture runs after.
pbrain_emit_habits_extract "end-of-day" || true
pbrain_emit_self_improve "end-of-day" || true
