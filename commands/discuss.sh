#!/usr/bin/env bash
set -euo pipefail

# discuss.sh <topic>
# Personal dilemma discussion — a Socratic thinking partner that reads your
# pbrain context (journal, gratitude, goals profile) before engaging. Saves
# a short note with the insight/resolution to agent-work/notes/.
#
# Default destination:  $VAULT_DIR/agent-work/notes
# Overrides:
#   PBRAIN_VAULT         — vault root
#   PBRAIN_NOTES_DIR     — override the notes dir directly

if [[ $# -lt 1 ]]; then
  echo "Usage: discuss.sh <what's on your mind>" >&2
  exit 1
fi

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

pbrain_emit_prefs "discuss" || true

NOTES_DIR="${PBRAIN_NOTES_DIR:-$VAULT_DIR/agent-work/notes}"
DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
GRATITUDE_DIR="${PBRAIN_GRATITUDE_DIR:-$VAULT_DIR/life/gratitude-journal}"
PROFILE_FILE="${PBRAIN_PLAN_PROFILE_FILE:-$VAULT_DIR/life/Goals Profile.md}"

mkdir -p "$NOTES_DIR"

TOPIC="$*"
TODAY="$(date +%Y-%m-%d)"
YESTERDAY="$(python3 -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=1)).isoformat())")"

SLUG="$(python3 - "$TOPIC" <<'PY'
import re, sys

text = sys.argv[1]
text = re.sub(r'https?://\S+', ' ', text)
text = re.sub(r'[^a-z0-9\s]', ' ', text.lower())
words = text.split()

STOP = {
    'a','an','the','and','or','but','if','then','to','of','for','in','on','at','by',
    'with','from','as','is','are','was','were','be','been','being','have','has','had',
    'do','does','did','will','would','should','could','can','may','might','must',
    'i','you','we','they','he','she','it','this','that','these','those',
    'my','your','our','their','its','his','her','them','us','me','him',
    'so','too','very','just','also','only','than','any','some','no','not',
    'into','onto','about','over','under','out','up','down','off','more','most',
    'maybe','still','really','quite','pretty','kind','sort','like','want','need',
    'get','got','make','made','say','said','think','thought','know','knew',
    'one','two','three','here','there','what','when','where','why','how',
}

keep = [w for w in words if w not in STOP and len(w) > 1]
slug_words = keep[:5]
if len(slug_words) < 3:
    extras = [w for w in words if w not in slug_words and len(w) > 1]
    slug_words.extend(extras[: 3 - len(slug_words)])
if len(slug_words) > 8:
    slug_words = slug_words[:8]
if not slug_words:
    slug_words = ['untitled']

print('-'.join(slug_words))
PY
)"

[[ -z "$SLUG" ]] && SLUG="untitled"

OUT_FILE="$NOTES_DIR/$TODAY-$SLUG.md"

# Resume if the note already exists from today.
if [[ -f "$OUT_FILE" ]]; then
  echo "$OUT_FILE"
  echo ""
  echo "A note for this topic already exists today. Resuming."
  echo ""
  echo "--- EXISTING NOTE ---"
  cat "$OUT_FILE"
  echo "--- END NOTE ---"
  pbrain_emit_self_improve "discuss" || true
  exit 0
fi

# Write the stub — agent fills it in at the end.
cat > "$OUT_FILE" <<STUB
---
type: discuss
date: $TODAY
title: "$TOPIC"
tags: []
---

## The dilemma

## What surfaced

## Resolution / insight
STUB

# ---------------------------------------------------------------------------
# Context block — read silently by the agent before engaging.
# ---------------------------------------------------------------------------
echo "DISCUSS_SESSION"
echo "date: $TODAY"
echo "topic: $TOPIC"
echo "output_file: $OUT_FILE"
echo ""

# Today's journal
if [[ -f "$DAILY_DIR/$TODAY.md" ]]; then
  echo "--- JOURNAL (today) ---"
  python3 - "$DAILY_DIR/$TODAY.md" <<'PY'
