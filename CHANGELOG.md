# Changelog

All notable changes to pbrain are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [Unreleased]

## [0.3.0] — 2026-06-03

### Added

- **`/habits` — habit tracking that auto-logs from your journaling.** Pick a few habits to build (meditate, walk) or cap (alcohol, doomscrolling), each with a priority and a weekly or monthly cap; the first run interviews you and writes a `life/Habits Profile.md` (standard frontmatter + a fenced `json` block, browsable in Obsidian). After that, `/habits` shows a dashboard of counts vs caps for the week and month, flagging limit habits at/over cap and high-priority build habits that lagged. You rarely log by hand: a ride-along extractor (`pbrain_emit_habits_extract`, silent until a profile exists) is wired into `/journal`, `/gratitude-journal`, `/diet-journal`, `/fitness-journal`, `/plan-my-day`, and `/end-of-day`, so habits you mention doing or skipping are logged once per day automatically. Events live in a new shared local SQLite store (`lib/db.sh`, `~/.config/pbrain/pbrain.db`) keyed unique per (habit, day), so logging is idempotent across commands and re-runs. `/plan-my-day` and `/end-of-day` also surface the rollup inline and nudge first-time setup. New env vars: `PBRAIN_HABITS_PROFILE_FILE`, `PBRAIN_DB_FILE`.

- **`/remind` — lightweight reminders that fire as macOS notifications.** Set them in plain language ("remind me to call the dentist tomorrow 3pm", "pay rent on the 1st, monthly") and the command resolves a concrete due time and stores it in the shared SQLite DB. Reminders fire via `osascript` notifications, either opportunistically when `/remind`, `/plan-my-day`, or `/end-of-day` run, or — if you opt in with `/remind install` — from a launchd poller that ticks every ~5 minutes in the background (`/remind uninstall` removes it). Supports one-shot and `daily`/`weekdays`/`weekly`/`monthly` repeats; a long-overdue repeat fires once and rolls forward to its next future occurrence rather than pinging for every missed cycle. Firing is deduped (single `BEGIN IMMEDIATE` transaction + `fired_at` stamp) so a poller racing a `/plan-my-day` run can't double-ping. `/plan-my-day` and `/end-of-day` surface pending and overdue reminders inline and offer to set new ones for time-bound items that come up while planning. New env var: `PBRAIN_DB_FILE`.

- **Shared SQLite layer (`lib/db.sh`).** A single small local database (`~/.config/pbrain/pbrain.db`, override `PBRAIN_DB_FILE`) now backs the operational state that's better queried than grepped — the habit event log and the reminder queue. Human-facing definitions (habits profile, food library) stay as vault markdown; only event/queue data lives in the DB, and it's local-only per-machine state by design (not synced into the vault). Schema is created idempotently via Python's stdlib `sqlite3` (no external package, no `sqlite3` CLI dependency); `lib/db.sh`, `lib/habits.sh`, and `lib/reminders.sh` are sourced through `lib/vault.sh` and, like the other helpers, never exit non-zero. Covered by `tests/db.bats`, `tests/habits.bats`, `tests/reminders.bats`, `tests/remind.bats`.

- **`/plan-my-day` declutter prompt + `/end-of-day` tick-off.** The planner now asks one opt-out question — "anything to declutter or tidy today?" — and writes it as a checkbox under a new `## Declutter` section of the day plan. `/end-of-day` reads that section and, if there's an unchecked item, asks once whether you got to it and ticks the box. Skip it permanently by telling the planner to stop asking (captured as a standing preference); unticked items surface in `/loose-ends`.

- **Per-command self-improvement loop.** Every command (except `/init-obsidian`, which runs before a vault exists) now ends with a conservative "did you correct me?" reflection, via the shared `lib/self-improve.sh` (sourced through `lib/vault.sh` like `lib/update-check.sh`). It fires *only* on an explicit standing preference or correction — neutral sessions stay silent — then classifies each item as a **preference** (how this user wants the command to behave) or a **quality fix** (helps everyone). Preferences are consolidated into `~/.config/pbrain/prefs/<command>.md` (read back on the next run by `lib/prefs.sh` and injected into context, so the loop actually closes); quality fixes append to `~/.config/pbrain/feedback/<command>.md` with an optional offer to open a GitHub issue. Mode is set by `PBRAIN_SELF_IMPROVE`: `prefs` (default, everyone — writes outside the plugin so it survives `/plugin update`), `off` (disable), or `dev` (additionally lets the agent *propose* edits to live command source under `PBRAIN_DEV_DIR/commands/`, always as a diff requiring explicit yes, with a warning if the dev tree is dirty or on `main`). New helpers `lib/prefs.sh` + `lib/self-improve.sh` are defensive — they never exit non-zero, since a fault would otherwise take down every command at once (covered by `tests/*.bats`). New env vars: `PBRAIN_SELF_IMPROVE`, `PBRAIN_PREFS_DIR`, `PBRAIN_FEEDBACK_DIR`.

