# /fitness-journal

A flexible daily fitness journal — **logger-first, with on-request session generation**. You describe your session in plain words — "swam 2k in 45 min", "bench 3×8 at 60kg then squats", "easy yoga, 20 min" — and it derives that activity's **KPIs**, tolerates whatever you leave out, and writes the day's entry. When you instead **plan a session ahead** (accept the owed/scheduled session, or ask it to "plan it" / "what should I do?"), it **generates a complete, ready-to-follow session**: for the gym it computes your Block/Day rotation, progressive overload, and training-gap deload, and writes a coaching note, warmup, weighted targets, cooldown, and an empty set-log table to fill in; for other activities it writes concrete KPI targets. It never prescribes onto a session you're merely reporting. Casual or serious, full data or a one-liner — both work.

All base config lives in the **versioned profile store** under your tracking dir:

```
$VAULT_DIR/fitness/daily-tracking/.profile/
├── fitness-profile.vN.md     # overall profile: sleep window, steps/day, health-tracker metrics
├── fitness-library.vN.md     # activity list + occurrence (N×/week|month) + stable metadata + per-activity KPIs
└── activities/<slug>.vN.md   # per-activity profile: fixed days, goals, focus areas, equipment
```

Profiles are markdown with a fenced JSON block; a **committed** version is final — changes mint the next version (`profile new` → edit the draft → `profile commit`).

## First-run setup (two-step bootstrap)

Acts as a full-stack fitness coach the first time you run it.

**Step 1 — Overall profile + library.** Asks your sleep window (bed time, wake time — hours inferred), steps per day, optional health-tracker metrics (Whoop / Garmin / Apple Health), then your activities. For each activity: occurrence per week or month, **fixed days of the week**, and **which KPIs to log** (gym → sets; swimming → distance + duration; dance/yoga/meditation → minutes; team sport → duration + notes — sensible defaults suggested, you trim or add). Days are assigned non-conflicting — gym defaults to 4×/week (e.g. Mon/Tue/Thu/Fri), other activities spread over free days; you can override any assignment. Equipment, location, typical time, and duration are captured once here.

**Step 2 — Per-activity profiles.** Re-run `/fitness-journal`. For each library activity without a profile, it interviews you (current state, goals, focus areas) and writes a personalised profile. The gym profile keeps a **Block/Day** plan that drives a generated gym session (which day in the rotation, which exercises) when you plan a session ahead — it is never auto-prescribed onto a session you're just logging.

If you add a new activity to the library later, the next run detects the missing profile and only interviews you about that one.

After step 2, the command suggests running `/diet-journal` to set up the nutrition side.

## Per-activity KPIs

Each activity in the library carries a `kpis` list — the things worth logging for it. KPI types: `sets` (exercise/reps/weight — renders a Log table), `distance`, `duration`, `number`, `rating` (1–10), `text`. They're **user-extensible**: tell the logger "also track RPE for gym" and it appends the KPI in place.

KPIs are **backward-compatible** — if an activity has no `kpis` yet (e.g. a library from before this feature), the logger derives sensible defaults from the activity type on the fly and offers once to save them. No migration, nothing breaks.

## Migrating from older pbrain

If you had the old setup (`fitness-activities.json`, `Gym Plan.md`, `fitness/plans/*.md`), the first run after upgrading walks your existing data across **part by part** — you confirm, update, or drop each activity and plan, answer the new profile questions (sleep window, steps, metrics, fixed days), and the old files are parked in `$VAULT_DIR/.pbrain/backup/`. One-time; recorded in the migration ledger so it never re-runs.

## Daily flow

After setup, every run:

