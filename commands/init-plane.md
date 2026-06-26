---
description: Set up a local self-hosted Plane (makeplane) instance and wire pbrain to it. Plane is pbrain's sole project brain (Module → Issue → Sub-issue + a Linear-like UI); pbrain's /plan-my-work and /end-of-day then read ready tasks from Plane and write status back. Guided, idempotent — safe to re-run. Use when the user wants to run Plane locally as pbrain's task tracker (task planning + project progress require Plane).
argument-hint: (none) | fetch | up | config | vhost | github | app | status
---
> **Note:** `/project-manager` now absorbs this wizard (`probe|fetch|up|config|vhost|status`) plus all Plane ops, and is the preferred entry point once a vault exists. `/init-plane` stays as the vault-free setup path (it needs no Obsidian vault). If the user already has pbrain set up, point them at `/project-manager`.

This is a guided setup wizard (like /init-obsidian). Run the script with your shell, read the token it prints, and walk the user through the steps below. Substitute any argument for `$ARGUMENTS`:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/init-plane.sh" "$ARGUMENTS"
```

With no argument the script runs `probe` and prints `INIT_PLANE_PROBE` followed by machine state (`docker`, `docker_running`, `compose`, `selfhost_dir`, `setup_sh`, `plane_config`, `plane_running`, `configured`, `default_url`). **Drive the wizard from that state — do one step, confirm, then the next. Never echo the API token back to the user.**

The flow:

1. **Prerequisites.** Plane self-host needs **Docker + Docker Compose running** (≈4 GB RAM, 2 cores).
   - `docker: no` → tell the user to install **Docker Desktop** (`https://www.docker.com/products/docker-desktop/`) and re-run. Stop here.
   - `docker_running: no` → tell them to start Docker Desktop, then re-run. Stop here.
   - `compose: no` → their Docker is too old; updating Docker Desktop bundles Compose.

2. **Download Plane's installer.** Run `init-plane fetch` — downloads Plane's official `setup.sh` into the managed dir and makes it executable. Confirm `INIT_PLANE_FETCHED`.

3. **Bring Plane up.** Run `init-plane up` — this launches Plane's **own interactive installer** (`setup.sh`) with a menu (Install / Start / Stop / Restart / Upgrade / View Logs / Backup). First time: choose **Install** (a sizeable Docker pull — minutes), then **Start**. Plane owns its own lifecycle through this menu; pbrain doesn't reimplement it. When it's up, the app is at **http://localhost** (port 80). (If `up` reports `INIT_PLANE_NEED_FETCH`/`INIT_PLANE_NEED_DOCKER`, handle that first.)

4. **Move Plane to its stable URL (default, folded into `up`).** PB-113: `init-plane up` now moves Plane off port 80 to **http://plane.localhost:1800** automatically, right after the stack is up — no separate step — so the URL never collides with another local app on port 80 and stays stable across restarts, and the account/workspace you create below all live at the final URL. (Pass `up --no-vhost` or `up --port 80` to stay on bare `http://localhost`.) The standalone `init-plane vhost` command remains for re-applying with a custom `--host`/`--port` or reverting (`vhost --remove`). It edits Plane's OWN `plane.env` (`APP_DOMAIN` + `LISTEN_HTTP_PORT`, which Plane substitutes into `WEB_URL`/`CORS_ALLOWED_ORIGINS` itself) and restarts the Plane stack. No sidecar proxy, no Node, no `/etc/hosts` — Plane's built-in Caddy listens host-agnostically on the new port, so the browser's vanity URL (resolved free by RFC 6761) and pbrain's loopback (`http://127.0.0.1:1800`) hit the same backend. (pbrain's `base_url` is set automatically when you wire it in step 7; nothing to re-point yet here.) Flags: `--host` (default `plane.localhost`), `--port` (default `1800`), `--plane-home` (override env-file discovery), `--no-restart` (edit only). To stay on plain `http://localhost` instead, **skip this step** (or undo it later with `init-plane vhost --remove`).

5. **Create the account + structure (browser, guide the user).** Open **http://plane.localhost:1800** → sign up (first user is the admin) → create a **workspace** (note its **slug** from the URL, e.g. `plane.localhost:1800/my-workspace` → `my-workspace`) → create a **project** (note its **project id** from Project → Settings, or the URL). Suggest they model their umbrella parts as **Modules** (Frontend / Backend / Security), larger tasks as **Issues**, and subtasks as **Sub-issues** — that mirrors pbrain's hierarchy. (If you ran `up --no-vhost`, this is **http://localhost** instead.)

