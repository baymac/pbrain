# /end-of-day

Close-of-day **completion pass** — bookend to `/plan-my-day`. Not a reflection journal: it takes what the day's tables and tracker already record, asks only **specific gap-filling questions** (never open-ended "how did it go"), makes sure the day's trackings are complete, then writes a lean **executive summary** into the existing "How it went" section of today's plan file — no sibling close files.

The plan-close loop is where most planning systems get sticky. Opening the day without closing it leaves the plan unverified — you keep planning into a void. Closing reconnects the loop and gives `/weekly-review` something to read.

**Write target:** the existing `## How it went` section of `$VAULT_DIR/life/daily-planning/YYYY-MM-DD.md` (the file `/plan-my-day` already created). One file per day, not two. Pass `--date YYYY-MM-DD` (or a bare date positional arg) to close a **past day** — useful when you missed an end-of-day or closed late. Every downstream path (habit rollup, laptop report, diet/fitness cross-ref) keys off that date, not today's.

**Behaviour:**

- Leads with a one-line **recap** of what's already known (resolved tasks, logged meals, the fitness session, habit marks, laptop usage), then asks only the gaps — one domain per message: (1) still-open plan tasks/blocks, (2) the fitness session + on-track-to-sleep (today only), (3) unlogged meals, (4) which due habits got done, (5) any unresolved journal open questions. A domain with no gaps is skipped.
- **Deep work focus** (when laptop tracking is set up): extracts the work-block time windows from the plan, scores how much of that active time went to work vs. distraction (via `/laptop-tracking focus-breakdown`), asks you to categorize any new sites once, and folds the focus % into the laptop line of the close.
- Fills the plan in place: the `## Work tracker` (Status / Done at / % complete / Est rating) and `## Today at a glance` (a `✓` prefix on blocks that happened). (Legacy plans with a `## Task log` are reconciled the same way.)
- **Plane reconcile** (when Plane is configured): pushes each work-tracker row's status back to Plane (idempotent) and pulls in any issues you completed in Plane today but never planned as **"unplanned"** rows. The weekly-goal rollup matches work by **project** (`plane_project`), not task text. Without Plane, this step is skipped silently — the local `## Work tracker` reconciliation still runs.
- Writes a lean `## How it went`: **Executive summary** (small wins across work / diet / fitness / relationships + anything logged in your journal & thoughts), **Scoreboard** (see below), **Goal progress** (vs `focus_today`), **Sleep**, and an auto-derived **Carry-forward** (your not-done tasks, which next day's `/plan-my-day` offers back to you). No energy curve, no tomorrow-seed prompt.
- **Marks all five scored-habit defaults** from the day's data as a backstop — Work the plan, Train, Eat clean, Sleep well, Deep work — so weekly/monthly scores aren't full of holes (idempotent if a command already marked one).
- On the last day of the ISO week / month, adds a once pointer to `/weekly-review` / `/monthly-review` (non-blocking).
- If today's plan file doesn't exist → creates a free-form close at that path instead of anchoring to a plan.
- If `## How it went` already has user-filled content → asks whether to overwrite, append, or skip before touching it (idempotency guardrail).
- Propagates the close into today's diet and fitness files automatically:
  - **Diet file:** flips planned meals to `eaten` (or `skipped`) with real items + macros, recomputes the Total/Net rows, rebuilds the Nutrition Analysis table against actuals, strips the stale "Suggested next meal(s)" block and replaces it with a short carry-forward list, updates the Coach note to the day that actually happened.
  - **Fitness file:** flips `status: planned` → `completed` (or `skipped`), preserves the sets the user already logged, appends an `## Other movement today` section for walks / ring closes / extra cardio if mentioned.
  - **Journal file:** untouched (it's the user's raw voice from earlier).
  - **Habits:** logs any tracked habits you evidenced today and notes standouts (a limit habit over cap, a high-priority build habit that lagged). Before consolidating, an **autostatus** pass (`habits autostatus`) records every build habit that was *due today but never marked* as **missed** — so scheduled habits stop silently vanishing — while leaving anything already done or skipped untouched (limit habits and off-day habits are never auto-missed). The consolidated day file then keeps your done / skipped / missed rows; only the untouched ones are pruned. Silent if you haven't set up `/habits` (nudges once).
  - **Reminders:** once your habits are consolidated, a **two-way sync with sweep** runs (`habits reminders-sync --sweep`) for any habit linked to an Apple Reminder (`/remind`): a reminder you ticked off in the Reminders app marks the habit done here, and a habit you closed today completes its per-day reminder. The `--sweep` pass (end-of-day only) then cancels any still-pending one-shot reminders for habits you didn't complete, so they don't linger as overdue notifications overnight. Surfaced as a one-line summary only if something moved (e.g. "Synced 2 habit reminders, cleared 1 undone."), never asked. No proactive "want to link these?" nag — linking is opt-in, per habit, only when you ask (or at `/habits` add/setup). Reminders only — a Calendar event has no "done" state. Silent when nothing's linked or the Reminders helper isn't built / lacks access.
  - Bookkeeping only — the close never invents new analysis or new prescriptions.

**`### Scoreboard`** — a numeric snapshot written into `## How it went`, immediately after `### Executive summary`:

- **Habits (scored):** a table with one row per scored habit — Score (`0.NN` on a 0–1 scale, read back verbatim from `habits.sh scores --date <date>` after the marks are written), Priority, and Basis (a terse derivation: `4 clean / 1 unclean`, `bed 23:40 vs 23:30 · 7.2h`, `2h10 work / 35m social`). Score values come straight from the engine (stored in `habit_events.amount` at mark time) — never re-derived by the model.
- **Habits (other due today):** one line per non-scored habit that was due, from the rollup, plus a one-line `Today: N missed · M skipped` summary from the autostatus pass when either is non-zero.
- **Diet:** `Cals X / target Y (net ±Z) · P x/t · C x/t · F x/t · Fiber x/t`, from the closed diet log.
- **Fitness:** `{activity} — actual/planned volume (Train 0.NN) · {status}`.
- **Work:** `Focus N% — work Xm / social Ym / entertainment Zm · AFK Wm over Vh blocks`.
- Any domain with nothing logged is omitted. Numbers are never invented.

**Tone rules baked into the prompt:**

- Specific questions only — no open-ended reflection prompts; the agent's job is to record, not pile on.
- Neutral language only — no "wins" or "losses" in the agent's voice (the user's own framing is preserved verbatim).
- Quotes the user's own words verbatim into the file — no corporate paraphrase.
- If the day went sideways (illness, crisis), keeps the remaining questions minimal and the summary soft.
- One line of closing warmth, not three paragraphs.

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_PLAN_DIR` | Where the plan file lives (read + write target) |
| `PBRAIN_JOURNAL_DIR` | Today's daily journal (cross-reference + open-questions + summary feed) |
| `PBRAIN_GRATITUDE_DIR` | Today's gratitude entry (completeness note) |
| `PBRAIN_THOUGHTS_DIR` | Today's captured thoughts (summary feed) |
| `PBRAIN_FITNESS_DIR` | Today's fitness session (cross-reference + bookkeeping update target) |
| `PBRAIN_DIET_DIR` | Today's diet log (cross-reference + bookkeeping update target) |
| `PBRAIN_HABITS_PROFILE_FILE` | Habits profile (cross-ref for the habit rollup) |
| `PBRAIN_DB_FILE` | Shared SQLite store for reminders + habit events |

**Examples:**

```bash
/end-of-day                         # close today
/end-of-day --date 2026-06-09       # close a past day
/end-of-day 2026-06-09              # same — bare date positional also accepted
```

## Migrating older `-close.md` sibling files

Older runs of this command wrote a sibling file at `$VAULT_DIR/life/daily-planning/YYYY-MM-DD-close.md`. The new behaviour is in-place inside the plan file's existing `## How it went` section. If you have legacy close files, fold their contents back into the matching plan file and delete the sibling — `/weekly-review` and downstream readers only look at the plan file going forward.
