---
description: Weekly synthesis — tight 3–5 bullet read of the last 7 days, 3 reflection questions, writes to life/weekly-tracking/YYYY-Www.md. Proposes plan updates to goals profile, diet plan, and fitness plans; only edits a plan file on explicit per-change yes.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/weekly-review.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits `WEEKLY_REVIEW_SESSION` with all 7 days of context inlined. Follow the INSTRUCTIONS exactly. Key hard rules:

- **Synthesis first, then questions.** Present the 3–5 bullet read before asking anything.
- Quote the user back to themselves — their language, not yours.
- If a day has zero entries, note it once ("you were dark Thursday") and move on. Don't moralize.
- Propose plan changes **into the review file**. Only edit an actual plan file if the user explicitly says yes to that specific change this session.
- Do NOT generate a generic "great week!" summary. Specifics or silence.
- Do NOT prescribe productivity systems or self-improvement frameworks.
