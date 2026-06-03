---
description: Habit tracking. First run interviews you one question at a time to build a habits profile — each habit with its own criteria (daily / N-per-week / N-per-month, build or limit) and a priority. Day-to-day tracking lives in dated markdown files (life/habit-tracking/<date>.md) you tick like a checklist; a SQLite store is synced from them for analysis. Afterward it shows your progress vs each criteria (✅ met / ⏳ not yet / ⚠️ over), top 20 by priority. Habits are auto-marked from your journaling + planning sessions.
argument-hint: (none) | track | list | history --name "X"
---
Run this with the Bash tool first (substituting any argument for `$ARGUMENTS`), then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/habits.sh" "$ARGUMENTS"
```

The script prints one of:

- `HABITS_SETUP_PROFILE` — first run, no profile yet. Follow its INSTRUCTIONS: ask ONE question at a time, starting with "suggest from your entries, or specify yourself?", then gather each habit's own criteria and create it with the `add` subcommand (which mints a stable id and writes valid JSON — never hand-edit the file).
- `HABITS_DASHBOARD` — profile exists. Give a tight read of the rollup — **lead with ⚠️ over-cap items, then ⏳ high-priority unmet, then nice streaks**. Max ~800 words. No motivational padding, no coaching. Offer to open today's tracker, mark a habit, add/edit/archive one, or show history. Use the subcommands shown; never hand-edit the profile JSON or the tracking table directly.
- `HABITS_TRACK_FILE` — today's dated tracking markdown was created/refreshed; tell the user where it is and that they can tick the Done column (or you'll mark cells as they mention habits).
- `HABITS_LIST` — just relay the configured habits.
- `HISTORY: …` — relay the event history for that habit.

Tracking model: the dated `life/habit-tracking/<date>.md` files are the human-facing log; the SQLite DB is synced from them (read commands sync first; `/end-of-day` consolidates). Mark habits with `mark` (ticks the md), not `log`. Don't pad. This is a dashboard, not a coaching session.
