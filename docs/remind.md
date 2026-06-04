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

Repeating reminders roll forward to their next occurrence after each fire; one-shot reminders fire once and then read as **fired** in the list (still there so you can mark them done) rather than lingering as overdue.

### The notifier

Notifications are delivered by **pbrain's own tiny notifier app** (`pbrain-notify.app`), not by `osascript`. The reason: `osascript display notification` is *silently dropped* when fired from the background launchd poller — from that context there's no trusted app for macOS's notification-permission check, so nothing ever appears. The bundled app carries a real app-bundle identity, so it fires reliably even from the background.

You don't install it separately. It's compiled on demand from a ~60-line Swift source the first time a reminder fires (or at `/remind install`) using `swiftc` (Apple Command Line Tools — already on any dev Mac), and cached at `~/.config/pbrain/pbrain-notify.app`. If `swiftc` isn't available, firing falls back to `osascript` (which still works from interactive `/remind`, `/plan-my-day`, `/end-of-day` runs — just not from the background poller).

Notifications appear under the **"Terminal"** identity and clicking one opens Terminal. That's deliberate: on macOS 14/15 (Sequoia) notifications from an unrecognized app are dropped, so the notifier borrows Terminal's already-trusted notification permission (the same technique the `alerter` tool uses). To use a different identity, set `PBRAIN_NOTIFY_IDENTITY` to a bundle id (e.g. your own), or to an empty string to deliver under pbrain's own `com.pbrain.notify` identity — at the risk of macOS not showing it until you enable it in System Settings → Notifications.

## Where reminders show up

- **`/plan-my-day`** surfaces what's due today / overdue at the top of planning, and offers to set new ones for the day.
- **`/end-of-day`** surfaces outstanding reminders, lets you mark off what you handled, and offers to carry a reminder into tomorrow.

## Defaults and overrides

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_DB_FILE` | SQLite DB path (shared with `/habits`) | `~/.config/pbrain/pbrain.db` |
| `PBRAIN_NOTIFY_APP` | Where the compiled notifier app is cached/built | `~/.config/pbrain/pbrain-notify.app` |
| `PBRAIN_NOTIFY_IDENTITY` | Bundle id the notifier delivers under (`""` = pbrain's own, no impersonation) | unset → `com.apple.Terminal` |

**Subcommands (the script's API — you normally just type natural language):** `add --text … [--due …] [--repeat …]`, `list`, `done <id>`, `cancel <id>`, `clear --yes`, `tick`, `install`, `uninstall`.

**Note:** macOS only (uses the bundled notifier / launchd). Notifications fire under the "Terminal" identity by default (see *The notifier* above), so they ride Terminal's notification permission. If notifications don't appear at all, check System Settings → Notifications and make sure Terminal (or whichever identity you set) is allowed.
