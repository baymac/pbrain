# /habits

Track your habits over time — each with its **own** fulfillment criteria. There's no cap on how many you track. First run defines the set (one question at a time); every run after shows where you stand against each habit's criteria.

**Two layers.** Definitions live in the versioned habits profile (the *what*) — `life/habit-tracking/.profile/habits-profile.vN.md`. The day-to-day log lives in **dated markdown files** — `life/habit-tracking/<date>.md` — exactly like `/journal` and `/fitness-journal`. Those files are what you work with. A local SQLite DB is a *derived* analysis store, synced from the markdown, that the history/rollup/weekly-review reads. You edit markdown; the DB stays in sync underneath.

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

**Three daily states: done / skipped / missed.** A habit-day is no longer just "done or not". The **Done** column carries a state token — `x` (done), `skip` (you deliberately cancelled it today — an *off day*), or `miss` (it was scheduled and you just didn't do it). **Skipped never breaks a streak or counts against you** (it's treated like a non-due day); **missed is a real miss** (it breaks a build streak). At `/end-of-day`, any build habit that was due but left unmarked is recorded as `missed`, so scheduled habits stop silently vanishing. Mark a state with `mark --status done|skipped|missed` (or the shorthand `--skip`).

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
$VAULT/life/habit-tracking/.profile/habits-profile.vN.md
```

The structured data lives in a fenced ` ```json ` block. Each habit has a **stable `id`** (a slug) — minted once and never changed. Renaming a habit touches only its display name; its history (kept in SQLite, keyed by `id`) stays attached. Removing a habit **soft-archives** it, so history is preserved. Shape:

```json
{
  "created": "2026-06-03",
  "habits": [
    { "id": "brush-at-night", "name": "Brush at night", "direction": "at_least",
      "schedule": { "type": "daily" }, "priority": "high", "category": "cleanliness", "archived": false, "notes": "" },
    { "id": "gym", "name": "Gym", "direction": "at_least",
      "schedule": { "type": "weekdays", "days": ["mon","wed","fri"] }, "priority": "high", "category": "fitness-activity", "archived": false },
    { "id": "water", "name": "Water", "direction": "at_least",
      "schedule": { "type": "daily" }, "unit": "L", "measure_target": 4, "priority": "high", "archived": false },
    { "id": "alcohol", "name": "Alcohol", "direction": "at_most",
      "schedule": { "type": "weekdays", "days": ["mon"] }, "target_count": 2, "priority": "medium", "archived": false }
  ]
}
```

(`unit` + `measure_target` are the optional measure; omit them for a plain yes/no habit. `schedule_type`/`target_count` may also appear — written for compatibility, derived from the `schedule`.)

Don't hand-edit ids — the `add`/`edit`/`archive` subcommands manage them and keep the JSON valid.

## Parts (categories)

Each habit can belong to **one part** — a coarse area it lives in. There are seven canonical parts:

`wellness` · `fitness-activity` · `bad-habits` · `looks` · `cleanliness` · `work` · `diet`

A custom part is fine too (any slug) when none fit; it just sorts after the canonical ones. Set a part when you create or change a habit:

```
/habits add  … --category cleanliness          # or --part "fitness activity" (it slugifies)
/habits edit --id <id> --category work          # --category "" clears it
```

The part shows up in the dashboard, which **groups habits under part headers** (canonical order, then any custom parts, then *Uncategorized*), keeping the priority sort within each part. If you already had habits before parts existed, the first `/habits` run after upgrading walks you through sorting them — one part at a time, your call on each — as a one-time pass.

## Daily tracking files (the human surface)

Each day has its own file: `life/habit-tracking/<date>.md`. It's generated from your profile and **split into one table per [part](#parts-categories)**, each under a `## <Part>` heading (canonical order, then custom parts, then `## Other` for uncategorized), with empty cells to tick:

```
## Fitness activity

| Habit | Criteria | Progress | Done | Count | Note |
|-------|----------|----------|------|-------|------|
| Gym   | weekdays | 1/3 wk   | x    |       |      |

## Wellness

| Habit | Criteria   | Progress | Done | Count | Note |
|-------|------------|----------|------|-------|------|
| Water | daily ≥4 L | 2.5/4 L  | x    | 2.5   |      |

## Cleanliness

| Habit          | Criteria | Progress | Done | Count | Note |
|----------------|----------|----------|------|-------|------|
| Brush at night | daily    | 5/7 wk   | x    |       |      |
```

The sectioning is derived from your profile on every refresh — editing a habit's category moves it to the right section on the next sync. Old single-table files (with or without a Part column) are still read fine and get re-sectioned the next time they're written.

