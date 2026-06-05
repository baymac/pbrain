#!/usr/bin/env bash
set -euo pipefail

# thoughts.sh [<thought text>]
# Sets up today's thought-tracking file and emits a THOUGHT_ENTRY block.
# Claude "explodes" the thought and appends the expanded entry to the file.
# No args: prompts Claude to ask for a thought first.
#
# Default destination:  $VAULT_DIR/life/thought-tracking/YYYY-MM-DD.md
# Overrides:
#   PBRAIN_VAULT          — set the vault root
#   PBRAIN_THOUGHTS_DIR   — set the thoughts directory directly

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

pbrain_emit_prefs "thoughts" || true

THOUGHTS_DIR="${PBRAIN_THOUGHTS_DIR:-$VAULT_DIR/life/thought-tracking}"
mkdir -p "$THOUGHTS_DIR"

TODAY="$(date +%Y-%m-%d)"
NOW="$(date +%H:%M)"
OUT_FILE="$THOUGHTS_DIR/$TODAY.md"

if [[ $# -eq 0 ]]; then
  cat <<NOTHOUGHT
THOUGHT_PROMPT
date: $TODAY
time: $NOW
output_file: $OUT_FILE
NOTHOUGHT
  exit 0
fi

THOUGHT="$*"

if [[ ! -f "$OUT_FILE" ]]; then
  printf '# Thoughts \xe2\x80\x94 %s\n' "$TODAY" > "$OUT_FILE"
fi

cat <<ENTRY
THOUGHT_ENTRY
date: $TODAY
time: $NOW
output_file: $OUT_FILE
raw: $THOUGHT
ENTRY

pbrain_emit_self_improve "thoughts" || true
