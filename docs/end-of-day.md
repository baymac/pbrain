# /end-of-day

Close-of-day reflection — bookend to `/plan-my-day`. Reads today's plan, daily journal, fitness session, and diet log, then walks four questions: what got done, what got dropped, energy curve, what to carry into tomorrow. Writes the answers **into the existing "How it went" section of today's plan file** — no sibling close files.

The plan-close loop is where most planning systems get sticky. Opening the day without closing it leaves the plan unverified — you keep planning into a void. Closing reconnects the loop and gives `/weekly-review` something to read.

**Write target:** the existing `## How it went` section of `$VAULT_DIR/life/daily-planning/YYYY-MM-DD.md` (the file `/plan-my-day` already created). One file per day, not two.

**Behaviour:**

- If today's plan file exists → fills the `## How it went` section in place with: what you actually did, wins, what slipped, goal progress (vs `focus_today`), energy curve, tomorrow seed.
- If today's plan file doesn't exist → creates a free-form close at that path instead of anchoring to a plan.
- If `## How it went` already has user-filled content → asks whether to overwrite, append, or skip before touching it (idempotency guardrail).
- Propagates the close into today's diet and fitness files automatically:
  - **Diet file:** flips planned meals to `eaten` (or `skipped`) with real items + macros, recomputes the Total/Net rows, rebuilds the Nutrition Analysis table against actuals, strips the stale "Suggested next meal(s)" block and replaces it with a short carry-forward list, updates the Coach note to the day that actually happened.
  - **Fitness file:** flips `status: planned` → `completed` (or `skipped`), preserves the sets the user already logged, appends an `## Other movement today` section for walks / ring closes / extra cardio if mentioned.
  - **Journal file:** untouched (it's the user's raw voice from earlier).
  - **Declutter:** if the plan has an unchecked `## Declutter` item, asks whether you got to it and ticks the checkbox (`- [ ]` → `- [x]`). Skipped if there's no item or your prefs turned the declutter prompt off.
  - **Reminders:** surfaces anything overdue / due today (already fired as notifications), lets you mark off what you handled, and offers once to set a reminder for anything worth carrying into tomorrow.
  - **Habits:** logs any tracked habits you evidenced today and notes standouts (a limit habit over cap, a high-priority build habit that lagged). Silent if you haven't set up `/habits` (nudges once).
  - Bookkeeping only — the close never invents new analysis or new prescriptions.

**Tone rules baked into the prompt:**

- Warm but tight — the user already reflected, the agent's job is to record, not pile on.
- Neutral language only — no "wins" or "losses" in the agent's voice (the user's own framing is preserved verbatim).
- Quotes the user's own words verbatim into the file — no corporate paraphrase.
- If the day went sideways (illness, crisis), skips the "what got dropped" question and softens the rest.
- One line of closing warmth, not three paragraphs.

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_PLAN_DIR` | Where the plan file lives (read + write target) |
| `PBRAIN_JOURNAL_DIR` | Today's daily journal (cross-reference) |
| `PBRAIN_FITNESS_DIR` | Today's fitness session (cross-reference + bookkeeping update target) |
| `PBRAIN_DIET_DIR` | Today's diet log (cross-reference + bookkeeping update target) |
| `PBRAIN_HABITS_PROFILE_FILE` | Habits profile (cross-ref for the habit rollup) |
| `PBRAIN_DB_FILE` | Shared SQLite store for reminders + habit events |

**Example:**

```bash
/end-of-day
```

## Migrating older `-close.md` sibling files

Older runs of this command wrote a sibling file at `$VAULT_DIR/life/daily-planning/YYYY-MM-DD-close.md`. The new behaviour is in-place inside the plan file's existing `## How it went` section. If you have legacy close files, fold their contents back into the matching plan file and delete the sibling — `/weekly-review` and downstream readers only look at the plan file going forward.