You can open it in Obsidian and tick the **Done** column by hand, or let the agent mark cells for you (below). The `Progress` column shows where each habit stands so far (from the DB) for context. For a **measured** habit (one with a unit), put the day's amount in the **Count** cell — that's the litres/minutes/km the rest of the tooling reads as your quantity.

`/plan-my-day` offers, at the end, to create today's file (`/habits track`). The day's marks accumulate there.

## How habits get marked

You rarely mark by hand. Once the profile exists, every daily journaling and planning command (`/journal`, `/gratitude-journal`, `/fitness-journal`, `/diet-journal`, `/plan-my-day`, `/end-of-day`) watches for habits you actually mention and **ticks them in today's tracking file** automatically (`/habits mark`). Marking a name that isn't a tracked habit is **rejected** (you add it first). Marking is **live**: the moment a habit is ticked, that day's `Progress` column is recomputed from the DB, so the number you see is current — not a stale snapshot from when the file was created.

**Limit habits work inversely.** For an `at_most` habit (a cap — `No smoking`, `No drinking`, `No masturbation`, `TV under 1hr`), a mark means you **lapsed** (did the capped thing), with the amount in `--count` and the detail in a `--note`. A clean / abstinent day is simply **not marked** — for a cap, no mark *is* the success, and an unmarked day keeps you under the limit. Never mark a limit habit because you avoided it; that would count the win against you.

Those commands also nudge: if you show a standing intention to build a new habit that isn't tracked yet, they'll offer to add it — at most once, and they won't re-nag the same idea for ~2 weeks.

## How the DB stays accurate (sync + consolidate)

The markdown is the source of truth; the SQLite DB (`~/.config/pbrain/pbrain.db`) is synced from it, keyed by stable `habit_id`, one row per habit per day:

- **sync** mirrors a day's file into the DB — so unticking a habit in the markdown removes its event. Read commands sync recent days before showing the rollup, so what you see is current.
- **`/end-of-day` consolidates**: it runs an **autostatus** pass first (any due build habit with no mark → `missed`), marks the day's habits from your journal/plan/fitness/diet, syncs today into the DB, then **prunes the day's file to the habits with a recorded state** — done, skipped *and* missed survive; only the untouched "not yet" rows go — leaving a clean record and accurate analysis data for weekly/monthly review.

You refer to the markdown files; the subcommands that need history (rollup, status, weekly review) read the DB.

## The dashboard

Running `/habits` (with a profile in place) syncs your recent files, then shows the **top 20 by priority**, each against its own criteria:

- daily: done today **✅** / not yet **⏳**, plus this-week N/7 and your streak,
- fixed-schedule (weekdays / interval / monthly): on a due day, done **✅** / not yet **⏳**; on an **off day**, `off today (next <date>)` — never a miss — plus due-day progress like `1/3 this week` and a due-day streak,
- floating "N times a week/month, any days": progress like `2/2 this week ✅` or `1/2 this week ⏳`,
- measured: amount-based progress with the unit, like `2.5/4 L today ⏳` or `12/20 km this week`,
- limit habits: **⚠️ OVER** or `— at cap`,
- the head shows each habit's schedule (e.g. `Gym (Mon/Wed/Fri, high)`); last-done date; a `+N more` line if you track more than 20.

