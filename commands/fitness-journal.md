---
description: Daily adaptive fitness journal — first run builds an activity list and per-activity plans via targeted interview. Subsequent runs pick today's session based on recent history and the gym plan, generate it in the user's exact tracking format.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/fitness-journal.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits one of several tokens — follow the INSTRUCTIONS for whichever fires. Key hard rules:
- First-time setup: build one plan per activity. Process them one at a time; finish one before moving to the next.
- Returning session: pick today's session based on recency and the plan. Ask readiness in one question; don't run a full intake survey.
- Generate sessions in the user's exact tracking format (match the format already in the plan file, not a generic template).
- Never schedule rest when the plan calls for training, or training when the user signals they need rest.

## Morning sequence check (do this first)

Before logging today's training, check the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Want to fill it in first? Clears the head before anything else." Pause.
2. Else if `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first?" Pause.

Suggest once. If user says continue / skip / no, proceed. **If the injected USER PREFERENCES block (global or per-command) says to skip the journal/gratitude nudge, skip steps 1–2 entirely** — a standing preference always overrides a built-in nudge. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
