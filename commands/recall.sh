#!/usr/bin/env bash
set -euo pipefail

# recall.sh <query>
# Grep-based recall across the vault. Surfaces every markdown file that
# mentions the query and prints surrounding context for Claude to
# synthesize. Stdlib-only, fast, no embeddings — the 70% answer for
# "what date did I write about X?" without gbrain.
#
# Default scope: life/ agent-work/ startup/ side-quests/ software-dev/ notes/
# Skipped: Clippings/ (third-party), fitness/daily-tracking/ (numeric logs).
#
# Overrides:
#   PBRAIN_VAULT          — vault root
#   PBRAIN_RECALL_SCOPE   — space-separated subdir list (relative to vault)

if [[ $# -lt 1 ]]; then
  echo "Usage: recall.sh <query>" >&2
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

QUERY="$*"

DEFAULT_SCOPE="life agent-work startup side-quests software-dev notes"
SCOPE="${PBRAIN_RECALL_SCOPE:-$DEFAULT_SCOPE}"

if command -v rg >/dev/null 2>&1; then
  GREPPER="rg"
else
  GREPPER="grep"
fi

TARGETS=()
SKIPPED=()
for sub in $SCOPE; do
  if [[ -d "$VAULT_DIR/$sub" ]]; then
    TARGETS+=("$VAULT_DIR/$sub")
  else
    SKIPPED+=("$sub")
  fi
done

echo "RECALL_QUERY: $QUERY"
echo "RECALL_VAULT: $VAULT_DIR"
echo "RECALL_SCOPE: $SCOPE"
echo "RECALL_GREPPER: $GREPPER"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "RECALL_SKIPPED_MISSING: ${SKIPPED[*]}"
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo ""
  echo "No matching subdirs found in $VAULT_DIR (looked for: $SCOPE)" >&2
  echo "Set PBRAIN_RECALL_SCOPE to override." >&2
  exit 1
fi

echo ""
echo "--- MATCHES (markdown only, case-insensitive, 2 lines of context) ---"

if [[ "$GREPPER" == "rg" ]]; then
  rg -i --no-heading --line-number --context 2 --type md \
    -- "$QUERY" "${TARGETS[@]}" 2>/dev/null || true
else
  grep -rni --include='*.md' -B 2 -A 2 -- "$QUERY" "${TARGETS[@]}" 2>/dev/null || true
fi

echo ""
echo "--- END MATCHES ---"
