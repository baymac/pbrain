# pbrain — Tool Development Context

This is the **pbrain tooling repo**. You are in the outer repo, not the vault.

- Write code here: scripts, slash commands, templates, docs.
- Write notes in the vault (open a separate CC session from the vault).
- Never create personal notes, ideas, or journal entries here.

See `README.md` for the full spec and architecture.

## Vault location

The plugin is path-agnostic — works against any vault directory the user marks. Resolution order in `lib/vault.sh`:

1. `$PBRAIN_VAULT` env var, 2. path written in `~/.config/pbrain/vault`, 3. default `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault`.
4. **Zero-config fallback**: if nothing above is configured (no `$PBRAIN_VAULT`, no config file) and the default iCloud path doesn't exist, `lib/vault.sh` auto-creates a plain local vault at `~/pbrain-vault` (via the shared `lib/scaffold.sh` — git init + `.gitignore` + `CLAUDE.md` + initial commit + config file, exactly like `/init-obsidian bootstrap`, with git treated as optional) and continues, so commands never hard-fail on a fresh machine without Obsidian. Only the unset (default) case auto-creates — an explicit but missing env/config path still errors (a typo shouldn't silently spawn a vault elsewhere). `PBRAIN_NO_AUTOVAULT=1` opts back into the hard-fail.

This user's actual vault is at the default iCloud path. It's a standalone git repo (not a submodule), in iCloud Drive for iOS sync.

## Where agents write in the vault

When Claude (or any agent) writes content into the vault, it goes under `agent-work/`. User-curated folders (life/, fitness/, startup/, daily/, etc.) are off-limits — never write or modify those without explicit instruction.

| Subdir | Contents |
|---|---|
| `agent-work/brainstorms/tbd/` | `/brainstorm` outputs (active, default landing). |
| `agent-work/brainstorms/backlog/` | Parked ideas — not now, not dropped. Manually moved by user. |
| `agent-work/brainstorms/done/` | Actioned, shipped, or set aside. Manually moved by user. |
| `agent-work/chat-history/` | Chat session takeaways saved on request |
| `agent-work/drafts/` | Drafts of blog posts, docs, longer writeups |
| `agent-work/notes/` | Misc captured notes from agent conversations |
| `agent-work/research/` | Research outputs, web summaries, references |
| `agent-work/people/` | People pages (auto-enriched contacts from gbrain or hand-written) |
| `agent-work/clips/<platform>/` | `/clipper` outputs — videos saved as clean, faithful transcripts (`x/`, `yt/`). |
| `agent-work/daily-grooming/` | `/project-manager groom` outputs (PB-94) — per-day grooming data: todo-only triage, ordered run queue, enrichment log. Full mechanics (quality gate, autonomous mode, scoping) in `commands/project-manager.md`. One `<date>.md` per day, iCloud-synced. |
| `agent-work/summaries/<type>/` | `/summarize` outputs — vault folders summarized via a per-type prompt (`webinar/`). |

If a new content type doesn't fit any of these, ask before creating a new subdir.

**Daily journal lives at `vault/life/daily-tracking/YYYY-MM-DD.md`** — not under `agent-work/`, because it's user-owned content. `/journal` creates a stub for the user to fill in; the content is the user's personal log, not agent output.

**`/laptop-tracking` writes `vault/life/laptop-tracking/YYYY-MM-DD.md`** — also a sanctioned `life/` path (a derived per-day usage report, domain-level only). The granular DB stays local at `~/.config/pbrain/tracker.db` and is never synced to the vault.

## Morning sequence (journal → gratitude → everything else)

The day starts on `/journal` (a raw brain dump that clears the head), then `/gratitude-journal` (anchors baseline on cleared ground). When the user invokes any other slash command — or asks for personal reflection / capture / brainstorming — check today's files in order: (1) if `vault/life/daily-tracking/YYYY-MM-DD.md` is missing, suggest `/journal`; (2) else if `vault/life/gratitude-journal/YYYY-MM-DD.md` is missing, suggest `/gratitude-journal`; (3) otherwise proceed. **Suggest once, never block** — the user can override and continue.

Exempt (never trigger the check): `/journal`, `/gratitude-journal`, `/init-obsidian`, `/codex-install`, `/remind`, `/thoughts`, `/discuss`, `/laptop-tracking`, `/loose-ends`, `/vault-backup`. `/habits` is **not** exempt (it runs after the morning sequence). **Overridable by a standing preference**: if the user's injected USER PREFERENCES block says to skip the journal/gratitude nudge, don't make it — the morning-sequence skip is a *global* preference at `.pbrain/_global/prefs.md`. More broadly, any built-in suggestion/nudge yields to a standing preference that silences it.

