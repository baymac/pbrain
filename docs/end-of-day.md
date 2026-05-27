# /end-of-day

Close-of-day reflection — bookend to `/plan-my-day`. Reads today's plan, daily journal, fitness session, and diet log, then walks four questions: what got done, what got dropped, energy curve, what to carry into tomorrow. Writes the answers **into the existing "How it went" section of today's plan file** — no sibling close files.

The plan-close loop is where most planning systems get sticky. Opening the day without closing it leaves the plan unverified — you keep planning into a void. Closing reconnects the loop and gives `/weekly-review` something to read.

**Write target:** the existing `## How it went` section of `$VAULT_DIR/life/daily-planning/YYYY-MM-DD.md` (the file `/plan-my-day` already created). One file per day, not two.

**Behaviour:**

- If today's plan file exists → fills the `## How it went` section in place with: what you actually did, wins, what slipped, goal progress (vs `focus_today`), energy curve, tomorrow seed.
- If today's plan file doesn't exist → creates a free-form close at that path instead of anchoring to a plan.
- If `## How it went` already has user-filled content → asks whether to overwrite, append, or skip before touching it (idempotency guardrail).
- When the user describes what they actually ate or trained, applies obvious bookkeeping updates to the diet log (marks meals `eaten`, recomputes totals) and the fitness file (flips status to `completed`). Bookkeeping only — no analysis sneak-in.

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

**Example:**

```bash
/end-of-day
```

## Migrating older `-close.md` sibling files

Older runs of this command wrote a sibling file at `$VAULT_DIR/life/daily-planning/YYYY-MM-DD-close.md`. The new behaviour is in-place inside the plan file's existing `## How it went` section. If you have legacy close files, fold their contents back into the matching plan file and delete the sibling — `/weekly-review` and downstream readers only look at the plan file going forward.
