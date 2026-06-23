# /plan-my-work

The **work layer** of the daily loop. [`/plan-my-day`](plan-my-day.md) lays out the day's *shape* — life anchors (calendar, fitness, meals, walk, bed, habit reminders) and **empty work blocks**. `/plan-my-work` then **fills those blocks with real tasks pulled from Plane** (via [`/project-manager`](project-manager.md)) and writes a rich `## Work tracker` into the same daily file.

Weekly/monthly goals are now a **CEO overview** — which Plane PROJECTS are in play, at what priority, and at what **% allocation** (summing to 100) — not task text. The tasks live in Plane.

## The flow

1. **Preflight / standalone.** If `/plan-my-day` already ran today, it reads the empty work-block rows. Run alone (no plan yet) → it asks your focus hours and computes the block count from now → bed (no whole-day timeline).
2. **Ready-check (delegated).** Grooming the tasks — descriptions, priorities, assignees, breaking up multi-step issues, moving backlog → todo — is **`/project-manager`'s** job, not this command's. If this week's goal projects have thin issues, `/plan-my-work` hands them to `/project-manager` in executor mode (it grooms fast, no interrogation), then pulls. This is the clean split: `/plan-my-work` owns goals → allocation → blocks; `/project-manager` owns every Plane read/write.
3. **Progress report (weekly primary + monthly).** Per weekly goal: name · alloc% · Plane pct · tasks done this week · flags. **% of expected time spent = Σ(alloc%·pct) / Σ(alloc%)**. Flags: **pile-up** (last week's partial/open rows still open) and **re-evaluate** (high alloc%, low pct, no activity). Plus a one-line monthly read (are this week's goals serving the month's?).
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

## Executing the plan

`/plan-my-work task execute` is the **execution layer** — the only pbrain command that touches code, branches, PRs, and merges. It walks the **current time block's** tasks to Done, one at a time, then cascades until the day's work is exhausted.

It auto-picks the block whose time range contains *now* (or the next upcoming block; nothing to do once you're past the last block), reads that block's unfinished `## Work tracker` rows (already-`done` rows are skipped, so a re-run resumes the first unfinished task), then for each task runs a supervised lifecycle:

**pick → in-progress → spec/approval gate → implement → finish → PR → gated merge → done.**

- **Spec/approval gate (PB-45).** At the plan step, `task execute` reads the issue's recorded plan + approval (`/project-manager spec "<tie>" --read`). If the plan was **approved** ahead of time (the `plan-approved` label, written via [`/project-manager spec`](project-manager.md)), it **fast-paths** — implementing straight against the recorded `## Implementation Plan` with no live planning gate. If **unapproved**, it **falls back** to drafting a plan inline with a [gate] (exactly as before), then offers to save it as approved for next time. It's a fast path, not a wall — nothing is blocked; pre-speccing just removes the hand-holding. `/plan-my-work` packs approved tasks first and tags each tracker row `✅ plan approved` / `⏳ needs spec`.
- **Working location.** Each task runs in a *configured, pre-existing* repo or Conductor workspace — `task execute` never spawns one, it `cd`s in and isolates the work on a `git worktree`/branch off a fresh `origin/<base>`. Record the location once with [`/project-manager workdir <project> --path <abs>`](project-manager.md); if it's unset, `task execute` asks for the path and offers to record it. Defaults keep your main checkout safe (`kind=repo`, `isolation=worktree`).
- **Gates everywhere.** It's read-only until you say go, and asks for an explicit yes before marking in-progress, before writing any code, and before finishing.
- **Double-gated merge.** The one irreversible step. It opens a PR (`gh pr create --fill`), watches CI, and merges **only** when CI is green (or you explicitly waive a non-blocking check) **and** you type the exact confirm word `merge <PB-id>`. CI red → it stops. No `gh`/CI → it pushes the branch and hands you a manual PR URL; it never fabricates a PR or a merge.
- **Plane stays in sync.** Status moves `doing` on start and `done` only after the merge lands — every Plane write routed through `/project-manager` (the sole Plane writer). The `## Work tracker` `Status` column *is* the lifecycle state, so it's resume-safe.
- **Cascade.** When a block is done it advances to the next block; when a project's planned tasks run out (with day left) it offers to pull more ready tasks; when a project is fully done it suggests a new one. Each hand-off is a gate.

`/end-of-day` reconciles the tracker back to Plane afterward (mapping `in-progress → doing` idempotently).

## Standalone vs in-loop

Run `/plan-my-day` then `/plan-my-work` for the full day. Run `/plan-my-work` alone for a quick "what should I work on for the next few hours" — it computes blocks from now → bed and writes a minimal file. It needs a committed plans profile (for working style + bed time); if there's none, it points you at `/plan-my-day` first.

## Environment

Same as `/plan-my-day`: `PBRAIN_PLAN_DIR`, `PBRAIN_PLAN_PROFILE_FILE`, `PBRAIN_FITNESS_DIR` (bed/wake anchors), plus the Plane backend env (`PBRAIN_PLANE_*`).

The auto-pull session **requires Plane** ([`/project-manager`](project-manager.md)) — without it the script emits `PLAN_MY_WORK_NO_PLANE` and points you at setup. The `task add|remove|list` verb edits the day's tracker without Plane.
