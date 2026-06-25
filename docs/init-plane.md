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
| `/init-plane github [flags]` | Configure Plane's GitHub integration (two-way issue/PR sync) by writing `GITHUB_*` + `SILO_BASE_URL` into `plane.env`. No flags → print the GitHub-App setup guide; `--remove` strips the keys. See below. |
| `/init-plane app [flags]` | Package the running Plane instance as a native **macOS** app (a Tauri shell with a `plane://` deep-link scheme) and install it to `/Applications`. Idempotent; `--remove` deletes it. See below. |
| `/init-plane status` | Docker + Plane container + whether pbrain is configured (+ `silo_running`, `github_configured`). |

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

## GitHub integration (optional)

`/init-plane github` wires Plane's **GitHub integration** — two-way sync between Plane work items and GitHub issues, plus PR/commit linking. It edits Plane's own `plane.env` (the `GITHUB_*` credentials + `SILO_BASE_URL`) and restarts the stack, just like `vhost`. It's optional and independent of the main setup.

Run it with no flags first to print the setup guide:

```bash
/init-plane github
```

That prints the exact **GitHub App** to create (GitHub → Settings → Developer settings → GitHub Apps → New), with the callback/webhook URLs prefilled. Then wire it in:

```bash
/init-plane github \
  --app-name <name> --app-id <id> --client-id <id> \
  --client-secret <secret> --private-key /path/to/private-key.pem \
  --silo-base-url https://<public-host>
```

`--private-key` takes the **.pem path** (the script base64-encodes it into `GITHUB_PRIVATE_KEY`; the secret is never printed). Other flags: `--silo-base-url` (defaults to `http://<APP_DOMAIN>` from `plane.env`), `--plane-home`, `--no-restart`, `--remove` (strips only the GitHub keys). Finally connect the app in Plane → Workspace Settings → Integrations → GitHub.

**Two caveats:**
- The integration runs on Plane's **`silo`** service, part of Plane's **Commercial / "govern" layer** — it isn't bundled in the free Community stack `up` installs. If no `silo` container is running, it likely won't activate on that build.
- **GitHub has to reach your instance** for OAuth + webhooks, so a `localhost` URL won't work — point `--silo-base-url` at a **public HTTPS URL** (a real domain or a tunnel like cloudflared/ngrok).

## Package as a macOS desktop app (optional) — with deep linking

`/init-plane app` wraps your running Plane instance in a **native macOS app** — a small [Tauri v2](https://tauri.app) shell whose source ships with pbrain at `lib/plane-app/` — and installs it to `/Applications`, so Plane lives in your Dock, Spotlight, and Launchpad like any other app. The window is 1400×900 with an overlay title bar, in-app Find (`Cmd+F`), and the Plane logo as the icon.

The headline feature is **deep linking**: the app registers a `plane://` URL scheme, so a link like `plane://pb/browse/PB-110` opens that exact issue *inside the app* instead of a browser tab. (This replaces an earlier Pake-based build, which couldn't deep-link because Pake ignores any URL passed to it on launch.)

```bash
/init-plane app                 # build + install /Applications/Plane.app
/init-plane app --remove        # quit + delete the app

# open an issue in the app:
open 'plane://pb/browse/PB-110'
# or convert a normal browser link first:
lib/plane-app/plane-open.sh 'http://plane.localhost:1800/pb/browse/PB-110'
```

It's **idempotent** — re-run to rebuild and replace the installed copy. After install the unsigned app's Gatekeeper quarantine flag is cleared (so it opens without the "unidentified developer" prompt) and the `plane://` scheme is registered with Launch Services (macOS only binds a custom scheme from an app under `/Applications`).

**Deep-link-aware vault links.** Once the app is installed, pbrain's grooming queue (`/project-manager groom` → `agent-work/daily-grooming/<date>.md`) writes issue links as `plane://` deep links instead of `http://`, so clicking one in Obsidian opens the issue in the app. Without the app installed (or on non-macOS) the links stay plain `http://` and open in your browser, exactly as before. Force either form with `PBRAIN_PLANE_DEEPLINK=1` / `=0`.

**Prerequisite — the Tauri toolchain.** The command does *not* auto-install it (the same guide-don't-install stance as `up` with Docker). If `cargo` or the Tauri CLI is missing you'll get `INIT_PLANE_APP_NEED_TAURI`; install once and re-run:

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # Rust (if you don't have cargo)
cargo install tauri-cli --version "^2"                           # the Tauri v2 CLI
```

The first build compiles a Rust binary and takes a few minutes; subsequent rebuilds are incremental.

**The `/etc/hosts` caveat (app-specific).** If Plane is on the default `http://plane.localhost:1800` vhost, the app needs a one-time `/etc/hosts` entry or it loads a **blank white screen**:

```bash
echo "127.0.0.1 plane.localhost" | sudo tee -a /etc/hosts
```

This does **not** contradict the `vhost` section's "no `/etc/hosts`" note — that note is true for the **browser** and for **pbrain's loopback client**, both of which resolve `*.localhost` to `127.0.0.1` for free (browsers via RFC 6761, pbrain via the numeric `127.0.0.1` URL). The desktop app is the one consumer that's different: its **macOS WebView resolves hostnames through the OS resolver, which has no `*.localhost` shortcut**, so the name has to actually resolve. The command detects an unresolvable host and prints the exact `sudo` line above for you to run — it never runs sudo itself. (Stay on plain `http://localhost`? Then no hosts entry is needed at all.)

The app's start URL **and** its `plane://` deep-link target are both templated from the resolved Plane URL at build time, so a custom `--url`/`--host`/`--port` (or a VPS host) carries through to both. The app **only works while Plane's Docker stack is running**, and the first launch shows Plane's login screen — after you sign in, deep links land on the requested issue.

Flags: `--name` (default `Plane`), `--url` (override the target URL), `--host` / `--port` (compose a URL without `--url`), `--icon` (PNG URL/path; defaults to the Plane logo), `--no-install` (build the `.app` without copying to `/Applications`), `--remove` (quit + delete the installed app), `--plane-home` (env-file discovery override). **macOS only** — on other platforms it prints `INIT_PLANE_APP_UNSUPPORTED`.

## Notes

- The **token is a secret** — it lives only in `~/.config/pbrain/plane.json` (local, `0600`), never in the vault or git.
- Plane self-host is a real Docker stack (Postgres, Redis, MinIO, app services). For a solo machine 4 GB RAM is the floor; close it down from the `setup.sh` menu when you don't need it.

## Overrides

| Env var | Default |
|---|---|
| `PBRAIN_PLANE_HOME` | `~/.config/pbrain/plane-selfhost` (where `setup.sh` + Plane's data live) |
| `PBRAIN_PLANE_BASE_URL` / `PBRAIN_PLANE_API_KEY` / `PBRAIN_PLANE_WORKSPACE` / `PBRAIN_PLANE_PROJECT` | env overrides for the written config |
