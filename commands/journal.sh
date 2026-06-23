#!/usr/bin/env bash
set -euo pipefail

# journal.sh
# Quiet daily journal. Doesn't ask an opening question — the user just
# starts writing. Claude treats whatever they share as the dump, scans for
# unresolved threads, and only asks open questions when there are any to
# ask. No prompts otherwise — just capture and save.
#
# If today's file already exists, the session resumes additively — Claude
# appends to existing sections instead of overwriting.
#
# Default destination:  $VAULT_DIR/life/daily-tracking
# Overrides:
#   PBRAIN_VAULT          — set the vault root
#   PBRAIN_JOURNAL_DIR    — set the journal directory directly

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /journal (emits nothing if none set).
pbrain_emit_prefs "journal" || true

DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
mkdir -p "$DAILY_DIR"

TODAY="$(date +%Y-%m-%d)"
TIME="$(date +%H:%M)"
OUT_FILE="$DAILY_DIR/$TODAY.md"

# Whatever the user typed after the slash command (the dump) arrives as args.
# When present, the entry is already in hand — ingest it and skip the wait.
DUMP="$*"

if [[ -f "$OUT_FILE" ]]; then
  cat <<EXISTING
JOURNAL_SESSION_RESUME
date: $TODAY
time: $TIME
output_file: $OUT_FILE
dump_provided: $([[ -n "$DUMP" ]] && echo yes || echo no)
$([[ -n "$DUMP" ]] && printf 'provided_dump: |\n%s\n' "$(printf '%s\n' "$DUMP" | sed 's/^/  /')")

Today's journal already exists. Current contents:

---
$(cat "$OUT_FILE")
---

INSTRUCTIONS:
Step 1 — Get the entry.
  - If dump_provided is yes, the user already typed their entry as the command
    argument (shown above as provided_dump). Treat THAT as what they shared —
    do NOT say "Go ahead." or wait. Go straight to Step 2.
  - If dump_provided is no, keep the opener minimal — one short line like
    "Go ahead." — then wait for them to share. Do not summarize or ask what's
    on their mind; they came here to log something specific.

Step 2 — Once you have the entry, decide if a follow-up is warranted:
  - Reflective entry (a mistake, a decision, something emotionally loaded):
    ask ONE follow-up question about the "why" or "what now" — pulled from their
    actual words, not a generic prompt. Wait for their answer.
  - Factual log (finished a task, did an activity, ate something, went somewhere):
    skip straight to Step 3 with no question.

Step 3 — Append a timestamped entry to $OUT_FILE.
  - If "## Log" already exists in the file, append the new entry under it.
  - If "## Log" does not exist, add it after the last line of the file, then
    append the entry under it.
  - Format each entry as:

### $TIME

{Content in the user's voice — what happened, why (if they explained), any
reflection they offered. Bullets if they listed things; prose otherwise.
Keep it tight.}

  Do NOT touch the existing ## Focus / ## Notes / ## Decisions / ## Open questions
  sections. Do NOT rewrite, summarize, or consolidate anything already in the file.
EXISTING
  pbrain_emit_habits_extract "journal" || true
  exit 0
fi

cat <<PROMPT
JOURNAL_SESSION
date: $TODAY
output_file: $OUT_FILE
dump_provided: $([[ -n "$DUMP" ]] && echo yes || echo no)
$([[ -n "$DUMP" ]] && printf 'provided_dump: |\n%s\n' "$(printf '%s\n' "$DUMP" | sed 's/^/  /')")

INSTRUCTIONS: This is a quiet daily journal. Do NOT ask the user what's on
their mind.
  - If dump_provided is yes, the user already typed their dump as the command
    argument (shown above as provided_dump). Do NOT say "Ready when you are."
    or wait — treat provided_dump as the dump and go straight to Step 1.
  - If dump_provided is no, wait for them to share whatever they want to
    share — that's the dump. Until they do, just say one short line like
    "Ready when you are." and wait.

Once you have the dump, follow these steps in order.

Step 1 — Silently scan the dump for:
  - Focus       → the headline of what they're working on
  - Notes       → raw thoughts worth keeping
  - Decisions   → things they've already chosen or concluded
  - Open threads → things they mentioned but did NOT resolve

Step 2 — If there are open threads, generate 2–3 open questions. Rules:
  - Pull phrasing from their actual words, not generic prompts
  - Each question points at something they didn't decide yet
  - Make it a question they'd actually want to sit with
  - Don't ask things they already answered in the dump

  If there are NO open threads, skip straight to Step 4. Don't invent
  questions just to have something to ask. A quiet day is fine.

Step 3 — If Step 2 produced any questions, you MUST run the interview before
  writing anything: ask each question one at a time, waiting for a response
  before asking the next. Keep it conversational. If they say "skip" or "no
  idea", move on and record "—" as that one's answer. Do NOT skip the
  interview, and do NOT pre-fill or write "—" for a question you never
  actually asked. Only when every question has an answer (or an explicit
  skip) do you proceed to Step 4.

Step 4 — Write the entry to $OUT_FILE with this exact structure:

---
type: daily
date: $TODAY
tags: []
---

## Focus

{1–2 line headline derived from the dump, in their voice}

## Notes

{The dump, lightly cleaned. Preserve their phrasing. Use bullets if they
listed things, paragraphs otherwise.}

## Decisions

{Bullet list of decisions extracted from the dump, in their voice.
If none, write: —}

## Open questions

{Bullet list — each question from Step 2 followed by the answer the user
gave in the Step 3 interview, indented under it. Example:

- Should I refactor the auth layer before the launch?
  Their answer here.

Use only answers you actually collected in Step 3. If a question was
skipped, record "—" as the answer. If Step 2 produced no questions at all,
write: —}
PROMPT

# Habit extraction (silent if no habits profile).
pbrain_emit_habits_extract "journal" || true
