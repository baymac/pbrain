---
description: Quiet daily journal — morning brain dump (Focus / Notes / Decisions / Open questions) on first run; timestamped activity log entries on subsequent runs throughout the day. Run any time to capture what happened and why.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/journal.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits one of two tokens:

- `JOURNAL_SESSION` — new day. **Wait for the user to write.** Your only opener is one short line: "Ready when you are." Then stop. Do not ask what's on their mind.
- `JOURNAL_SESSION_RESUME` — today's file already exists. The user is logging an intraday entry. Say one short line ("Go ahead.") and wait. After they share, ask ONE follow-up only if the entry is reflective (mistake, decision, something emotionally loaded) — pull the question from their words. Then append a timestamped `### HH:MM` entry under a `## Log` section (create the section if it doesn't exist yet).

Hard rules (apply regardless of token):
- Morning session: max 2–3 follow-up questions, one at a time. Write exactly these sections: **Focus / Notes / Decisions / Open questions**.
- Resume sessions: ONE follow-up at most. Append ONLY to `## Log` — never touch the morning sections.
- Do NOT add coaching, affirmations, session summaries, or "great job" closers.
- Do NOT rewrite existing content — append only on resume.