## Linking a Claude Code chat to a filed issue ("ref chat")

When you file a `/project-manager` Plane issue from a Claude Code session **and** the user says to reference the chat (e.g. "ref chat", "ref this chat", or equivalent), append this exact line to the **bottom of the issue description** (last line): `---` then `Claude Code chat ref: <full path to the current session .jsonl>`. Resolve the path as `~/.claude/projects/<sanitized-cwd>/<session-id>.jsonl` (cwd with `/`→`-`, session UUID); verify it exists first (`find ~/.claude/projects -name '<session-id>.jsonl'`) and say so rather than guessing if it can't be resolved.

Rules: the ref goes in the description body, not a comment (`update --edits` replaces the whole `description` field, so re-send the full existing text with the ref appended); only add it when asked, never automatically; one ref line per issue — replace, don't stack, if one already exists.

## Nightly-groom flow doc — keep it in sync

`docs/nightly-groom-flow.html` is the source-of-truth flow diagram for the nightly groom (launchd entry → mechanical scan → autonomous judgment pass → vault write). **Whenever you change the groom flow — `lib/pbrain-groom.swift`, `lib/pm-groom.sh`, the groom pieces of `lib/plane.py`, `commands/templates/project-manager/groom-drive.txt`, `lib/hooks/groom-triage-guard.sh`, or any new env var/branch/phase/invariant in those — update this doc in the same change**: edit the affected node + the footer's "traced from / invariants" line; redraw the whole lane (don't just append a note) if a phase goes obsolete.

## Repository layout (monorepo)

**Every file's own header comment/docstring is the source of truth for its implementation detail** — this section only maps names to purpose in one clause; don't duplicate a header's content here, and don't let this list substitute for reading the header. Slash-command behavior is in the index further down + each `commands/<cmd>.md`.

```
pbrain/
├── .claude-plugin/plugin.json   ← Claude plugin manifest (this repo IS the plugin)
├── commands/                    ← all slash command .md + .sh pairs (see the index below; spec in each commands/<cmd>.md)
├── lib/vault.sh                 ← shared VAULT_DIR resolver, sourced by every command
├── lib/scaffold.sh              ← vault-scaffold helpers (mkdir + git init + config); used by init-obsidian.sh and vault.sh's auto-fallback
├── lib/update-check.sh          ← upgrade nudge
├── lib/prefs.sh                 ← per-command preference injection
├── lib/self-improve.sh          ← feedback capture (see "Self-improvement loop" below)
├── lib/profile.sh               ← fenced-JSON-block extractor for profile files
├── lib/profiles.sh              ← versioned profile store (.profile/<base>.vN.md)
├── lib/projects.sh              ← shared Plane seam layer for the daily loop
├── lib/plane.py                 ← pbrain ↔ Plane backend (multi-project, stdlib urllib); the sole project source
├── lib/plane-backup.sh          ← /project-manager backup: pg_dump + uploads snapshot → local/external/vps, restore
├── lib/vault-backup.sh          ← /vault-backup: off-iCloud vault snapshot → local/external/vps, restore
├── lib/plane-host.sh            ← /project-manager host: move Plane off localhost onto a VPS
├── lib/migrations.sh            ← migration runner (see "Versioned profiles + migrations" below)
├── lib/migrations/              ← the ordered migration scripts (each self-documents)
├── lib/db.sh                    ← shared SQLite store (habit events + reminder queue) + separate tracker.db for /laptop-tracking
├── lib/launchd.sh               ← native-helper build + LaunchAgent helpers
├── lib/habits.sh                ← habits profile + md tracking + scored-habit evaluator
├── lib/habit_schedule.py        ← habit schedule engine (is_due / derive_schedule / spacing)
├── lib/profile_lock.py          ← atomic read-modify-write helper for the habits profile JSON block
├── lib/reminders.sh             ← /remind (Apple Reminders) + /remind-blocking (overlay poller)
├── lib/pbrain-reminders.swift   ← EventKit Reminders helper source
├── lib/pbrain-notify.swift      ← macOS notifier source (overlay's no-swiftc fallback)
├── lib/pbrain-overlay.swift     ← full-screen blocking-overlay source (/remind-blocking)
├── lib/assets/chime.mp3         ← bundled lifecycle chime for the overlay
├── lib/pbrain-tracker.swift     ← /laptop-tracking daemon source (resident LaunchAgent)
├── lib/whats-new.sh             ← per-release "what's new" doc, surfaced once on update
├── scripts/release.sh           ← reproducible release pipeline; sole writer of VERSION + plugin.json. See docs/release.md
├── tests/                       ← bats tests for the shared lib/ helpers
├── docs/                        ← one short user-facing doc per command
├── gbrain/                      ← gbrain operations (separate from the plugin): scripts/, launchd/, docs/, .logs/ (gitignored)
├── promo-video/                 ← HyperFrames source composition for the promo video (renders gitignored)
├── CLAUDE.md
└── README.md
```

