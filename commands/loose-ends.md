---
description: Surfaces unresolved threads across the vault — stale brainstorms, unanswered open questions, open todos, recurring tomorrow-seeds, and focus areas that have gone quiet. Read-only dashboard; writes nothing.
---
Run this with the Bash tool first:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/loose-ends.sh"
```

## How to handle the scan

The script swept the vault for five kinds of open loop and printed a labeled block. Each section is already sorted oldest-first. The script **wrote nothing** — this is a surfacing pass, not a write.

The five signal sections:
1. **STALE IDEAS** — brainstorms in `tbd/` older than the stale threshold (default 7d).
2. **UNANSWERED QUESTIONS** — `## Open questions` from journals with an empty/`—` answer, plus open-question bullets sitting in `tbd/` brainstorms.
3. **OPEN TODOS** — unchecked `- [ ]` boxes in recent daily plans.
4. **RECURRING TOMORROW-SEEDS** — `### Tomorrow seed` bullets that repeated across plans (something that keeps getting deferred).
5. **FOCUS DRIFT** — `current_focus` items from the plans profile that haven't shown up in recent plans.

**Your job:**
1. Read every populated section.
2. Synthesize a tight report grouped by the five signal types, oldest-first within each. Quote the user's own words. Cite the relative file path after each item so they can jump to the source.
3. For any section the script marked `(none)`, say so in one line and move on — don't pad.
4. Land on a single line: **"What I'd pick up first:"** — your one best suggestion for the most actionable or most-overdue loop, with a reason.

**Optionally offer to act, but never auto-write:**
- You *may* offer to move a stale idea to `backlog/`, kick off a `/brainstorm`, or draft an answer to an open question — but only as an offer. Wait for an explicit yes before doing anything that writes.

**Hard rules:**
- This is surfacing, not coaching. Don't prescribe productivity systems or moralize about the backlog.
- Don't invent loops. If the scan came back mostly empty, say the vault is clean and stop.
- Never write or modify files as part of `/loose-ends` itself. Acting on a loop is a separate, explicitly-confirmed step.
