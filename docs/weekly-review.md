# /weekly-review

Weekly review — pulls the last 7 days of journal, gratitude, plan, close-of-day, fitness, and diet entries; the agent reads everything, presents a tight synthesis (3-5 bullets, quoting you), then walks three questions: what this week wanted to teach you, what to drop next week, what to double down on.

A weekly cadence is the missing layer between daily journaling (too noisy) and quarterly review (too slow). Patterns surface inside a week that you can't see inside a day.

**Default destination:** `$VAULT_DIR/life/weekly-tracking/YYYY-Www.md` — one file per ISO week (e.g. `2026-W22.md`).

**Behavior:**

- Always covers today and the 6 days back, regardless of day of week. Run it whenever feels natural — Sunday evening, Monday morning, mid-week if you want a check-in.
- If a day has zero entries, it's noted briefly and the review moves on. No moralizing about missed days.
- If this week's review already exists, the existing file is shown and the command exits without overwriting.

**Tone rules baked into the prompt:**

- Specifics or silence. No generic "great week!" summaries.
- Quotes you back to yourself in the synthesis — your language, not the agent's.
- No productivity-system prescriptions. The user is reviewing their own life, not buying a course.

**Plan enrichment (Step 4):**

After the synthesis and the three questions, the review proposes concrete, evidence-tied updates to your core plans — "you skipped legs twice", "protein landed under target 5/7 days", "the focus you set wasn't mentioned in any plan". It proposes nothing when the week gives no clear signal; it won't invent changes.

All three core plans — `Goals Profile.md`, `Diet Plan.md`, and the fitness plans — are user-owned vault files and are treated the same way: each proposed change is written into a `## Proposed plan changes` section of the review, and the actual plan file is edited **only** if you say yes to that specific change in-session. Propose-in-review is the default; nothing is auto-written. The decisions you make are recorded in that section. (When the goals profile is edited, its fenced JSON block is kept valid.)

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_WEEKLY_DIR` | Where the weekly review writes |
| `PBRAIN_JOURNAL_DIR` | Daily journals (read) |
| `PBRAIN_GRATITUDE_DIR` | Gratitude entries (read) |
| `PBRAIN_PLAN_DIR` | Daily plans, including the in-place end-of-day close (read) |
| `PBRAIN_FITNESS_DIR` | Fitness sessions (read) |
| `PBRAIN_DIET_DIR` | Diet logs (read) |
| `PBRAIN_PLAN_PROFILE_FILE` | Goals profile for enrichment (vault-owned; proposed). Default `$VAULT/life/Goals Profile.md` |
| `PBRAIN_DIET_PLAN_FILE` | Diet plan for enrichment (vault-owned; proposed). Default `$VAULT/fitness/Diet Plan.md` |
| `PBRAIN_FITNESS_PLANS_DIR` | Per-activity fitness plans for enrichment (vault-owned; proposed). Default `$VAULT/fitness/plans` |
| `PBRAIN_GYM_PLAN_FILE` | Primary gym plan for enrichment (vault-owned; proposed) |

**Example:**

```bash
/weekly-review
```

Pairs well with `/recall` — once a pattern surfaces in a weekly review, run `/recall <theme>` to see how far back it actually goes.
