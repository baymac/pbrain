# Changelog

All notable changes to pbrain are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [Unreleased]

## [0.1.2] — 2026-05-28

### Added

- **`PBRAIN_DEV_DIR` env var** — three-tier path resolution for all command `.md` files: `PBRAIN_DEV_DIR` (local dev) → `CLAUDE_PLUGIN_ROOT` (plugin command path) → `~/.claude/plugins/marketplaces/pbrain` (marketplace fallback). Set `export PBRAIN_DEV_DIR=/path/to/pbrain` in your shell profile to point at a live clone; `.sh` edits take effect immediately without reinstalling.
- **`scripts/uninstall-commands.sh`** — inverse of `install-commands.sh`. Removes per-file symlinks from `~/.claude/commands/` only if they point at this repo; leaves foreign symlinks and real files untouched. Idempotent.
- **`/plan-my-day` schedule table** — plan output now leads with a **Today at a glance** table (time range | action | goal tie) instead of prose blocks. Supporting detail (coaching, eating, rest, avoids) follows as reference sections.

### Fixed

- **Marketplace install path fallback** — all 11 command `.md` files previously fell back to `~/.claude/commands/` when `CLAUDE_PLUGIN_ROOT` was absent (e.g. when the Bash tool invokes the script directly). That path doesn't exist on marketplace installs, causing `bash: No such file or directory`. Fallback now correctly targets `~/.claude/plugins/marketplaces/pbrain`.
- **Time format example in `/plan-my-day`** — template example `"10:30–12:00 AM"` was semantically wrong (`12:00 AM` is midnight). Corrected to `"10:30 AM–12:00 PM"` / `"10:30–12:00"` with explicit 12h/24h guidance.
- **`uninstall-commands.sh` race on `rmdir`** — final `rmdir` on the now-empty `~/.claude/commands/` could crash the script under `set -e` if another process created a file concurrently. Now swallowed gracefully.

## [0.1.1] — 2026-05-27

### Fixed

- **Marketplace install** — added `.claude-plugin/marketplace.json` so `/plugin marketplace add baymac/pbrain` resolves. The repo was missing a marketplace manifest, leaving users stuck at "no progress" after `/plugin install` did nothing. Documented two-step install in the README Quick Start.
- **Slash command permission check** — replaced the `` !`bash "${CLAUDE_PLUGIN_ROOT:-…}/commands/<name>.sh"` `` pre-exec line in all 11 commands. Newer Claude Code rejects `!`-prefix commands containing `${VAR}` expansion ("Shell command permission check failed: Contains expansion"). Each command now invokes its backing script via the Bash tool from the body instructions, which expands `${VAR}` normally. UX change: one visible tool call per slash command instead of an invisible pre-exec.
- **`/end-of-day` write target** — now fills the plan file's existing `## How it went` section in place instead of writing a sibling `YYYY-MM-DD-close.md`. One file per day. Asks before overwriting an already-filled section; also flips bookkeeping fields on the day's diet and fitness logs when the user describes what they actually ate or trained.

## [0.1.0] — 2026-05-27

Initial public release.

### Added

- **Plugin manifest** at `.claude-plugin/plugin.json` — installable as the `pbrain` Claude plugin.
- **Vault resolver** (`lib/vault.sh`) — shared `$VAULT_DIR` resolution across all commands. Order: `$PBRAIN_VAULT` env → `~/.config/pbrain/vault` file → default iCloud Obsidian path.
- **Slash commands:**
  - `/init-obsidian` — bootstrap a vault (Obsidian install check, vault creation, optional iCloud migration, optional private `.nosync` dir, optional git remote).
  - `/journal` — stub today's daily note at `life/daily-tracking/`.
  - `/gratitude-journal` — three-question gratitude entry with rotating reflection theme (12 themes × 5 opening words, deduped against the last 30 entries).
  - `/brainstorm <topic>` — idea dump with `tbd/`/`backlog/`/`done/` lifecycle dirs.
  - `/plan-my-day` — adaptive daily planner anchored on a one-time goals profile interview (horizon goals, current focus, working style, anti-patterns, personal anchors).
  - `/end-of-day` — close-of-day reflection that cross-references today's plan, journal, fitness, and diet entries.
  - `/weekly-review` — 7-day synthesis across journal, gratitude, plan, close-of-day, fitness, and diet entries; writes to `life/weekly-reviews/YYYY-Www.md`.
  - `/recall <topic>` — grep-based search across vault narrative folders, scoped to skip `Clippings/` and numeric daily logs.
  - `/diet-journal` — diet log with optional first-run profile (height, weight, goals); writes to `fitness/diet-tracking/`.
  - `/fitness-journal` — adaptive workout planner with per-activity plans; writes to `fitness/daily-tracking/`.
  - `/organize-clippings` — sort `Clippings/` (Obsidian Web Clipper output) into user-curated topical folders.
- **Morning sequence anchor** — `/brainstorm` and `/plan-my-day` softly suggest `/gratitude-journal` then `/journal` first if today's entries are missing. Suggestion only; never blocks.
- **Per-command docs** under `docs/` — one short user-facing page per command.
- **gbrain operational scripts** under `gbrain/` — `gbrain-sync-wrapper.sh` (lockfile + JSONL log), `gbrain-dashboard.sh` (stuck procs + sync stats), `gbrain-upgrade.sh`, `install-launchd.sh`. Currently degraded due to an upstream gbrain schema issue; documented in `gbrain/docs/gbrain-sync.md`.
- **MIT License**.

### Known issues

- Scheduled gbrain sync via launchd hangs on the current upstream gbrain version. Workaround: leave the launchd job disabled and rely on in-process MCP writes. Fix tracked in `gbrain/docs/gbrain-bug-report.md`.
