# /project-manager

The **technical commander of Plane** ([makeplane](https://plane.so)) — pbrain's project brain. It sets up a local or Cloud Plane instance and then reads/writes its work items so the daily loop (`/plan-my-work`, `/end-of-day`, `/weekly-review`) can pull ready tasks and push status back.

One pbrain "project" = **one Plane PROJECT** (a workspace holds many), tracked in a small registry. **Plane is pbrain's sole project backend** — task-based planning and project progress require it. When Plane isn't configured, the ops below print a friendly "set Plane up" note and the daily-loop seams degrade to empty, so pbrain stays a working life-planner without them.

> `/project-manager` absorbs the old [`/init-plane`](init-plane.md) self-host wizard (`probe|fetch|up|config|vhost|status`) **plus** all Plane ops. `/init-plane` stays as the truly vault-free setup path; `/project-manager` is the richer tool once you have a vault.

## Editing Plane in plain words

You don't touch the Plane web UI to *change* things — you tell `/project-manager` and it makes the API calls. Just describe what you want:

```
/project-manager bump the gym-reminder bug to high and tag it backend
/project-manager comment on PB-26 that the fix shipped, then move it to done
/project-manager find the auth issue and assign it to me
```

It **resolves** the issue you mean — by link, id (`PB-26`), or fuzzy name — asks if there's more than one match, then runs the specific operations. One sentence can be several edits, across several issues. For the slice the API can't reach (file attachments, deleting an issue, workspace settings), it hands you the exact UI steps instead of failing.

**Guardrails:** labels you name are created on the fly (capped per run so they don't pile up); people and projects are never auto-created — it confirms first.

## Setup (absorbed from /init-plane)

With **no argument** it runs `probe` and prints the machine state. Drive the wizard one step at a time:

1. **Prerequisites** — Docker + Docker Compose running (~4 GB RAM).
2. `fetch` — download Plane's official `setup.sh`.
3. `up` — run Plane's own installer menu (Install, then Start). App comes up at **http://localhost** (port 80).
4. **Move Plane to its stable URL (default)** — `vhost` moves it off port 80 to **http://plane.localhost:1800** (no port-80 collisions). Run it right after `up`, *before* the browser step, so your account/workspace live at the final URL. Edits Plane's own `plane.env` (`APP_DOMAIN`, `LISTEN_HTTP_PORT`) — no sidecar proxy, no Node, no `/etc/hosts`. Browser uses the vanity URL (RFC 6761 resolves `*.localhost` for free); pbrain talks to `http://127.0.0.1:1800` (no DNS needed). Flags: `--host`, `--port`, `--plane-home`, `--no-restart`, `--remove`. To stay on plain `http://localhost`, skip this step (or undo later with `vhost --remove`).
5. **Account + structure** (browser) — at http://plane.localhost:1800: first user = admin → create a workspace (note the slug) → create one or more projects (note each id). Model umbrella parts as **Modules**, larger tasks as **Issues**, subtasks as **Sub-issues**.
6. **Token** — Plane → Profile Settings → Personal Access Tokens → Add → copy.
7. **Wire pbrain → Plane**:
   - Local instance: `config --api-key <token> --workspace <slug> --project <id>` (base URL auto-detected from `plane.env` — `http://127.0.0.1:1800` after `vhost`, else `http://localhost`).
   - Cloud / remote: `setup --base-url <url> --api-key <token> --workspace <slug> --project <id>`.
   Either writes `~/.config/pbrain/plane.json` (mode `0600`, never synced).
8. `projects --sync` — pull every project in the workspace into the registry. Add short `shortcut` codes (edit `plane.json`) so `--projects lt,pb` is ergonomic.
9. **Verify** — `test` (lists states), `ready` (ready issues).

`status` shows Docker + Plane container + configured state at any time. Everything is idempotent. **The API token is a secret — it is never echoed back.**

## Ops

| Subcommand | What it does |
|---|---|
| `projects [--sync]` | Show / refresh the project registry (`{id,name,shortcut}`). |
| `ready [--projects a,b]` | Ready work items across projects (uuid \| name \| shortcut), cross-project sorted by priority → due, each tagged with its project + full `tie`. This is what `/plan-my-work` packs into blocks. |
| `progress --projects a,b [--since DATE]` | Per-project progress: `pct` (estimate-weighted when present, else count), status counts, items completed since `DATE`. The engine behind `/plan-my-work`'s progress report. |
| `find <ref> [--project R]` | Resolve an issue by URL, id (`PB-26`), bare sequence, or **fuzzy name** → candidate cards `{tie, id, title, state, project}`. The resolver behind plain-language editing. |
| `review --projects a,b` | **Read-only** scan for thin issues (flags ⊆ `no_description \| no_priority`). Absent fields are "can't assess," not thin. Followed by the dual-mode enrichment-walk instructions. |
| `explode <ref> [--project R]` | **Read-only** context for breaking ONE issue down. Resolves the ref, then prefetches its description + existing sub-issues + estimate scale and emits a **Socratic walk** (see below). |
| `spec <ref> [--project R] [--read]` | The **spec/approval gate** (PB-45). A **Socratic walk** that drafts a tight `## Implementation Plan` into the issue description and, on explicit approval, adds the `plan-approved` label. An approved issue lets `/plan-my-work task execute` skip its live planning gate (fast path). `--read` emits JSON only (plan + approval state, no walk) — how `task execute` reads it. |
| `bug "<symptom>" [--project R]` | The **bug-filing & triage convention** (PB-67). **Read-only** until you file. Prefetches the target project's labels + recent open bugs (for dedupe) + the severity→priority map, then emits a **Socratic triage walk**: repro → expected/actual → scope → severity. On explicit yes, creates the issue with a structured body (`## Bug/Repro/Expected/Actual/Severity`), the `bug` label, and a severity-derived priority (crash/blocker→urgent · high→high · minor→medium · polish→low). "file this bug …" routes here. |
| `labels --seed [--projects R,…]` | Seed the convention labels `bug`/`feature`/`chore`/`docs` onto the project(s) (default: all). Idempotent; new projects get them on create (PB-70). |
| `enrich` / `update --edits '<json>'` | The generic write path: `[{tie,field,value}]`. `field` ∈ description · title · priority · target_date/due · start_date · estimate · assignees(name\|uuid) · tag/untag/labels · state · parent · cycle · module · comment · link · subissue · relation:&lt;type&gt;. One batch shares a creation-guard + cache. |
| `move <tie> --to <status>` | Status (`todo\|doing\|done\|blocked\|dropped`). |
| `priority <tie> --value <p>` | Priority (`urgent\|high\|medium\|low\|none`). |
| `timeline <tie> --target-date <d>` | Target date (`YYYY-MM-DD`). |
| `tag <tie> --add a,b [--remove c] [--set x,y]` | Labels — add (auto-created, capped), remove, or replace the whole set. |
| `assign <tie> --to <name\|email\|uuid>` | Assignee by fuzzy name/email; `''` clears. Ambiguous → candidates returned. |
| `comment <tie> --body <text>` | Add a comment. |
| `reparent <tie> --parent <PB-12\|none>` | Move under a parent issue, or un-parent. |
| `cycle <tie> --name <c>` / `module <tie> --name <m>` | Add the issue to a cycle (sprint) or module (area). |
| `issue --project <ref> --title <t> [--priority p] [--target-date d]` | Create a new issue (`ref` = uuid \| name \| shortcut). Reports the new `sequence_id` + title. |
| `project-create --name <n> [--shortcut <s>]` | Create a new Plane project + add it to the registry. |
| `labels\|members\|cycles\|modules [--project R]` | List a project's labels / members / cycles / modules (the name→uuid tables). |

A **tie** is `<project_id>:<issue_id>` — the handle that flows through the daily loop (the `## Work tracker` carries it, `/end-of-day` resolves it back).

## Backups (PB-17)

A self-hosted Plane keeps all its data in two Docker volumes — Postgres (issues, projects, comments) and MinIO (file attachments). `backup` snapshots both into a single dated, self-describing tarball and can run on a daily schedule.

```
/project-manager backup estimate        # how big is a snapshot? (measured, not guessed)
/project-manager backup now             # take one right now
/project-manager backup enable          # daily snapshot at 03:30, kept 14 days
/project-manager backup status          # schedule, destination, latest snapshot
/project-manager backup restore latest --yes   # DESTRUCTIVE: roll the DB + uploads back
```

| Subcommand | What it does |
|---|---|
| `backup estimate` | Measure the current snapshot size (DB via `pg_dump -Fc` + uploads tar) and the projected retention footprint. |
| `backup now [--dir <path>]` | Take a snapshot immediately into the configured destination (or a one-off `--dir`). |
| `backup enable [--time HH:MM] [--dest local\|external\|vps] [--dir <p>] [--keep N] [--vps-host …] [--vps-path …] [--vps-port …] [--ssh-key …]` | Save the settings and install a daily LaunchAgent. |
| `backup disable` | Stop the schedule (existing snapshots are kept). |
| `backup config …` | Change settings; refreshes a live schedule in place. |
| `backup status` / `backup list` | Schedule + destination + Time-Machine coverage + snapshots; the list with sizes. |
| `backup restore <file\|latest> --yes` | Restore a snapshot (`pg_restore --clean` + rewrite uploads). Destructive — needs `--yes`. Restart Plane workers afterward. |

**Where it lands.** Three destinations:

- **local** (default) — `~/.config/pbrain/plane-backups`, which **Time Machine backs up by default** (status warns if that path is excluded).
- **external** — a mounted volume, e.g. `--dest external --dir /Volumes/Backup/plane`. Won't write if the volume isn't mounted.
- **vps** — `rsync`/`scp` over ssh, e.g. `--dest vps --vps-host deploy@host --vps-path ~/plane-backups` (optionally a non-default `--vps-port` / `--ssh-key`). Uploads run non-interactively, so set up key auth.

A snapshot is `plane-YYYYMMDD-HHMMSS.tar.gz` containing `db.dump` (logical `pg_dump`, ~6× smaller than the raw volume), `uploads.tar.gz`, and a `manifest.json` (sizes + sha256). It operates on Docker directly, so it works even before Plane is wired to pbrain. Redis and RabbitMQ are ephemeral and not backed up. Config: `~/.config/pbrain/plane-backup.json` (mode `0600`); the scheduled run logs to `~/.config/pbrain/plane-backup.log`.

## Host on a VPS (`host`, PB-18)

Move the self-hosted Plane off your laptop onto an always-on VPS so the phone can reach it. It **reuses the VPS host/SSH-key from `plane-backup.json`** (the same box your backups already go to); a brand-new user can pass `--vps-host` / `--ssh-key` / `--vps-port` instead. Subcommands:

- `host probe` — read-only state of the VPS (reachable? docker / Plane / WireGuard?).
- `host deploy [--port 1800]` — **guide** to stand Plane up on the VPS. Plane's `setup.sh` is an interactive menu, so this prints the runbook rather than driving it blind; pin Plane to a non-80/443 port if the box runs other services.
- `host domain [--domain d]` — **guide** for a public domain + Plane's bundled Caddy auto-TLS (set the DNS A-record and open 80/443 first).
- `host vpn [name] [--tunnel split]` — no-domain access via your own [quick-vpn](https://github.com/baymac/quick-vpn) (WireGuard). **Reuses** an existing quick-vpn client (creating none), or installs quick-vpn + creates one, then prints the client config/QR for the phone. Full tunnel is the default; `--tunnel split` routes only the VPN subnet. If WireGuard is already running un-managed, it's left untouched.
- `host import [latest] --yes` — restore a backup tarball that already lives on the VPS **into** the VPS-hosted Plane (`pg_restore` + uploads, over SSH). Destructive — requires `--yes`.
- `host wire --base-url URL [--internal-email E --internal-password P]` — point pbrain at the remote (`http://<wg-ip>:1800` or `https://<domain>`). For a remote instance it switches the internal estimates API from the local browser-cookie scrape to **email/password**; the password is stored in the **macOS Keychain** (service `pbrain-plane-internal`), never in `plane.json`. This is the only step that changes your active backend — until you run it, local stays primary.

Typical flow: `host probe` → `host deploy` (or `host domain`) → `host vpn` (no-domain) → `host import latest --yes` → `host wire …`.

## The review walk (dual-mode)

`review` proposes nothing on its own — it scans, then follows the enrichment-walk instructions. **Invoked directly**, it walks the flagged issues **one at a time**, suggests a concrete enrichment per issue, and writes **only on an explicit yes** — never auto-committing a flag you declined. **Invoked by `/plan-my-work`** (executor mode), it grooms fast — infers sensible values as a PM would (description, priority, assignee, relations, sub-tasks, backlog→todo) and applies them in batches without interrogating you, so the morning planner just gets ready work.

## Exploding a task (interactive break-down)

Where `review` scans many thin issues and infers, `explode <ref>` takes the ONE issue you name and breaks it down **with** you — a Socratic, one-question-at-a-time walk in the spirit of `/discuss` and `/journal`'s open questions. It uses the `AskUserQuestion` tool (suggested options drawn from the issue, plus a free-form answer; it falls back to plain conversation where that tool isn't available, e.g. the Codex CLI) to draw out what "done" looks like, the natural seams to split on, ordering/dependencies, sizing (toward ~30m–1h sub-issues), and what's out of scope. It prefetches the issue's existing sub-issues so it never proposes a duplicate. Once you confirm, it writes the refined parent **description** plus each child as a `subissue` in one batch, then reports a compact table. Drive it in plain words too — "break down PB-24 into sub-issues" routes here.

## Working locations (for `/plan-my-work task execute`)

`/plan-my-work task execute` needs to know **where** each Plane project's tasks get implemented. `workdir` records that — a per-project working location stored in `plane.json` (`projects[].work`):

```
/project-manager workdir                                    # list configured locations
/project-manager workdir pb --path ~/code/pbrain            # set (repo at that path)
/project-manager workdir pb --path ~/code/pbrain --kind conductor --base-branch main
/project-manager workdir pb --clear                         # remove
```

The path must already exist — `task execute` `cd`s into it and isolates work on a `git worktree`/branch; it never creates or spawns a repo/workspace. Fields: `path` (absolute), `kind` (`repo` default, or `conductor`), `base_branch` (default `main`), `isolation` (`worktree` default, or `branch`) — the defaults keep your main checkout untouched. As a config write it's a `/project-manager` verb (the single-writer rule), and `projects --sync` preserves it.

## Environment

`PBRAIN_PLANE_HOME` (self-host dir), `PBRAIN_PLANE_BASE_URL` / `_API_KEY` / `_WORKSPACE` / `_PROJECT` / `_DEFAULT_EST_H`. Plus: `PBRAIN_PLANE_MAX_CREATES` (cap on auto-created labels per run, default 5), `PBRAIN_PM_CALLER` (set to `plan-my-work` by the daily loop to put the router in executor mode). Config lives at `~/.config/pbrain/plane.json` (mode `0600`, never synced to the vault); backup settings live alongside it at `~/.config/pbrain/plane-backup.json`.
