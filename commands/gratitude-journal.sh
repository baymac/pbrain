#!/usr/bin/env bash
set -euo pipefail

# gratitude-journal.sh
# Interactive gratitude journal. Asks 2 questions, saves a daily entry.
# The reflection question is generated fresh each session, grounded in what
# actually surfaced today — the gratitude answer just given plus today's journal
# entry (life/daily-tracking/<date>.md). Theme rotation is only a fallback for
# days too thin to ground a question on. (PB-35)
# Runs after /journal in the morning sequence — the raw dump (and mood)
# lands in the journal first, so this stays focused purely on gratitude.
#
# Default destination:  $VAULT_DIR/life/gratitude-journal
# Overrides:
#   PBRAIN_VAULT             — set the vault root
#   PBRAIN_GRATITUDE_DIR     — set the gratitude journal directory directly
#   PBRAIN_JOURNAL_DIR       — where today's journal entry is read from (context)
#
# Usage:
#   /gratitude-journal

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /gratitude-journal (emits nothing if none set).
pbrain_emit_prefs "gratitude-journal" || true

JOURNAL_DIR="${PBRAIN_GRATITUDE_DIR:-$VAULT_DIR/life/gratitude-journal}"
mkdir -p "$JOURNAL_DIR"

TODAY="$(date +%Y-%m-%d)"
HOUR="$(date +%-H)"
OUT_FILE="$JOURNAL_DIR/$TODAY.md"

# Morning-first nudge — stronger after noon.
if (( HOUR >= 12 )); then
  TIMING_NUDGE="TIMING_NUDGE (show this verbatim before Step 1, then proceed):
  \"Quick note before we start — it's already past noon. Gratitude lands hardest early in the day, right after your journal dump, before the feed, the comparisons, the dopamine chase. Doing it early sets your baseline to *enough*, so the rest of the day runs on overflow instead of envy. When it slips late, you've usually absorbed everyone else's highlight reel before grounding yourself. Try anchoring tomorrow's entry to your first coffee. Continuing with today's now.\""
else
  TIMING_NUDGE="TIMING_NUDGE (show this verbatim before Step 1, then proceed):
  \"Nice — doing this early is the move. Gratitude right after the journal dump anchors your baseline to *enough*, so the rest of the day runs on overflow instead of comparison.\""
fi

if [[ -f "$OUT_FILE" ]]; then
  echo "Today's entry already exists: $OUT_FILE"
  echo ""
  cat "$OUT_FILE"
  exit 0
fi

# Collect past reflection question headers (3rd ## in each entry) for dedup
PAST_QUESTIONS="$(python3 - "$JOURNAL_DIR" <<'PYEOF'
import os, re, glob, sys
d = sys.argv[1]
qs = []
for f in sorted(glob.glob(os.path.join(d, "*.md")))[-30:]:
    try:
        with open(f) as fh:
            content = fh.read()
        headers = re.findall(r'^## (.+)', content, re.MULTILINE)
        # Reflection question is always the last ## header. Robust across both
        # the old 3-header format (feeling/gratitude/reflection) and the new
        # 2-header format (gratitude/reflection).
        if len(headers) >= 2:
            qs.append(headers[-1].strip())
    except Exception:
        pass
print('\n'.join(qs) if qs else "(none yet)")
PYEOF
)"

# Count existing entries to determine next theme index
ENTRY_COUNT="$(python3 - "$JOURNAL_DIR" <<'PYEOF'
import glob, os, sys
d = sys.argv[1]
print(len(glob.glob(os.path.join(d, '*.md'))))
PYEOF
)"

# Pull today's journal entry (written earlier in the morning sequence) so the
# reflection question can respond to what actually surfaced today instead of a
# blind theme rotation. Missing/empty file → a graceful placeholder that flips
# the prompt into theme-fallback mode. (PB-35)
DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
TODAY_JOURNAL_CONTEXT="$(python3 - "$DAILY_DIR/$TODAY.md" <<'PYEOF'
import os, sys
f = sys.argv[1]
text = ""
try:
    with open(f) as fh:
        text = fh.read()
except Exception:
    text = ""
# Strip a leading YAML frontmatter block.
if text.startswith("---"):
    parts = text.split("---", 2)
    if len(parts) == 3:
        text = parts[2]
text = text.strip()
if not text:
    print("(no journal entry today)")
else:
    # Keep the context bounded.
    if len(text) > 1500:
        text = text[:1500].rstrip() + " …"
    print(text)
PYEOF
)"

cat <<PROMPT
GRATITUDE_JOURNAL_SESSION
date: $TODAY
output_file: $OUT_FILE
entry_count: $ENTRY_COUNT

PAST_REFLECTION_QUESTIONS (do not reuse these or close variations):
$PAST_QUESTIONS

TODAY_JOURNAL_CONTEXT (today's journal entry — ground the reflection question in this; "(no journal entry today)" means none was written):
$TODAY_JOURNAL_CONTEXT

$TIMING_NUDGE

---
INSTRUCTIONS: Follow these steps in order.

Step 0 — Show the TIMING_NUDGE message above verbatim, then continue without waiting for a response.

Step 1 — Ask the user exactly this question, nothing else:
  "What are you grateful for in life? (share 3–6 things)"
  If they give fewer than 3 points, prompt once: "Can you add a few more? Aim for at least 3."
  If they give more than 6, keep only the first 6 in the saved entry.

Step 2 — Generate ONE reflection question grounded in what surfaced TODAY, then ask it.
  Ground it in today's material, in this priority order:
    1. The gratitude answer the user just gave in Step 1.
    2. TODAY_JOURNAL_CONTEXT above (today's dump, decisions, open questions, mood).
  Read both, find the most alive thread — a person, tension, fear, value, win, or
  decision they actually surfaced — and turn it into a single deeper question that
  invites them to look underneath it. The question must clearly connect to that
  material; do not ask a generic prompt when something specific is available.

  Theme fallback — use ONLY when today's material is too thin to ground a question
  (e.g. a terse gratitude list AND "(no journal entry today)"):
    Themes (rotate by entry_count mod 12): childhood, failure, future self, health,
      money, identity, fear, friendship, discipline, loneliness, family, regret
    Opening word (rotate by entry_count*3 mod 5): When, Who, Why, How, What

  Constraints (always):
    - Max 18 words
    - Must NOT contain: today, small thing, grateful, appreciate
    - Must NOT be semantically similar to any past question above
    - No preamble — ask only the question itself
  Fallbacks if all attempts fail:
    "What memory still teaches you who you want to become?"
    "How did one hard season quietly strengthen your character?"
    "Why does a past challenge still shape your decisions now?"
    "When did you surprise yourself by choosing growth over comfort?"
    "Who helped you change when you were close to giving up?"

Step 3 — After their answer, write the entry to: $OUT_FILE

File format (write exactly this, frontmatter included):
---
type: gratitude
date: $TODAY
tags: []
---

## What are you grateful for in life?

{gratitude answer — bullet list if they listed things, plain text otherwise}

## {the reflection question you generated}

{reflection answer — verbatim}
PROMPT

# Habit extraction (silent if no habits profile).
pbrain_emit_habits_extract "gratitude-journal" || true
