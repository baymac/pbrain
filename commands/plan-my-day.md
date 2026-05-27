---
description: Adaptive daily planner anchored on your goals. First run interviews you to build a goals profile (horizon goals, current focus, working style, anti-patterns, personal anchors). Every subsequent run plans the day against that profile, pulling today's fitness session as the one hard anchor.
---
!`bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/plan-my-day.sh"`

## Morning sequence check (do this first)

Planning the day works best on top of the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first? It anchors the day before planning." Pause.
2. Else if `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Surfaces what's on your mind before we plan." Pause.

Suggest once. If user says continue / skip / no, proceed. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
