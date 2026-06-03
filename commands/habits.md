---
description: Habit tracking. First run builds a small profile of habits to build or limit (each with a priority and a weekly/monthly cap). Afterward it shows your patterns — counts vs caps, what's lagging, what's over. Habits are auto-logged from your journaling + planning sessions.
argument-hint: (none) | list
---
Run this with the Bash tool first (substituting any argument for `$ARGUMENTS`), then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/habits.sh" "$ARGUMENTS"
```

The script prints one of:

- `HABITS_SETUP_PROFILE` — first run, no profile yet. Follow its INSTRUCTIONS to interview the user and write `Habits Profile.md`.
- `HABITS_DASHBOARD` — profile exists. Give a tight read of the rollup (lead with what needs attention), then offer to log today or tweak the list.
- `HABITS_LIST` — just relay the configured habits.

Don't pad. This is a dashboard, not a coaching session.
