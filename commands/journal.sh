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
OUT_FILE="$DAILY_DIR/$TODAY.md"

if [[ -f "$OUT_FILE" ]]; then
  cat <<EXISTING
JOURNAL_SESSION_RESUME
date: $TODAY
output_file: $OUT_FILE

Today's journal already exists. Current contents:

---
$(cat "$OUT_FILE")
---

INSTRUCTIONS:
Step 1 — Summarize the existing entry in one line (Focus + counts of notes / decisions / open questions), then say:
  "Anything to add?"
  (Don't ask anything else — wait for them to either share more or end the session.)

Step 2 — If they share more, scan the new content for unresolved threads.
  If you find any, generate 1–2 follow-up open questions in their own
  words and ask them one at a time before saving. If there are no
  unresolved threads, just save without asking anything.

Step 3 — Append the new content to the right sections in $OUT_FILE
  (## Focus, ## Notes, ## Decisions, ## Open questions). Preserve
  existing content verbatim. Never overwrite the whole file. New open
  questions go under ## Open questions as bullets, with the user's answer
  indented under each one (or "—" if they skipped).
EXISTING
  pbrain_emit_habits_extract "journal" || true
  exit 0
fi

cat <<PROMPT
JOURNAL_SESSION
date: $TODAY
output_file: $OUT_FILE

INSTRUCTIONS: This is a quiet daily journal. Do NOT ask the user what's on
their mind. Wait for them to share whatever they want to share — that's
the dump. If they haven't shared anything yet, just say one short line
like "Ready when you are." and wait.

Once they've shared, follow these steps in order.

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

Step 3 — Ask each open question one at a time, waiting for a response.
  Keep it conversational. If they say "skip" or "no idea", move on and
  record "—" as the answer for that one.

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

{Bullet list — each question followed by the user's answer indented under
it. Example:

- Should I refactor the auth layer before the launch?
  Their answer here.

If a question was skipped, record "—" as the answer. If Step 2 produced
no questions at all, write: —}
PROMPT

# Habit extraction (silent if no habits profile) + self-improvement capture.
pbrain_emit_habits_extract "journal" || true
pbrain_emit_self_improve "journal" || true
