# /remind

Lightweight reminders that fire as **macOS notifications**. Set them in plain language; they surface in `/plan-my-day` and `/end-of-day`, and — if you opt in — fire on their own in the background.

Reminders live in a small local SQLite database (`~/.config/pbrain/pbrain.db`), shared with habit tracking. They are per-machine operational state, not vault notes.

## Setting a reminder

```bash
/remind call the dentist tomorrow at 3pm
/remind pay rent on the 1st every month
/remind take a walk every weekday at 5pm
/remind buy oat milk          # no time → an undated "someday" reminder
```

The command resolves the time **relative to now** (so "tomorrow 3pm" becomes a concrete datetime), detects recurrence (`daily` / `weekdays` / `weekly` / `monthly`), and fires a confirmation notification. If the time is genuinely ambiguous it asks one quick question first.

A reminder with a **date but no time** ("remind me Friday") fires around **9am** that day and reads as "today" until then — add a time ("Friday 2pm") if you need it precise. A long-overdue repeating reminder (laptop was asleep, or you just installed the poller) fires **once** and rolls forward to its next future occurrence, rather than pinging once per missed cycle.

## Managing reminders

```bash
/remind list            # show pending reminders with ids and due times
/remind                 # same — also fires anything due right now
```

To complete or drop one, just say so ("mark the dentist one done", "I paid rent") — it matches your words to an id and runs `done`/`cancel`. Completed and cancelled reminders stay in the DB but drop off the pending list.

## How firing works

A reminder fires (a macOS notification) when it becomes due. There are two firing paths:

1. **Opportunistic (default, zero setup).** Whenever you run `/remind`, `/plan-my-day`, or `/end-of-day`, any due-and-unfired reminders fire. Each fires once (tracked by `fired_at`), so it never double-pings.
2. **Background poller (opt-in).** Run `/remind install` to register a launchd agent that ticks every ~5 minutes, so reminders fire even when no pbrain command is running. `/remind uninstall` removes it.

Repeating reminders roll forward to their next occurrence after each fire; one-shot reminders fire once and wait for you to mark them done.

## Where reminders show up

- **`/plan-my-day`** surfaces what's due today / overdue at the top of planning, and offers to set new ones for the day.
- **`/end-of-day`** surfaces outstanding reminders, lets you mark off what you handled, and offers to carry a reminder into tomorrow.

## Defaults and overrides

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_DB_FILE` | SQLite DB path (shared with `/habits`) | `~/.config/pbrain/pbrain.db` |

**Subcommands (the script's API — you normally just type natural language):** `add --text … [--due …] [--repeat …]`, `list`, `done <id>`, `cancel <id>`, `clear --yes`, `tick`, `install`, `uninstall`.

**Note:** macOS only (uses `osascript`/launchd). If notification permissions are off for your terminal/Claude Code, enable them in System Settings → Notifications.
