---
description: Grep-based recall across the vault. Surfaces past notes mentioning a topic, then synthesizes what you've written over time. A simpler, faster replacement for gbrain search.
argument-hint: <topic or phrase>
---
Run this with the Bash tool first (substituting the user's query for `$ARGUMENTS`):

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/commands/recall.sh" "$ARGUMENTS"
```

## How to handle the matches

The script ran a case-insensitive grep across the user's vault narrative folders (`life/`, `agent-work/`, `startup/`, `side-quests/`, `software-dev/`, `notes/`). It deliberately skips `Clippings/` (third-party) and `fitness/daily-tracking/` (numeric logs).

**Your job:**
1. Read every match the script printed.
2. Group by source: gratitude entries vs. daily journals vs. brainstorms vs. drafts.
3. Synthesize what the user has actually written about this topic over time. Quote them where possible — their words, not yours.
4. Surface: recurring themes, how their thinking has shifted, open threads they haven't closed, decisions they made and then walked back.
5. Land on a one-line takeaway.

**Hard rules:**
- Do NOT solve, plan, or advise. This is recall, not coaching.
- Cite by relative file path (e.g. `life/daily-tracking/2026-04-12.md`) so the user can jump to the source.
- If matches are sparse (1-2 hits), say so directly. Don't pad.
- If zero matches: tell the user, suggest 2-3 spelling variants or adjacent terms they could try, then stop. Don't make things up.
- If the query is a single common word ("work", "today", "feeling"), warn the user it'll be noisy and suggest a more specific phrase.

This is meant to replace what gbrain would do — grep is dumb but fast, and most recall is "where did I write about X."
