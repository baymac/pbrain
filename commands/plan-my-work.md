---
description: Fill the day's work blocks with real tasks pulled from Plane. Runs AFTER /plan-my-day (which lays out the life anchors + empty work blocks and no longer assigns tasks). /plan-my-work shows a progress report keyed off this week's project-level goals (each with an allocation %), lets you pick today's projects, renormalizes their allocation across the day's blocks, pulls ready tasks from Plane (via /project-manager), packs them biggest-rock-first, and writes a rich "## Work tracker" into the same daily file. Mid-day, `task add|remove|list` revises it. /end-of-day reconciles the tracker back to Plane.
argument-hint: (none) | task add | task remove | task list
---
Run this with your shell first (substituting any argument for `$ARGUMENTS`), then follow the INSTRUCTIONS in the token it prints:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/plan-my-work.sh" "$ARGUMENTS"
```

This is the **work layer** of the daily loop. `/plan-my-day` builds the day's *shape* — life anchors (calendar, fitness, meals, walk, bed, habit reminders) and empty work **blocks**. `/plan-my-work` then **fills those blocks with real tasks pulled from Plane**, the project brain (one pbrain project = one Plane PROJECT; see `/project-manager`). Weekly/monthly goals are now a CEO overview — which projects are in play, at what priority, and at what **% allocation** (summing to 100) — not task text. The tasks live in Plane.

The script prints one of:

- `PLAN_MY_WORK_SESSION` — the main flow. The data block is lean: the plans profile's **working_style + day shape only** (current_focus/anti-patterns belong to `/plan-my-day`), this week's project goals (`allocation_percent`/`plane_project`), the registry, a `progress_json`, this week's `## Work tracker` rows for carry-forward, and — when `plan_exists: yes` — today's plan. The instructions live in `commands/templates/plan-my-work/session.txt` (the `.sh` is a thin dispatcher). Steps: **(1)** preflight/standalone, **(2)** READY-CHECK — **delegate grooming to `/project-manager`** (`PBRAIN_PM_CALLER=plan-my-work bash <pm> review --projects …`); PM owns the enrichment/triage, you don't do it inline, **(3)** progress report (per-goal alloc% · Plane pct · tasks done · flags; **% of week's importance met = Σ(alloc%·pct)/Σ(alloc%)**; plus a one-line monthly read), **(4)** pick projects → allocate via the `alloc` helper (deterministic, leftover to highest priority), **(5)** pull ready tasks and pack biggest-rock-first (prefer one project per block; honor `last_block_end`), **(6)** write `## Work tracker` + relabel the glance work-block rows, **(7)** confirm tightly. **Standalone** (`plan_exists: no`): don't build a whole-day timeline — ask focus hours, compute blocks now → bed with the `blocks` helper, write a minimal file.
- `PLAN_MY_WORK_NO_PROFILE` — there's no committed plans profile yet, so there's no working style to lay blocks against. Tell the user to run `/plan-my-day` first (it builds the profile + the day's shape), then come back. Don't proceed.
- `PLAN_MY_WORK_TASK` — `task add|remove|list` on a day that's already planned. Revise the **`## Work tracker`** (rows pulled from Plane, with the full tie in the `Plane id` column) and re-flow the `## Today at a glance` work blocks — both tables rewritten together, the life anchors untouched. Follow the per-action INSTRUCTIONS. For a brand-new task, offer to create it in Plane (via `/project-manager`) before pulling it.
- `PLAN_MY_WORK_TASK_NO_PLAN` — `task …` but today isn't planned yet. Point the user at `/plan-my-day` then `/plan-my-work`; the task verb only revises an existing day. One line, stop.

The **`## Work tracker`** schema (the day's idempotency ledger — `/end-of-day` reconciles it back to Plane by the `Plane id` tie):

```
| Block | Task | Project | Plane id | Priority | Est | Status | Done at | % complete | Est rating | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| Block 1 (10:00–11:30) | ship allocation refactor | Lettuce | <pid>:<iid> | high | 2h | planned | | | | |
```

`Est rating` is a later judgment of whether the estimate held (an estimate-calibration signal). The "Work the plan" and "Deep work" habits score against this table at `/end-of-day` — same as before, new source. Keep reads tight and let the user drive which projects get today.
