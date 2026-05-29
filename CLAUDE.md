# pbrain — Tool Development Context

This is the **pbrain tooling repo**. You are in the outer repo, not the vault.

- Write code here: scripts, slash commands, templates, docs.
- Write notes in the vault (open a separate CC session from the vault).
- Never create personal notes, ideas, or journal entries here.

See `README.md` for the full spec and architecture.

---

## Vault location

The plugin is path-agnostic — works against any vault directory the user marks. Resolution order in `lib/vault.sh`:

1. `$PBRAIN_VAULT` env var
2. Path written in `~/.config/pbrain/vault`
3. Default: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault`

This user's actual vault is at the default iCloud path. It's a standalone git repo (not a submodule), in iCloud Drive for iOS sync.

---

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

If a new content type doesn't fit any of these, ask before creating a new subdir.

**Daily journal lives at `vault/life/daily-tracking/YYYY-MM-DD.md`** — not under `agent-work/`, because it's user-owned content. `/journal` creates a stub for the user to fill in; the content is the user's personal log, not agent output.

---

## Morning sequence (gratitude → journal → everything else)

The day starts on `/gratitude-journal`, then `/journal`. Both anchor the user's baseline before agent work happens.

When the user invokes any slash command other than `/gratitude-journal`, `/journal`, or `/init-obsidian` — OR asks for help with personal reflection / capture / brainstorming — check the daily files in this order:

1. **Gratitude first.** If `vault/life/gratitude-journal/YYYY-MM-DD.md` doesn't exist, suggest `/gratitude-journal` before proceeding. Gratitude lands hardest first thing — it anchors baseline to *enough* so the rest of the day runs on overflow.
2. **Then daily journal.** If gratitude exists but `vault/life/daily-tracking/YYYY-MM-DD.md` doesn't, suggest `/journal` before proceeding. Journaling surfaces what's actually on the user's mind.
3. **Otherwise proceed.**

Suggest once, never block. The user can override and continue. `/init-obsidian`, `/gratitude-journal`, and `/journal` are exempt from the check (they're the entry points).

---

## Repository layout (monorepo)

```
pbrain/
├── .claude-plugin/
│   └── plugin.json                     ← Claude plugin manifest (this repo IS the plugin)
├── commands/                           ← all slash command .md + .sh pairs
├── lib/vault.sh                        ← shared VAULT_DIR resolver (sourced by every command)
├── docs/                               ← one short user-facing doc per command
├── gbrain/                             ← gbrain operations (separate from the plugin)
│   ├── scripts/                        ← gbrain-sync-wrapper, dashboard, upgrade, install-launchd
│   ├── launchd/com.pbrain.sync.plist.template
│   ├── docs/                           ← setup (gbrain-only), gbrain-sync, gbrain-beyond-notes, gbrain-bug-report
│   └── .logs/                          ← gitignored: sync-runs.jsonl, upgrade-status.json
├── CLAUDE.md
└── README.md
```

There's no `.claude/commands` symlink at the repo root — by design. Slash commands are made available globally via a one-time `ln -s <repo>/commands ~/.claude/commands` (documented in the README's Quick start), so edits to the scripts go live in every CC session. The tooling repo is for editing, the vault is for running.

---

## Conventions for editing scripts

- Shell: `#!/usr/bin/env bash` with `set -euo pipefail` on every script.
- Complex logic (JSON parsing, markdown conversion): inline Python 3 heredoc inside the shell script. No external deps — stdlib only (no pip packages). Modules in use: `json`, `re`, `sys`, `os`, `datetime`, `subprocess`, `shutil`, `glob`, `random`, `collections`, `uuid`.
- Scripts must be idempotent. Re-running on unchanged state should produce the same result without side effects.
- All `.sh` files must be executable (`chmod +x`).
- Slash command sources live **only** in `commands/`. Commands become available globally via `~/.claude/commands` → `<repo>/commands` (one-time user symlink). Never duplicate sources elsewhere.
- gbrain operational scripts live in `gbrain/scripts/`. Never mix plugin commands with gbrain scripts.
- **Never hardcode the vault path in a command.** Source the shared resolver and use the resulting `$VAULT_DIR`:
  ```bash
  _SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  source "$_SCRIPT_DIR/../lib/vault.sh"
  # then use $VAULT_DIR plus an optional per-command override like
  # FOO_DIR="${PBRAIN_FOO_DIR:-$VAULT_DIR/some/sub/path}"
  ```
  `pwd -P` is required so sourcing works whether the script was invoked via the vault's `.claude/commands` symlink or directly.
