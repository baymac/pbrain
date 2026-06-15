---
description: Close-of-day completion pass — confirms the day's tables (planning, diet, fitness, habits), asks only specific gap-filling questions, marks the scored-habit defaults, then writes a lean executive summary + carry-forward into the '## How it went' section of today's plan file in place.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/end-of-day.sh"
```

**Date:** by default the script closes **today**. If `$ARGUMENTS` asks for a different day ("previous day", "yesterday", "last Friday", or an explicit date), FIRST resolve it to a concrete `YYYY-MM-DD` relative to the current date, then pass it: append `--date YYYY-MM-DD` to the command above. Every downstream path — plan/journal/fitness/diet files, the habit rollup + consolidate + reminders-sync, AND the laptop-usage report — keys off that one date, so the laptop report is rendered for the day being closed (not today). Do not pass `--date` when closing today.

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits `END_OF_DAY_SESSION` with the target day's plan, journal, thoughts, fitness, and diet files inlined (the `date:` line names the day). Follow the INSTRUCTIONS exactly. This is a **completion pass, not a reflection journal**. Key hard rules:

- **No open-ended questions.** Lead with a one-line recap of what's already known, then ask ONLY specific gap-filling questions — one domain per message, waiting for each: (1) still-open plan tasks/blocks, (2) the fitness session + tonight-sleep (today only), (3) unlogged meals, (4) which due habits got done, (5) any unresolved journal open questions. Skip a question whose domain has no gaps.
- Fill **both** plan tables in-place with the Edit tool: `## Task log` (Done at/Status) and `## Today at a glance` (`✓ ` prefix on blocks that happened). No sibling close files.
- Propagate diet + fitness actuals silently from the answers; recompute diet totals.
- **Mark the scored-habit defaults** from the day's data as the backstop — Work the plan, Train, Eat clean, Sleep well, Deep work — then consolidate. Idempotent if a command already marked one.
- **Deep-work marking sequence** (when the tracker DB is present): extract the WORK-block windows from "## Today at a glance" → run `laptop-tracking focus-breakdown` over those windows → propose a category for any *unknown* domain/app in ONE batch, persist confirmed picks via `categorize --set` → re-run `focus-breakdown` → `habits.sh mark --name "Deep work" --focus <per-category JSON>`. `focus-breakdown` emits `FOCUS_BREAKDOWN {work,social,entertainment,neutral,afk,total_active,unknown[]}` (AFK = window − active, never penalized); the focus score + breakdown fold into the single laptop line.
- Auto-derive a **`### Carry-forward`** from not-done tasks (no question) — `/plan-my-day` reads it next day.
- Write a lean `## How it went`: **`### Executive summary`** (small wins across work/diet/fitness/relationships + logged thoughts), **`### Scoreboard`** (engine-computed scored-habit scores read back verbatim via `habits.sh scores`, plus diet macros, fitness volume, and work focus %), `### Goal progress`, `### Sleep`. No energy curve, no tomorrow-seed prompt.
- The 4h weekly-goal rollup matches work by `plane_project`, not by task text.
- On a week/month boundary, add a once pointer to `/weekly-review` or `/monthly-review` — non-blocking, don't run it.
- Reminders sync runs silently after consolidate; surface one line only if something moved.
- One closing line. No paragraphs of reflection. Do NOT call the day a "win" or a "loss" — neutral language only. No action items, accountability frameworks, or pep talks.
