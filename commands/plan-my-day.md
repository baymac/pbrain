---
description: Adaptive daily planner anchored on your goals. First run interviews you to build a goals profile (horizon goals, current focus, working style, anti-patterns, personal anchors). Every subsequent run plans the day against that profile, pulling today's fitness session as the one hard anchor.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/plan-my-day.sh"
```

**Run bash immediately.** The script injects today's goals profile, fitness session, and carryover items as context. Follow the INSTRUCTIONS in its output. The fitness session is the one hard anchor — always place it in the plan. Don't plan beyond today.

## Morning sequence check (do this first)

Planning the day works best on top of the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Surfaces what's on your mind before we plan." Pause.
2. Else if `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first? It anchors the day before planning." Pause.

Suggest once. If user says continue / skip / no, proceed. **If the injected USER PREFERENCES block (global or per-command) says to skip the journal/gratitude nudge, skip steps 1–2 entirely** — a standing preference always overrides a built-in nudge. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
