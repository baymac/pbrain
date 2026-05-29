#!/usr/bin/env bash
set -euo pipefail

# brainstorm.sh <topic>
# Creates a brainstorming session file. The topic becomes the filename slug.
#
# Default destination:  $VAULT_DIR/agent-work/brainstorms/{tbd,backlog,done}
# Overrides:
#   PBRAIN_VAULT             — set the vault root
#   PBRAIN_BRAINSTORMS_DIR   — set the brainstorms parent directly (tbd/backlog/done are subdirs)
#
# Usage:
#   /brainstorm "my topic idea"
#   /brainstorm my-topic-idea

if [[ $# -lt 1 ]]; then
  echo "Usage: brainstorm.sh <topic>" >&2
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

BRAINSTORMS_DIR="${PBRAIN_BRAINSTORMS_DIR:-$VAULT_DIR/agent-work/brainstorms}"
IDEAS_DIR="$BRAINSTORMS_DIR/tbd"
BACKLOG_DIR="$BRAINSTORMS_DIR/backlog"
DONE_DIR="$BRAINSTORMS_DIR/done"

mkdir -p "$IDEAS_DIR" "$BACKLOG_DIR" "$DONE_DIR"

TOPIC="$*"
TODAY="$(date +%Y-%m-%d)"

# Slugify to 3-8 significant words: strip URLs, drop stopwords, hyphenate.
SLUG="$(python3 - "$TOPIC" <<'PY'
import re, sys

text = sys.argv[1]
text = re.sub(r'https?://\S+', ' ', text)
text = re.sub(r'\b\S+\.(?:com|org|io|lol|net|dev|app|sh|gg|co|me|ai|xyz)\S*', ' ', text, flags=re.I)
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

if [[ -z "$SLUG" ]]; then
  SLUG="untitled"
fi

OUT_FILE="$IDEAS_DIR/$SLUG.md"
BACKLOG_FILE="$BACKLOG_DIR/$SLUG.md"
DONE_FILE="$DONE_DIR/$SLUG.md"

if [[ -f "$DONE_FILE" ]]; then
  echo "$DONE_FILE"
  echo ""
  echo "A brainstorm with this slug already exists in done/. Open it to review, or pick a different topic."
  exit 0
fi

if [[ -f "$BACKLOG_FILE" ]]; then
  echo "$BACKLOG_FILE"
  echo ""
  echo "A brainstorm with this slug is sitting in backlog/. Open it to continue, or pick a different topic."
  exit 0
fi

if [[ -f "$OUT_FILE" ]]; then
  echo "$OUT_FILE"
  echo ""
  echo "File already exists. Open it and continue writing, or describe your idea to Claude."
  exit 0
fi

cat > "$OUT_FILE" <<TEMPLATE
---
type: idea
date: $TODAY
title: "$TOPIC"
tags: []
status: draft
---

<!-- What's the idea? State it in one sentence. -->

## Core claim

## Why it matters

## Open questions
TEMPLATE

echo "$OUT_FILE"
echo ""
echo "File created. Open it and start writing, or describe your idea to Claude."
