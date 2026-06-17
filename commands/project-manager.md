---
description: The technical commander of Plane (makeplane) — pbrain's project brain. One pbrain project = one Plane PROJECT (a workspace holds many); each is a Module → Issue → Sub-issue tree with Plane's own UI. /project-manager sets up a local or Cloud Plane instance and then reads/writes work items so the daily loop (/plan-my-work, /end-of-day, /weekly-review) can pull ready tasks and push status back. Absorbs the old /init-plane self-host wizard plus all Plane ops (projects, ready, progress, review/enrich, move, priority, timeline, issue, project-create). Use to set up Plane, sync the project registry, create projects/issues, run a progress report, enrich thin issues, or change an issue's status/priority/date.
argument-hint: (none=probe) | fetch | up | config … | vhost [--host … --port …] | status | setup … | use plane|markdown | test | projects [--sync] | ready [--projects …] | progress --projects … | review --projects … | move <tie> --to … | priority <tie> --value … | timeline <tie> --target-date … | issue --project <ref> --title <t> [--priority p] [--target-date d] | project-create --name <n> [--shortcut <s>]
---
Run this with your shell first (substituting any argument for `$ARGUMENTS`), then follow the INSTRUCTIONS below based on the token it prints:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/project-manager.sh" "$ARGUMENTS"
```

`/project-manager` is the operator between pbrain and **Plane** (makeplane). Plane owns the task tree (Module → Issue → Sub-issue) and the UI; pbrain reads ready work and writes status back through two seams. One pbrain "project" = one Plane PROJECT; a workspace holds many, tracked in a small registry (`projects [--sync]`). **Plane is pbrain's sole project backend** — task planning and project progress require it. When Plane isn't configured the ops emit `PM_NOT_CONFIGURED` (a friendly "set Plane up" note); the setup family still runs.

**Never print or echo the Plane API token back to the user — treat it as a secret at every step.**

## Setup wizard (absorbed from the old /init-plane)

With **no argument** the script runs `probe` → `INIT_PLANE_PROBE` + machine state (`docker`, `docker_running`, `compose`, `selfhost_dir`, `setup_sh`, `plane_config`, `plane_running`, `configured`, `default_url`, `plane_env`, `vhost_port`, `vhost_domain`). **Drive the wizard one step at a time from that state.** This is the same local self-host flow /init-plane had:

1. **Prerequisites.** Plane self-host needs **Docker + Docker Compose running** (≈4 GB RAM, 2 cores). `docker: no` → install Docker Desktop and stop. `docker_running: no` → start it and stop. `compose: no` → update Docker Desktop.
2. **`fetch`** → downloads Plane's official `setup.sh` (`INIT_PLANE_FETCHED`).
3. **`up`** → runs Plane's **own interactive installer** (menu: Install / Start / Stop / …). First time choose **Install** (a big Docker pull), then **Start**. App comes up at **http://localhost**. (Handle `INIT_PLANE_NEED_FETCH`/`INIT_PLANE_NEED_DOCKER` first.)
4. **Account + structure (browser, guide the user).** http://localhost → sign up (first user = admin) → create a **workspace** (note the **slug** from the URL) → create one or more **projects** (note each **project id**). Suggest modeling umbrella parts as **Modules**, larger tasks as **Issues**, subtasks as **Sub-issues**.
5. **Token.** Plane → Profile Settings → Personal Access Tokens → Add → copy. Ask the user to paste it; handle as a secret, never echo it.
6. **Wire pbrain → Plane.** For the **local** instance run `config --api-key <token> --workspace <slug> --project <project-id>` (base URL defaults to `http://localhost`). For **Cloud or a remote host** run `setup --base-url <url> --api-key <token> --workspace <slug> --project <id>` (no localhost default). Either writes `~/.config/pbrain/plane.json` (mode 0600, never synced). Confirm `PLANE_CONFIGURED`.
7. **Sync the registry.** Run `projects --sync` so all of the workspace's projects are known to pbrain (`PM_PROJECTS` + a JSON array of `{id,name,shortcut}`). Offer to add short `shortcut` codes by editing `plane.json` (e.g. `lt` for Lettuce) — they make `--projects lt,pb` ergonomic.
8. **Verify.** `test` lists the project's states; `ready` shows ready issues. On `PLANE_ERROR`, relay it (bad token, wrong workspace/project, or Plane not fully up) and help fix it — don't loop.
9. **(Optional) Named vhost on a non-80 port.** Run `vhost` to move Plane off port 80 to a stable `http://plane.localhost:1800` (so port 80 is free for other local apps and the URL never collides). Zero new daemons — it edits Plane's OWN `plane.env` (`APP_DOMAIN` + `LISTEN_HTTP_PORT`, which Plane substitutes into `WEB_URL`/`CORS_ALLOWED_ORIGINS` automatically), restarts the Plane stack, and re-points pbrain's `base_url` to the loopback form `http://127.0.0.1:1800` (token/workspace/project preserved; the vanity host is browser-only). Plane's built-in Caddy is host-agnostic on its listener port, so both URLs hit the same backend. Flags: `--host` (default `plane.localhost`), `--port` (default `1800`), `--plane-home` (override env-file discovery), `--no-restart` (edit only), `--remove` (revert via the backup written on first apply). Then `test` to verify.

