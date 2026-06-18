# /init-plane

> **Superseded by [`/project-manager`](project-manager.md)** for users who already have a vault — it absorbs this whole wizard (`probe|fetch|up|config|vhost|status`) plus all Plane ops. `/init-plane` stays as the **vault-free** setup path (it needs no Obsidian vault), so it's still the right entry point when you're bootstrapping Plane before anything else.

Stand up a **self-hosted [Plane](https://plane.so)** instance on your own machine and wire pbrain to it — so Plane becomes the project brain (a Linear-like UI with Module → Issue → Sub-issue), and pbrain's daily loop reads ready tasks from it and writes status back. Guided and idempotent, in the spirit of `/init-obsidian`.

Plane is pbrain's **sole** project backend — task-based planning ([`/plan-my-work`](plan-my-work.md)) and project progress need it. This is the turnkey path to setting it up; you only need it once. (Without Plane, pbrain still works as a life-planner — journal, gratitude, fitness, diet, habits, and `/plan-my-day`'s day-shape — minus task pull and project progress.)

## What it does

1. **Checks prerequisites** — Docker + Docker Compose running (~4 GB RAM, 2 cores).
2. **Downloads Plane's official installer** (`setup.sh`) into `~/.config/pbrain/plane-selfhost/`.
3. **Runs it** — Plane's own interactive menu (Install / Start / Stop / Restart / Upgrade) brings the stack up at **http://localhost**. pbrain leans on Plane's installer rather than reimplementing Docker Compose.
4. **Moves it to a stable URL** — by default runs `vhost` right after the stack is up to put Plane at **http://plane.localhost:1800** (off port 80, no collisions), *before* you create an account so everything lives at the final URL. Skip it to stay on plain `http://localhost`.
5. **Guides account + structure** — you create the first (admin) account, a workspace, and a project in the browser, and a Personal Access Token.
6. **Wires pbrain → Plane** — writes `~/.config/pbrain/plane.json` (mode `0600`, never synced to your vault); the base URL is auto-detected from `plane.env` (`http://127.0.0.1:1800` after `vhost`, else `http://localhost`).

After setup, `/plan-my-work` pulls ready Plane issues into your work blocks and `/end-of-day` writes their status back. Manage the actual task tree in Plane's UI.

## Usage

Run `/init-plane` and follow the wizard. The underlying subcommands (also runnable directly):

| Subcommand | What it does |
|---|---|
| `/init-plane` (probe) | Print machine state (docker / compose / install / config / configured / running). |
| `/init-plane fetch` | Download Plane's `setup.sh` into the managed dir. |
| `/init-plane up` | Run Plane's installer menu (Install the first time, then Start). |
| `/init-plane config --api-key <t> --workspace <slug> --project <id>` | Wire pbrain to the instance (base URL auto-detected from `plane.env` — `http://127.0.0.1:1800` after `vhost`, else `http://localhost`). |
| `/init-plane vhost [flags]` | Move Plane off port 80 to a named vhost (default `http://plane.localhost:1800`) by editing its own `plane.env`. Run by default during setup; `--remove` reverts to `http://localhost`. |
| `/init-plane status` | Docker + Plane container + whether pbrain is configured. |

## Named vhost on a non-80 port (the default)

Plane's installer brings the stack up on `http://localhost` (port 80). The wizard then moves it — **by default** — to a stable, named URL **`http://plane.localhost:1800`**, so it never collides with another local app on port 80. The move happens right after `up` and *before* you create your account, so the workspace/project you set up all live at the final URL. The command is:

```bash
/init-plane vhost              # default: --host plane.localhost --port 1800
```

This edits Plane's OWN `plane.env` (`APP_DOMAIN=plane.localhost:1800`, `LISTEN_HTTP_PORT=1800`, which Plane substitutes into `WEB_URL`/`CORS_ALLOWED_ORIGINS` itself) and restarts the Plane stack via `docker compose up -d`. No sidecar proxy, no Node, no `/etc/hosts`. Plane's built-in Caddy is host-agnostic on its listener port, so:

- **Browser** uses the vanity URL `http://plane.localhost:1800` — `*.localhost` resolves to `127.0.0.1` for free in every modern browser (RFC 6761).
- **pbrain** uses `http://127.0.0.1:1800` — numeric loopback, no DNS gymnastics. `config` auto-detects this from `plane.env`, and a later `vhost` run (once pbrain is wired) re-points the saved `base_url` for you, **preserving** your token / workspace / project.

Both URLs hit the same Plane stack on the same port. Then `/project-manager test` to verify.

Flags: `--host` (default `plane.localhost`), `--port` (default `1800`), `--plane-home` (override env-file discovery — by default the command finds `plane.env` via `PBRAIN_PLANE_HOME` or by inspecting the running `plane-app-proxy-1` container), `--no-restart` (edit only, you restart manually), `--remove` (revert to plain `http://localhost` via the `plane.env.pbrain-bak` written on first apply, falling back to resetting the two keys if no backup is found).

Prefer plain `http://localhost`? Just skip the `vhost` step during setup — everything else works the same. To debug a restart issue in isolation you can also bring Plane up on `:80` first, confirm `/project-manager test`, then run `vhost`.

## Notes

- The **token is a secret** — it lives only in `~/.config/pbrain/plane.json` (local, `0600`), never in the vault or git.
- Plane self-host is a real Docker stack (Postgres, Redis, MinIO, app services). For a solo machine 4 GB RAM is the floor; close it down from the `setup.sh` menu when you don't need it.
- Plane Cloud works too — skip `fetch`/`up` and just run `/project-manager setup --base-url https://api.plane.so --api-key … --workspace … --project …`.

## Overrides

| Env var | Default |
|---|---|
| `PBRAIN_PLANE_HOME` | `~/.config/pbrain/plane-selfhost` (where `setup.sh` + Plane's data live) |
| `PBRAIN_PLANE_BASE_URL` / `PBRAIN_PLANE_API_KEY` / `PBRAIN_PLANE_WORKSPACE` / `PBRAIN_PLANE_PROJECT` | env overrides for the written config |
