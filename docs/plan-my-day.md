# /plan-my-day

Adaptive daily planner anchored on **your plans**, not a generic to-do list. On first run, interviews you to build a versioned plans profile over two short reference libraries. Every subsequent run plans the day against that profile, tying each work block back to a specific current focus item.

## The profile store

All base config lives in the **versioned profile store** under your planning dir:

```
$VAULT_DIR/life/daily-planning/.profile/
├── plans-profile.vN.md   # THE lens: current_focus list + working_style + planning_guidelines + anchors + typical_day + variation_rules
├── work-library.vN.md    # short reference cards for every work project (living doc)
└── goals-library.vN.md   # short reference cards for non-work goals (living doc)
```

The **plans profile is the live, detailed home** — `current_focus` lists every active item with its deadline, context, and success criteria. The libraries are stable **reference cards** (name + shortcut + one-line context each) that the profile items point to by id.

`working_style` carries the numbers the planner builds with: `session_length_min`, `break_min` + `break_activities`, `work_hours_per_day`, `focus_hours`, and `last_block_end`.

`planning_guidelines` is a prose contract — a short paragraph in your own words describing how you want your day shaped. Written once, refined over time.

`typical_day` is a **generously-padded baseline** of what your normal day looks like, captured as two wake→bed timelines — a `workday` and a `rest_day` — plus the `rest_days` weekdays that pick between them. Each segment carries a `category` (wake/fitness/meal/work/movement/rest/bed) and a `flex` level (`fixed` for meals/wake/bed, `flex` for work, `skippable` for fitness). Padding it generously means real days leave **slack to do extra, never a deficit** — the planner treats the segments as ceilings it may compress, never expand, and derives the flat `daily_anchors` from the workday. `variation_rules` then says how to adapt when a day deviates: non-negotiables come first, the meal **count** stays the same, **work is the flex variable** (meals + fitness protected), late wake-ups shift the timeline while keeping ≥30 min before the first work block, non-gym fitness days ask the activity's duration including buffer and shift meals to fit, and the planner only *suggests* skipping fitness when meals run late AND you've already been active recently.

Each library card has a **shortcut** (2–3 letter alias): you can reference a project as "pbd" instead of the full name when chatting mid-session.

## First-run setup

A one-sitting interview. You're asked about:

- **Current focus** — what are you actually working on or building right now? Each item gets: track (professional/personal), horizon (short/long), priority, deadline, and "success looks like" + brief context.
- **Working style** — focus hours, total work hours/day, session length, break preference + rotation, last block end, energy peak, day-wreckers.
- **Planning guidelines** — how should I shape your day? (a prose contract you write, e.g. "front-load hard work, keep afternoons light, protect 90-minute deep work sessions")
- **Typical day template** — walk through an average workday and an average rest/weekend day, wake → bed, every block generously padded so real days leave slack to do *extra*, never a deficit. The flat **daily anchors** (wake/workout/lunch/dinner/walk/bed) are derived from the workday timeline, so there's no separate anchors question.
- **Variation rules** — captured once: how the planner adapts when a day deviates (non-negotiables first, work is the flex variable, meals + fitness protected, late-wake 30-min gap, non-gym fitness duration + buffer → meal shift, the in-context skip-fitness judgment).
- **Anti-patterns** and **personal anchors**.

After setup, library cards are registered for each focus item — suggested at creation, accepted or skipped by you.

## Migrating from older pbrain

If you had the old `Goals Profile.md` (or `plan-profile.json`), the first run after upgrading walks a **one-sitting rebuild**: each old goal confirmed/updated/dropped, classified by track + horizon, the new working-style questions asked, planning guidelines written, the **typical-day template + variation rules** captured (fleshing your flat anchors into full padded workday + rest-day timelines), libraries seeded. Old files are parked in `$VAULT_DIR/.pbrain/backup/`. One-time; recorded in the migration ledger.

## Daily flow

After setup, every run:

1. Reads your plans profile + both libraries + today's `/fitness-journal` (including recorded **sleep data** *and* the **chosen activity** from its `focus:` field) + today's `/journal` + the diet profile's **meal times** + today's **scheduled fitness activity** + the last 7 day-plans + your calendar + your habit rollup.
   - **Activity-aware habit reminders.** When today's fitness entry names a chosen activity, the planner reconciles your fitness-habit reminders to it deterministically: the matching habit's reminder is set (even off its usual schedule), and any *other* fitness habit that was scheduled today but isn't the one you chose has its reminder cancelled and is auto-**skipped** (no stale "go to the gym" notification on a day you did Apple Fitness instead). Floating activities (Yoga, Meditation) that co-occur with a workout are never auto-skipped.
2. Surfaces your `current_focus` as the anchor for today.
3. **Wake time** — confirmed from the fitness entry if recorded; otherwise "what time did you wake up?"
4. **Backfill** — "what have you done since waking?" slotted gap-free, no overlaps.
5. **Today's shape** — when a `typical_day` template exists, the planner picks `workday` vs `rest_day` (from your `rest_days`), lays it as today's padded baseline, anchors today's non-negotiables (calendar + an explicit "anything that can't move?" ask) **first**, then applies `variation_rules` — preponing/postponing around the fixed points, detecting a non-gym fitness day or a late wake-up, keeping the meal count, and proposing its own reshaped day for you to accept or tweak. (No template yet → it plans from scratch and offers to add one.)
6. **Focus hours → block layout** — "how many focused hours from now?" The planner computes work blocks around your **life anchors** (calendar events, the fitness session, meal slots, the walk/wind-down/bed, habit reminder times) and lays the blocks as **generic placeholders** ("Block N — focus work"). Anchors are life structure only — work is never an anchor; it fills the gaps the anchors leave.
7. Confirm the gap-free **Today at a glance** table, then it writes the plan and nudges you to run **[`/plan-my-work`](plan-my-work.md)** to fill the blocks with tasks.

**AUTO-LIBRARY**: if you mention a project or goal not already in a library card, the planner offers to register a shortcut card (name + shortcut + context) so future sessions can reference it by name or shortcut.

The plan includes: a **Today at a glance** schedule table (work blocks are placeholders), **Today's focus** (the week's projects), **Anchors** (life only), **Blocks**, **Breaks & movement**, **Eating**, **Rest**, **Avoiding today**, **Notes**, and a lean **How it went** template `/end-of-day` fills at close (**Executive summary**, **Goal progress**, **Sleep**, **Carry-forward**). It **no longer writes a Task log** — [`/plan-my-work`](plan-my-work.md) writes the `## Work tracker` when it fills the blocks.

## Tasks moved to /plan-my-work

`/plan-my-day` lays out the day's *shape*; it no longer proposes or assigns tasks. After it confirms the day, run **[`/plan-my-work`](plan-my-work.md)** to pull real tasks from Plane into the blocks. Mid-day task edits (`task add` / `task remove` / `task list`) also live there now — running `/plan-my-day task …` just points you at `/plan-my-work task …`.

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

**Draft commit safety:** after any change to an open profile draft, the planner shows what changed and asks "Want to lock this in?" before committing. Auto-commit is never allowed — you must explicitly confirm (yes / "lock" / "commit" / "save it"). If you ask for more edits, it keeps modifying the same open draft — no new version is minted until you say so.

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
