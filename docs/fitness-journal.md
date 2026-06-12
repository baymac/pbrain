# /fitness-journal

Adaptive daily fitness journal. Asks your current state (energy, soreness, sleep window, stress), **pre-selects today's workout from your fixed weekly schedule** (gym, football, swimming, yoga — whatever you do), and generates a session tailored to it. For gym days, runs the block/day rotation with progressive overload pulled from recent sessions and your gym activity profile — including training-gap handling when you've been away.

All base config lives in the **versioned profile store** under your tracking dir:

```
$VAULT_DIR/fitness/daily-tracking/.profile/
├── fitness-profile.vN.md     # overall profile: sleep window, steps/day, health-tracker metrics
├── fitness-library.vN.md     # activity list + occurrence (N×/week|month) + stable metadata
└── activities/<slug>.vN.md   # per-activity profile: fixed days, goals, focus areas, equipment
```

Profiles are markdown with a fenced JSON block; a **committed** version is final — changes mint the next version (`profile new` → edit the draft → `profile commit`).

## First-run setup (two-step bootstrap)

Acts as a full-stack fitness coach the first time you run it.

**Step 1 — Overall profile + library.** Asks your sleep window (bed time, wake time — hours inferred), steps per day, optional health-tracker metrics (Whoop / Garmin / Apple Health), then your activities. For each activity: occurrence per week or month and **fixed days of the week**. Days are assigned non-conflicting — gym defaults to 4×/week (e.g. Mon/Tue/Thu/Fri), other activities spread over free days; you can override any assignment. Equipment, location, typical time, and duration are captured once here.

**Step 2 — Per-activity profiles.** Re-run `/fitness-journal`. For each library activity without a profile, it interviews you (current state, goals, focus areas) and writes a personalised profile. The gym profile keeps the parseable block/day structure the daily session generator consumes.

If you add a new activity to the library later, the next run detects the missing profile and only interviews you about that one.

After step 2, the command suggests running `/diet-journal` to set up the nutrition side.

## Migrating from older pbrain

If you had the old setup (`fitness-activities.json`, `Gym Plan.md`, `fitness/plans/*.md`), the first run after upgrading walks your existing data across **part by part** — you confirm, update, or drop each activity and plan, answer the new profile questions (sleep window, steps, metrics, fixed days), and the old files are parked in `$VAULT_DIR/.pbrain/backup/`. One-time; recorded in the migration ledger so it never re-runs.

## Daily flow

After setup, every run:

1. Asks your state in one batch — energy, soreness/pain/injury, **sleep as bed time + wake time + quality** (hours inferred, midnight crossing handled), stress, bodyweight. The session file records `sleep_bed`, `sleep_wake`, `sleep_quality`, `sleep_hours` in its frontmatter (`/plan-my-day` reads your wake time from here so it doesn't re-ask).
2. Proposes today's activity from your fixed days ("Today is Thu — your schedule says Gym. Go with that, or override?"). The full menu plus Recovery / Walk / Rest stays available.
3. Asks 2–4 follow-ups tailored to the chosen activity (kickoff/location for football, time available for gym — equipment is never re-asked; it's in the profile).
4. Applies adaptive coaching (downgrade on bad sleep + soreness + stress; flag neglected muscle groups or focus areas).
5. **Training-gap rule (gym):** 7–13 days since your last gym session → weights stay the same, no progression, focus on form. 14+ days → deload: −20% on all last logged weights (rounded to 2.5kg) with a note in the session. Under 7 days → normal progressive overload.
6. Generates the session in your tracking format. Non-gym activities get a per-activity rating matrix for post-session review.
7. Suggests `/diet-journal` once the session is saved — only if today's diet entry doesn't already exist.

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

If today's entry already exists, it's shown and you're asked if you want to update the "Log your sets here" section.
