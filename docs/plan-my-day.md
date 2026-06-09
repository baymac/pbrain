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

Writes everything to a note in your vault:

```
$VAULT/life/Goals Profile.md
```

It's a normal Obsidian note (standard frontmatter + a short intro), with the structured data carried in a fenced ` ```json ` block so the commands that read it (`/plan-my-day`, `/loose-ends`, `/weekly-review`) can parse it. Edit it directly any time, or delete it to redo the interview from scratch. The JSON block's shape:

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

1. Reads your profile + today's `/fitness-journal` + today's `/journal` + the last 7 day-plans + a 30-day cadence signal across recent plans + any pending reminders + your habit rollup (week/month vs caps).
2. Surfaces your current focus areas as the anchor for today (or nudges you to set them if empty).
3. Runs a short **interview-style check-in** (a back-and-forth, not a wall of questions) — opens with what time you woke up and what you've done since (backfilled into the plan as ✓ rows), then adapts: energy, your **top things to do today named in order of complexity/priority** (the Now/Next/Later list — usually 3, but not capped), commitments, available hours, what to avoid, mood for creative, and **anything to declutter** — skipping anything you already mentioned in passing. From that task list it **allocates work blocks by complexity** — the deeper/higher-priority tasks get more blocks, small ones share a block — weaves a **~30-min break between blocks** (rotating through your saved break activities: walk, a couple of games, snack prep), and shows you the split to adjust. The resulting table is gap-free and overlap-free: every span from wake to bed is accounted for.
4. Sweeps the cadence signal against your `personal_anchors` — only suggests calls/check-ins for contacts you actually listed.
5. Surfaces what needs attention from reminders + habits (see below), and generates a structured day plan tied back to the chosen goals.

The plan includes: **Anchoring on** (current focus + this-week moves), **Anchors** (fitness + commitments), **Work** (blocks annotated with which goal they serve), **Breaks & movement**, **Eating**, **Relationships** (only if due and named in profile), **Creative** (tied to your craft), **Rest**, **Avoiding today** (union of your answer + profile anti-patterns), **Notes**, **Declutter** (a tidy task to tick off later), and a **How it went** template for end-of-day reflection — including a **Goal progress** row.

## Declutter, reminders, habits

- **Declutter** — the check-in asks if there's a small mess to tidy today (inbox, desk, files, tabs). Whatever you name lands in a **`## Declutter`** checkbox in the plan, and `/end-of-day` asks whether you got to it and ticks it off. The question is **opt-out**: say "stop asking me to declutter" and the self-improve loop saves that preference, after which it's dropped.
- **Reminders** — anything due today or overdue is surfaced at the top (and has already fired as a macOS notification). Mark one done just by saying so. If a set-time thing comes up while planning ("call X at 3"), the planner offers to set it as a reminder. See [`remind.md`](remind.md).
- **Habits** — if you've set up [`/habits`](habits.md), the planner notes anything that needs attention (a limit habit over its cap, a high-priority build habit lagging this week) and weaves it into the day. Habits you mention are logged automatically. If you haven't set habits up, it nudges once (non-blocking).

**Cadence thresholds:** parents ≥ 6 days → suggest a call, siblings ≥ 14, friends ≥ 7, creative ≥ 4 (if yes/maybe), walk ≥ 2 (if a walk habit is in your profile).

**Monday weekly-review nudge:** on Mondays only, the planner measures how many calendar days have elapsed since your last `/weekly-review` (parsed from the review's covered-through date; if you've never run one, it counts from your oldest day-plan). Once that span hits **7+ days**, it suggests running `/weekly-review` first (once, non-blocking — you can plan now and review later). The span is calendar-based, so days you skipped `/plan-my-day` still count toward the 7 — a sparse planning week won't under-count. If you reviewed within the last week (e.g. the prior Sunday), it stays quiet, and it keeps nudging each Monday until you actually run a review.

## Defaults and overrides

**Default destination:** `$VAULT_DIR/life/daily-planning/YYYY-MM-DD.md`

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_PLAN_DIR` | Where today's plan is written |
| `PBRAIN_PLAN_PROFILE_FILE` | Goals profile note (default: `$VAULT/life/Goals Profile.md`; JSON in a fenced block) |
| `PBRAIN_HABITS_PROFILE_FILE` | Habits profile note (default: `$VAULT/life/Habits Profile.md`; cross-ref for the habit rollup) |
| `PBRAIN_DB_FILE` | Shared SQLite store for reminders + habit events (default: `~/.config/pbrain/pbrain.db`) |
| `PBRAIN_FITNESS_DIR` | Where the script reads today's fitness entry from (cross-ref) |
| `PBRAIN_JOURNAL_DIR` | Where the script reads today's daily journal from (cross-ref) |
| `PBRAIN_WEEKLY_DIR` | Where the script checks for last week's review (Monday nudge, cross-ref) |

**Example:**

```bash
/plan-my-day
```

If today's plan already exists, it's shown and you're asked if you want to update the "How it went" section or revise blocks.

**Re-running setup:** delete `$VAULT/life/Goals Profile.md` to redo the goals interview. Or edit the JSON block directly when goals shift.

**Migrating from an older install:** if you previously had `~/.config/pbrain/plan-profile.json`, the next `/plan-my-day` converts it into `Goals Profile.md` automatically — no re-interview.
