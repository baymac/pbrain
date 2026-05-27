#!/usr/bin/env bash
set -euo pipefail

# gratitude-journal.sh
# Interactive gratitude journal. Asks 3 questions, saves a daily entry.
# Reflection question is generated fresh each session using theme rotation.
#
# Default destination:  $VAULT_DIR/life/gratitude-journal
# Overrides:
#   PBRAIN_VAULT             — set the vault root
#   PBRAIN_GRATITUDE_DIR     — set the gratitude journal directory directly
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

JOURNAL_DIR="${PBRAIN_GRATITUDE_DIR:-$VAULT_DIR/life/gratitude-journal}"
mkdir -p "$JOURNAL_DIR"

TODAY="$(date +%Y-%m-%d)"
HOUR="$(date +%-H)"
OUT_FILE="$JOURNAL_DIR/$TODAY.md"

# Morning-first nudge — stronger after noon.
if (( HOUR >= 12 )); then
  TIMING_NUDGE="TIMING_NUDGE (show this verbatim before Step 1, then proceed):
  \"Quick note before we start — it's already past noon. Gratitude lands hardest first thing in the morning, before the feed, the comparisons, the dopamine chase. Doing it early sets your baseline to *enough*, so the rest of the day runs on overflow instead of envy. When it slips late, you've usually absorbed everyone else's highlight reel before grounding yourself. Try anchoring tomorrow's entry to your first coffee. Continuing with today's now.\""
else
  TIMING_NUDGE="TIMING_NUDGE (show this verbatim before Step 1, then proceed):
  \"Nice — doing this early is the move. Gratitude first thing anchors your baseline to *enough*, so the rest of the day runs on overflow instead of comparison.\""
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
        if len(headers) >= 3:
            qs.append(headers[2].strip())
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

cat <<PROMPT
GRATITUDE_JOURNAL_SESSION
date: $TODAY
output_file: $OUT_FILE
entry_count: $ENTRY_COUNT

PAST_REFLECTION_QUESTIONS (do not reuse these or close variations):
$PAST_QUESTIONS

$TIMING_NUDGE

---
INSTRUCTIONS: Follow these steps in order.

Step 0 — Show the TIMING_NUDGE message above verbatim, then continue without waiting for a response.

Step 1 — Ask the user exactly this question, nothing else:
  "How are you feeling?"

Step 2 — After their answer, ask exactly:
  "What are you grateful for in life? (share 3–6 things)"
  If they give fewer than 3 points, prompt once: "Can you add a few more? Aim for at least 3."
  If they give more than 6, keep only the first 6 in the saved entry.

Step 3 — Generate a reflection question using these rules, then ask it:
  Themes (rotate by entry_count mod 12): childhood, failure, future self, health,
    money, identity, fear, friendship, discipline, loneliness, family, regret
  Opening word (rotate by entry_count*3 mod 5): When, Who, Why, How, What
  Constraints:
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

Step 4 — After their answer, write the entry to: $OUT_FILE

File format (write exactly this, no frontmatter):
## How are you feeling

{feeling answer — verbatim}

## What are you grateful for in life?

{gratitude answer — bullet list if they listed things, plain text otherwise}

## {the reflection question you generated}

{reflection answer — verbatim}
PROMPT
