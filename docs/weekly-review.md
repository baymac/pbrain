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

**Improvements (Step 4):**

After the synthesis and the three questions, the review builds a **per-command improvement list** from the week's evidence — one list each for `/plan-my-day` (goals profile + work/goals libraries), `/diet-journal` (diet profile), `/fitness-journal` (fitness profile, library, activity profiles), and `/habits` (the habit set). Each improvement is one evidence-tied line — "you skipped legs twice", "protein landed under target 5/7 days", "the Lettuce goal wasn't touched in any plan". It proposes nothing when the week gives no clear signal.

You then walk the list **one item at a time** — approve or reject each, no batch approvals. For every profile with at least one approved improvement, a **new version is minted** through the owning command's `profile` subcommand (`profile new` → the approved edits land in the draft → `profile commit`); the old version stays on disk as history. Libraries (work, goals, food, fitness) are living documents — approved library edits apply in place with no version mint. Everything proposed, decided, and committed (with the new version path) is recorded in the review's `## Improvements` section.

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_WEEKLY_DIR` | Where the weekly review writes |
| `PBRAIN_JOURNAL_DIR` | Daily journals (read) |
| `PBRAIN_GRATITUDE_DIR` | Gratitude entries (read) |
| `PBRAIN_PLAN_DIR` | Daily plans + the plan profile store inside it (read) |
| `PBRAIN_FITNESS_DIR` | Fitness sessions + the fitness profile store (read) |
| `PBRAIN_DIET_DIR` | Diet logs + the diet profile store (read) |
| `PBRAIN_PLAN_PROFILE_FILE` | Explicit goals-profile file, bypassing the store |

**Example:**

```bash
/weekly-review
```

Pairs well with `/recall` — once a pattern surfaces in a weekly review, run `/recall <theme>` to see how far back it actually goes.