import sys
with open(sys.argv[1]) as f:
    content = f.read()
# Strip frontmatter
if content.startswith('---'):
    parts = content.split('---', 2)
    content = parts[2].strip() if len(parts) >= 3 else content
# Cap at 1200 chars to keep context lean
if len(content) > 1200:
    content = content[:1200] + "\n[...truncated]"
print(content)
PY
  echo "--- END JOURNAL ---"
  echo ""
elif [[ -f "$DAILY_DIR/$YESTERDAY.md" ]]; then
  echo "--- JOURNAL (yesterday) ---"
  python3 - "$DAILY_DIR/$YESTERDAY.md" <<'PY'
import sys
with open(sys.argv[1]) as f:
    content = f.read()
if content.startswith('---'):
    parts = content.split('---', 2)
    content = parts[2].strip() if len(parts) >= 3 else content
if len(content) > 800:
    content = content[:800] + "\n[...truncated]"
print(content)
PY
  echo "--- END JOURNAL ---"
  echo ""
fi

# Today's gratitude
if [[ -f "$GRATITUDE_DIR/$TODAY.md" ]]; then
  echo "--- GRATITUDE (today) ---"
  python3 - "$GRATITUDE_DIR/$TODAY.md" <<'PY'
import sys
with open(sys.argv[1]) as f:
    content = f.read()
if content.startswith('---'):
    parts = content.split('---', 2)
    content = parts[2].strip() if len(parts) >= 3 else content
if len(content) > 600:
    content = content[:600] + "\n[...truncated]"
print(content)
PY
  echo "--- END GRATITUDE ---"
  echo ""
fi

# Goals profile (focus areas + personal anchors only)
if [[ -f "$PROFILE_FILE" ]]; then
  echo "--- GOALS PROFILE (focus areas + anchors) ---"
  python3 - "$PROFILE_FILE" <<'PY'
import sys, re, json

with open(sys.argv[1]) as f:
    content = f.read()

# Extract the JSON block
m = re.search(r'```json\s*(.*?)\s*```', content, re.DOTALL)
if not m:
    sys.exit(0)

try:
    data = json.loads(m.group(1))
except Exception:
    sys.exit(0)

# Print only the fields that matter for personal context
keys = ['current_focus', 'personal_anchors', 'anti_patterns', 'horizon_goals']
out = {}
for k in keys:
    if k in data and data[k]:
        out[k] = data[k]

if out:
    print(json.dumps(out, indent=2, ensure_ascii=False))
PY
  echo "--- END GOALS PROFILE ---"
  echo ""
fi

cat <<'INSTRUCTIONS'
INSTRUCTIONS:
You are a personal thinking partner helping the user work through a dilemma.
The context blocks above are background — read them silently. Do NOT reference
them explicitly unless the user brings something up that clearly connects.

Rules:
- One question at a time. Always. Never two in a row without waiting for a response.
- Start by acknowledging the topic in one short sentence, then ask the first
  question. Do NOT recap, rephrase, or explain their dilemma back to them.
- Questions should deepen, not widen. Each one should follow from what they
  just said — pull on the thread, don't introduce new threads.
- Do NOT offer solutions, advice, or suggestions unless the user explicitly
  asks for them ("what do you think I should do?"). Your job is to help them
  think, not to think for them.
- Do NOT validate or reassure reflexively ("that's totally valid", "I hear you").
  Stay neutral and curious.
- When the user seems to have landed somewhere — a realization, a decision, a
  clearer framing — pause and check: "Does that feel like the thing?" If yes,
  offer to write up the note. If no, keep going.
- When writing the note, use the user's own words. Flat numbered or bulleted
  list, telegraphic one-liners, → for consequences. No bold headers inside
  sections — the section titles (## The dilemma, ## What surfaced,
  ## Resolution / insight) are enough.
- The session ends when the user feels resolved, not when a verdict is reached.
  It's fine if they leave with more clarity but no decision.
INSTRUCTIONS

pbrain_emit_self_improve "discuss" || true
