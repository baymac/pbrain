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

**Work review:**

The review adds a **`## Work review`** section — a per-project read of the week's work built from the week's `## Work tracker` rows plus the Plane project progress (`/project-manager progress`). Per project in play: planned vs done, Plane pct + delta, allocation % vs where the time actually went (an estimate-calibration signal), and pile-up flags. When it mints **next week's goals**, they're now **project-level** — each goal carries an `allocation_percent` (balanced to sum to 100 across active goals) and, when Plane is configured, a `plane_project` picked from the project registry. (Without Plane the section degrades gracefully — it reads "No project work tracked," and goals are minted as a focus-area + `allocation_percent` only, with no `plane_project` link.)

**Improvements (Step 4):**

After the synthesis and the three questions, the review builds a **per-command improvement list** from the week's evidence — one list each for `/plan-my-day` (plans profile + work/goals libraries), `/diet-journal` (diet profile), `/fitness-journal` (fitness profile, library, activity profiles), and `/habits` (the habit set). Each improvement is one evidence-tied line — "you skipped legs twice", "protein landed under target 5/7 days", "the Lettuce goal wasn't touched in any plan". It proposes nothing when the week gives no clear signal.

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
| `PBRAIN_PLAN_PROFILE_FILE` | Explicit plans-profile file, bypassing the store |

**Example:**

```bash
/weekly-review
```

**Clippings walk (Step 6):**

If `$VAULT_DIR/Clippings/` contains `.md` files, the session ends with a guided filing walk — shown as Step 6. For each clipping you see a frontmatter + body preview, pick (or confirm) a destination folder inside the vault, and the file is moved and optionally renamed. Path containment is enforced — moves outside `VAULT_DIR` are blocked. To skip the selection prompt, set `PBRAIN_CLIPPINGS_TARGETS` to a comma-separated list of top-level vault dirs (or `all`).

Pairs well with `/recall` — once a pattern surfaces in a weekly review, run `/recall <theme>` to see how far back it actually goes.
