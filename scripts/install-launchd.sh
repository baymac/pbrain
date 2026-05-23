#!/usr/bin/env bash
# Render launchd/com.pbrain.sync.plist.template with your local paths,
# copy it into ~/Library/LaunchAgents/, and load it.
#
# Override the vault path by exporting VAULT_DIR before running.
# Override the bun bin dir by exporting BUN_BIN before running.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_DIR/launchd/com.pbrain.sync.plist.template"
DEST="$HOME/Library/LaunchAgents/com.pbrain.sync.plist"

VAULT_DIR="${VAULT_DIR:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault}"
BUN_BIN="${BUN_BIN:-$HOME/.bun/bin}"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "template not found: $TEMPLATE" >&2
  exit 1
fi
if [[ ! -d "$VAULT_DIR" ]]; then
  echo "vault dir not found: $VAULT_DIR" >&2
  echo "set VAULT_DIR env var if your vault lives elsewhere." >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/pbrain"

sed \
  -e "s|__HOME__|$HOME|g" \
  -e "s|__REPO__|$REPO_DIR|g" \
  -e "s|__VAULT__|$VAULT_DIR|g" \
  -e "s|__BUN_BIN__|$BUN_BIN|g" \
  "$TEMPLATE" > "$DEST"

# Reload (unload first if already loaded)
launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"

echo "installed: $DEST"
echo "loaded:    $(launchctl list | grep com.pbrain.sync || echo 'not loaded')"
echo
echo "trigger one run:  launchctl start com.pbrain.sync"
echo "view dashboard:   $REPO_DIR/scripts/gbrain-dashboard.sh"
