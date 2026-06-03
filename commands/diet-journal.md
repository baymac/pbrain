---
description: Daily diet log — user lists meals or snacks, agent estimates macros against the diet plan, updates diet-tracking/<date>.md. First run builds a personalized macro plan via interview. Adds new meals, swaps planned ones, recomputes totals.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/diet-journal.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits one of several tokens — follow the INSTRUCTIONS for whichever fires. Key hard rules:
- First-time setup: interview in 2–3 question batches (not one at a time, not all at once). Don't log food until the plan is built.
- Returning session: show a one-line macro summary, then ask what to update. Don't re-explain the plan.
- Never invent food items the user didn't mention. Estimate macros from their description; reuse the Food Library if the item matches.
- Recompute totals after every change. Keep the Nutrition Analysis table anchored to actuals, not projections.

## Morning sequence check (do this first)

Before logging meals, check the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Want to fill it in first? Clears the head before anything else." Pause.
2. Else if `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first?" Pause.

Suggest once. If user says continue / skip / no, proceed. **If the injected USER PREFERENCES block (global or per-command) says to skip the journal/gratitude nudge, skip steps 1–2 entirely** — a standing preference always overrides a built-in nudge. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
