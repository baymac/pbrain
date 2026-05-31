# /fitness-journal

Adaptive daily fitness journal. Asks your current state (energy, soreness, sleep, stress), picks today's workout from **your** configured activities (gym, football, swimming, basketball, yoga, climbing — whatever you do), and generates a session tailored to it. For gym days, runs the block/day rotation with progressive overload pulled from recent sessions and `fitness/Gym Plan.md`.

## First-run setup (two-step bootstrap)

Acts as a full-stack fitness coach the first time you run it.

**Step 1 — Activities.** Asks what activities you do and writes them to:

```
~/.config/pbrain/fitness-activities.json
```

Shape:

```json
{
  "activities": ["Football", "Swimming", "Basketball", "Gym", "Yoga"]
}
```

Edit that file directly any time to add or remove activities. `Rest day`, `Recovery/stretching`, and `Walk/cardio` are always offered alongside your list — don't add them to the config.

**Step 2 — Plans.** Re-run `/fitness-journal`. For each activity without a plan, it interviews you (current state, goals, focus areas, constraints) and writes a personalised plan markdown file. Plans live at:

- Gym → `$VAULT_DIR/fitness/Gym Plan.md` (block/day structure consumed by the daily session generator)
- Everything else → `$VAULT_DIR/fitness/plans/<slug>.md` (one file per activity)

Plans include current-state snapshot, 3-month goals, weekly structure, focus-area drills with progression, and milestones. The daily session flow reads these to shape each day's work.

If you add a new activity to the config later, the next `/fitness-journal` run will detect the missing plan and only interview you about that one.

After step 2, the command suggests running `/diet-journal` to set up the nutrition side.

## Daily flow

After setup, every run:

1. Asks your state (energy, soreness, sleep, stress, pain, bodyweight).
2. Shows your activity menu and asks what you want today.
3. Asks 2–4 follow-ups tailored to the chosen activity (e.g. kickoff/location for football, pool/strokes for swimming, time/equipment for gym).
4. Applies adaptive coaching (downgrade on bad sleep + soreness + stress; flag overused muscle groups, etc.).
5. Generates the session in your tracking format. For non-gym activities, builds a per-activity rating matrix for post-session review.
6. Once the session is saved, suggests `/diet-journal` to log today's food — once, never blocks, and only if today's diet entry doesn't already exist.

**Default destination:** `$VAULT_DIR/fitness/daily-tracking/YYYY-MM-DD.md`

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_FITNESS_DIR` | Where today's session is written |
| `PBRAIN_GYM_PLAN_FILE` | Path to your gym plan markdown (default: `$VAULT_DIR/fitness/Gym Plan.md`) |
| `PBRAIN_FITNESS_PLANS_DIR` | Dir for non-gym activity plans (default: `$VAULT_DIR/fitness/plans`) |
| `PBRAIN_FITNESS_ACTIVITIES_FILE` | Path to activities config (default: `~/.config/pbrain/fitness-activities.json`) |
| `PBRAIN_DIET_DIR` | Diet-tracking dir, checked to decide whether to suggest `/diet-journal` after a session (default: `$VAULT_DIR/fitness/diet-tracking`) |

**Example:**

```bash
/fitness-journal
```

If today's entry already exists, it's shown and you're asked if you want to update the "Log your sets here" section.