6. **Generate a token.** In Plane: **Profile Settings → Personal Access Tokens → Add personal access token** → copy it. Ask the user to paste it to you (handle it as a secret — don't print it back).

7. **Wire pbrain → Plane.** Run:
   ```
   init-plane config --api-key <token> --workspace <slug> --project <project-id>
   ```
   The base URL is auto-detected from Plane's `plane.env` — `http://127.0.0.1:1800` once the vhost is applied (the `up` default), else `http://localhost`; pass `--base-url` only when your self-host isn't at the default local URL (e.g. it runs on another machine or behind a custom domain). This writes `~/.config/pbrain/plane.json` (mode `0600`, **never** synced to the vault). Confirm `PLANE_CONFIGURED`.

8. **Verify.** Run `/project-manager test` (should list your project's states) and `/project-manager ready` (your ready issues). If you see `PLANE_ERROR`, relay it — usually a bad token, wrong workspace/project, or Plane not fully started yet — and help fix it; don't loop.

After this, `/plan-my-work` pulls ready issues from Plane into the day's blocks and `/end-of-day` writes their status back.

9. **Package as a desktop app (optional, macOS).** Run `init-plane app` to wrap the running Plane instance in a native macOS app — a **Tauri v2 shell** (source in `lib/plane-app/`) that registers a `plane://` URL scheme so issue links **deep-link straight into the app** — and install it to `/Applications` (opens maximized, 1400×900 restore size, overlay title bar, in-app Find with `Cmd+F`, Plane logo icon). It's idempotent (re-run to rebuild) and `--remove` deletes it. The app's start URL **and** the `plane://` deep-link target are templated from the resolved Plane URL at build time. This replaces the old Pake build (Pake ignored any URL passed on launch, so it couldn't deep-link); the `Cmd+Shift+P` global hotkey from that build is not carried over. Two things to surface (the script also prints them):
   - **The Tauri toolchain is required** but not auto-installed — if `cargo: no` or `tauri_cli: no` in probe, tell the user to install Rust (`https://rustup.rs`) then `cargo install tauri-cli --version "^2"`, and re-run. (Sentinel: `INIT_PLANE_APP_NEED_TAURI`.)
   - **The `/etc/hosts` caveat.** If Plane is on the `plane.localhost:1800` vhost, the app needs `127.0.0.1 plane.localhost` in `/etc/hosts`, or it loads a **blank white screen**. This is *specific to the app* and does **not** contradict the vhost step's "no `/etc/hosts`" note: browsers (and pbrain's loopback client) resolve `*.localhost` for free via RFC 6761, but the app's macOS webview resolves through the OS, which has no such shortcut. The command detects an unresolvable host and prints the exact one-line fix (`echo "127.0.0.1 plane.localhost" | sudo tee -a /etc/hosts`) for the user to run — it never runs sudo itself. The app also only works while Plane's Docker containers are up. Flags: `--name` (default `Plane`), `--url`, `--host`, `--port`, `--icon`, `--no-install` (build without copying to `/Applications`), `--remove`, `--plane-home`.

## GitHub integration (optional, separate subcommand)

`init-plane github` wires Plane's **GitHub integration** (two-way issue ↔ GitHub-issue sync, PR/commit linking) by writing the `GITHUB_*` + `SILO_BASE_URL` knobs into Plane's own `plane.env` and restarting the stack — the same `plane.env`-editing approach as `vhost`. It's **independent of the core setup** above; run it only if the user wants GitHub sync.

**Two caveats to surface up front (the script also prints them):**
1. The integration runs on Plane's **`silo`** service, which ships with Plane's **Commercial / "govern" layer** — it is **not** part of the free Community stack that `up` installs. If `silo_running: no`, the integration likely won't activate on this build. Don't promise it works on a plain Community self-host.
2. **GitHub must be able to reach the instance** for OAuth callbacks + webhooks. A `localhost` / `127.0.0.1` URL won't work — the user needs a **public HTTPS URL** (a real domain or a tunnel like cloudflared/ngrok) passed as `--silo-base-url`.

Flow:

1. **Show the guide.** Run `init-plane github` (no flags) → prints `INIT_PLANE_GITHUB_GUIDE` with the exact GitHub-App settings to create, with callback/webhook URLs prefilled from the silo base URL (derived from `plane.env`'s `APP_DOMAIN`, override with `--silo-base-url`). Walk the user through creating the **GitHub App** (GitHub → Settings → Developer settings → GitHub Apps → New): homepage, both callback URLs, post-install setup URL + "Redirect on update", webhook URL, **disable "Expire user authorization tokens"**, the repo/account permissions, the event subscriptions, then generate a **client secret** + **private key (.pem)** and note **App ID / Client ID / App name**. Make the app **Public**.
2. **Wire it in.** Run:
   ```
   init-plane github --app-name <name> --app-id <id> --client-id <id> \
     --client-secret <secret> --private-key /path/to/private-key.pem \
     --silo-base-url https://<public-host>
   ```
   `--private-key` takes the **.pem file path**; the script base64-encodes it into `GITHUB_PRIVATE_KEY` (it never prints the secret). All five credential flags are required; the base URL defaults to `http://<APP_DOMAIN>` if `--silo-base-url` is omitted (and warns if that's local). Confirm `INIT_PLANE_GITHUB`.
3. **Activate in Plane.** In Plane → Workspace Settings → Integrations → GitHub → Connect, install the app on the user's repos, then connect a repo to a project.

`--no-restart` edits `plane.env` without bouncing the stack; `--remove` strips only the `GITHUB_*` + `SILO_BASE_URL` keys (leaving `vhost`'s `APP_DOMAIN`/`LISTEN_HTTP_PORT` untouched) and restarts. `init-plane status` / `probe` now also report `silo_running` and `github_configured`.

`init-plane status` shows Docker + Plane container state + whether pbrain is configured at any time. Everything is idempotent — re-running never double-installs or clobbers an existing config.