When any habit has a **part** (see [Parts](#parts-categories)), the list is grouped under part headers — `**Wellness**`, `**Fitness activity**`, … then `**Uncategorized**` — with habits still priority-sorted inside each part. With nothing categorized, it stays a flat priority list.

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
`mark --name "X" --date YYYY-MM-DD [--count N] [--amount X] [--note "…"] [--status done|skipped|missed | --skip]` (the primary write path → ticks the md; `--status`/`--skip` set the 3-state token — skipped/missed write a `count=0` row that's recorded but not a completion; `--amount` for measured habits; scored habits take their classification channel instead — `--good/--bad`, `--slips`, `--actual-time/--actual-hours`, `--items`, `--session`, `--focus`, or `--done '["part",…]'` for a checklist),
`track [--date …]`, `sync [--days N] [--date YYYY-MM-DD]` (mirror md → DB; `--date` targets a specific end date for the sync window), `consolidate [--date …]` (sync + prune, run by `/end-of-day`), `autostatus [--date …]` (end-of-day pass: mark every due build habit with no mark as `missed` — done/skipped left, limit + not-due habits never touched; run by `/end-of-day` before consolidate), `refresh [--date …] [--days N]` (recompute the `Progress` column from the DB without touching marks — one day or the last N, oldest→newest; for backfilling history after a formula or data change),
`add --name "X" --direction at_least|at_most --schedule daily|weekdays|interval|monthly [schedule args] [--unit "L"] [--measure-target N] [--target N] [--components "A; B=2; C"] [--priority …] [--notes "…"]` — schedule args by kind: `weekdays` → `--days mon,wed,fri` or `--times-per-week N [--start-day mon]`; `interval` → `--every-days N [--start-date YYYY-MM-DD]`; `monthly` → `--days-of-month 1,16` or `--times-per-month N [--start-dom D]`. `--components` attaches a checklist scoring spec (weight after `=`, default 1; defaults `--measure-target` to 1.0 so the score persists). (Legacy `--type daily|weekly|monthly [--target N]` still works — it maps to a schedule.)
`edit --id <id> [--name …] [--direction …] [--schedule … + its schedule args] [--target N] [--unit …] [--measure-target N] [--components "…"] [--priority …] [--notes …]` (passing any schedule flag rebuilds the schedule; `--measure-target ""` clears a measure; `--components ""` clears the checklist scoring),
`archive --id <id>`, `rollup [--date …]`, `status [--date …]`, `scores [--date …]` (read back engine-computed 0–1 unit scores for all scored habits on a date; emits one line per habit + a `HABIT_SCORES [...]` JSON trailer — used by `/end-of-day` to fill the `### Scoreboard` table verbatim without re-deriving the numbers), `log` (low-level direct-to-DB primitive; takes `--amount` too),
`reminder --id <id> (--link --time HH:MM | --decline | --unlink [--cancel])` (manage a habit's Apple-Reminder opt-in — the schedule decides the days), `reminders-pending` (undecided habits), `reminders-ensure [--date]` (create that day's one-shot reminders for linked habits due that day, idempotent), `reminders-sync [--date] [--sweep]` (reconcile linked habits ↔ their reminders both directions; `--sweep` additionally cancels any still-pending one-shots for habits not completed that day — run by `/end-of-day` to keep the Reminders list clean), `reminders-reschedule --habit <name> --time HH:MM [--date YYYY-MM-DD]` (update the due time of a pending one-shot for a linked habit — run by `/plan-my-day` when it places a habit at a specific time in the plan; returns `RESCHEDULED | NOT_LINKED | NOT_FOUND | UNAVAILABLE`), `reminders-cancel --habit <name|id> [--date YYYY-MM-DD]` (delete a pending one-shot + mark its row cancelled so it isn't re-created — returns `CANCELLED | NOT_FOUND | UNAVAILABLE`), `fitness-reconcile --activity "<name|slug>" [--date YYYY-MM-DD]` (align the fitness-habit reminders to today's chosen activity — the matching habit's reminder is set, the scheduled-but-not-chosen fitness habits are cancelled + auto-skipped; run by `/plan-my-day` from today's `/fitness-journal` `focus:` field).

## Defaults and overrides

**Default profile:** `$VAULT_DIR/life/Habits Profile.md`

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_VAULT` | Vault root | iCloud Obsidian path |
| `PBRAIN_HABITS_PROFILE_FILE` | Explicit profile file (bypasses the versioned store) | `$VAULT/life/habit-tracking/.profile/habits-profile.vN.md` |
| `PBRAIN_HABIT_TRACK_DIR` | Dated tracking-file directory | `$VAULT/life/habit-tracking` |
| `PBRAIN_DB_FILE` | SQLite analysis DB (shared with `/remind`) | `~/.config/pbrain/pbrain.db` |
| `PBRAIN_HABIT_SUGGEST_FILE` | New-habit suggestion suppress-list | `~/.config/pbrain/habit-suggest-seen` |
| `PBRAIN_HABIT_SUGGEST_TTL_DAYS` | Days to suppress a re-suggestion | `14` |

**Re-running setup:** add/edit/archive via the dashboard's offers, or delete `Habits Profile.md` to redo the interview.

**Migration:** older event logs (keyed by habit name) are migrated to stable-id keys automatically on first run — one-time, guarded, idempotent.

## Versioned profile + scored defaults

The habits profile lives in the **versioned profile store** (`life/habit-tracking/.profile/habits-profile.vN.md`; the legacy `life/Habits Profile.md` is moved there automatically by migration 0005). Day-to-day `add` / `edit` / `archive` amend the latest version in place — the profile is a living document. Structural redesigns go through versions:

```bash
/habits profile show      # human-readable summary + which version is active
/habits profile new       # mint an editable draft copied from the current version
/habits profile commit    # freeze the draft — commands read the latest committed
```

**Default scored habits.** As soon as the profile they key off is committed, five scored habits seed themselves. Each is a **weekly aggregate**: every day you produce a 0.0–1.0 unit score you never pick by hand (every scored habit shares this scale; only the model differs — the model classifies your raw inputs, the lib computes the number), and the week banks the daily scores as a running **sum out of 7** (Progress shows `4/7 wk`), passing once the weekly sum reaches `measure_target` (`5`, shown as Criteria `weekly ≥5`). All five are confirmed at `/end-of-day`:

- **Eat clean** (`meal_ratio`, seeded once a **diet profile** exists): score = share of clean meals — `mark --name "Eat clean" --good <clean> --bad <unclean>`. The score depends on how many meals the day had: 1 slip out of 3 meals scores worse than 1 out of 6. The diet journal's extraction block classifies the meals.
- **Sleep well** (`deviation`, seeded once a **fitness profile** exists, normal window baked from it): score from deviation vs your normal bed time + sleep hours — `mark --name "Sleep well" --actual-time HH:MM --actual-hours N.N`. Every 30 min off your normal bed time and every half-hour of sleep shortfall steps the score down the ladder (1.0 → 0.9 → 0.75 → 0.5 → 0.25 → 0). The midnight crossing is handled (00:30 vs a 23:00 normal counts as 90 minutes, not 21.5 hours). The fitness check-in's bed/wake answers feed this automatically.
- **Work the plan** (`weighted_completion`, seeded once a **plans profile** exists): scores the day's task log like gym volume. Each task's weight = its difficulty (easy 1 / normal 2 / hard 3 / nightmare 5) boosted by its priority (p1 ×1.5, p2 ×1.25, p3+ ×1.0); credit = its status (done 1.0 / partial 0.5 / dropped, carried 0). `day score = earned / possible` (0–1). **Every planned task is in the denominator**, so piling on tasks you don't finish lowers the score, and finishing a hard high-priority task is worth far more than a clutch of easy ones. Marked at `/end-of-day` once the task-log actuals are filled — `mark --name "Work the plan" --items '[{"priority":1,"difficulty":"hard","status":"done"},…]'`.
- **Train** (`session_volume`, seeded once a **fitness library** exists): counts any fitness session you log (mark it on the days you train, ~6/week). A skipped session scores 0; a strength/duration session scores `clamp(actual/planned, 0, 1)` (strength = Σreps vs target sets×reps; duration = actual vs target minutes — capped at 1.0, so hitting plan = 1, a reduced deload target still hits 1); a binary session (yoga/sport, no target) scores by status (completed 1 / partial 0.5). Marked at `/fitness-journal` when you log a session, or at `/end-of-day` when the day closes — `mark --name "Train" --session '{"mode":"strength","status":"completed","planned":120,"actual":115}'`.
- **Deep work** (`focus_ratio`, seeded once **laptop tracking is set up** *and* a **plans profile** exists): scores how focused your scheduled work blocks actually were — not whether the tasks got done (that's *Work the plan*), but whether the time went to work vs. distraction. At `/end-of-day` it maps the day's laptop activity onto the plan's work-block windows and scores `work / (work + distraction)` of *active* minutes (0–1); AFK time is reported but never penalized. Which domains/apps count as work vs. social vs. entertainment comes from a reusable [category map](laptop-tracking.md) that grows as you confirm new sites — `mark --name "Deep work" --focus '{"work":130,"social":35,"entertainment":15,"neutral":10}'`.

Seeding is idempotent and archiving a default keeps it gone — it is never re-added.

**Per-activity fitness habits.** Once a **fitness library** is committed, one habit is also seeded **per library activity** (Gym, Apple Fitness, Football, Yoga, …), each tagged with its `activity` slug so `/plan-my-day` can map the day's chosen workout to the right habit reliably. If a habit already matches an activity (by name), its `activity` field is backfilled in place — no duplicate is created. These per-activity habits own occurrence + reminders + the done/skipped/missed record; the scored **Train** habit above stays as the single cross-activity *volume* score — the two are complementary.

**Build-your-own scored habit — checklists.** Beyond the five auto-seeded defaults, you can add a **checklist** scored habit for any fixed daily routine made of named parts — a supplement stack, a skincare routine, a morning ritual. Each component has a weight (default 1), and the daily score is `sum(completed weights) / sum(all weights)` (0–1). Add it with `--components`:

```bash
/habits add --name "Supplements" --type daily --priority high \
  --components "Morning vitamin D; Morning omega-3; Magnesium (night)"
```

That's a 3-part stack scored as a fraction of 3 — taking the two morning ones but skipping the night magnesium scores 0.67. Put a weight after `=` to make a part count for more (`--components "Morning stack=2; Magnesium=1"` scores the morning group as 2 of 3). Mark it by listing the parts you actually did (by name *or* id) — the rest are assumed skipped, and the engine computes the number:

```bash
/habits mark --name "Supplements" --done '["Morning vitamin D","Morning omega-3"]'
```

Like the defaults, the score lands in the day's tracker and the `### Scoreboard`, and the auto-marking ride-along will fill it in from your journaling/planning sessions when you mention taking them. `edit --id <id> --components "…"` rewrites the parts; `--components ""` drops it back to a plain tracked habit.
