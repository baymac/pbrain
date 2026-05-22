#!/usr/bin/env bash
set -euo pipefail

# journal.sh
# Creates or opens today's daily journal entry in vault/agent-work/daily/.
# If the file already exists, just prints the path (does not overwrite).
#
# Usage:
#   /journal

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PBRAIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VAULT_DIR="$PBRAIN_ROOT/vault"
DAILY_DIR="$VAULT_DIR/agent-work/daily"

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
