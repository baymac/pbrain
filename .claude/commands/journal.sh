#!/usr/bin/env bash
set -euo pipefail

# journal.sh
# Creates or opens today's daily journal entry in vault/life/daily-tracking/.
# If the file already exists, just prints the path (does not overwrite).
#
# Usage:
#   /journal

VAULT_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault"
DAILY_DIR="$VAULT_DIR/life/daily-tracking"

mkdir -p "$DAILY_DIR"

TODAY="$(date +%Y-%m-%d)"
OUT_FILE="$DAILY_DIR/$TODAY.md"

if [[ -f "$OUT_FILE" ]]; then
  echo "$OUT_FILE"
  exit 0
fi

cat > "$OUT_FILE" <<TEMPLATE
---
type: daily
title: "$TODAY"
tags: []
created: $TODAY
---

<!-- Daily note. Capture raw thoughts, decisions, and blockers. -->

## Focus

<!-- What are you working on today? -->

## Notes

## Decisions

## Open questions

## Tomorrow
TEMPLATE

echo "$OUT_FILE"