`status` (`INIT_PLANE_STATUS`) shows Docker + Plane container + configured state at any time. Everything is idempotent.

## Ops tokens

- `PM_PROJECTS` — JSON array of `{id,name,shortcut}` (the registry). With `--sync` it was just refreshed from the live workspace. Give a tight read; note any project without a shortcut the user may want to name.
- `PM_READY` — JSON array of ready work items across the chosen projects (`--projects` is a comma list of uuid|name|shortcut; omitted = all registry projects), each tagged with `project`/`project_id` and a full `tie` (`<project_id>:<issue_id>`), sorted by priority → due. Present grouped by project as "what's pickable now." This is the same data `/plan-my-work` packs into blocks.
- `PM_PROGRESS` — a JSON object keyed by project id: `pct` (done-weight ÷ total, weighted by estimate when present), `counts` (todo/doing/done/dropped), `completed_since` (when `--since DATE` was passed). Render a per-project progress read; lead with what's moving and what's stalled. This is the engine behind `/plan-my-work`'s progress report.
- `PM_REVIEW` — a JSON array of thin issues, each `{tie, project, title, flags}` where flags ⊆ `no_description | no_estimate | no_priority | no_subissues`. **Read-only — it proposes nothing on its own.** Now **walk the list ONE issue at a time**: for each, suggest a concrete enrichment (a description, an estimate in hours, a priority, or a sub-issue breakdown) and **ask the user to confirm or edit it before writing anything**. Only on an explicit yes, collect the confirmed edits into `[{"tie":"…","field":"description|priority|estimate|target_date|subissue","value":…}]` and apply them with `enrich --edits '<json>'`. **Never auto-commit; never enrich a flag the user declined — on a decline, leave the issue flagged and move on.** Absent fields are reported as "can't assess," not thin, so you won't be asked to fill a field Plane simply doesn't return.
- `PM_ENRICH` — the confirmed writes were applied; relay the per-edit `ok`/`error` summary in one line each.
- `PM_MOVE` / `PM_PRIORITY` / `PM_TIMELINE` — a single-issue write succeeded (or returned `ok:false` with an error); confirm it in one line. `move <tie> --to <todo|doing|done|blocked|dropped>`, `priority <tie> --value <urgent|high|medium|low|none>`, `timeline <tie> --target-date <YYYY-MM-DD>`.
- `PM_ISSUE` — JSON `{project_id, project, issue}` where `issue` is the raw Plane response for the newly created work item. Report the issue's `sequence_id` (human-readable number) and title. On `PLANE_ERROR`, relay it. Usage: `issue --project <uuid|name|shortcut> --title <title> [--priority urgent|high|medium|low|none] [--target-date YYYY-MM-DD]`.
- `PM_PROJECT_CREATE` — JSON `{id, name, shortcut}` for the newly created Plane project. It has already been added to the local registry — no `projects --sync` needed. Report the name, id, and shortcut (if given). On `PLANE_ERROR`, relay it. Usage: `project-create --name <name> [--shortcut <alias>]`.
- `PM_TEST` / `PM_SETUP` / `PM_COMPLETED` / `PLANE_CONFIGURED …` / `PLANE_OK …` / `PLANE_ERROR …` — config/verify results. On `PLANE_ERROR`, relay the message and help fix the config; don't loop.

Keep reads tight, lead with what needs attention, and let the user drive. This is a commander, not a coach.
