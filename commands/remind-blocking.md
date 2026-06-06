---
description: Full-screen blocking reminders — a hard-to-dismiss "Take a break" overlay across every display (hold Control to skip, or wait out a countdown). Same scheduling as /remind; use it for hard stops, stretch breaks, and screen-time limits.
argument-hint: <reminder, e.g. "take a break every day at 3pm for 5 min"> | test | list | done <id>
---
Run this with the Bash tool first (substituting the user's text for `$ARGUMENTS`), then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/remind-blocking.sh" "$ARGUMENTS"
```

For management subcommands (`test`, `list`, `done <id>`, `cancel <id>`, `install`, `uninstall`) the script acts directly and prints the result — just relay it.

Otherwise the script prints a `REMIND_BLOCKING_ENTRY` block. Follow its INSTRUCTIONS: a blocking reminder fires as a **full-screen overlay** the user must hold the Control key to dismiss (or wait out a countdown), so reach for it only for genuine hard stops — routine pings stay on plain `/remind`. Blocking overlays fire **only via the background poller** (near their due time), never opportunistically, so the first `add` auto-installs that poller. Parse any natural-language time **relative to the `now` value in the block**, parse a "for N minutes" duration into `--duration <seconds>` (omit it to keep the overlay up until the user skips it), and call the right subcommand. Keep the on-screen `--text` short — it's shown huge. One-line confirmations.
