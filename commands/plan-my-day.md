---
description: Adaptive daily planner anchored on your plans. First run builds a versioned plans profile (current_focus list with deadline + context per item, working style, planning guidelines, a generous workday + rest-day typical-day template + variation rules, anti-patterns). Daily runs plan against that profile — or against this week's weekly goals if /weekly-review is set up. Includes a per-day task log table (/end-of-day fills Done at/Status). Mid-day, `task add`/`task remove`/`task list` revises an existing day's tasks and re-flows the schedule. `focus` subcommand manages the current_focus list; `library` subcommand shows/edits the work and goals reference cards. Supports profile new/commit for plans-profile, work-library, goals-library, monthly-goals, and weekly-goals.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/plan-my-day.sh"
```

**Run bash immediately.** The script injects today's plans profile (with `current_focus` list), work/goals libraries, fitness sleep data, diet meal times, and today's scheduled session as context. Follow the INSTRUCTIONS in its output. If the user passed arguments (e.g. `profile show`, `profile new work-library`, `profile commit`, `task add` / `task remove` / `task list`, `focus list` / `focus add` / `focus archive`, or `library work show`), append them to the command. The fitness session is the one hard anchor — always place it in the plan. Don't plan beyond today.

**Mid-day task edits.** When the user wants to revise *today's already-written plan* — "add a task to ship the diet refactor", "drop the email cleanup", "what's on my list?" — map it to `plan-my-day.sh task add` / `task remove` / `task list` (do NOT rebuild the day). The script emits a `PLAN_MY_DAY_TASK` block with today's plan + goals context, or `PLAN_MY_DAY_TASK_NO_PLAN` if today hasn't been planned yet (tell the user to run `/plan-my-day` first). On add/remove, follow its INSTRUCTIONS: edit the task-log row AND re-flow "Today at a glance" around the fixed anchors, then rewrite both tables together.

Key hard rules:
- Rebuild (`PLAN_MY_DAY_REBUILD`): build the plans profile part by part with the user — confirm/update/drop each current_focus item, ask working-style questions, set planning_guidelines. Never import silently. The plans profile IS the focus: `current_focus` is the heart; the libraries are stable reference cards.
- Wake time comes from today's fitness entry when recorded — confirm it in passing instead of re-asking.
- Backfill the morning yourself from what the user says — gap-free, no overlaps; they correct, you place.
- Show the computed block layout (blocks + breaks around the anchors) before asking what goes in the blocks.
- Today's calendar events + anything the user flags as non-negotiable come FIRST — they're the day's fixed points and drive preponing/postponing the routine (workout, work, meals shift around them).
- When the plans profile carries a `typical_day` template, lay its workday/rest-day skeleton as today's baseline and apply `variation_rules`: keep the meal COUNT, protect meals + fitness, shrink WORK to absorb pressure (work is the flex variable), keep ≥30 min between wake and the first work block, ask non-gym fitness duration including buffer and shift meals to fit — and only *suggest* (never silently drop) skipping fitness when meals run late AND the last few days were already active.
- Committed profiles are final — changes go through `profile new` → edit draft → `profile commit`. The work/goals libraries are living documents (enrich in place). For weekly-goals and monthly-goals, use `profile new weekly-goals` / `profile new monthly-goals`.
- **Never auto-commit a draft.** After applying any change to a draft, show the user what changed and ask: "Want to lock this in?" (or similar). Only run `profile commit` when the user explicitly says yes / "lock" / "commit" / "save it". If they ask for more edits, keep modifying the same open draft — do NOT mint a new version.
- The daily task-log table (in Step 3) is one row per task from 2d. /end-of-day fills Done at / Status at close. Mid-day, `task add`/`task remove` revise this table and re-flow "Today at a glance" together — `task remove` confirms first if the row is already closed (Status filled), so end-of-day's rollup isn't lost.
- **AUTO-LIBRARY**: when the user mentions a project or goal not in any library card, offer to register a shortcut card (name + shortcut + context) so future sessions can reference it by name.

## Morning sequence check (do this first)

Planning the day works best on top of the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Surfaces what's on your mind before we plan." Pause.
2. Else if `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first? It anchors the day before planning." Pause.

Suggest once. If user says continue / skip / no, proceed. **If the injected USER PREFERENCES block (global or per-command) says to skip the journal/gratitude nudge, skip steps 1–2 entirely** — a standing preference always overrides a built-in nudge. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
