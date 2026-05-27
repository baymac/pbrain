---
description: Walk through vault/Clippings/ and move each clip into one of your chosen top-level vault folders (or any subpath underneath), renaming if needed. Asks upfront which dirs to use. Decides on its own when confident, asks when split.
---
!`bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/organize-clippings.sh"`

## Morning sequence check (do this first)

Before sorting clippings, check the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first?" Pause.
2. Else if `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Want to fill it in first?" Pause.

Suggest once. If user says continue / skip / no, proceed. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
