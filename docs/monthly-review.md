# /monthly-review

Monthly synthesis + goals lifecycle command. Reads all weekly reviews from the current calendar month, walks a 3-question reflection, and manages the monthly-goals tier.

## What it does

1. **Month synthesis** — reads all weekly reviews for the month, surfaces 3–5 recurring themes, asks what the month was about, what to change, and what to keep.
2. **Monthly goals lifecycle** — commits the closing month's goals draft, mints next month's goals (derived from the plans profile `current_focus`, one goal at a time with a one-month milestone), then commits.
3. **Plans-profile hygiene pass** — optional: archive completed `current_focus` items, update stale context. Prior versions keep the history.
4. **Improvements walk** — same approve/reject flow as /weekly-review, but for month-level patterns only.
5. **Habit month review** — one paragraph read, evidence-based proposals.

## Output

Writes `$VAULT_DIR/life/monthly-tracking/YYYY-MM.md` (default; override with `PBRAIN_MONTHLY_DIR`).

If this month's review already exists, the existing file is shown and the command exits without overwriting.

## Monthly goals tier

Monthly goals live in `<plan-dir>/.profile/monthly-goals.vN.md` with a `"period": "YYYY-MM"` field in the JSON block. They're optional — if you skip them, /weekly-review derives its weekly goals directly from the plans profile.

When monthly goals are set up:
- /weekly-review derives weekly goals from them (rather than the full profile)
- /plan-my-day surfaces them as the fallback menu when no weekly goals exist

The JSON shape for a monthly-goals file:

```json
{
  "created": "YYYY-MM-DD",
  "period": "YYYY-MM",
  "derived_from": "plans-profile vN",
  "goals": [
    {
      "id": "slug",
      "goal": "...",
      "tie": "profile-goal-id or null",
      "priority": 1,
      "success_looks_like": "...",
      "status": "active"
    }
  ]
}
```

## Env overrides

| Variable | Default | Purpose |
|---|---|---|
| `PBRAIN_MONTHLY_DIR` | `$VAULT_DIR/life/monthly-tracking` | Where reviews write |
| `PBRAIN_WEEKLY_DIR` | `$VAULT_DIR/life/weekly-tracking` | Weekly reviews (read) |
| `PBRAIN_PLAN_DIR` | `$VAULT_DIR/life/daily-planning` | Plan store (plans profile lives here) |
| `PBRAIN_PLAN_PROFILE_FILE` | (store auto-resolves) | Explicit plans-profile override |
| `PBRAIN_FITNESS_DIR` | `$VAULT_DIR/fitness/daily-tracking` | Fitness sessions + profile store (read) |
| `PBRAIN_DIET_DIR` | `$VAULT_DIR/fitness/diet-tracking` | Diet logs + profile store (read) |

## When to run

At the end of each calendar month (last 3 days) or the start of the next one (first 3 days). Pairs well with `/recall` — once a pattern surfaces in a monthly review, run `/recall <theme>` to see how far back it actually goes.
