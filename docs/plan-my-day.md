# /plan-my-day

Adaptive daily planner that's actually anchored on **your goals**, not a generic to-do list. On first run, interviews you to build a goals profile. Every subsequent run plans the day against that profile, surfacing your current focus areas at the top and tying each work block back to a specific goal.

## First-run setup

Acts as a planning coach the first time you run it.

Asks you about:

- **Horizon goals** (1–5 things you're trying to build / become / achieve over the next 3–12 months, with rough deadlines + what success looks like)
- **Current focus** (1–3 goals you're actively pushing this month, with this week's concrete move)
- **Working style** (when you actually do focused work, realistic focused hours/day, preferred deep-work block length, energy peak, your "day-wreckers")
- **Anti-patterns** to actively avoid (doomscrolling, late nights, whatever sabotages you)
- **Personal anchors** (relationships to nurture, creative pursuits you practise, health/movement non-negotiables)

Writes everything to:

```
~/.config/pbrain/plan-profile.json
```

Edit that file directly any time, or delete it to redo the interview from scratch. Shape:

```json
{
  "created": "2026-05-27",
  "horizon_goals": [
    { "goal": "Ship pbrain v1", "deadline": "2026-06", "success_looks_like": "..." }
  ],
  "current_focus": [
    { "goal": "Ship pbrain v1", "this_week_move": "publish repo + write blog post" }
  ],
  "working_style": {
    "focus_window": "9am-1pm + 8pm-10pm",
    "focused_hours_per_day": 4,
    "deep_work_block_min": 90,
    "energy_peak": "morning",
    "day_wreckers": ["sleep<7h", "no exercise"]
  },
  "anti_patterns": ["doomscrolling", "late nights"],
  "personal_anchors": {
    "relationships": ["mom", "partner", "best friend"],
    "creative_pursuits": ["music", "writing"],
    "health_habits": ["daily walk", "gym 4x/week"]
  },
  "notes": ""
}
```

## Daily flow

After setup, every run:

1. Reads your profile + today's `/fitness-journal` + today's `/journal` + the last 7 day-plans + a 30-day cadence signal across recent plans.
2. Surfaces your current focus areas as the anchor for today (or nudges you to set them if empty).
3. Asks a short 6-question check-in (energy, today's push from your focus areas, commitments, available hours, what to avoid, mood for creative).
4. Sweeps the cadence signal against your `personal_anchors` — only suggests calls/check-ins for contacts you actually listed.
5. Generates a structured day plan tied back to the chosen goals.

The plan includes: **Anchoring on** (current focus + this-week moves), **Anchors** (fitness + commitments), **Work** (blocks annotated with which goal they serve), **Breaks & movement**, **Eating**, **Relationships** (only if due and named in profile), **Creative** (tied to your craft), **Rest**, **Avoiding today** (union of your answer + profile anti-patterns), **Notes**, and a **How it went** template for end-of-day reflection — including a **Goal progress** row.

**Cadence thresholds:** parents ≥ 6 days → suggest a call, siblings ≥ 14, friends ≥ 7, creative ≥ 4 (if yes/maybe), walk ≥ 2 (if a walk habit is in your profile).

## Defaults and overrides

**Default destination:** `$VAULT_DIR/life/daily-planning/YYYY-MM-DD.md`

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_PLAN_DIR` | Where today's plan is written |
| `PBRAIN_PLAN_PROFILE_FILE` | Goals profile JSON (default: `~/.config/pbrain/plan-profile.json`) |
| `PBRAIN_FITNESS_DIR` | Where the script reads today's fitness entry from (cross-ref) |
| `PBRAIN_JOURNAL_DIR` | Where the script reads today's daily journal from (cross-ref) |

**Example:**

```bash
/plan-my-day
```

If today's plan already exists, it's shown and you're asked if you want to update the "How it went" section or revise blocks.

**Re-running setup:** delete `~/.config/pbrain/plan-profile.json` to redo the goals interview. Or edit the JSON directly when goals shift.