- **`/weekly-review` enriches your core plans.** After the week's synthesis and reflection questions, a new Step 4 proposes concrete, evidence-tied updates to your plans. All three core plans — the goals profile, `Diet Plan.md` (`PBRAIN_DIET_PLAN_FILE`), and fitness plans (`PBRAIN_FITNESS_PLANS_DIR` / `PBRAIN_GYM_PLAN_FILE`) — are user-owned vault files and treated identically: proposed into a new `## Proposed plan changes` section of the review and edited in place only on an explicit per-change yes. Propose-in-review is the default; nothing is auto-written.

- **Goals profile moved into the vault.** The `/plan-my-day` goals profile now lives at `$VAULT/life/Goals Profile.md` (was `~/.config/pbrain/plan-profile.json`), so all core plans live in Obsidian and are treated uniformly by the weekly enrichment. It's a normal note — standard frontmatter plus the structured data in a fenced `json` block — read via the shared `lib/profile.sh` (`pbrain_profile_json`) by `/plan-my-day`, `/loose-ends`, and `/weekly-review`. Existing `plan-profile.json` files are auto-migrated on the next `/plan-my-day` (no re-interview). New env default: `PBRAIN_PLAN_PROFILE_FILE` → `$VAULT/life/Goals Profile.md`.

- **In-session plan updates, uniform across plan-owning commands.** The self-improve reflection now takes an optional plan target (`pbrain_emit_self_improve <cmd> [plan-file] [plan-label]`), so a lasting plan change you raise mid-session — "bump my protein target", "drop leg day", "my focus this month is X" — is proposed against the actual plan file and written only on an explicit per-change yes, under the same conservative-trigger, propose→confirm→write discipline as preference capture. Wired into `/plan-my-day` (Goals Profile), `/diet-journal` (Diet Plan), and `/fitness-journal` (fitness plans); `/weekly-review` continues to handle plans via its richer whole-week Step 4. Previously only `/weekly-review` could revise a plan — the daily commands generated their plan once and were read-only thereafter.

- **`/plan-my-day` nudges `/weekly-review` on Mondays.** On Mondays, the planner's preflight measures the calendar span since your last weekly review (parsed from the review's covered-through date; falls back to the oldest day-plan if you've never reviewed) and suggests `/weekly-review` once that span reaches 7+ days. The count is calendar-based, so `/plan-my-day` days you skipped still count toward the 7 — a sparse week won't under-count — and it keeps nudging each Monday until a review is actually run. Non-blocking (plan now, review later). Reads `PBRAIN_WEEKLY_DIR` (default `$VAULT_DIR/life/weekly-tracking`) and `PBRAIN_PLAN_DIR` for the check.

### Changed

