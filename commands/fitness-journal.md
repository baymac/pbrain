---
description: Daily adaptive fitness journal — first run builds an overall fitness profile (sleep window, steps, health metrics), an activity library with fixed weekly days, and per-activity profiles via targeted interview. Subsequent runs pre-select today's session from your schedule, apply training-gap rules (no progression / deload), and generate it in your exact tracking format.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/fitness-journal.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.** If the user passed arguments (e.g. `profile show`, `profile new fitness-library`, `profile commit activity gym`), append them to the command.

The script emits one of several tokens — follow the INSTRUCTIONS for whichever fires. Key hard rules:
- Migration (`FITNESS_JOURNAL_MIGRATION`): walk the old plans/config across part by part — confirm, update, or drop each piece with the user before writing the new profiles. Never import silently.
- First-time setup: build the overall profile + library first, then one profile per activity. Process activities one at a time; finish one before moving to the next.
- Returning session: today's activity is pre-selected from the fixed days — confirm it, don't re-run a full menu interrogation. Ask readiness in one batch.
- Sleep is captured as bed time + wake time (+ quality); infer hours yourself and write the `sleep_*` frontmatter fields into the session file.
- Respect the training-gap band: 7–13 idle days → repeat weights, no progression; 14+ → deload −20% (rounded to 2.5kg). Never apply progression on a gap session.
- Generate sessions in the user's exact tracking format (match the format in the activity profile, not a generic template).
- Never schedule rest when the schedule calls for training, or training when the user signals they need rest.
- Committed profiles are final — changes go through `profile new` → edit draft → `profile commit`.
- **Never auto-commit a draft.** After applying any change to a draft, show the user what changed and ask: "Want to lock this in?" (or similar). Only run `profile commit` when the user explicitly says yes / "lock" / "commit" / "save it". If they ask for more edits, keep modifying the same open draft — do NOT mint a new version. If a draft is already open at the start of a session, keep editing it rather than minting a new one.

## Morning sequence check (do this first)

Before logging today's training, check the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Want to fill it in first? Clears the head before anything else." Pause.
2. Else if `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first?" Pause.

Suggest once. If user says continue / skip / no, proceed. **If the injected USER PREFERENCES block (global or per-command) says to skip the journal/gratitude nudge, skip steps 1–2 entirely** — a standing preference always overrides a built-in nudge. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
