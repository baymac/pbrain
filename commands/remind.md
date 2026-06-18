---
description: Natural-language reminders that land as real Apple Reminders — timed due dates with optional cron-based recurrence, priority, and early alarms. Reminders + iCloud own firing and cross-device sync; create, list, edit, complete, and cancel them in plain language.
argument-hint: <reminder, e.g. "call dentist tomorrow 3pm, high priority"> | list | done <id> | cancel <id> | edit <id> …
---
Run this with the Bash tool first (substituting the user's text for `$ARGUMENTS`), then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/remind.sh" "$ARGUMENTS"
```

For management subcommands (`list`, `done <id>`, `cancel <id>`, `edit <id> …`, `access`) the script acts directly and prints the result — just relay it.

Otherwise the script prints a `REMIND_ENTRY` block. Follow its INSTRUCTIONS: decide whether the user is creating, listing, editing, completing, or cancelling a reminder. For a new reminder, resolve the time **relative to the `now` value in the block** and pick the timing form — `--due` for a one-off, or `--cron "<5-field>"` for a repeat (the cron's minute/hour set the time; map "every weekday 8am" → `0 8 * * 1-5`). Cron's day-of-week field supports two nth-weekday extensions: `dow#n` = the nth weekday of the month (e.g. `1#1` = first Monday), `dowL` = the last weekday of the month (e.g. `5L` = last Friday) — so "first Monday" → `0 8 * * 1#1`, "last Friday" → `0 22 * * 5L`. Use `--repeat` only for every-N intervals cron can't express. Pass `--priority`, `--early`, `--until`/`--count` when the user implies them. Don't invent a due time when the user was specific; ask one quick question only if genuinely ambiguous. Sub-daily cadences ("every 5 minutes", "hourly") aren't possible as Apple Reminders — tell the user and point them to `/remind-blocking`. Keep confirmations to one line.

## Notes for downstream callers

- **`status --id <reminder-id>` op** — the bundled EKReminder helper reports a single reminder's completion state. It exists because the helper's `list` op returns *incomplete reminders only*; to check whether a specific reminder was ticked you must query it by id. `/habits` uses this for its two-way habit↔reminder sync.
- **Linked-habit reminders — the schedule owns days, NOT the reminder.** When a habit is linked to a reminder, `/habits` creates a per-day **one-shot** reminder (no Apple recurrence) on the days the *habit's schedule* is due. The link intent on the habit carries `{"state":"linked","time":"HH:MM"}` with **NO `days` field** — the habit's schedule is the sole source of which days fire. Per-day reminder ids live in the DB's `habit_reminders` table, not on the habit.