1. **Quick, skippable check-in** — energy, soreness (pre-filled from your recent sessions — "right knee 6/10 after football last night"), sleep (bed/wake/quality), stress, bodyweight. Answer some, all, or none — or say **`skip`**. If you skip, it asks once whether to skip the check-in from now on; say yes and it won't ask again (a standing preference is saved). If you just say what you did or are planning, it goes straight to logging.
2. **Today's picture + one question** — a tight read of where you stand (the weekday/date from your computer's clock, whether it's a fixed training day, what's owed or carried over, your most recent relevant session), then a single question: *"planning to do {the owed/scheduled session}, or something else?"* No long menu. Then it parses your description into KPIs — resolving the activity against your library and filling what you mentioned (e.g. "ran 5k easy" → distance 5 km, intensity easy); anything you don't mention is left blank.
3. **Folds in your state** — infers sleep hours and records `sleep_bed`, `sleep_wake`, `sleep_quality`, `sleep_hours` in frontmatter (`/plan-my-day` and the Sleep-well habit read these). If a flag stands out (short sleep, high soreness, low energy) it says so in one line and may suggest scaling back — never blocks, never prescribes.
4. **Generates the session on request** — if you're planning ahead (you accept the owed/scheduled session, or ask it to plan), it writes a complete, ready-to-follow session: a coaching note, a warmup, weighted/target work in `## Planned`, a cooldown, and an empty `## Logged` table to fill in. For the gym it picks the next day in your A→B→C→D rotation and sets weights by progressive overload — easing back automatically after a layoff (repeat weights after 7–13 days off, a ~20% deload after 14+). If you'd rather just log what you already did, or hand your own exercise list, it logs that instead and never prescribes.
5. **Writes the entry** — frontmatter (keeping `activity:`/`focus:`/`sleep_*`/`status`), a KPI summary line, and up to two sections: **`## Planned`** (your targets) and **`## Logged`** (your actuals). Reconciles your fitness-habit reminders to what you actually did.
6. Suggests `/diet-journal` once the session is saved — only if today's diet entry doesn't already exist.

Re-run it later the same day to log the actuals against your plan, add more, correct a number, log a second activity, or ask for plan help — it updates the entry in place.

### Planned vs Logged

An entry carries up to two sections:

- **`## Planned`** — what you set out to do (target sets × reps × weight, or distance/duration goals). Present whenever there's a plan.
- **`## Logged`** — what you actually did. Appears once you've done (or started) the session.

The flow follows your reality:

- **Plan ahead, not done yet** → just `## Planned`, `status: planned`.
- **Logged directly / done** → both sections — the logger explodes your description into the targets you aimed at and the actuals you hit — `status: completed` (or `partial` if you fell short).
- **At close** → `/end-of-day` flips a still-`planned` entry to `completed` (session happened) or `skipped`, filling `## Logged` from what you report.

The "Train" habit scores planned-vs-actual straight from these two sections.

## Managing profiles

```bash
/fitness-journal profile show                      # human-readable summary of all fitness profiles
/fitness-journal profile new                       # mint a new draft of the overall profile
/fitness-journal profile new fitness-library       # … or the library
/fitness-journal profile new activity football     # … or one activity profile
/fitness-journal profile commit [base]             # finalize the open draft
```

A draft (`committed: false`) is editable; iterate freely. Committing freezes it — commands always read the latest committed version, and old versions stay on disk as history.

**Default destination:** `$VAULT_DIR/fitness/daily-tracking/YYYY-MM-DD.md`

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_FITNESS_DIR` | Daily-tracking dir; the `.profile` store lives inside it |
| `PBRAIN_DIET_DIR` | Diet-tracking dir, checked to decide whether to suggest `/diet-journal` after a session |
| `PBRAIN_GYM_PLAN_FILE` / `PBRAIN_FITNESS_PLANS_DIR` / `PBRAIN_FITNESS_ACTIVITIES_FILE` | Legacy paths — only read by the one-time migration |

**Example:**

```bash
/fitness-journal
```

If today's entry already exists, it's shown and you're asked what to update — add to the session, correct a KPI, log a second activity, or get help planning the rest.
