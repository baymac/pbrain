---
description: Resident macOS usage tracker — records which app you're in and for how long, and the browser DOMAIN your time goes to, excluding locked/idle/asleep time (a playing video still counts). Renders a per-day report into the vault. Subcommands: start | stop | status | access | report.
argument-hint: start | access | status | report [<date>] | stop
---
Run this with the Bash tool (substituting the user's text for `$ARGUMENTS`), then relay the result:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/laptop-tracking.sh" "$ARGUMENTS"
```

This is a utility command — like `/remind`, it's **exempt from the morning-sequence (journal → gratitude) check**. Just run it.

The tracker is **opt-in / off by default** — `start` (alias `enable`) turns it on, `stop` (alias `disable`) turns it off. `/plan-my-day` nudges once to set it up and records a decline so it won't ask again.

The script acts directly and prints the result for every subcommand — relay it plainly, don't add analysis:

- `start` (or `enable`) — builds the Swift daemon on demand (needs `swiftc`), creates the local `tracker.db`, and installs a resident LaunchAgent that relaunches at login. After it prints, remind the user to run `/laptop-tracking access` once so browser **domains** are captured (without it, browser time still counts at the app level).
- `access` — provokes the one-time per-browser Automation grant. It prints a ✓/✗ line per running browser. If it says no browsers were running, tell the user to open the browsers they want tracked and re-run. If a browser shows ✗, they can approve the prompt or grant it in System Settings → Privacy & Security → Automation.
- `status` — whether the daemon is running + today's quick numbers.
- `report [<date>]` — renders `life/laptop-tracking/<date>.md` (default today) from the DB and prints the path. This is the on-demand finalize; `/end-of-day` also does it automatically.
- `stop` (or `disable`) — stops and uninstalls the daemon.
- `decline` — used by the `/plan-my-day` nudge: run it when the user says they don't want laptop tracking, so the nudge never fires again.
- `focus-breakdown --date D --windows "HH:MM-HH:MM,…"` / `categorize --set "key=cat,…" | --list` — internal plumbing for the **Deep work** focus score (normally called by `/end-of-day`, not by hand). `focus-breakdown` reports active minutes per category over the given work-block windows + AFK + any uncategorized keys; `categorize` edits the reusable domain/app → `work|social|entertainment|neutral` map at `life/laptop-tracking/categories.md`.

If the output contains `UPGRADE_AVAILABLE <local> <remote>`, mention a newer pbrain is out (suggest `/plugin update pbrain`, link `https://github.com/baymac/pbrain/blob/main/CHANGELOG.md`), then continue. Apply any `USER PREFERENCES` block; act on the `SELF-IMPROVE CHECK` only per its own rules.

Keep confirmations to one or two lines. The report writes domain-level data only; the granular `tracker.db` is local and never synced — reassure the user of that if they ask about privacy.