- Python heredocs that need vault paths: pass them as argv (`python3 - "$VAULT_DIR" <<'PYEOF' ... sys.argv[1] ...`). Do NOT use `os.path.expanduser` on a hardcoded path.
- Slash command `.md` files use `${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/<name>.sh` — three-tier resolution:
  1. `PBRAIN_DEV_DIR` — local dev override. Set `export PBRAIN_DEV_DIR=/path/to/pbrain` in your shell profile to point at the live repo; edits to `.sh` files take effect immediately.
  2. `CLAUDE_PLUGIN_ROOT` — set by the Claude Code harness when running a plugin command. Points to the plugin install dir automatically.
  3. `$HOME/.claude/plugins/marketplaces/pbrain` — marketplace install fallback. Used when neither env var is set (e.g. when the Bash tool invokes the command outside the plugin system).
  The fallback must be an absolute path — slash commands run with the *user's project* as cwd, which inside a Conductor workspace is not the pbrain repo.

---

## Slash commands

Sources live in `commands/`. Available in every CC session once the user symlinks `~/.claude/commands` → this repo's `commands/`, or after `/plugin marketplace add baymac/pbrain` + `/plugin install pbrain@pbrain` once it's published. User-facing docs: `README.md` (overview + env var table) and `docs/<command>.md` (per command).

