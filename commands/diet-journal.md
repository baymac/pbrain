---
description: Daily diet log — user lists meals or snacks, agent estimates macros against the diet profile, updates diet-tracking/<date>.md. First run builds a personalized versioned diet profile (targets + meal structure + times) via interview. Adds new meals, swaps planned ones, recomputes totals; meal times anchor to today's fitness session.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/diet-journal.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.** If the user passed arguments (e.g. `profile show`, `profile new`, `profile commit`), append them to the command.

The script emits one of several tokens — follow the INSTRUCTIONS for whichever fires. Key hard rules:
- Migration (`DIET_JOURNAL_MIGRATION`): merge the old profile JSON + diet plan into one versioned profile, validating part by part with the user — confirm stats, recompute stale targets, ask the new meal-times questions. Never import silently.
- First-time setup: interview in 2–3 question batches (not one at a time, not all at once). Present computed targets for confirmation before writing the profile. Don't log food until the profile is committed.
- Returning session: show a one-line macro summary, then ask what to update. Don't re-explain the profile.
- Never invent food items the user didn't mention. Estimate macros from their description; reuse the Food Library if the item matches.
- Recompute totals after every change. Keep the Nutrition Analysis table anchored to actuals, not projections.
- Meal times are fitness-anchored: pre-workout fuel and post-workout protein land relative to today's real session time; rest days use the profile's stored meal times.
- Committed profiles are final — changes go through `profile new` → edit draft → `profile commit`. The food library is a living document (rows append in place, no version bump). **Standing prefs are the same kind of living-document exception (PB-37):** a captured COMMAND preference is folded into the diet profile in place (the field it belongs to, or the top-level `prefs` array as fallback) with NO version mint — `pbrain_emit_prefs` reads that `prefs` array back next run.
- **Never auto-commit a draft.** After applying any change to a draft, show the user what changed and ask: "Want to lock this in?" (or similar). Only run `profile commit` when the user explicitly says yes / "lock" / "commit" / "save it". If they ask for more edits, keep modifying the same open draft — do NOT mint a new version. If a draft is already open at the start of a session, keep editing it rather than minting a new one.

## Morning sequence check (do this first)

Before logging meals, check the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Want to fill it in first? Clears the head before anything else." Pause.
2. Else if `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first?" Pause.

Suggest once. If user says continue / skip / no, proceed. **If the injected USER PREFERENCES block (global or per-command) says to skip the journal/gratitude nudge, skip steps 1–2 entirely** — a standing preference always overrides a built-in nudge. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
