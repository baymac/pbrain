---
description: Lightweight reminders that fire as macOS notifications. Set them in plain language; they ride along with /plan-my-day and /end-of-day, and can fire in the background via an optional launchd poller.
argument-hint: <reminder, e.g. "call dentist tomorrow 3pm"> | list | done <id>
---
Run this with the Bash tool first (substituting the user's text for `$ARGUMENTS`), then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/remind.sh" "$ARGUMENTS"
```

For management subcommands (`list`, `done <id>`, `cancel <id>`) the script acts directly and prints the result — just relay it.

Otherwise the script prints a `REMIND_ENTRY` block. Follow its INSTRUCTIONS: figure out whether the user is creating, listing, or completing a reminder, parse any natural-language time **relative to the `now` value in the block**, then call the right subcommand (`add --text ... --due ...`, `list`, or `done <id>`). Don't invent a due time when the user was specific; ask one quick question only if the time is genuinely ambiguous. Keep confirmations to one line.
