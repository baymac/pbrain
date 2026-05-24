#!/usr/bin/env bash
set -euo pipefail

# gratitude-journal.sh
# Interactive gratitude journal. Asks 3 questions, saves to vault/life/gratitude-journal/.
# Reflection question is generated fresh each session using theme rotation.
#
# Usage:
#   /gratitude-journal

VAULT_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault"
JOURNAL_DIR="$VAULT_DIR/life/gratitude-journal"
mkdir -p "$JOURNAL_DIR"

TODAY="$(date +%Y-%m-%d)"
OUT_FILE="$JOURNAL_DIR/$TODAY.md"

if [[ -f "$OUT_FILE" ]]; then
  echo "Today's entry already exists: $OUT_FILE"
  echo ""
  cat "$OUT_FILE"
  exit 0
fi

# Collect past reflection question headers (3rd ## in each entry) for dedup
PAST_QUESTIONS="$(python3 <<'PYEOF'
import os, re, glob
d = os.path.expanduser(
    "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault/life/gratitude-journal"
)
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
ENTRY_COUNT="$(python3 -c "
import glob, os
d = os.path.expanduser('~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault/life/gratitude-journal')
print(len(glob.glob(os.path.join(d, '*.md'))))
" 2>/dev/null || echo "0")"

cat <<PROMPT
GRATITUDE_JOURNAL_SESSION
date: $TODAY
output_file: $OUT_FILE
entry_count: $ENTRY_COUNT

PAST_REFLECTION_QUESTIONS (do not reuse these or close variations):
$PAST_QUESTIONS

---
INSTRUCTIONS: Follow these steps in order.

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
