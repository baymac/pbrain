---
description: Flexible daily fitness logger — first run builds an overall fitness profile (sleep window, steps, health metrics), an activity library with fixed weekly days + per-activity KPIs, and per-activity profiles via targeted interview. Subsequent runs are a low-friction logger — describe your session in plain words, it derives the activity's KPIs (gym→sets, swim→distance, dance→minutes), tolerates partial logs, and then OFFERS to help you plan your own session. KPIs are user-extensible.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/fitness-journal.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.** If the user passed arguments (e.g. `profile show`, `profile new fitness-library`, `profile commit activity gym`), append them to the command.

The script emits one of several tokens — follow the INSTRUCTIONS for whichever fires. Key hard rules:
- Migration (`FITNESS_JOURNAL_MIGRATION`): walk the old plans/config across part by part — confirm, update, or drop each piece with the user before writing the new profiles. Never import silently.
- First-time setup: build the overall profile + library first (capture each activity's KPIs — what to log — with sensible defaults), then one profile per activity. Process activities one at a time; finish one before moving to the next.
- **This is a LOGGER, not a prescriber.** Returning session (`FITNESS_JOURNAL_SESSION`) runs in two phases: **(1) a quick, SKIPPABLE check-in** (energy, soreness — pre-filled from recent sessions —, sleep bed/wake/quality, stress, bodyweight). It offers `skip`; on skip, ask once whether to skip it from now on and, on a yes, write a standing pref to `.pbrain/fitness-journal/prefs.md` (a `skip the check-in` pref then suppresses it on future runs). **(2) Today's picture + ONE targeted question** — a tight situational read (weekday/date, whether it's a fixed day, what's owed/carried over, the most recent relevant session) then "planning to do {the owed/scheduled session}, or something else?" — **no numbered menu dump**. Parse the plain-language description into the chosen activity's KPIs; tolerate partial/missing data. Then **OFFER** to help the user plan their OWN session — never auto-generate a prescribed workout, weights, or split.
- **Date is authoritative from the script.** The block carries `date`, `day_of_week`, and a fully-spelled `date_human` (local machine time). Use them verbatim — never compute or guess the weekday.
- Per-activity KPIs come from the library (`kpis`); when an activity has none, the script derives archetype defaults and flags them `"derived": true` — use them, and offer once to save them to the library (living-doc append). KPIs are user-extensible.
- The check-in is never a gate. When sleep is given, infer hours and write the `sleep_*` frontmatter fields (plan-my-day and the Sleep-well habit read them); flag a standout (short sleep, high soreness, low energy) in one line and suggest scaling — never prescribe, never block.
- The training-gap band and the fixed-day schedule are soft HINTS for the optional plan offer only — never forced weight calcs or a gate on what to log.
- **Planned vs Logged.** Each entry has up to two sections — `## Planned` (intended/target work per KPI) and `## Logged` (actuals). Plan-ahead-only → `## Planned` only, `status: planned`. Done / logged directly → both sections (explode the description into targets vs actuals), `status: completed` (or `partial`). `/end-of-day` flips a `planned` entry to `completed`/`skipped` at close. The "Train" habit takes planned from `## Planned` and actual from `## Logged`.
- Keep the `activity:`/`focus:` frontmatter on every entry (plan-my-day reads them) and run `fitness-reconcile` after writing. Existing/update session (`FITNESS_JOURNAL_EXISTING`): show whether it's still planned or has actuals, then log the planned session, add/correct, log a second activity, or offer plan help — rewrite in place.
- The gym Block/Day plan is an OPTIONAL reference surfaced only when the user asks for planning help — never an auto-prescribed session.
- Committed profiles are final — changes go through `profile new` → edit draft → `profile commit`.
- **Never auto-commit a draft.** After applying any change to a draft, show the user what changed and ask: "Want to lock this in?" (or similar). Only run `profile commit` when the user explicitly says yes / "lock" / "commit" / "save it". If they ask for more edits, keep modifying the same open draft — do NOT mint a new version. If a draft is already open at the start of a session, keep editing it rather than minting a new one.

## Morning sequence check (do this first)

Before logging today's training, check the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Want to fill it in first? Clears the head before anything else." Pause.
2. Else if `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first?" Pause.

Suggest once. If user says continue / skip / no, proceed. **If the injected USER PREFERENCES block (global or per-command) says to skip the journal/gratitude nudge, skip steps 1–2 entirely** — a standing preference always overrides a built-in nudge. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
