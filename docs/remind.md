# /remind

A simple **"remind me to…"** command. Describe a reminder in plain language and `/remind` creates a real **Apple Reminder** (in the Reminders app) — a to-do with a timed due date, an optional recurrence, a priority, and optional early heads-up alarms. Reminders + iCloud own the notification and sync it across your devices (Mac, iPhone, iPad).

There's no pbrain database or background poller involved — the reminder lives in Reminders, editable there like any other. (Reminders are *not* calendar events, so they do **not** appear on the calendar grid and do **not** anchor `/plan-my-day` — that planner reads your real Calendar events, separately.)

## Setting a reminder

```bash
/remind call the dentist tomorrow at 3pm
/remind pay rent on the 1st every month
/remind take a walk every weekday at 5pm
/remind drink water at 9am, 1pm and 5pm every day
/remind submit the report friday, high priority, warn me 30 min before
```

The command reads what you asked and works out:

- **Title** — a clean title (filler like "remind me to" is stripped).
- **Time** — resolved **relative to now**. A **date with no time** ("remind me Friday") anchors to **9am** (a reminder needs a time to fire a notification).
- **Frequency** — a recurrence, if you imply one (see below).
- **Priority** — `high` / `medium` / `low`, if you signal urgency ("important", "urgent").
- **Early alarm** — an extra heads-up *before* the due time ("warn me 15 min before").

If the time is genuinely ambiguous it asks one quick question first, then creates the reminder and confirms in one line.

### Recurrence — cron is the language

Repeats are expressed as a 5-field **cron** expression (`minute hour day-of-month month day-of-week`). You speak naturally; pbrain maps your words to cron, validates it, and converts it to an Apple recurrence:

| You say | cron | Apple recurrence |
|---|---|---|
| every day at 9am | `0 9 * * *` | daily |
| weekdays at 7:30 | `30 7 * * 1-5` | weekly, Mon–Fri |
| every Monday 6pm | `0 18 * * 1` | weekly, Mon |
| Wed & Sat 9am | `0 9 * * 3,6` | weekly, Wed+Sat |
| 15th of the month, 9am | `0 9 15 * *` | monthly, day 15 |
| 1st & 15th, 9am | `0 9 1,15 * *` | monthly, days 1 & 15 |
| **first Monday** 8am | `0 8 * * 1#1` | monthly, 1st Monday |
| **last Friday** 10pm | `0 22 * * 5L` | monthly, last Friday |
| Dec 25 at 9am | `0 9 25 12 *` | yearly, Dec 25 |
| quarterly (1st of Jan/Apr/Jul/Oct), noon | `0 12 1 1,4,7,10 *` | yearly, those months |
| **9am AND 5pm** daily | `0 9,17 * * *` | **two** reminders (one per time) |

cron day-of-week: `0`/`7`=Sun, `1`=Mon … `6`=Sat. The `d#n` extension means *nth weekday* (`1#1` = first Monday) and `dL` means *last weekday* (`5L` = last Friday).

**What cron-as-reminders can't do (and what happens):**

- **Sub-daily** (`every 5 minutes`, `hourly`, `*/30 9-17 * * *`) — Apple reminder recurrence is daily-or-coarser only, so these are **rejected** with a pointer to **`/remind-blocking`** (which runs a real cron poller and *can* fire sub-daily).
- **Multiple times of day** (`0 9,17 * * *`) — one Apple rule fires at one time, so this **splits into one reminder per time**.
- **`day-of-month` AND `day-of-week` together** (cron's OR-match) — **splits into two reminders** (a single rule would silently change the meaning to AND).
- **Every-N intervals** (`every 2 days`, `every other week`) — cron can't express an interval, so use the **`--repeat`** token form instead: `every-Nd`, `every-Nw[:WE,SA]`, plus `daily | weekdays | weekly | weekly:TU | monthly | monthly:1MO`.

### Bounding a recurrence

Say "until Friday" or "10 times" and it stops automatically — one of `--until "YYYY-MM-DD"` or `--count N` (mutually exclusive, recurrence only).

```bash
/remind water the plants every day until next Sunday
/remind take the medication twice a day for 10 days   # → two reminders, each capped
```

## Managing reminders

```bash
/remind list                 # upcoming pbrain reminders (with ids, priority, recurrence)
/remind                      # same — shows your upcoming reminders, ready for a new one
```

`list` shows only reminders **pbrain created** (each carries a hidden marker in its notes), not your whole Reminders list. Refer to one in plain language and pbrain matches it to an id:

- **"I did it" / "mark done"** → marks the reminder **complete**. For a recurring reminder this rolls it forward to the next occurrence (Apple's model).
- **"cancel" / "remove" / "delete"** → **deletes** the reminder. For a recurring one this removes the whole series.

### Editing (this and all future occurrences)

```bash
/remind move the dentist reminder to friday 4pm
/remind make the standup reminder weekly on mondays
/remind bump the rent reminder to high priority
```

A recurring reminder is a single series object, so editing it (time, recurrence, priority, title, early alarm) changes **all future occurrences**. Under the hood: `edit <id> [--text …] [--due …] [--cron …] [--repeat …] [--clear-recurrence] [--priority …] [--early …] [--clear-early] [--notes …]`.

**What needs the Reminders app instead:** editing or skipping **just one occurrence** of a recurring reminder. EventKit has no per-instance API for reminders — only the whole series — so for "skip just this Tuesday" or "move only next week's", open the Reminders app.

> **One-time Reminders permission:** the first create/list/edit/cancel triggers a macOS prompt to let **pbrain-reminders** access your Reminders — approve it once. Trigger it ahead of time with `/remind access`. (This is a permission distinct from Calendar access.) If `swiftc` (Xcode Command Line Tools) isn't installed the EventKit helper can't be built, and `/remind` will say so rather than half-work — run `xcode-select --install`.

## Where reminders show up

- **Reminders app / Notification Center** — the reminder fires a notification at its due time (plus any early alarms) and syncs to all your Apple devices.
- **NOT in `/plan-my-day`** — reminders aren't timed calendar events, so the planner doesn't read them. `/plan-my-day` anchors the day around your real **Calendar** events and your fitness session.

## Defaults and overrides

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_REMINDERS_LIST` | Which Reminders list to create/read in | the system default list |
| `PBRAIN_REMINDER_MARKER` | Hidden notes marker tagging pbrain reminders (so `list` finds them) | `⟦pbrain-reminder⟧` |
| `PBRAIN_REMINDERS_APP` | Where the EventKit helper app is cached/built | `~/.config/pbrain/pbrain-reminders.app` |

**Subcommands (the script's API — you normally just type natural language):**
`add --text "…" (--due "YYYY-MM-DD HH:MM" | --cron "<5-field>" | --repeat <token>) [--priority high|medium|low] [--early "15" | "15,60"] [--until YYYY-MM-DD | --count N] [--notes "…"] [--list "<list>"]`, `list`, `edit <id> …`, `done <id>`, `cancel <id>`, `access`.

**Note:** macOS only. All Reminders operations go through a tiny bundled **EventKit** helper (`pbrain-reminders.app`, compiled on demand from `lib/pbrain-reminders.swift`), launched via `open` so the one-time Reminders access is attributed to the bundle. Needs `swiftc` (Xcode Command Line Tools).

---

*Looking for full-screen "take a break" style blocking reminders, or a true sub-daily cron cadence? That's a separate feature — `/remind-blocking` — backed by a launchd poller and a SQLite queue. `/remind` itself is purely an Apple Reminders front-end.*
