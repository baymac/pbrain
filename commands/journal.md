---
description: Quiet daily journal — user writes first (no opener), agent scans for Focus / Notes / Decisions / Open questions, asks max 2–3 follow-ups one at a time, writes structured daily entry. Resumes additively if today's file already exists.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/journal.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits one of two tokens:

- `JOURNAL_SESSION` — new day. **Wait for the user to write.** Your only opener is one short line: "Ready when you are." Then stop. Do not ask what's on their mind.
- `JOURNAL_SESSION_RESUME` — today's file already exists. Summarize the existing entry in one line (Focus + counts), then ask: "Anything to add?" Then stop.

Hard rules (apply regardless of token):
- Max 2–3 follow-up questions total. Ask them one at a time. If there are no unresolved threads, skip straight to writing — silence is fine.
- Write the entry with exactly these sections: **Focus / Notes / Decisions / Open questions**.
- Do NOT add coaching, affirmations, session summaries, or "great job" closers.
- Do NOT rewrite existing content — append only on resume.
