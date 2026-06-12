# /plan-my-day

Adaptive daily planner anchored on **your plans**, not a generic to-do list. On first run, interviews you to build a versioned plans profile over two short reference libraries. Every subsequent run plans the day against that profile, tying each work block back to a specific current focus item.

## The profile store

All base config lives in the **versioned profile store** under your planning dir:

```
$VAULT_DIR/life/daily-planning/.profile/
├── plans-profile.vN.md   # THE lens: current_focus list + working_style + planning_guidelines + anchors
├── work-library.vN.md    # short reference cards for every work project (living doc)
└── goals-library.vN.md   # short reference cards for non-work goals (living doc)
```

The **plans profile is the live, detailed home** — `current_focus` lists every active item with its deadline, context, and success criteria. The libraries are stable **reference cards** (name + shortcut + one-line context each) that the profile items point to by id.

`working_style` carries the numbers the planner builds with: `session_length_min`, `break_min` + `break_activities`, `work_hours_per_day`, `focus_hours`, and `last_block_end`.

`planning_guidelines` is a prose contract — a short paragraph in your own words describing how you want your day shaped. Written once, refined over time.

Each library card has a **shortcut** (2–3 letter alias): you can reference a project as "pbd" instead of the full name when chatting mid-session.

## First-run setup

A one-sitting interview. You're asked about:

- **Current focus** — what are you actually working on or building right now? Each item gets: track (professional/personal), horizon (short/long), priority, deadline, and "success looks like" + brief context.
- **Working style** — focus hours, total work hours/day, session length, break preference + rotation, last block end, energy peak, day-wreckers.
- **Planning guidelines** — how should I shape your day? (a prose contract you write, e.g. "front-load hard work, keep afternoons light, protect 90-minute deep work sessions")
- **Daily anchors** — wake/workout/lunch/dinner/walk/bed.
- **Anti-patterns** and **personal anchors**.

After setup, library cards are registered for each focus item — suggested at creation, accepted or skipped by you.

## Migrating from older pbrain

If you had the old `Goals Profile.md` (or `plan-profile.json`), the first run after upgrading walks a **one-sitting rebuild**: each old goal confirmed/updated/dropped, classified by track + horizon, the new working-style questions asked, planning guidelines written, libraries seeded. Old files are parked in `$VAULT_DIR/.pbrain/backup/`. One-time; recorded in the migration ledger.

## Daily flow

After setup, every run:

1. Reads your plans profile + both libraries + today's `/fitness-journal` (including recorded **sleep data**) + today's `/journal` + the diet profile's **meal times** + today's **scheduled fitness activity** + the last 7 day-plans + your calendar + your habit rollup.
2. Surfaces your `current_focus` as the anchor for today.
3. **Wake time** — confirmed from the fitness entry if recorded; otherwise "what time did you wake up?"
4. **Backfill** — "what have you done since waking?" slotted gap-free, no overlaps.
5. **Focus hours → block layout** — "how many focused hours from now?" The planner computes work blocks around your **life anchors** (calendar events, the fitness session, meal slots, the walk/wind-down/bed, habit reminder times) and shows the layout before proposing what goes in the blocks. Anchors are life structure only — work is never an anchor; it fills the gaps the anchors leave.
6. **Brainstorm → proposed slate** — assuming you may not know what to do today, the planner *proposes* a candidate task set sized to your blocks (biggest-rock first) drawn from this week's weekly goals (ordered priority → difficulty) + carry-forward, falling back to monthly goals → the `current_focus` list. You react — keep all, swap, drop, or add your own — rather than starting from a blank "what do you want to work on?".
7. Confirm the gap-free **Today at a glance** table, then it writes the plan.

**AUTO-LIBRARY**: if you mention a project or goal not already in a library card, the planner offers to register a shortcut card (name + shortcut + context) so future sessions can reference it by name or shortcut.

The plan includes: a **Today at a glance** schedule table, a **Task log** table (one row per task — `/end-of-day` fills *Done at* / *Status*), **Today's focus**, **Anchors** (life only), **Blocks**, **Breaks & movement**, **Eating**, **Rest**, **Avoiding today**, **Notes**, and a lean **How it went** template `/end-of-day` fills at close (**Executive summary**, **Goal progress**, **Sleep**, **Carry-forward**).

## Mid-day task edits

Once today's plan exists, revise it without rebuilding the day:

```bash
/plan-my-day task add        # "add a task to ship the diet refactor"
/plan-my-day task remove     # "drop the email cleanup"
/plan-my-day task list        # show today's task-log rows
```

`task add` appends a row to the **Task log** (resolving its tie to a weekly goal, offering to add it at the right tier if nothing matches) and **re-flows "Today at a glance"** — slotting a new work block into the next free gap, never past `last_block_end`. `task remove` drops a row and frees its block (confirming first if the row is already closed). Both tables are always rewritten together.

## Managing the current_focus list

```bash
/plan-my-day focus list              # show all active focus items
/plan-my-day focus add               # add a new focus item (interviews you)
/plan-my-day focus archive <id>      # archive a completed or dropped item
/plan-my-day focus restore <id>      # restore an archived item
```

The planner emits `PLAN_MY_DAY_FOCUS` context with the full profile + libraries so you can review and edit together.

## Managing the libraries

```bash
/plan-my-day library work show       # show work-library cards
/plan-my-day library goals show      # show goals-library cards
/plan-my-day library work edit       # update a work-library card
/plan-my-day library goals edit      # update a goals-library card
```

Libraries are living documents — cards are appended and enriched in place; the version only bumps on a structural rebuild.

## Reminders, habits, cadence

- **Reminders** — if a set-time thing comes up while planning ("call X at 3"), the planner offers to set it as an Apple Reminder. Habits placed at a specific time get their one-shot reminders silently rescheduled to match. See [`remind.md`](remind.md).
- **Habits** — if you've set up [`/habits`](habits.md), the planner notes anything that needs attention and weaves it into the day. Recurring touchpoints (call mom, creative session, daily walk) should be tracked as habits — the planner reads their streaks/last-done from the rollup.
- **Monday weekly-review nudge** — on Mondays, once 7+ calendar days have passed since your last `/weekly-review`, it suggests running one first (once, non-blocking).
- **End-of-session diet nudge** — after the plan is saved, if today's `/diet-journal` entry doesn't exist yet, it drops one non-blocking line offering to log your meals.

## Managing profiles

```bash
/plan-my-day profile show                  # human-readable summary of all profiles
/plan-my-day profile new                   # mint a new plans-profile draft
/plan-my-day profile new work-library      # structural rebuild of a library (rare)
/plan-my-day profile commit [base]         # finalize the open draft
```

## Defaults and overrides

**Default destination:** `$VAULT_DIR/life/daily-planning/YYYY-MM-DD.md`

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_PLAN_DIR` | Where today's plan is written; the `.profile` store lives inside it |
| `PBRAIN_PLAN_PROFILE_FILE` | Explicit plans-profile file, bypassing the store |
| `PBRAIN_FITNESS_DIR` | Today's fitness entry + the fitness store (sleep data, scheduled session) |
| `PBRAIN_DIET_DIR` | The diet store (meal times) + today's diet entry (end-of-session nudge) |
| `PBRAIN_JOURNAL_DIR` | Today's daily journal (cross-ref) |
| `PBRAIN_WEEKLY_DIR` | Last week's review (Monday nudge, cross-ref) |
| `PBRAIN_HABITS_PROFILE_FILE` / `PBRAIN_DB_FILE` | Habits profile / shared SQLite store (cross-ref) |

If today's plan already exists, it's shown and you're asked if you want to update the "How it went" section or revise blocks.
