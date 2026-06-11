# /plan-my-day

Adaptive daily planner that's actually anchored on **your goals**, not a generic to-do list. On first run, interviews you to build a versioned goals profile over two living libraries. Every subsequent run plans the day against that profile, tying each work block back to a specific goal.

## The profile store

All base config lives in the **versioned profile store** under your planning dir:

```
$VAULT_DIR/life/daily-planning/.profile/
├── goals-profile.vN.md   # THE lens: work_goals + life_goals + working_style + anchors
├── work-library.vN.md    # every project you work on, with rich context (living doc)
└── goals-library.vN.md   # non-work goals: health, creative, relationships (living doc)
```

The **goals profile is the combination view** over the two libraries — each `work_goals` entry references a work-library project, each `life_goals` entry a goals-library goal. A **committed** version is final; changes mint the next version (`profile new` → edit the draft → `profile commit`). The libraries are living documents — entries are appended and enriched in place.

`working_style` carries the numbers the planner builds with: `session_length_min` (work-session length), `break_min` + `break_activities` (the rotation between blocks), `work_hours_per_day`, `focus_hours` (your important hours of the day), and `last_block_end` (when the final block must end).

## First-run setup

Asks you about: **work goals** (1–5 concrete outcomes with deadlines + the projects behind them, which seed the work library), **life goals** (health, creative, relationships — the goals library), **working style** (focus hours, total work hours/day, session length, break preference + activities, last block end, energy peak, day-wreckers), **daily anchors** (wake/workout/lunch/dinner/walk/bed), **anti-patterns**, and **personal anchors**.

## Migrating from older pbrain

If you had the old `Goals Profile.md` (or the ancient `plan-profile.json`), the first run after upgrading rebuilds it **part by part** — each goal confirmed/updated/dropped and classified work vs life, the new working-style questions asked (break preference, total hours, focus hours, last block end), the work library seeded from your old goals + recent plans. The old `current_focus` concept is gone — **the goals profile is the focus**. Old files are parked in `$VAULT_DIR/.pbrain/backup/`. One-time; recorded in the migration ledger.

## Daily flow

After setup, every run:

1. Reads your profile + both libraries + today's `/fitness-journal` (including its recorded **sleep data**) + today's `/journal` + the diet profile's **meal times** + today's **scheduled fitness activity** + the last 7 day-plans + your calendar + your habit rollup.
2. Surfaces your goals as the anchor for today.
3. **Wake time** — if today's fitness check-in recorded it, the planner confirms it in passing instead of asking; otherwise it opens with "what time did you wake up?" (short sleep gets flagged; the plan gets a `sleep_hours:` frontmatter field).
4. **Backfill** — "what have you done since waking until now?" Whatever you say gets slotted into ✓ time ranges by the planner itself — gap-free, no overlaps; you correct, it places.
5. **Focus hours → block layout** — "how many focused hours from now?" The planner computes and shows the possible blocks (your session length, breaks rotating through your break activities) laid around the day's fixed anchors — calendar events, the fitness session, meal times (workout-shifted), habit reminder times, your focus hours, nothing past `last_block_end` — and asks if you want to add or reduce.
6. **Allocation** — what goes in the blocks: your work goals first (with context pulled from the work library), life goals next, anything else you name. Deeper tasks get more blocks; small things share one.
7. Confirm the gap-free **Today at a glance** table, then it writes the plan.

The plan includes: a **Today at a glance** schedule table, a **Task log** table (one row per task — `/end-of-day` fills *Done at* / *Status*), **Anchoring on**, **Anchors**, **Blocks** (annotated with which goal each serves), **Breaks & movement**, **Eating**, **Rest**, **Avoiding today**, **Notes**, and a lean **How it went** template `/end-of-day` fills at close (**Executive summary**, **Goal progress**, **Sleep**, **Carry-forward**). Unfinished tasks land in **Carry-forward**, which the next day's plan offers back to you.

## Mid-day task edits

Once today's plan exists, revise it without rebuilding the day:

```bash
/plan-my-day task add        # "add a task to ship the diet refactor"
/plan-my-day task remove     # "drop the email cleanup"
/plan-my-day task list        # show today's task-log rows
```

`task add` appends a row to the **Task log** (resolving its tie to a current weekly goal, offering to add it at the right tier if nothing matches, taking priority + difficulty) and **re-flows "Today at a glance"** — it slots a new work block into the next free gap around the fixed anchors (calendar, meals, fitness, habit 🔔), never past your `last_block_end`, flagging if it doesn't fit. `task remove` drops a row and frees its block (confirming first if the row is already closed, so end-of-day's rollup isn't lost). Both tables are always rewritten together so the schedule and the task log never drift. Running any of these before today is planned is a clear no-op pointing you at `/plan-my-day`.

## Reminders, habits, cadence

- **Reminders** — if a set-time thing comes up while planning ("call X at 3"), the planner offers to set it as an Apple Reminder. Habits placed at a specific time get their one-shot reminders silently rescheduled to match. See [`remind.md`](remind.md).
- **Habits** — if you've set up [`/habits`](habits.md), the planner notes anything that needs attention (a limit habit over cap, a high-priority build habit lagging) and weaves it into the day. **Habits are the only cadence source now**: recurring touchpoints you want surfaced (call mom, creative session, daily walk) should be tracked as habits — the planner reads their streaks/last-done from the rollup instead of grepping old plans.
- **Monday weekly-review nudge** — on Mondays, once 7+ calendar days have passed since your last `/weekly-review`, it suggests running one first (once, non-blocking).

## Managing profiles

```bash
/plan-my-day profile show                 # human-readable summary of all three
/plan-my-day profile new                  # mint a new goals-profile draft
/plan-my-day profile new work-library     # structural rebuild of a library (rare)
/plan-my-day profile commit [base]        # finalize the open draft
```

## Defaults and overrides

**Default destination:** `$VAULT_DIR/life/daily-planning/YYYY-MM-DD.md`

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_PLAN_DIR` | Where today's plan is written; the `.profile` store lives inside it |
| `PBRAIN_PLAN_PROFILE_FILE` | Explicit goals-profile file, bypassing the store |
| `PBRAIN_FITNESS_DIR` | Today's fitness entry + the fitness store (sleep data, scheduled session) |
| `PBRAIN_DIET_DIR` | The diet store (meal times) |
| `PBRAIN_JOURNAL_DIR` | Today's daily journal (cross-ref) |
| `PBRAIN_WEEKLY_DIR` | Last week's review (Monday nudge, cross-ref) |
| `PBRAIN_HABITS_PROFILE_FILE` / `PBRAIN_DB_FILE` | Habits profile / shared SQLite store (cross-ref) |

If today's plan already exists, it's shown and you're asked if you want to update the "How it went" section or revise blocks.
