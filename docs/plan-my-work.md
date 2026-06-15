# /plan-my-work

The **work layer** of the daily loop. [`/plan-my-day`](plan-my-day.md) lays out the day's *shape* — life anchors (calendar, fitness, meals, walk, bed, habit reminders) and **empty work blocks**. `/plan-my-work` then **fills those blocks with real tasks pulled from Plane** (via [`/project-manager`](project-manager.md)) and writes a rich `## Work tracker` into the same daily file.

Weekly/monthly goals are now a **CEO overview** — which Plane PROJECTS are in play, at what priority, and at what **% allocation** (summing to 100) — not task text. The tasks live in Plane.

## The flow

1. **Preflight / standalone.** If `/plan-my-day` already ran today, it reads the empty work-block rows. Run alone (no plan yet) → it asks your focus hours and computes the block count from now → bed (no whole-day timeline).
2. **Review first.** Runs `/project-manager review` over this week's goal projects and walks thin issues (per-item confirm), so the tasks it pulls are well-formed.
3. **Progress report.** Per weekly goal: name · alloc% · Plane pct · tasks done this week · flags. **% of the week's importance met = Σ(alloc%·pct) / Σ(alloc%)**. Flags: **pile-up** (last week's partial/open rows still open) and **re-evaluate** (high alloc%, low pct, no activity). Plus a one-line monthly read.
4. **Pick projects → daily allocation.** You name today's subset; it **renormalizes** their allocation across the day's blocks (`daily_alloc_g = alloc%_g / Σ(chosen alloc%) × 100`) and distributes the blocks deterministically (leftover → highest-priority chosen project).
5. **Pull tasks + assign.** Pulls ready tasks for the chosen projects, prefers one project per block, biggest-rock first (priority → est), honoring `last_block_end`.
6. **Write `## Work tracker`** and relabel the `## Today at a glance` work-block rows.

## The `## Work tracker`

```
| Block | Task | Project | Plane id | Priority | Est | Status | Done at | % complete | Est rating | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| Block 1 (10:00–11:30) | ship allocation refactor | Lettuce | <pid>:<iid> | high | 2h | planned | | | | |
```

The `Plane id` column carries the full **tie** (`<project_id>:<issue_id>`) — the day's idempotency ledger that `/end-of-day` reconciles back to Plane. `Est rating` is a later judgment of whether the estimate held (an estimate-calibration signal). The "Work the plan" and "Deep work" habits score against this table at `/end-of-day`.

## Mid-day edits

`/plan-my-work task add|remove|list` revises an already-planned day — it rewrites the `## Work tracker` rows and re-flows the `## Today at a glance` work blocks together, never touching the life anchors. (This moved here from `/plan-my-day`.) For a brand-new task it offers to create it in Plane first.

## Standalone vs in-loop

Run `/plan-my-day` then `/plan-my-work` for the full day. Run `/plan-my-work` alone for a quick "what should I work on for the next few hours" — it computes blocks from now → bed and writes a minimal file. It needs a committed plans profile (for working style + bed time); if there's none, it points you at `/plan-my-day` first.

## Environment

Same as `/plan-my-day`: `PBRAIN_PLAN_DIR`, `PBRAIN_PLAN_PROFILE_FILE`, `PBRAIN_FITNESS_DIR` (bed/wake anchors), plus the Plane backend env (`PBRAIN_PLANE_*`).

The auto-pull session **requires Plane** ([`/project-manager`](project-manager.md)) — without it the script emits `PLAN_MY_WORK_NO_PLANE` and points you at setup. The `task add|remove|list` verb edits the day's tracker without Plane.
