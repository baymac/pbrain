---
description: Monthly synthesis — reads all weekly reviews from the current month, 3 reflection questions, writes to life/monthly-tracking/YYYY-MM.md. Drives monthly-goals versioning (commit closing month → mint next month's draft derived from the plans profile current_focus, priority only, one goal at a time). Optional plans-profile hygiene pass (archive completed items, update stale context).
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/monthly-review.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits `MONTHLY_REVIEW_SESSION` with all the month's weekly reviews inlined plus the CORE PROFILES (plans/work/goals-library, diet, fitness, habits — versioned). Follow the INSTRUCTIONS exactly. Key hard rules:

- **Synthesis first, then questions.** Present the 3–5 bullet read before asking anything.
- Quote the user back to themselves — their language, not yours.
- **Monthly goals one by one.** Derive each goal from the plans profile `current_focus`, confirm inclusion + milestone, no batch approvals.
- **Plans-profile hygiene.** Offer the pass once — archive completed `current_focus` items, update stale context. Never force it.
- **Improvements one by one.** Month-level patterns only — no noise. Same approve/reject flow as /weekly-review.
- Do NOT generate a generic "great month!" summary. Specifics or silence.

## Morning sequence check (do this first)

Use today's date in `YYYY-MM-DD` format. Same check as other planning commands:
1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → suggest `/journal` first.
2. If gratitude journal missing → suggest `/gratitude-journal`.

Suggest once. If user says skip/continue, proceed.
