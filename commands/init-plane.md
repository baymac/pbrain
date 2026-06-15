---
description: Set up a local self-hosted Plane (makeplane) instance and wire pbrain to it. Plane is pbrain's sole project brain (Module → Issue → Sub-issue + a Linear-like UI); pbrain's /plan-my-work and /end-of-day then read ready tasks from Plane and write status back. Guided, idempotent — safe to re-run. Use when the user wants to run Plane locally as pbrain's task tracker (task planning + project progress require Plane).
argument-hint: (none) | fetch | up | config | portless | status
---
> **Note:** `/project-manager` now absorbs this wizard (`probe|fetch|up|config|portless|status`) plus all Plane ops, and is the preferred entry point once a vault exists. `/init-plane` stays as the vault-free setup path (it needs no Obsidian vault). If the user already has pbrain set up, point them at `/project-manager`.

This is a guided setup wizard (like /init-obsidian). Run the script with your shell, read the token it prints, and walk the user through the steps below. Substitute any argument for `$ARGUMENTS`:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/init-plane.sh" "$ARGUMENTS"
```

With no argument the script runs `probe` and prints `INIT_PLANE_PROBE` followed by machine state (`docker`, `docker_running`, `compose`, `selfhost_dir`, `setup_sh`, `plane_config`, `plane_running`, `configured`, `default_url`). **Drive the wizard from that state — do one step, confirm, then the next. Never echo the API token back to the user.**

The flow:

1. **Prerequisites.** Plane self-host needs **Docker + Docker Compose running** (≈4 GB RAM, 2 cores).
   - `docker: no` → tell the user to install **Docker Desktop** (https://www.docker.com/products/docker-desktop/) and re-run. Stop here.
   - `docker_running: no` → tell them to start Docker Desktop, then re-run. Stop here.
   - `compose: no` → their Docker is too old; updating Docker Desktop bundles Compose.

2. **Download Plane's installer.** Run `init-plane fetch` — downloads Plane's official `setup.sh` into the managed dir and makes it executable. Confirm `INIT_PLANE_FETCHED`.

3. **Bring Plane up.** Run `init-plane up` — this launches Plane's **own interactive installer** (`setup.sh`) with a menu (Install / Start / Stop / Restart / Upgrade / View Logs / Backup). First time: choose **Install** (a sizeable Docker pull — minutes), then **Start**. Plane owns its own lifecycle through this menu; pbrain doesn't reimplement it. When it's up, the app is at **http://localhost**. (If `up` reports `INIT_PLANE_NEED_FETCH`/`INIT_PLANE_NEED_DOCKER`, handle that first.)

4. **Create the account + structure (browser, guide the user).** Open **http://localhost** → sign up (first user is the admin) → create a **workspace** (note its **slug** from the URL, e.g. `localhost/my-workspace` → `my-workspace`) → create a **project** (note its **project id** from Project → Settings, or the URL). Suggest they model their umbrella parts as **Modules** (Frontend / Backend / Security), larger tasks as **Issues**, and subtasks as **Sub-issues** — that mirrors pbrain's hierarchy.

5. **Generate a token.** In Plane: **Profile Settings → Personal Access Tokens → Add personal access token** → copy it. Ask the user to paste it to you (handle it as a secret — don't print it back).

6. **Wire pbrain → Plane.** Run:
   ```
   init-plane config --api-key <token> --workspace <slug> --project <project-id>
   ```
   (base URL defaults to `http://localhost` for the local instance; pass `--base-url` only for a remote/custom one). This writes `~/.config/pbrain/plane.json` (mode `0600`, **never** synced to the vault). Confirm `PLANE_CONFIGURED`.

7. **Verify.** Run `/project-manager test` (should list your project's states) and `/project-manager ready` (your ready issues). If you see `PLANE_ERROR`, relay it — usually a bad token, wrong workspace/project, or Plane not fully started yet — and help fix it; don't loop.

8. **(Optional) Named URL via portless.** If the probe shows `portless: yes` (and `node:` is v24+), you can give Plane a stable `https://plane.localhost` instead of `http://localhost` — handy so the URL never collides with another local app on port 80. Run `init-plane portless` — it registers a portless static alias (`https://plane.localhost` → `localhost:80`) and re-points pbrain's `base_url` at it (your token/workspace/project are preserved). Then, as the printed steps say: start the proxy once (`portless proxy start`, or `portless service install` to persist), **add `https://plane.localhost` to Plane's `CORS_ALLOWED_ORIGINS` / `WEB_URL` in its `.env` and restart Plane**, and re-run `/project-manager test`. If `portless: no`, skip this — install portless with `npm install -g portless` (needs Node 24+) first, or just stay on `http://localhost`. Flags: `--name` (default `plane`), `--plane-port` (default `80`, set it if you changed Plane's nginx port), `--no-tls` (plain http), `--url <explicit>`, `--remove` (tear it down and restore `http://localhost`).

After this, `/plan-my-work` pulls ready issues from Plane into the day's blocks and `/end-of-day` writes their status back.

`init-plane status` shows Docker + Plane container state + whether pbrain is configured at any time. Everything is idempotent — re-running never double-installs or clobbers an existing config.
