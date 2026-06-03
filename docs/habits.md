# /habits

Track a small set of habits over time — both ones you want to **build** (do regularly) and ones you want to **limit** (keep under a cap). First run defines the set; every run after shows where you stand.

## First-run setup

Acts as a setup interview the first time you run it. You define a handful of habits (5–8 is plenty). For each:

- **kind** — `build` (do at least N times) or `limit` (stay at or under N times).
- **priority** — low / medium / high.
- **cap** — a count per **week** or per **month** (a target for build habits, a ceiling for limit habits). Optional — leave it off if there's no natural cap.
- an optional short note ("10 min morning", "weekends only").

Written to a normal Obsidian note in your vault:

```
$VAULT/life/Habits Profile.md
```

It's a markdown note with the structured data in a fenced ` ```json ` block (same pattern as your goals profile), so you can edit it directly or delete it to redo setup. Shape:

```json
{
  "created": "2026-06-03",
  "habits": [
    { "name": "Meditate", "kind": "build", "priority": "high", "cap_period": "week", "cap_count": 7, "notes": "10 min, morning" },
    { "name": "Alcohol",  "kind": "limit", "priority": "medium", "cap_period": "week", "cap_count": 2, "notes": "" }
  ]
}
```

## How habits get logged

You rarely log by hand. Once the profile exists, every daily journaling and planning command (`/journal`, `/gratitude-journal`, `/fitness-journal`, `/diet-journal`, `/plan-my-day`, `/end-of-day`) watches for habits you actually mention and logs them automatically. Events go into the shared SQLite DB (`~/.config/pbrain/pbrain.db`), **one row per habit per day** — so the same habit mentioned across several commands isn't double-counted, and re-running a command is safe.

`/plan-my-day` and `/end-of-day` also actively surface habit patterns and ask about today's habits. `/weekly-review` **surfaces** the week's rollup (it doesn't log — the week's habits were already captured day-by-day by the commands above).

## The dashboard

Running `/habits` (with a profile in place) shows a rollup per habit:

- this-week and this-month counts vs your cap,
- last-done date,
- flags: limit habits **over cap** (⚠️), high-priority build habits **lagging / untouched this week**, build habits with their **target met** (✅).

Then it offers to log today's habits or tweak the list.

## Subcommands

| Command | What it does |
|---|---|
| `/habits` | Setup (first run) or dashboard |
| `/habits list` | List the configured habits |

Script-level API (used by the auto-logging): `log --name "X" --date YYYY-MM-DD [--count N] [--source cmd] [--note "…"]`, `rollup [--date YYYY-MM-DD]`.

## Defaults and overrides

**Default profile:** `$VAULT_DIR/life/Habits Profile.md`

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_VAULT` | Vault root | iCloud Obsidian path |
| `PBRAIN_HABITS_PROFILE_FILE` | Habits profile markdown path | `$VAULT/life/Habits Profile.md` |
| `PBRAIN_DB_FILE` | SQLite event-log DB (shared with `/remind`) | `~/.config/pbrain/pbrain.db` |

**Re-running setup:** edit the JSON block directly when habits change, or delete `Habits Profile.md` to redo the interview.
