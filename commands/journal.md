---
description: Quiet daily journal — morning brain dump (Focus / Notes / Decisions / Open questions) on first run; timestamped activity log entries on subsequent runs throughout the day. Run any time to capture what happened and why.
---
Run this with the Bash tool first, passing along whatever the user typed after the command (their dump), then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/journal.sh" "$ARGUMENTS"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits one of two tokens, each carrying a `dump_provided: yes|no` line (and the `provided_dump` block when yes — the text the user typed after the command):

- `JOURNAL_SESSION` — new day. If `dump_provided: yes`, the user already wrote their dump as the argument — **ingest it and proceed, do not say "Ready when you are." or wait.** If `dump_provided: no`, your only opener is one short line: "Ready when you are." Then stop and wait. Either way, do not ask what's on their mind.
- `JOURNAL_SESSION_RESUME` — today's file already exists. The user is logging an intraday entry. If `dump_provided: yes`, ingest the argument as the entry — don't say "Go ahead." or wait. If `dump_provided: no`, say one short line ("Go ahead.") and wait. After you have the entry, ask ONE follow-up only if it is reflective (mistake, decision, something emotionally loaded) — pull the question from their words. Then append a timestamped `### HH:MM` entry under a `## Log` section (create the section if it doesn't exist yet).

Hard rules (apply regardless of token):
- Morning session: max 2–3 follow-up questions, one at a time. Write exactly these sections: **Focus / Notes / Decisions / Open questions**.
- Resume sessions: ONE follow-up at most. Append ONLY to `## Log` — never touch the morning sections.
- Do NOT add coaching, affirmations, session summaries, or "great job" closers.
- Do NOT rewrite existing content — append only on resume.
