# /habits

Track your habits over time — each with its **own** fulfillment criteria. There's no cap on how many you track. First run defines the set (one question at a time); every run after shows where you stand against each habit's criteria.

**Two layers.** Definitions live in `Habits Profile.md` (the *what*). The day-to-day log lives in **dated markdown files** — `life/habit-tracking/<date>.md` — exactly like `/journal` and `/fitness-journal`. Those files are what you work with. A local SQLite DB is a *derived* analysis store, synced from the markdown, that the history/rollup/weekly-review reads. You edit markdown; the DB stays in sync underneath.

## The criteria model

Each habit carries three fields that say how it's evaluated:

- **schedule_type** — `daily` (every day, e.g. brush at night, 4L water), `weekly` (N times a week, e.g. nail cut twice), or `monthly` (N times a month, e.g. a long run 5×).
- **direction** — `at_least` (a habit you're building) or `at_most` (a habit you're capping, e.g. alcohol).
- **target_count** — how many times within the period. For a plain daily habit this is just 1 (every day).

Plus a **priority** (low / medium / high) and an optional short note.

### Measured habits (quantity tracking)

A habit can optionally carry a **measure** — a `unit` and a `measure_target` — when what matters is an *amount*, not a yes/no:

- **unit** — what you're counting, e.g. `L`, `min`, `km`, `g`, `pages`.
- **measure_target** — the amount that fulfills the period (may be fractional, e.g. `2.5`).

When a habit is measured, fulfillment checks the **summed amount over its period** against the target (`2.5/4 L`, `12/20 km this week`) instead of done/not-done — and `target_count` is then irrelevant. Most habits are genuinely binary; only set a measure when the user frames the habit as a quantity. You record the day's amount with `--amount` (it lands in the Count cell of the tracking file and the `amount` column in the DB).

| Example | schedule_type | direction | target_count | unit | measure_target |
|---|---|---|---|---|---|
| Brush at night | daily | at_least | 1 | — | — |
| Drink 4L water | daily | at_least | — | L | 4 |
| Run 20 km/week | weekly | at_least | — | km | 20 |
| Nail cut | weekly | at_least | 2 | — | — |
| Long run | monthly | at_least | 5 | — | — |
| Alcohol | weekly | at_most | 2 | — | — |
| Sugar ≤30 g/day | daily | at_most | — | g | 30 |

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
    { "id": "brush-at-night", "name": "Brush at night", "schedule_type": "daily",  "direction": "at_least", "target_count": 1, "priority": "high",   "archived": false, "notes": "" },
    { "id": "water",          "name": "Water",          "schedule_type": "daily",  "direction": "at_least", "target_count": null, "unit": "L", "measure_target": 4, "priority": "high", "archived": false, "notes": "" },
    { "id": "alcohol",        "name": "Alcohol",        "schedule_type": "weekly", "direction": "at_most",  "target_count": 2, "priority": "medium", "archived": false, "notes": "" }
  ]
}
```

(`unit` + `measure_target` are the optional measure; omit them — or leave `measure_target` null — for a plain yes/no habit.)

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

You rarely mark by hand. Once the profile exists, every daily journaling and planning command (`/journal`, `/gratitude-journal`, `/fitness-journal`, `/diet-journal`, `/plan-my-day`, `/end-of-day`) watches for habits you actually mention and **ticks them in today's tracking file** automatically (`/habits mark`). Marking a name that isn't a tracked habit is **rejected** (you add it first).

Those commands also nudge: if you show a standing intention to build a new habit that isn't tracked yet, they'll offer to add it — at most once, and they won't re-nag the same idea for ~2 weeks.

## How the DB stays accurate (sync + consolidate)

The markdown is the source of truth; the SQLite DB (`~/.config/pbrain/pbrain.db`) is synced from it, keyed by stable `habit_id`, one row per habit per day:

- **sync** mirrors a day's file into the DB — so unticking a habit in the markdown removes its event. Read commands sync recent days before showing the rollup, so what you see is current.
- **`/end-of-day` consolidates**: it marks the day's habits from your journal/plan/fitness/diet, syncs today into the DB, then **prunes the day's file to only the habits you actually did** — leaving a clean record and accurate analysis data for weekly/monthly review.

You refer to the markdown files; the subcommands that need history (rollup, status, weekly review) read the DB.

## The dashboard

Running `/habits` (with a profile in place) syncs your recent files, then shows the **top 20 by priority**, each against its own criteria:

- daily: done today **✅** / not yet **⏳**, plus this-week N/7 and your streak,
- weekly / monthly: progress like `2/2 this week ✅` or `1/2 this week ⏳`,
- measured: amount-based progress with the unit, like `2.5/4 L today ⏳` or `12/20 km this week`,
- limit habits: **⚠️ OVER** or `— at cap`,
- last-done date; a `+N more` line if you track more than 20.

Then it offers to open today's tracker, mark a habit, add/edit/archive one, or show history.

## Subcommands

| Command | What it does |
|---|---|
| `/habits` | Setup (first run) or dashboard |
| `/habits track [--date]` | Create/refresh the dated tracking file |
| `/habits list` | List the configured habits (with ids) |
| `/habits history --name "X"` | Event history for one habit, newest first |

Script-level API (used by the auto-marking, surfacing, and the dashboard's offers):
`mark --name "X" --date YYYY-MM-DD [--count N] [--amount X] [--note "…"]` (the primary write path → ticks the md; `--amount` for measured habits),
`track [--date …]`, `sync [--days N]` (mirror md → DB), `consolidate [--date …]` (sync + prune, run by `/end-of-day`),
`add --name "X" --type daily|weekly|monthly --direction at_least|at_most [--target N] [--unit "L"] [--measure-target N] [--priority …] [--notes "…"]`,
`edit --id <id> [--name …] [--type …] [--direction …] [--target N] [--unit …] [--measure-target N] [--priority …] [--notes …]` (pass `--measure-target ""` to clear a measure),
`archive --id <id>`, `rollup [--date …]`, `status [--date …]`, `log` (low-level direct-to-DB primitive; takes `--amount` too).

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
