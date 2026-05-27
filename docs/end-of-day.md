# /end-of-day

Close-of-day reflection — bookend to `/plan-my-day`. Reads today's plan, daily journal, fitness session, and diet log, then walks four questions: what got done, what got dropped, what surprised, what to carry into tomorrow. Writes the answers to a sibling close-of-day note next to the plan.

The plan-close loop is where most planning systems get sticky. Opening the day without closing it leaves the plan unverified — you keep planning into a void. Closing reconnects the loop and gives `/weekly-review` something to read.

**Default destination:** `$VAULT_DIR/life/daily-planning/YYYY-MM-DD-close.md` (sibling of the plan file).

**Tone rules baked into the prompt:**

- Warm but tight — the user already reflected, the agent's job is to record, not pile on.
- Neutral language only — no "wins" or "losses."
- Quotes the user's own words verbatim into the file — no corporate paraphrase.
- If the day went sideways (illness, crisis), skips the "what got dropped" question and softens the surprises question.
- One line of closing warmth, not three paragraphs.

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_PLAN_DIR` | Where close-of-day notes land (same dir as `/plan-my-day`) |
| `PBRAIN_JOURNAL_DIR` | Today's daily journal (cross-reference) |
| `PBRAIN_FITNESS_DIR` | Today's fitness session (cross-reference) |
| `PBRAIN_DIET_DIR` | Today's diet log (cross-reference) |

**Example:**

```bash
/end-of-day
```

If today's close-of-day note already exists, it's shown and the command exits without re-prompting.

If today's plan file doesn't exist, the agent does a free-form close instead of anchoring to a plan.
