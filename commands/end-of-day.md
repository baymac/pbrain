---
description: Close-of-day reflection — fills the '## How it went' section of today's plan file in place, then propagates actuals to diet and fitness files. Asks what got done, what dropped, energy curve, tomorrow seed — one question at a time.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/end-of-day.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits `END_OF_DAY_SESSION` with today's plan, journal, fitness, and diet files inlined. Follow the INSTRUCTIONS exactly. Key hard rules:

- Ask the four questions **one at a time**. Wait for each answer before asking the next.
- Fill the plan file **in-place** using the Edit tool. No sibling close files.
- Propagate actuals to the diet and fitness files **silently** as bookkeeping — surface a one-line summary per file touched at the end, not mid-session.
- One closing line. No paragraphs of reflection. The user already reflected — your job is to record.
- Do NOT call the day a "win" or a "loss." Neutral language only.
- Do NOT prescribe action items, accountability frameworks, or pep talks.