There's no `.claude/commands` symlink at the repo root — by design. Slash commands go live globally via a one-time `ln -s <repo>/commands ~/.claude/commands` (see README's Quick start). The tooling repo is for editing, the vault is for running.

## Conventions for editing scripts

- Shell: `#!/usr/bin/env bash` with `set -euo pipefail` on every script.
- Complex logic (JSON parsing, markdown conversion): inline Python 3 heredoc inside the shell script. No external deps — stdlib only (no pip packages). Modules in use: `json`, `re`, `sys`, `os`, `datetime`, `calendar`, `sqlite3`, `subprocess`, `shutil`, `glob`, `random`, `collections`, `uuid`. (`sqlite3` is Python stdlib — the shared store in `lib/db.sh` uses it, not the `sqlite3` CLI binary.)
- Scripts must be idempotent. Re-running on unchanged state should produce the same result without side effects.
- All `.sh` files must be executable (`chmod +x`).
- Slash command sources live **only** in `commands/`. Commands become available globally via `~/.claude/commands` → `<repo>/commands` (one-time user symlink). Never duplicate sources elsewhere.
- gbrain operational scripts live in `gbrain/scripts/`. Never mix plugin commands with gbrain scripts.
- **URLs in chat output (PB-95).** `pbrain_emit_prefs` ships a baseline CHAT OUTPUT HYGIENE rule on every command run telling the agent to wrap chat URLs as `[label](url)` or in backticks and never paste a bare URL with punctuation jammed against it (the renderer swallows a trailing `.,;:)]}>` into the link target and breaks it). Author instruction text and `echo`s the same way: prefer backtick-wrapped or markdown-link URLs over bare `(https://…)` / `https://…​.` in any `.md`/`.sh`/`.txt` the agent reads or relays.
- **Never hardcode the vault path in a command.** Source the shared resolver (`_SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"; source "$_SCRIPT_DIR/../lib/vault.sh"`, `pwd -P` so it works whether invoked via the vault's symlink or directly) and use the resulting `$VAULT_DIR`, with an optional per-command override like `FOO_DIR="${PBRAIN_FOO_DIR:-$VAULT_DIR/some/sub/path}"`.
- Python heredocs that need vault paths: pass them as argv (`python3 - "$VAULT_DIR" <<'PYEOF' ... sys.argv[1] ...`). Do NOT use `os.path.expanduser` on a hardcoded path.
- Slash command `.md` files use `${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/<name>.sh` — three-tier resolution: `PBRAIN_DEV_DIR` (local dev override, edits take effect immediately) → `CLAUDE_PLUGIN_ROOT` (set by the harness for a plugin install) → the marketplace path fallback (must stay absolute — a slash command's cwd is the *user's project*, e.g. a Conductor workspace, not the pbrain repo).

## Slash commands

Sources live in `commands/`. Available in every CC session once the user symlinks `~/.claude/commands` → this repo's `commands/`, or after `/plugin marketplace add baymac/pbrain` + `/plugin install pbrain@pbrain` once it's published.

**The per-command contract lives in each `commands/<cmd>.md`** (the spec the agent reads when running/editing the command); user-facing docs are `README.md` (overview) + `docs/<command>.md`. **Env vars:** see README.md's env-var table and each command's `.sh` defaults. The index below is name + default write path only — do not re-expand a command's behavior here; that duplicates its `.md` and drifts out of sync with it.

| Command | Default write path |
|---|---|
| `/init-obsidian` | `~/.config/pbrain/vault` |
| `/init-plane` | `~/.config/pbrain/plane.json` |
| `/journal` | `life/daily-tracking/<date>.md` |
| `/brainstorm <topic>` | `agent-work/brainstorms/tbd/` |
| `/discuss <topic>` | `agent-work/notes/` |
| `/diet-journal` | `fitness/diet-tracking/` |
| `/fitness-journal` | `fitness/daily-tracking/` |
| `/finance` | `life/finance-tracking/<YYYY-MM>.md` |
| `/gratitude-journal` | `life/gratitude-journal/` |
| `/plan-my-day` | `life/daily-planning/<date>.md` |
| `/plan-my-work` | Plane only (no vault write) |
| `/end-of-day` | `life/daily-planning/<date>.md` |
| `/weekly-review` | `life/weekly-tracking/YYYY-Www.md` |
| `/monthly-review` | `life/monthly-tracking/YYYY-MM.md` |
| `/thoughts [<text>]` | `life/thought-tracking/<date>.md` |
| `/recall <query>` | — (read-only) |
| `/loose-ends` | — (read-only) |
| `/organize-clippings` | user-chosen vault dirs |
| `/habits` | `life/habit-tracking/` |
| `/remind <text>` | Apple Reminders (no vault write) |
| `/remind-blocking <text>` | SQLite DB (no vault write) |
| `/laptop-tracking` | `life/laptop-tracking/<date>.md` |
| `/project-manager` | Plane (no vault write) |
| `/vault-backup` | `~/.config/pbrain/vault-backups/` |
| `/clipper <platform> <url>` | `agent-work/clips/<platform>/<slug>.md` |
| `/summarize <type> <folder>` | `agent-work/summaries/<type>/<slug>.md` |
| `/codex-install` | `$CODEX_HOME/skills/pbrain-<cmd>/` |

A few invariants worth stating here because they cut across commands and aren't obvious from any single `.md`: **`/plan-my-work` is the only command that touches code, branches, PRs, or merges** (a fixed 5-stage pipeline — plan/implement/test/ship/land — gated per-stage by `auto:<stage>` labels; nothing auto-merges, ever). **`/project-manager` is the sole writer of Plane** — all other commands read Plane through it, never directly. **State for the daily work loop lives in Plane only** (no vault `## Work tracker`) — `/plan-my-work` and `/end-of-day` read/write it via `/project-manager spec/move/comment`.

`/init-obsidian`, `/codex-install`, and `/init-plane` are the commands that don't go through `lib/vault.sh` — they're setup commands that must run before/around a vault being configured (or, for `/init-plane`, need no vault at all). `/init-obsidian` writes the config every other command reads; `/codex-install` only reads it (read-only resolve, never exits if absent); `/init-plane` is independent of the vault entirely. (`/remind-blocking tick`, the background poller path, also bypasses `lib/vault.sh` on purpose — it only needs the DB, and must not exit when no vault dir exists.)

### Versioned profiles + migrations

**Every profile-owning command keeps its base config in a versioned store** (`lib/profiles.sh`): `<tracking-dir>/.profile/<base>.vN.md` — markdown + frontmatter (`version: N`, `committed: true|false`) + a fenced ```json block (read with `pbrain_profile_json`). The rules:

- Commands READ the highest **committed** version (`pbrain_profile_latest`). An explicit `PBRAIN_<X>_PROFILE_FILE` env override always wins (no versioning, also bypasses that command's staged-migration prompt).
- **Committed = final.** Changes mint the next version: each owning command exposes `profile show|new|commit [base]` — `new` mints an editable draft (copied from the latest; refuses while a draft is open), `commit` freezes it. `/weekly-review`'s Improvements walk drives this for approved week-end changes.
- **Libraries are living documents** (food-library, work-library, goals-library, fitness-library; the habits profile behaves the same for `add`/`edit`/`archive`): entries append/amend in place on the latest version — version mints only on structural rebuilds.
- Which `.profile/` bases each command owns is listed in its `commands/<cmd>.md` (plan-my-day, habits, fitness-journal, diet-journal).

**Migrations** (`lib/migrations.sh` + `lib/migrations/<NNNN_slug>.sh`) move pbrain from one state to another exactly once, DB-migration style: the applied-set ledger is `$VAULT_DIR/.pbrain/migrations/<id>.done` — correctness is **ledger-based, not semver-based**. Three kinds (declared by `MIGRATION_KIND`): **auto** — pure local data moves, applied silently by `pbrain_run_migrations` on every command run. **staged** — needs an LLM rebuild validating old data with the user; stays pending until the owning command's next run emits the rebuild block. **effectful** — mutates an external/live system (e.g. re-pointing Plane issues); never fires on the silent hot path, only when opted in (`bash lib/migrations.sh run --effectful` or `PBRAIN_MIGRATIONS_EFFECTFUL=1`); the migration body must be idempotent. `PBRAIN_MIGRATIONS=0` disables the runner entirely.

**Editing a migration that hasn't shipped yet — don't stack a new one on top.** A migration is "live" only once merged to `main` (and may already sit in someone's ledger). If the prior migration is still unmerged, **edit it in place** instead of appending a next-numbered one — ask the user whether they want a new migration or a fold-in first. Why: an unmerged migration has no ledger entries anywhere, so rewriting it is safe; a merged one is immutable history that only a new higher-numbered migration may change.

### Upgrade prompt

Commands that source `lib/vault.sh` run a cached version check (`lib/update-check.sh`), **skipped on dev installs** (`PBRAIN_DEV_DIR` set — a dev clone updates via git and may legitimately differ from the marketplace line). When the local install is behind, stdout includes a single line `UPGRADE_AVAILABLE <local> <remote>`. On seeing it: briefly tell the user a newer pbrain is out, suggest `/plugin update pbrain`, link the changelog (`https://github.com/baymac/pbrain/blob/main/CHANGELOG.md`), then continue the real work — it's a nudge, not a gate (cached, so it may re-appear once per cache window until they upgrade).

### Self-improvement loop

Two helpers in `lib/prefs.sh` + `lib/self-improve.sh`, sourced through `lib/vault.sh` (mechanics in their headers). `pbrain_emit_prefs <cmd> [profile-file]` injects standing prefs (`_global/prefs.md` then per-command — a profile-owning command's prefs live in its profile's `prefs` array, else `.pbrain/<cmd>/prefs.md`) near the top of every command's output; these override built-in defaults/nudges for the session. Prefs live in the vault so they sync across devices (`PBRAIN_PREFS_DIR` overrides). `pbrain_emit_self_improve_batch <date>` is the **sole** self-improve mechanism, run once daily at the tail of `/end-of-day`: it mines that day's Claude Code transcripts for corrections the user made (even ones never flagged "remember this") and proposes each under a classify→propose→explicit-yes→act discipline — a PREFERENCE writes to prefs, a QUALITY FIX logs to the write-only `<cmd>/feedback.md` and is optionally raised as a GitHub issue. Gated by `PBRAIN_SELF_IMPROVE_BATCH` (default on) and `PBRAIN_SELF_IMPROVE=off` (full disable); neither helper ever exits non-zero. Tests: `tests/self-improve.bats`.

### Shared SQLite layer + habit extraction

`lib/db.sh`, `lib/habits.sh`, `lib/reminders.sh` (sourced through `lib/vault.sh`) back `/habits` and `/remind-blocking` on one local SQLite DB (`~/.config/pbrain/pbrain.db`, override `PBRAIN_DB_FILE`); `/remind` is Apple-Reminders-only, no DB. **Habit logging is markdown-first** — the dated checklist (`life/habit-tracking/<date>.md`) is the source of truth; the DB is derived from it via `commands/habits.sh mark`, never written directly. `pbrain_emit_habits_extract <cmd>` is silent when no habits profile exists, so it costs nothing until the user opts in. Full wiring lives in `commands/habits.md`, `commands/remind.md`, and the `lib/habits.sh`/`lib/reminders.sh` headers. Tests: `tests/db.bats`, `tests/habits.bats`, `tests/reminders.bats`.

### Codex interoperability

pbrain is a Claude Code plugin first; the OpenAI **Codex CLI** is a supported *secondary* runner. The invariant: **the `.sh` files are the agent-agnostic single source of truth** — nothing in them is Claude-specific, and you must **not fork behaviour per agent**. `/codex-install` (run from Claude Code after `/init-obsidian`) generates Codex entry points from the same `commands/*.md` sources — one `skills/pbrain-<cmd>/SKILL.md` per command + a managed, delimited `AGENTS.md` block — and shares one vault / config dir / DB / script set with Claude Code, so alternating runners is safe and re-running the installer is idempotent. The skill-body-transform mechanics + the why-skills-not-custom-prompts rationale live in `commands/codex-install.sh` / `docs/codex-install.md`. Tests: `tests/codex-install.bats`.

## Stack

- **Obsidian** — GUI for browsing and editing vault notes. First-time setup: run `/init-obsidian` from this repo.
- **pbrain plugin** — slash commands that read/write the vault. User docs: `README.md` (root) + `docs/<command>.md`.
- **gbrain** — hybrid vector + keyword search over vault, MCP server for Claude sessions. Setup: `gbrain/docs/setup.md`.
- **vault/** — markdown corpus (standalone git repo, location user-configurable); source of truth for all notes.

## What not to do here

- Don't write notes or ideas in the outer repo — use the vault at `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault`.
- Don't edit `~/.claude/commands/` directly if it's symlinked here — edit `commands/` in this repo instead (the symlink points back here, so it's the same files either way).
- Don't put gbrain scripts under `commands/` or `lib/`. Plugin = slash commands only. Gbrain ops = `gbrain/`.
- Don't `bun install -g github:garrytan/gbrain` — broken postinstall hook. Clone and link manually (see `gbrain/docs/setup.md`).