- **README diagrams rendered as SVG.** The Architecture, `/init-obsidian` flow, and Daily-flow sections now embed adaptive light/dark SVG diagrams (authored in [D2](https://d2lang.com)) instead of ASCII art, with the on-demand commands split into their own diagram. The four sources + rendered output live in `docs/diagrams/` (`architecture`, `init-obsidian`, `daily-flow`, `on-demand`); each `.d2` carries the `d2 --theme 0 --dark-theme 200 --pad 20 <file>.d2 <file>.svg` re-render command in a header comment, and every embed keeps a short prose summary beside it so the content stays searchable and accessible.

- **Morning sequence flipped to `/journal` → `/gratitude-journal`** (was gratitude → journal). The journal is a raw brain dump that clears the head — today's mood, yesterday's residue, loud thoughts, open questions — so gratitude then lands on cleared ground instead of competing with unprocessed residue. The morning-sequence file check (in `CLAUDE.md` and the vault guidance written by `/init-obsidian`) now suggests `/journal` first, then `/gratitude-journal`. As a consequence, `/gratitude-journal` **drops its "How are you feeling?" prompt** — mood is now captured in the journal dump next door — and is down to two prompts (gratitude list + themed reflection question). Saved gratitude entries no longer carry a `## How are you feeling` section; the reflection-question dedup parser keys off the *last* `##` header so it stays correct for both old (3-header) and new (2-header) entries. README quick-start, cadence table, and `docs/gratitude-journal.md` updated to match.

- **`/weekly-review` now writes to `life/weekly-tracking/` (was `life/weekly-reviews/`).** Default `PBRAIN_WEEKLY_DIR` updated, and `/plan-my-day`'s Monday nudge reads the new path. On the next `/weekly-review`, a one-time migration renames an existing `life/weekly-reviews/` directory to `life/weekly-tracking/` (only when the default path is in use and the new dir doesn't exist yet), so past reviews and the nudge's "days since last review" check carry over.

- **`scripts/install-commands.sh` now registers `PBRAIN_DEV_DIR` in `~/.claude/settings.json`** (and `uninstall-commands.sh` removes it). Previously, making local `.sh` edits run live required hand-exporting `PBRAIN_DEV_DIR` in a shell profile — which is invisible to GUI-launched apps (Conductor, the desktop app) because they don't source `~/.zshrc`, so the wrappers silently fell back to the stale marketplace snapshot. The install script now writes the var into the `settings.json` `env` block, which the harness reads regardless of launch method. Idempotent and order-preserving; uninstall only removes the entry when it still resolves (realpath) to this clone, so a setting pointing at a different clone is left alone. Requires a one-time Claude Code / Conductor restart to load. README "Local development" updated to match.

## [0.2.0] — 2026-05-29

### Added

- **`/loose-ends`** — new read-only surfacing command. The vault already *generates* open-loop data; nothing reflected it back. `/loose-ends` aggregates five kinds of unresolved thread and reports oldest-first: stale `tbd/` brainstorms (≥ `PBRAIN_STALE_DAYS`, default 7), unanswered `## Open questions` from journals (empty/`—` answer) plus open-question bullets in brainstorms, unchecked `- [ ]` todos in recent plans, recurring `### Tomorrow seed` bullets that keep getting deferred, and `current_focus` goals from the plan profile that have gone quiet. Writes nothing — it's a dashboard, safe to re-run. New env vars: `PBRAIN_STALE_DAYS` (default `7`) and `PBRAIN_LOOSE_ENDS_LOOKBACK` (default `30`); reuses `PBRAIN_JOURNAL_DIR`, `PBRAIN_BRAINSTORMS_DIR`, `PBRAIN_PLAN_DIR`, `PBRAIN_PLAN_PROFILE_FILE`.

### Changed

- **Frontmatter standardized across every note generator.** Each generated note now opens with a consistent `type` / `date` / `tags` block (plus `status` where a real lifecycle exists) — the prerequisite for any retrieval layer (gbrain, Obsidian Dataview, `/loose-ends` itself):
  - `/gratitude-journal` and `/weekly-review` now emit frontmatter (previously none); weekly also carries `week`.
  - `/journal` folds the old `title` + `created` keys into a single `date`.
  - `/brainstorm` renames `created` → `date` (keeps `title` and `status: draft`).
  - `/plan-my-day`, `/fitness-journal` (gym, rest, and other-activity templates), and `/diet-journal` gain `type` + `tags`.
  - `/end-of-day` is unchanged — it fills the plan file in place and has no frontmatter of its own.
  - Existing notes are not retrofitted; generators are updated going forward.

### Fixed

- **`/end-of-day` references aligned with in-place write behavior.** Since 0.1.1 `/end-of-day` fills the plan file's `## How it went` section in place rather than writing a sibling `<date>-close.md`, but three spots still assumed the old model: `weekly-review.sh` read a dead `$PLAN_DIR/$d-close.md` path that always returned "(no entry)" (now removed — the close lives in the plan file, already read, relabeled "Plan & close"), and the README + CLAUDE.md destination columns still listed `<date>-close.md` (now describe the in-place write). The historical CHANGELOG note and the `docs/end-of-day.md` migration guide intentionally keep the `-close.md` reference.

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
