---
description: Adaptive daily planner anchored on your goals. First run builds a versioned goals profile (work goals + life goals, working style, anti-patterns). Daily runs plan against that profile — or against this week's weekly goals if /weekly-review is set up. Includes a per-day task log table (/end-of-day fills Done at/Status). Mid-day, `task add`/`task remove`/`task list` revises an existing day's tasks and re-flows the schedule. Supports profile new/commit for goals-profile, work-library, goals-library, monthly-goals, and weekly-goals.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/plan-my-day.sh"
```

**Run bash immediately.** The script injects today's goals profile, work/goals libraries, fitness sleep data, diet meal times, and today's scheduled session as context. Follow the INSTRUCTIONS in its output. If the user passed arguments (e.g. `profile show`, `profile new work-library`, `profile commit`, or `task add` / `task remove` / `task list`), append them to the command. The fitness session is the one hard anchor — always place it in the plan. Don't plan beyond today.

**Mid-day task edits.** When the user wants to revise *today's already-written plan* — "add a task to ship the diet refactor", "drop the email cleanup", "what's on my list?" — map it to `plan-my-day.sh task add` / `task remove` / `task list` (do NOT rebuild the day). The script emits a `PLAN_MY_DAY_TASK` block with today's plan + goals context, or `PLAN_MY_DAY_TASK_NO_PLAN` if today hasn't been planned yet (tell the user to run `/plan-my-day` first). On add/remove, follow its INSTRUCTIONS: edit the task-log row AND re-flow "Today at a glance" around the fixed anchors, then rewrite both tables together.

Key hard rules:
- Migration (`PLAN_MY_DAY_MIGRATION`): rebuild the old goals profile part by part with the user — confirm/update/drop each goal, classify work vs life, ask the new working-style questions. Never import silently. The old current-focus concept is gone — the goals profile is the focus.
- Wake time comes from today's fitness entry when recorded — confirm it in passing instead of re-asking.
- Backfill the morning yourself from what the user says — gap-free, no overlaps; they correct, you place.
- Show the computed block layout (blocks + breaks around the anchors) before asking what goes in the blocks.
- Committed profiles are final — changes go through `profile new` → edit draft → `profile commit`. The work/goals libraries are living documents (enrich in place). For weekly-goals and monthly-goals, use `profile new weekly-goals` / `profile new monthly-goals`.
- The daily task-log table (in Step 3) is one row per task from 2d. /end-of-day fills Done at / Status at close. Mid-day, `task add`/`task remove` revise this table and re-flow "Today at a glance" together — `task remove` confirms first if the row is already closed (Status filled), so end-of-day's rollup isn't lost.

## Morning sequence check (do this first)

Planning the day works best on top of the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Surfaces what's on your mind before we plan." Pause.
2. Else if `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first? It anchors the day before planning." Pause.

Suggest once. If user says continue / skip / no, proceed. **If the injected USER PREFERENCES block (global or per-command) says to skip the journal/gratitude nudge, skip steps 1–2 entirely** — a standing preference always overrides a built-in nudge. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
