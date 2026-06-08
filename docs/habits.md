# /habits

Track your habits over time — each with its **own** fulfillment criteria. There's no cap on how many you track. First run defines the set (one question at a time); every run after shows where you stand against each habit's criteria.

**Two layers.** Definitions live in `Habits Profile.md` (the *what*). The day-to-day log lives in **dated markdown files** — `life/habit-tracking/<date>.md` — exactly like `/journal` and `/fitness-journal`. Those files are what you work with. A local SQLite DB is a *derived* analysis store, synced from the markdown, that the history/rollup/weekly-review reads. You edit markdown; the DB stays in sync underneath.

## Two axes: schedule + scoring

A habit is defined by **two independent things**:

**1. Schedule (when it happens).** Every habit carries a `schedule` that says which days it's due — the same thing that decides when a linked reminder fires. Four kinds:

- **daily** — every day.
- **weekdays** — specific weekdays, e.g. `mon,wed,fri`. "N times a week" is entered as a frequency + a start day and **resolved into spaced days** (2×/week from Monday → Mon + Thu; 3×/week → Mon/Wed/Fri).
- **interval** — every N days from a start date (e.g. every 15 days).
- **monthly** — specific calendar days of the month, e.g. the 1st (or N×/month spaced from a start date).

**2. Direction (how it's scored).** Independent of the schedule:

- **at_least** — a habit you're **building** (eat clean, exercise). Done on its due days = good.
- **at_most** — a habit you're **capping** (no smoking, alcohol ≤ 2). A mark means you lapsed.

Plus **target_count** (the cap for a limit habit, or per-period count), a **priority** (low / medium / high), and an optional note.

**Scoring is schedule-aware.** A habit with a fixed schedule is only *expected* on its due days — a Mon/Wed/Fri habit is never "missed" on a Tuesday, and its streak counts only due days. (A legacy "N times a week, any days" habit with no fixed schedule stays count-based: "did you do it N times this week.")

> The old `schedule_type` (daily/weekly/monthly) field is still written for compatibility, but the `schedule` block is the source of truth for *when* a habit occurs.

### Measured habits (quantity tracking)

A habit can optionally carry a **measure** — a `unit` and a `measure_target` — when what matters is an *amount*, not a yes/no:

- **unit** — what you're counting, e.g. `L`, `min`, `km`, `g`, `pages`.
- **measure_target** — the amount that fulfills the period (may be fractional, e.g. `2.5`).

When a habit is measured, fulfillment checks the **summed amount over its period** against the target (`2.5/4 L`, `12/20 km this week`) instead of done/not-done — and `target_count` is then irrelevant. Most habits are genuinely binary; only set a measure when the user frames the habit as a quantity. You record the day's amount with `--amount` (it lands in the Count cell of the tracking file and the `amount` column in the DB).

| Example | schedule | direction | notes |
|---|---|---|---|
| Brush at night | daily | at_least | every day |
| Drink 4L water | daily | at_least | measured: 4 L |
| Gym | weekdays `mon,wed,fri` | at_least | fixed days |
| Run 3×/week | weekdays (from `--times-per-week 3`) | at_least | spaced → Mon/Wed/Fri |
| Deep clean | interval `every 15 days` | at_least | from a start date |
| Pay rent | monthly `the 1st` | at_least | calendar date |
| No smoking | daily | at_most | a daily check-in cap |
| Alcohol ≤2/week | weekly (cap) | at_most | cap = 2 |

## First-run setup

A setup interview the first time you run it — **one question at a time**. It opens by asking whether to **suggest habits from your recent pbrain entries** (it scans the last ~30 days of journals/plans/fitness/diet for things you actually do) or let you **specify them yourself**. Either way, each habit then gets its own criteria, and is created with the `add` subcommand.

Written to a normal Obsidian note:

```
$VAULT/life/Habits Profile.md
```

The structured data lives in a fenced ` ```json ` block. Each habit has a **stable `id`** (a slug) — minted once and never changed. Renaming a habit touches only its display name; its history (kept in SQLite, keyed by `id`) stays attached. Removing a habit **soft-archives** it, so history is preserved. Shape:

```json
{
  "created": "2026-06-03",
  "habits": [
    { "id": "brush-at-night", "name": "Brush at night", "direction": "at_least",
      "schedule": { "type": "daily" }, "priority": "high", "archived": false, "notes": "" },
    { "id": "gym", "name": "Gym", "direction": "at_least",
      "schedule": { "type": "weekdays", "days": ["mon","wed","fri"] }, "priority": "high", "archived": false },
    { "id": "water", "name": "Water", "direction": "at_least",
      "schedule": { "type": "daily" }, "unit": "L", "measure_target": 4, "priority": "high", "archived": false },
    { "id": "alcohol", "name": "Alcohol", "direction": "at_most",
      "schedule": { "type": "weekdays", "days": ["mon"] }, "target_count": 2, "priority": "medium", "archived": false }
  ]
}
```

(`unit` + `measure_target` are the optional measure; omit them for a plain yes/no habit. `schedule_type`/`target_count` may also appear — written for compatibility, derived from the `schedule`.)

Don't hand-edit ids — the `add`/`edit`/`archive` subcommands manage them and keep the JSON valid.

## Daily tracking files (the human surface)

Each day has its own file: `life/habit-tracking/<date>.md`. It's generated from your profile as a table — a row per active habit, with empty cells to tick:

```
| Habit          | Criteria   | Progress  | Done | Count | Note     |
|----------------|------------|-----------|------|-------|----------|
| Brush at night | daily      | 5/7 wk    | x    |       |          |
| Water          | daily ≥4 L | 2.5/4 L   | x    | 2.5   |          |
| Nail cut       | weekly ≥2  | 1/2 wk    |      |       |          |
| Alcohol        | weekly ≤2  | 1/2 wk    | x    |       | one beer |
```

You can open it in Obsidian and tick the **Done** column by hand, or let the agent mark cells for you (below). The `Progress` column shows where each habit stands so far (from the DB) for context. For a **measured** habit (one with a unit), put the day's amount in the **Count** cell — that's the litres/minutes/km the rest of the tooling reads as your quantity.

`/plan-my-day` offers, at the end, to create today's file (`/habits track`). The day's marks accumulate there.

## How habits get marked

You rarely mark by hand. Once the profile exists, every daily journaling and planning command (`/journal`, `/gratitude-journal`, `/fitness-journal`, `/diet-journal`, `/plan-my-day`, `/end-of-day`) watches for habits you actually mention and **ticks them in today's tracking file** automatically (`/habits mark`). Marking a name that isn't a tracked habit is **rejected** (you add it first). Marking is **live**: the moment a habit is ticked, that day's `Progress` column is recomputed from the DB, so the number you see is current — not a stale snapshot from when the file was created.

**Limit habits work inversely.** For an `at_most` habit (a cap — `No smoking`, `No drinking`, `No masturbation`, `TV under 1hr`), a mark means you **lapsed** (did the capped thing), with the amount in `--count` and the detail in a `--note`. A clean / abstinent day is simply **not marked** — for a cap, no mark *is* the success, and an unmarked day keeps you under the limit. Never mark a limit habit because you avoided it; that would count the win against you.

Those commands also nudge: if you show a standing intention to build a new habit that isn't tracked yet, they'll offer to add it — at most once, and they won't re-nag the same idea for ~2 weeks.

## How the DB stays accurate (sync + consolidate)

The markdown is the source of truth; the SQLite DB (`~/.config/pbrain/pbrain.db`) is synced from it, keyed by stable `habit_id`, one row per habit per day:

- **sync** mirrors a day's file into the DB — so unticking a habit in the markdown removes its event. Read commands sync recent days before showing the rollup, so what you see is current.
- **`/end-of-day` consolidates**: it marks the day's habits from your journal/plan/fitness/diet, syncs today into the DB, then **prunes the day's file to only the habits you actually did** — leaving a clean record and accurate analysis data for weekly/monthly review.

You refer to the markdown files; the subcommands that need history (rollup, status, weekly review) read the DB.

## The dashboard

Running `/habits` (with a profile in place) syncs your recent files, then shows the **top 20 by priority**, each against its own criteria:

- daily: done today **✅** / not yet **⏳**, plus this-week N/7 and your streak,
- fixed-schedule (weekdays / interval / monthly): on a due day, done **✅** / not yet **⏳**; on an **off day**, `off today (next <date>)` — never a miss — plus due-day progress like `1/3 this week` and a due-day streak,
- floating "N times a week/month, any days": progress like `2/2 this week ✅` or `1/2 this week ⏳`,
- measured: amount-based progress with the unit, like `2.5/4 L today ⏳` or `12/20 km this week`,
- limit habits: **⚠️ OVER** or `— at cap`,
- the head shows each habit's schedule (e.g. `Gym (Mon/Wed/Fri, high)`); last-done date; a `+N more` line if you track more than 20.

Then it offers to open today's tracker, mark a habit, add/edit/archive one, or show history.

A linked habit (see below) also shows a **🔔 HH:MM** marker.

## Linking to Apple Reminders

**Any habit** can opt into an Apple reminder — build or limit. The reminder is just a **notification and a familiar checkbox** — pbrain still owns the habit data and the score. A linked habit gets **one per-day "one-shot" reminder** (not an Apple-recurring one): pbrain creates the reminder on the days the habit's **schedule** is due, and keeps it in **two-way sync** with the habit.

- **The schedule owns the days.** You don't tell the link which days to fire — the habit's `schedule` does. A daily habit fires every day; a Mon/Wed/Fri habit fires those days; an "every 15 days" habit fires on its cadence. To change the days, edit the habit's schedule, not the reminder.
- **Two-way sync.** Check the reminder off in the Apple Reminders app → the habit is marked done here. Mark the habit done here (any way) → that day's reminder is completed. Whichever you touch, the other follows.
- **Opt-in, per habit.** Linking is offered when you first build the profile and when you add a habit; otherwise it happens only when you ask. Say no once and it's recorded — it won't re-ask. The dashboard does **not** nag.
- **The link is an intent.** The habit stores `{"state":"linked","time":"HH:MM"}` (or `{"state":"declined"}`); the per-day reminder ids live in the DB (`habit_reminders`), not the profile. A linked habit shows `🔔 HH:MM` in the rollup (the days are visible in the schedule shown in its head). The first link triggers the one-time macOS **Reminders** permission (separate from Calendar — granted via `/remind access`).
- **When reminders get created/synced.** `/plan-my-day` (and `/habits track`) create the day's one-shot for each linked habit *that's due that day* and pull anything you already ticked off; `/end-of-day` runs the sync once more to reconcile the day. A one-shot only exists on days pbrain runs to create it — fine, since the tracker is built every morning.
- **Archiving** a linked habit offers to cancel its pending reminders too.

Managed by `reminder --id <id> (--link --time HH:MM | --decline | --unlink [--cancel])`, with `reminders-ensure [--date]` (schedule-gated creation) / `reminders-sync [--date]` driving creation and two-way sync. Reminders only — a Calendar event has no "done" state.

## Subcommands

| Command | What it does |
|---|---|
| `/habits` | Setup (first run) or dashboard |
| `/habits track [--date]` | Create/refresh the dated tracking file |
| `/habits list` | List the configured habits (with ids) |
| `/habits history --name "X"` | Event history for one habit, newest first |

Script-level API (used by the auto-marking, surfacing, and the dashboard's offers):
`mark --name "X" --date YYYY-MM-DD [--count N] [--amount X] [--note "…"]` (the primary write path → ticks the md; `--amount` for measured habits),
`track [--date …]`, `sync [--days N] [--date YYYY-MM-DD]` (mirror md → DB; `--date` targets a specific end date for the sync window), `consolidate [--date …]` (sync + prune, run by `/end-of-day`), `refresh [--date …] [--days N]` (recompute the `Progress` column from the DB without touching marks — one day or the last N, oldest→newest; for backfilling history after a formula or data change),
`add --name "X" --direction at_least|at_most --schedule daily|weekdays|interval|monthly [schedule args] [--unit "L"] [--measure-target N] [--target N] [--priority …] [--notes "…"]` — schedule args by kind: `weekdays` → `--days mon,wed,fri` or `--times-per-week N [--start-day mon]`; `interval` → `--every-days N [--start-date YYYY-MM-DD]`; `monthly` → `--days-of-month 1,16` or `--times-per-month N [--start-dom D]`. (Legacy `--type daily|weekly|monthly [--target N]` still works — it maps to a schedule.)
`edit --id <id> [--name …] [--direction …] [--schedule … + its schedule args] [--target N] [--unit …] [--measure-target N] [--priority …] [--notes …]` (passing any schedule flag rebuilds the schedule; `--measure-target ""` clears a measure),
`archive --id <id>`, `rollup [--date …]`, `status [--date …]`, `log` (low-level direct-to-DB primitive; takes `--amount` too),
`reminder --id <id> (--link --time HH:MM | --decline | --unlink [--cancel])` (manage a habit's Apple-Reminder opt-in — the schedule decides the days), `reminders-pending` (undecided habits), `reminders-ensure [--date]` (create that day's one-shot reminders for linked habits due that day, idempotent), `reminders-sync [--date]` (reconcile linked habits ↔ their reminders both directions).

## Defaults and overrides

**Default profile:** `$VAULT_DIR/life/Habits Profile.md`

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_VAULT` | Vault root | iCloud Obsidian path |
| `PBRAIN_HABITS_PROFILE_FILE` | Habits profile markdown path | `$VAULT/life/Habits Profile.md` |
| `PBRAIN_HABIT_TRACK_DIR` | Dated tracking-file directory | `$VAULT/life/habit-tracking` |
| `PBRAIN_DB_FILE` | SQLite analysis DB (shared with `/remind`) | `~/.config/pbrain/pbrain.db` |
| `PBRAIN_HABIT_SUGGEST_FILE` | New-habit suggestion suppress-list | `~/.config/pbrain/habit-suggest-seen` |
| `PBRAIN_HABIT_SUGGEST_TTL_DAYS` | Days to suppress a re-suggestion | `14` |

**Re-running setup:** add/edit/archive via the dashboard's offers, or delete `Habits Profile.md` to redo the interview.

**Migration:** older event logs (keyed by habit name) are migrated to stable-id keys automatically on first run — one-time, guarded, idempotent.
