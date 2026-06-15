# /project-manager

The **technical commander of Plane** ([makeplane](https://plane.so)) — pbrain's project brain. It sets up a local or Cloud Plane instance and then reads/writes its work items so the daily loop (`/plan-my-work`, `/end-of-day`, `/weekly-review`) can pull ready tasks and push status back.

One pbrain "project" = **one Plane PROJECT** (a workspace holds many), tracked in a small registry. **Plane is pbrain's sole project backend** — task-based planning and project progress require it. When Plane isn't configured, the ops below print a friendly "set Plane up" note and the daily-loop seams degrade to empty, so pbrain stays a working life-planner without them.

> `/project-manager` absorbs the old [`/init-plane`](init-plane.md) self-host wizard (`probe|fetch|up|config|portless|status`) **plus** all Plane ops. `/init-plane` stays as the truly vault-free setup path; `/project-manager` is the richer tool once you have a vault.

## Setup (absorbed from /init-plane)

With **no argument** it runs `probe` and prints the machine state. Drive the wizard one step at a time:

1. **Prerequisites** — Docker + Docker Compose running (~4 GB RAM).
2. `fetch` — download Plane's official `setup.sh`.
3. `up` — run Plane's own installer menu (Install, then Start). App at **http://localhost**.
4. **Account + structure** (browser) — first user = admin → create a workspace (note the slug) → create one or more projects (note each id). Model umbrella parts as **Modules**, larger tasks as **Issues**, subtasks as **Sub-issues**.
5. **Token** — Plane → Profile Settings → Personal Access Tokens → Add → copy.
6. **Wire pbrain → Plane**:
   - Local instance: `config --api-key <token> --workspace <slug> --project <id>` (base URL defaults to `http://localhost`).
   - Cloud / remote: `setup --base-url <url> --api-key <token> --workspace <slug> --project <id>`.
   Either writes `~/.config/pbrain/plane.json` (mode `0600`, never synced).
7. `projects --sync` — pull every project in the workspace into the registry. Add short `shortcut` codes (edit `plane.json`) so `--projects lt,pb` is ergonomic.
8. **Verify** — `test` (lists states), `ready` (ready issues).
9. **(Optional)** `portless` — a stable `https://plane.localhost` URL (needs Node 24+).

`status` shows Docker + Plane container + configured state at any time. Everything is idempotent. **The API token is a secret — it is never echoed back.**

## Ops

| Subcommand | What it does |
|---|---|
| `projects [--sync]` | Show / refresh the project registry (`{id,name,shortcut}`). |
| `ready [--projects a,b]` | Ready work items across projects (uuid \| name \| shortcut), cross-project sorted by priority → due, each tagged with its project + full `tie`. This is what `/plan-my-work` packs into blocks. |
| `progress --projects a,b [--since DATE]` | Per-project progress: `pct` (estimate-weighted when present, else count), status counts, items completed since `DATE`. The engine behind `/plan-my-work`'s progress report. |
| `review --projects a,b` | **Read-only** scan for thin issues (flags ⊆ `no_description \| no_estimate \| no_priority \| no_subissues`). Absent fields are "can't assess," not thin. |
| `enrich --edits '<json>'` | Apply confirmed enrichments `[{tie,field,value}]` (`field` ∈ description/priority/estimate/target_date/subissue). **Only after explicit per-item confirm.** |
| `move <tie> --to <status>` | Move one issue's status (`todo\|doing\|done\|blocked\|dropped`). |
| `priority <tie> --value <p>` | Set one issue's priority (`urgent\|high\|medium\|low\|none`). |
| `timeline <tie> --target-date <d>` | Set one issue's target date (`YYYY-MM-DD`). |

A **tie** is `<project_id>:<issue_id>` — the handle that flows through the daily loop (the `## Work tracker` carries it, `/end-of-day` resolves it back).

## The review walk

`review` proposes nothing on its own. The command walks the flagged issues **one at a time**, suggests a concrete enrichment per issue, and writes to Plane **only on an explicit yes** via `enrich` — never auto-committing, never touching a flag you declined.

## Environment

`PBRAIN_PLANE_HOME` (self-host dir), `PBRAIN_PLANE_BASE_URL` / `_API_KEY` / `_WORKSPACE` / `_PROJECT` / `_DEFAULT_EST_H`. Config lives at `~/.config/pbrain/plane.json` (mode `0600`, never synced to the vault).
