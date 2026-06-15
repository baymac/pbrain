# /init-plane

> **Superseded by [`/project-manager`](project-manager.md)** for users who already have a vault — it absorbs this whole wizard (`probe|fetch|up|config|portless|status`) plus all Plane ops. `/init-plane` stays as the **vault-free** setup path (it needs no Obsidian vault), so it's still the right entry point when you're bootstrapping Plane before anything else.

Stand up a **self-hosted [Plane](https://plane.so)** instance on your own machine and wire pbrain to it — so Plane becomes the project brain (a Linear-like UI with Module → Issue → Sub-issue), and pbrain's daily loop reads ready tasks from it and writes status back. Guided and idempotent, in the spirit of `/init-obsidian`.

Plane is pbrain's **sole** project backend — task-based planning ([`/plan-my-work`](plan-my-work.md)) and project progress need it. This is the turnkey path to setting it up; you only need it once. (Without Plane, pbrain still works as a life-planner — journal, gratitude, fitness, diet, habits, and `/plan-my-day`'s day-shape — minus task pull and project progress.)

## What it does

1. **Checks prerequisites** — Docker + Docker Compose running (~4 GB RAM, 2 cores).
2. **Downloads Plane's official installer** (`setup.sh`) into `~/.config/pbrain/plane-selfhost/`.
3. **Runs it** — Plane's own interactive menu (Install / Start / Stop / Restart / Upgrade) brings the stack up at **http://localhost**. pbrain leans on Plane's installer rather than reimplementing Docker Compose.
4. **Guides account + structure** — you create the first (admin) account, a workspace, and a project in the browser, and a Personal Access Token.
5. **Wires pbrain → Plane** — writes `~/.config/pbrain/plane.json` (mode `0600`, never synced to your vault).

After setup, `/plan-my-work` pulls ready Plane issues into your work blocks and `/end-of-day` writes their status back. Manage the actual task tree in Plane's UI.

## Usage

Run `/init-plane` and follow the wizard. The underlying subcommands (also runnable directly):

| Subcommand | What it does |
|---|---|
| `/init-plane` (probe) | Print machine state (docker / compose / install / config / configured / running). |
| `/init-plane fetch` | Download Plane's `setup.sh` into the managed dir. |
| `/init-plane up` | Run Plane's installer menu (Install the first time, then Start). |
| `/init-plane config --api-key <t> --workspace <slug> --project <id>` | Wire pbrain to the instance (base URL defaults to `http://localhost`). |
| `/init-plane portless [flags]` | Optional: front Plane with a stable `https://plane.localhost` via [portless](https://portless.sh). |
| `/init-plane status` | Docker + Plane container + whether pbrain is configured. |

## Named URL with portless (optional)

Plane self-host serves on `http://localhost` (port 80). If you'd rather hit it at a stable, named URL like **`https://plane.localhost`** — so it never collides with another local app on port 80 and you get local HTTPS — front it with [portless](https://portless.sh) (`vercel-labs/portless`, needs Node 24+):

```bash
npm install -g portless        # one-time, if the probe shows portless: no
/init-plane portless           # registers the alias + re-points pbrain
portless proxy start           # bring the proxy up (sudo for :443; 'portless service install' persists it)
```

`/init-plane portless` runs `portless alias plane 80` (its documented static-route case "for Docker containers" — portless's HTTPS proxy is on 443, Plane's nginx on 80, no conflict) and re-points pbrain's `base_url` to `https://plane.localhost`, **preserving** your token / workspace / project. One required manual step on Plane's side: add `https://plane.localhost` to **`CORS_ALLOWED_ORIGINS`** (and `WEB_URL`) in Plane's `.env`, then restart Plane from `setup.sh` — otherwise the API rejects the new origin. Then `/project-manager test`.

Flags: `--name` (default `plane`), `--plane-port` (default `80`; set it if you changed Plane's nginx port), `--no-tls` (plain http), `--url <explicit>`, `--remove` (drop the alias and restore `http://localhost`).

Tip: bring Plane up on plain `http://localhost` and confirm `/project-manager test` works **first**, then add portless — that isolates "is pbrain wired right" from "did Plane accept the custom host."

## Notes

- The **token is a secret** — it lives only in `~/.config/pbrain/plane.json` (local, `0600`), never in the vault or git.
- Plane self-host is a real Docker stack (Postgres, Redis, MinIO, app services). For a solo machine 4 GB RAM is the floor; close it down from the `setup.sh` menu when you don't need it.
- Plane Cloud works too — skip `fetch`/`up` and just run `/project-manager setup --base-url https://api.plane.so --api-key … --workspace … --project …`.

## Overrides

| Env var | Default |
|---|---|
| `PBRAIN_PLANE_HOME` | `~/.config/pbrain/plane-selfhost` (where `setup.sh` + Plane's data live) |
| `PBRAIN_PLANE_BASE_URL` / `PBRAIN_PLANE_API_KEY` / `PBRAIN_PLANE_WORKSPACE` / `PBRAIN_PLANE_PROJECT` | env overrides for the written config |
