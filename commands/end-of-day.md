---
description: Close-of-day reflection — fills the '## How it went' section of today's plan file in place, then propagates actuals to diet and fitness files. Asks what got done, what dropped, energy curve, tomorrow seed — one question at a time.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/end-of-day.sh"
```

**Date:** by default the script closes **today**. If `$ARGUMENTS` asks for a different day ("previous day", "yesterday", "last Friday", or an explicit date), FIRST resolve it to a concrete `YYYY-MM-DD` relative to the current date, then pass it: append `--date YYYY-MM-DD` to the command above. Every downstream path — plan/journal/fitness/diet files, the habit rollup + consolidate + reminders-sync, AND the laptop-usage report — keys off that one date, so the laptop report is rendered for the day being closed (not today). Do not pass `--date` when closing today.

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits `END_OF_DAY_SESSION` with the target day's plan, journal, fitness, and diet files inlined (the `date:` line names the day). Follow the INSTRUCTIONS exactly. Key hard rules:

- Ask the four questions **one at a time**. Wait for each answer before asking the next.
- Fill the plan file **in-place** using the Edit tool. No sibling close files.
- Ask about unlogged meals (dinner, snacks) as Q5 before closing the diet file. Propagate fitness actuals silently.
- Ask explicitly which habits the user did today as Q6 (one question listing all due habits). Do NOT auto-infer habits from conversation evidence.
- Reminders sync runs silently after consolidate; surface one line only if something moved.
- One closing line. No paragraphs of reflection. The user already reflected — your job is to record.
- Do NOT call the day a "win" or a "loss." Neutral language only.
- Do NOT prescribe action items, accountability frameworks, or pep talks.
