# /remind

A simple **"add it to my calendar"** command. Describe a reminder in plain language and `/remind` creates a real **Apple Calendar event** for it — title, time, recurrence, and any extra context. Calendar then owns the notification and syncs it across your devices (Mac, iPhone, iPad).

There's no pbrain database, notifier, or background poller involved: the reminder is just a calendar event, editable in Calendar.app like any other. Today's calendar events also become **hard anchors in `/plan-my-day`** (see below).

## Setting a reminder

```bash
/remind call the dentist tomorrow at 3pm
/remind pay rent on the 1st every month
/remind take a walk every weekday at 5pm
/remind stand up and stretch every hour
/remind submit the report friday — include the Q3 numbers and the link
```

The command reads what you asked and works out:

- **Title** — a clean event title (filler like "remind me to" is stripped).
- **Time** — resolved **relative to now**, so "tomorrow 3pm" becomes a concrete datetime. A **date with no time** ("remind me Friday") lands at **9am** that day.
- **Frequency** — recurrence, if you imply one (see the table below).
- **Context** — any extra detail ("include the Q3 numbers and the link") goes into the event's **notes**.

If the time is genuinely ambiguous it asks one quick question first, then creates the event and confirms in one line.

### Recurrence

| You say | Repeat token | iCalendar rule |
|---|---|---|
| every day | `daily` | `FREQ=DAILY` |
| every weekday | `weekdays` | `FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR` |
| every week | `weekly` | `FREQ=WEEKLY` |
| **Wed and Sat** | `weekly:WE,SA` | `FREQ=WEEKLY;BYDAY=WE,SA` |
| every Tuesday | `weekly:TU` | `FREQ=WEEKLY;BYDAY=TU` |
| every 3 days | `every-3d` | `FREQ=DAILY;INTERVAL=3` |
| every other week | `every-2w` | `FREQ=WEEKLY;INTERVAL=2` |
| biweekly on Mon | `every-2w:MO` | `FREQ=WEEKLY;INTERVAL=2;BYDAY=MO` |
| every month | `monthly` | `FREQ=MONTHLY` |
| **first Monday** of the month | `monthly:1MO` | `FREQ=MONTHLY;BYDAY=1MO` |
| **last Friday** of the month | `monthly:-1FR` | `FREQ=MONTHLY;BYDAY=-1FR` |
| every 2 hours | `every-2h` | `FREQ=HOURLY;INTERVAL=2` |
| every 5 minutes | `every-5m` | `FREQ=MINUTELY;INTERVAL=5` |
| every 30 seconds | `every-30s` | `FREQ=MINUTELY;INTERVAL=1` |

Day codes are `MO TU WE TH FR SA SU`. Apple Calendar's finest recurrence granularity is **one minute**, so a sub-minute cadence (`every-30s`) becomes a once-a-minute event.

### Ending a recurrence (bounded reminders)

A recurring reminder can stop automatically — say "until Friday" or "for the next 3 days" and it sets a bound:

```bash
/remind water the plants every day until next Sunday
/remind take the medication twice a day for 10 days   # → two reminders, each capped
```

Under the hood these add **one** of `--until "YYYY-MM-DD"` (stop after that date) or `--count N` (stop after N occurrences) to the recurrence. The two are mutually exclusive, and only apply alongside a `--repeat`.

**Multiple distinct times a day** ("9am and 5pm daily") isn't a single calendar rule, so `/remind` creates **one reminder per time** (each with the same recurrence).

**Still not a token:** arbitrary RRULE pieces beyond the above (e.g. "every 2nd and 4th week on specific days with a count") — set those in Calendar.app directly.

Every event also gets an **alarm at its start time**, so Calendar delivers a notification when it's due.

## Managing reminders

```bash
/remind list      # upcoming pbrain reminders on your calendar (with uids)
/remind           # same — shows your upcoming reminders, ready for a new one
```

`list` shows only reminders **pbrain created** (each is tagged with a hidden marker in its notes), not your whole calendar. To remove one, just say so ("cancel the dentist one", "I submitted the report") — it matches your words to the event and removes it.

Deletion is **reliable**, including recurring reminders. AppleScript can't dependably delete recurring iCloud events, so `/remind cancel` uses a tiny bundled **EventKit** helper (`pbrain-calendar.app`, compiled on demand from `lib/pbrain-calendar.swift`) which removes the whole series and commits it. Each pbrain reminder carries a hidden id in its notes, so cancel always targets the right event regardless of how Calendar/iCloud renumber things.

> **One-time Calendar permission:** the first cancel triggers a macOS prompt to let **pbrain-calendar** access your Calendar — approve it once. You can trigger it ahead of time with `/remind calendar-access`. (This is a separate permission from the Automation access used to *create* events.) If `swiftc` (Xcode Command Line Tools) isn't installed, the helper can't be built and cancel falls back to the unreliable AppleScript path — then delete recurring ones in Calendar.app.

## Where reminders show up

- **Apple Calendar / Notification Center** — the event fires a notification at its time and syncs to all your Apple devices.
- **`/plan-my-day`** — today's calendar events (recurrences expanded) are pulled in as **hard time anchors**. The planner surfaces them up front ("On your calendar today: standup 9:30, dentist 14:00") and builds the day's schedule around them, treating them as non-negotiable fixed rows. All-day items show as context; frequent pings (e.g. an hourly stand-up reminder) are noted once.

## Defaults and overrides

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_CALENDAR` | Which Apple Calendar to create/read reminders in | `Calendar` |
| `PBRAIN_CAL_MARKER` | Hidden notes marker that tags pbrain-created events (so `list`/`cancel` can find them) | `⟦pbrain-reminder⟧` |

**Subcommands (the script's API — you normally just type natural language):**
`add --text "…" --due "YYYY-MM-DD HH:MM" [--repeat <token>] [--until YYYY-MM-DD | --count N] [--notes "context"]`, `list`, `done <id>`, `cancel <id>`, `calendar-access`.
Repeat tokens: `daily | weekdays | weekly | weekly:WE,SA | monthly | monthly:1MO | every-Nd | every-Nw[:WE,SA] | every-Nh | every-Nm | every-Ns`.

**Note:** macOS only. Creating/listing reminders drives **Calendar.app** via AppleScript (`osascript`, needs Automation access — prompted the first time); cancelling uses the EventKit helper (needs Calendar access — see above). The reminder events live in the calendar named by `PBRAIN_CALENDAR`; point that at a dedicated calendar if you'd rather keep them separate from your main one.

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_CALENDAR_APP` | Where the EventKit cancel helper app is cached/built | `~/.config/pbrain/pbrain-calendar.app` |

---

*Looking for full-screen "take a break" style blocking reminders, or the SQLite-backed reminder queue? That's a separate feature (`remind-block`) — `/remind` itself is purely a calendar front-end.*
