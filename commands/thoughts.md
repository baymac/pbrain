---
description: Capture and expand a passing thought — surface what's underneath, then log the expanded entry with a timestamp. On-demand, any time of day. Optional; some days have no thoughts.
argument-hint: <thought>
---
Run this with the Bash tool first (substituting the user's thought for `$ARGUMENTS`):

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/thoughts.sh" "$ARGUMENTS"
```

**THOUGHT_PROMPT** (no thought provided) — ask "What's on your mind?" in one line. Wait. Whatever they share → re-run the script with that text, then continue as THOUGHT_ENTRY.

**THOUGHT_ENTRY** — explode the raw thought:
- In 2–5 lines, surface what's interesting: the pattern underneath, what it implies, a consequence or question worth sitting with.
- Stay sharp. No hedging. Use the user's voice — flat, telegraphic, `→` for consequences and connections.
- Don't pad. If the thought is simple, 2 lines is enough.

Then append this block to `output_file` using the Edit or Bash tool:

```
---

**{time}** — {raw thought}
{expanded lines, each starting with →}
```

Confirm in one line: `Logged.` Done.
