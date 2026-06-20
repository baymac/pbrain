---
description: Daily gratitude journal — asks what the user is grateful for (3–6 things), then poses one reflection question grounded in what surfaced today (the gratitude answer + today's journal entry), falling back to a rotated theme when the day is too thin. Writes a structured two-section entry to life/gratitude-journal/<date>.md.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/gratitude-journal.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits `GRATITUDE_JOURNAL_SESSION`. Follow its INSTRUCTIONS exactly. Key hard rules:
- Show the timing nudge verbatim, then move on — don't wait for a response.
- Ask the gratitude question first, then the reflection question. Two questions total, never more.
- Generate a fresh reflection question grounded in today's material — the gratitude answer just given plus the `TODAY_JOURNAL_CONTEXT` block. Only fall back to the theme/opening rotation when that material is too thin (terse gratitude list AND no journal today). Always honor the constraints, and never reuse a past question from the `PAST_REFLECTION_QUESTIONS` list.
- Write exactly two sections: the gratitude list and the reflection Q&A. No summaries, no affirmations after writing.
