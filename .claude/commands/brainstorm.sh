#!/usr/bin/env bash
set -euo pipefail

# brainstorm.sh <topic>
# Creates a brainstorming session file in vault/agent-work/ideas/.
# The topic becomes the filename slug.
#
# Usage:
#   /brainstorm "my topic idea"
#   /brainstorm my-topic-idea

if [[ $# -lt 1 ]]; then
  echo "Usage: brainstorm.sh <topic>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PBRAIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VAULT_DIR="$PBRAIN_ROOT/vault"
IDEAS_DIR="$VAULT_DIR/ideas"

mkdir -p "$IDEAS_DIR"

TOPIC="$*"
TODAY="$(date +%Y-%m-%d)"

# Slugify: lowercase, replace spaces/special chars with hyphens, collapse, max 80 chars
SLUG="$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//' | cut -c1-80)"

if [[ -z "$SLUG" ]]; then
  SLUG="untitled"
fi

OUT_FILE="$IDEAS_DIR/$SLUG.md"

# Handle collision: append -2, -3 etc. if file exists with different content
if [[ -f "$OUT_FILE" ]]; then
  echo "$OUT_FILE"
  echo ""
  echo "File already exists. Open it and continue writing, or describe your idea to Claude."
  exit 0
fi

cat > "$OUT_FILE" <<TEMPLATE
---
type: idea
title: "$TOPIC"
tags: []
created: $TODAY
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