| Command | Default destination | Override env var |
|---|---|---|
| `/init-obsidian` | bootstraps a vault, optional iCloud migration + private dir + git remote, writes `~/.config/pbrain/vault` | — |
| `/journal` | `$VAULT_DIR/life/daily-tracking/` | `PBRAIN_JOURNAL_DIR` |
| `/brainstorm <topic>` | `$VAULT_DIR/agent-work/brainstorms/{tbd,backlog,done}/` | `PBRAIN_BRAINSTORMS_DIR` |
| `/diet-journal` | `$VAULT_DIR/fitness/diet-tracking/` | `PBRAIN_DIET_DIR` (+ `PBRAIN_FITNESS_DIR` for cross-ref, `PBRAIN_DIET_PLAN_FILE` → `$VAULT_DIR/fitness/Diet Plan.md`, `PBRAIN_DIET_PROFILE_FILE` → profile JSON at `~/.config/pbrain/diet-profile.json`) |
| `/fitness-journal` | `$VAULT_DIR/fitness/daily-tracking/` | `PBRAIN_FITNESS_DIR` (+ `PBRAIN_GYM_PLAN_FILE`, `PBRAIN_FITNESS_PLANS_DIR` → per-activity plans at `$VAULT_DIR/fitness/plans/`, `PBRAIN_FITNESS_ACTIVITIES_FILE` → activities JSON config at `~/.config/pbrain/fitness-activities.json`) |
| `/gratitude-journal` | `$VAULT_DIR/life/gratitude-journal/` | `PBRAIN_GRATITUDE_DIR` |
| `/plan-my-day` | `$VAULT_DIR/life/daily-planning/` | `PBRAIN_PLAN_DIR`, `PBRAIN_PLAN_PROFILE_FILE` → goals profile JSON at `~/.config/pbrain/plan-profile.json` (+ `PBRAIN_FITNESS_DIR`, `PBRAIN_JOURNAL_DIR` for cross-ref) |
| `/end-of-day` | fills the `## How it went` section of `$VAULT_DIR/life/daily-planning/<date>.md` in place (no sibling file) | `PBRAIN_PLAN_DIR` (write target), `PBRAIN_JOURNAL_DIR`, `PBRAIN_FITNESS_DIR`, `PBRAIN_DIET_DIR` for cross-ref |
| `/weekly-review` | `$VAULT_DIR/life/weekly-reviews/YYYY-Www.md` (ISO week) | `PBRAIN_WEEKLY_DIR` (write target), reads `PBRAIN_JOURNAL_DIR`, `PBRAIN_GRATITUDE_DIR`, `PBRAIN_PLAN_DIR`, `PBRAIN_FITNESS_DIR`, `PBRAIN_DIET_DIR` over the last 7 days |
| `/recall <query>` | read-only; case-insensitive markdown grep across `life/`, `agent-work/`, `startup/`, `side-quests/`, `software-dev/`, `notes/` (uses `rg` if available, falls back to `grep -r`) | `PBRAIN_RECALL_SCOPE` (space-separated subdir list relative to vault; missing subdirs are skipped) |
| `/loose-ends` | read-only surfacing dashboard; aggregates stale `tbd/` brainstorms, unanswered journal/brainstorm open questions, unchecked plan todos, recurring tomorrow-seeds, and `current_focus` drift. Writes nothing. | `PBRAIN_STALE_DAYS` (default `7`), `PBRAIN_LOOSE_ENDS_LOOKBACK` (default `30`); reads `PBRAIN_JOURNAL_DIR`, `PBRAIN_BRAINSTORMS_DIR`, `PBRAIN_PLAN_DIR`, `PBRAIN_PLAN_PROFILE_FILE` |
| `/organize-clippings` | source: `$VAULT_DIR/Clippings/`; destinations dynamically discovered from `$VAULT_DIR` top-level dirs (always excludes `agent-work/` and `Clippings/`), with the user picking a subset at session start | `PBRAIN_CLIPPINGS_DIR`, `PBRAIN_CLIPPINGS_TARGETS` (comma-separated subset or `all` to skip the prompt) |

`/init-obsidian` is the only command in this table that doesn't go through `lib/vault.sh` — it runs *before* a vault is configured. It writes the config that every other command reads.

### Upgrade prompt

Every command that sources `lib/vault.sh` runs a cached version check (`lib/update-check.sh`). If pbrain on GitHub is newer than the local install, the command's stdout will include a single line:

```
UPGRADE_AVAILABLE <local> <remote>
```

When you see that line, briefly tell the user a newer pbrain is out and suggest `/plugin update pbrain`, then continue the command's real work. Don't block — it's a nudge, not a gate. The check is cached (1h up-to-date, 12h pending), so the marker may re-appear once per cache window until the user actually upgrades.

---

## Stack

- **Obsidian** — GUI for browsing and editing vault notes. First-time setup: run `/init-obsidian` from this repo.
- **pbrain plugin** — slash commands that read/write the vault. User docs: `README.md` (root) + `docs/<command>.md`.
- **gbrain** — hybrid vector + keyword search over vault, MCP server for Claude sessions. Setup: `gbrain/docs/setup.md`.
- **vault/** — markdown corpus (standalone git repo, location user-configurable); source of truth for all notes.

---

## What not to do here

- Don't write notes or ideas in the outer repo — use the vault at `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault`.
- Don't edit `~/.claude/commands/` directly if it's symlinked here — edit `commands/` in this repo instead (the symlink points back here, so it's the same files either way).
- Don't put gbrain scripts under `commands/` or `lib/`. Plugin = slash commands only. Gbrain ops = `gbrain/`.
- Don't `bun install -g github:garrytan/gbrain` — broken postinstall hook. Clone and link manually (see `gbrain/docs/setup.md`).
