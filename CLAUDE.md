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

## Morning sequence (journal → gratitude → everything else)

The day starts on `/journal`, then `/gratitude-journal`. Both anchor the user's baseline before agent work happens. The journal goes first: it's a raw brain dump that clears the head (today's mood, yesterday's residue, loud thoughts, open questions). Gratitude then lands on cleared ground — you can't genuinely ground on *enough* while still carrying unprocessed residue.

When the user invokes any slash command other than `/journal`, `/gratitude-journal`, `/init-obsidian`, `/codex-install`, `/remind`, or `/thoughts` — OR asks for help with personal reflection / capture / brainstorming — check the daily files in this order:

1. **Journal first.** If `vault/life/daily-tracking/YYYY-MM-DD.md` doesn't exist, suggest `/journal` before proceeding. The raw dump clears the head and surfaces what's actually on the user's mind.
2. **Then gratitude.** If the journal exists but `vault/life/gratitude-journal/YYYY-MM-DD.md` doesn't, suggest `/gratitude-journal` before proceeding. With the head cleared, gratitude anchors baseline to *enough* so the rest of the day runs on overflow.
3. **Otherwise proceed.**

Suggest once, never block. The user can override and continue. `/init-obsidian`, `/codex-install`, `/journal`, and `/gratitude-journal` are exempt from the check (the first two are setup; the latter two are the entry points); `/remind`, `/thoughts`, and `/discuss` are exempt too (quick utilities you fire any time). `/habits` is **not** exempt — it's part of the daily flow that runs after journal → gratitude (it's suggested by `/plan-my-day`, but can be run independently any time *after* the morning sequence), so it goes through the check like everything else.

**This check is overridable by a standing preference, like every other suggestion.** If the user's injected USER PREFERENCES block (global or per-command — see the self-improvement loop below) says to skip the journal/gratitude nudge, do **not** make it; proceed straight to the command's work. A skip of the morning-sequence check is a *global* preference (it fires from many commands), so it lives in `prefs/_global.md`. More broadly: any built-in suggestion or nudge in any command yields to a standing preference that says to skip it — preferences always win over a default nudge.

---

## Repository layout (monorepo)

```
pbrain/
├── .claude-plugin/
│   └── plugin.json                     ← Claude plugin manifest (this repo IS the plugin)
├── commands/                           ← all slash command .md + .sh pairs
├── lib/vault.sh                        ← shared VAULT_DIR resolver (sourced by every command)
├── lib/update-check.sh                 ← upgrade nudge (sourced by vault.sh)
├── lib/prefs.sh                        ← per-command preference injection (pbrain_emit_prefs)
├── lib/self-improve.sh                 ← end-of-session feedback capture (pbrain_emit_self_improve)
├── lib/profile.sh                      ← goals-profile JSON extractor (pbrain_profile_json)
├── lib/db.sh                           ← shared SQLite store (pbrain_db_init; habit events + reminders)
├── lib/habits.sh                       ← habits profile/criteria + dated md tracking layer (track/mark/sync/consolidate) + rollup + ride-along extraction (pbrain_emit_habits_extract)
├── lib/reminders.sh                    ← two reminder backends. /remind: Apple Calendar layer (pbrain_calendar_add/list/delete/today/rrule/access + pbrain_calendar_app_build). /remind-blocking: cron (pbrain_cron_next) + blocking-overlay build/show (pbrain_overlay_build, pbrain_overlay_show) + the poller tick (pbrain_reminders_tick dispatches block_seconds rows to the overlay). pbrain_notify/pbrain_notify_build remain only as the overlay's no-swiftc notification fallback
├── lib/pbrain-calendar.swift           ← source for pbrain's EventKit helper (built on demand by pbrain_calendar_app_build → pbrain-calendar.app in ~/.config/pbrain; used by /remind to reliably delete Calendar events, incl. recurring iCloud ones)
├── lib/pbrain-notify.swift             ← source for pbrain's own macOS notifier (built on demand by pbrain_notify_build → pbrain-notify.app in ~/.config/pbrain; now only the /remind-blocking overlay's degradation path when swiftc is absent)
├── lib/pbrain-overlay.swift            ← source for pbrain's full-screen blocking overlay (built on demand by pbrain_overlay_build → pbrain-overlay.app in ~/.config/pbrain; used by /remind-blocking)
├── tests/                              ← bats tests for the shared lib/ helpers
├── docs/                               ← one short user-facing doc per command
├── gbrain/                             ← gbrain operations (separate from the plugin)
│   ├── scripts/                        ← gbrain-sync-wrapper, dashboard, upgrade, install-launchd
│   ├── launchd/com.pbrain.sync.plist.template
│   ├── docs/                           ← setup (gbrain-only), gbrain-sync, gbrain-beyond-notes, gbrain-bug-report
│   └── .logs/                          ← gitignored: sync-runs.jsonl, upgrade-status.json
├── promo-video/                        ← HyperFrames source composition for the promo video (renders excluded via .gitignore)
├── CLAUDE.md
└── README.md
```

There's no `.claude/commands` symlink at the repo root — by design. Slash commands are made available globally via a one-time `ln -s <repo>/commands ~/.claude/commands` (documented in the README's Quick start), so edits to the scripts go live in every CC session. The tooling repo is for editing, the vault is for running.

---

## Conventions for editing scripts

- Shell: `#!/usr/bin/env bash` with `set -euo pipefail` on every script.
- Complex logic (JSON parsing, markdown conversion): inline Python 3 heredoc inside the shell script. No external deps — stdlib only (no pip packages). Modules in use: `json`, `re`, `sys`, `os`, `datetime`, `calendar`, `sqlite3`, `subprocess`, `shutil`, `glob`, `random`, `collections`, `uuid`. (`sqlite3` is Python stdlib — the shared store in `lib/db.sh` uses it, not the `sqlite3` CLI binary.)
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
| `/discuss <topic>` | Personal dilemma discussion — reads journal/gratitude/goals profile silently, Socratic one-question-at-a-time, saves insight note to `$VAULT_DIR/agent-work/notes/` | `PBRAIN_NOTES_DIR` |
| `/diet-journal` | `$VAULT_DIR/fitness/diet-tracking/` | `PBRAIN_DIET_DIR` (+ `PBRAIN_FITNESS_DIR` for cross-ref, `PBRAIN_DIET_PLAN_FILE` → `$VAULT_DIR/fitness/Diet Plan.md`, `PBRAIN_DIET_PROFILE_FILE` → profile JSON at `~/.config/pbrain/diet-profile.json`, `PBRAIN_FOOD_LIBRARY_FILE` → named-foods library at `$VAULT_DIR/fitness/Food Library.md`) |
| `/fitness-journal` | `$VAULT_DIR/fitness/daily-tracking/` | `PBRAIN_FITNESS_DIR` (+ `PBRAIN_GYM_PLAN_FILE`, `PBRAIN_FITNESS_PLANS_DIR` → per-activity plans at `$VAULT_DIR/fitness/plans/`, `PBRAIN_FITNESS_ACTIVITIES_FILE` → activities JSON config at `~/.config/pbrain/fitness-activities.json`; `PBRAIN_DIET_DIR` for the post-session `/diet-journal` suggestion cross-ref) |
| `/gratitude-journal` | `$VAULT_DIR/life/gratitude-journal/` | `PBRAIN_GRATITUDE_DIR` |
| `/plan-my-day` | `$VAULT_DIR/life/daily-planning/` | `PBRAIN_PLAN_DIR`, `PBRAIN_PLAN_PROFILE_FILE` → goals profile at `$VAULT_DIR/life/Goals Profile.md` (markdown; structured data in a fenced `json` block) (+ `PBRAIN_FITNESS_DIR`, `PBRAIN_JOURNAL_DIR`, `PBRAIN_WEEKLY_DIR` for cross-ref; the last drives the Monday weekly-review nudge) |
| `/end-of-day` | fills the `## How it went` section of `$VAULT_DIR/life/daily-planning/<date>.md` in place (no sibling file) | `PBRAIN_PLAN_DIR` (write target), `PBRAIN_JOURNAL_DIR`, `PBRAIN_FITNESS_DIR`, `PBRAIN_DIET_DIR` for cross-ref |
| `/weekly-review` | `$VAULT_DIR/life/weekly-tracking/YYYY-Www.md` (ISO week) | `PBRAIN_WEEKLY_DIR` (write target), reads `PBRAIN_JOURNAL_DIR`, `PBRAIN_GRATITUDE_DIR`, `PBRAIN_PLAN_DIR`, `PBRAIN_FITNESS_DIR`, `PBRAIN_DIET_DIR` over the last 7 days; Step 4 enrichment reads `PBRAIN_PLAN_PROFILE_FILE`, `PBRAIN_DIET_PLAN_FILE`, `PBRAIN_FITNESS_PLANS_DIR`, `PBRAIN_GYM_PLAN_FILE` (all vault-owned — proposed into the review, edited only on explicit per-change yes) |
| `/thoughts [<text>]` | explode + append a timestamped thought to `$VAULT_DIR/life/thought-tracking/<date>.md`; no args: Claude asks first | `PBRAIN_THOUGHTS_DIR` |
| `/recall <query>` | read-only; case-insensitive markdown grep across `life/`, `agent-work/`, `startup/`, `side-quests/`, `software-dev/`, `notes/` (uses `rg` if available, falls back to `grep -r`) | `PBRAIN_RECALL_SCOPE` (space-separated subdir list relative to vault; missing subdirs are skipped) |
| `/loose-ends` | read-only surfacing dashboard; aggregates stale `tbd/` brainstorms, unanswered journal/brainstorm open questions, unchecked plan todos, recurring tomorrow-seeds, and `current_focus` drift. Writes nothing. | `PBRAIN_STALE_DAYS` (default `7`), `PBRAIN_LOOSE_ENDS_LOOKBACK` (default `30`); reads `PBRAIN_JOURNAL_DIR`, `PBRAIN_BRAINSTORMS_DIR`, `PBRAIN_PLAN_DIR`, `PBRAIN_PLAN_PROFILE_FILE` |
| `/organize-clippings` | source: `$VAULT_DIR/Clippings/`; destinations dynamically discovered from `$VAULT_DIR` top-level dirs (always excludes `agent-work/` and `Clippings/`), with the user picking a subset at session start | `PBRAIN_CLIPPINGS_DIR`, `PBRAIN_CLIPPINGS_TARGETS` (comma-separated subset or `all` to skip the prompt) |
| `/habits` | habits profile (the *what*) at `$VAULT_DIR/life/Habits Profile.md` (markdown; JSON in a fenced block, each habit with a stable `id` + its own `schedule_type`/`direction`/`target_count` criteria, plus an optional measure `unit`/`measure_target` for amount-based habits like 4L water — fulfillment then sums the `--amount` over the period, stored in the `amount` column of `habit_events`). Day-to-day log is dated markdown — `$VAULT_DIR/life/habit-tracking/<date>.md`, a checklist table generated from the profile (like `/fitness-journal`); the SQLite DB is a *derived* analysis store synced from those files (keyed by `habit_id`). First run interviews one question at a time, then a dashboard (per-habit progress vs criteria, top 20 by priority). `add`/`edit`/`archive`/`history` own profile/DB; `track`/`mark`/`sync`/`consolidate`/`refresh` own the md→DB flow (mark ticks the md and rewrites the Progress cell live, consolidate at `/end-of-day` syncs+prunes, refresh recomputes Progress from the DB without touching Done marks — useful after a formula/data change). Auto-marked from journaling/planning commands via `pbrain_emit_habits_extract` | `PBRAIN_HABITS_PROFILE_FILE`, `PBRAIN_HABIT_TRACK_DIR`, `PBRAIN_DB_FILE`, `PBRAIN_HABIT_SUGGEST_FILE`, `PBRAIN_HABIT_SUGGEST_TTL_DAYS` |
| `/remind <text>` | a SIMPLE "add to Apple Calendar". Reminders land as **real Calendar events** (timed, with an alarm at start + optional RRULE recurrence) — **Calendar owns firing + cross-device sync**. There is **NO pbrain DB row and no launchd poller** for `/remind` (that's `/remind-blocking`, exclusively). Each event is tagged with a marker in its notes (`PBRAIN_CAL_MARKER`, default `⟦pbrain-reminder⟧`) + a minted `⟦pbrain-id:…⟧` handle so `list`/`cancel` find pbrain's own events. Create goes through `osascript`/AppleScript (`pbrain_calendar_add`); **delete** uses a bundled EventKit helper (`pbrain-calendar.app`, compiled on demand from `lib/pbrain-calendar.swift` by `pbrain_calendar_app_build`, launched via `open` so Calendar TCC is attributed to the bundle; AppleScript fallback when `swiftc` is absent — unreliable for recurring iCloud events). One-time Calendar grant via `calendar-access`. **NOT surfaced or fired opportunistically anywhere** — `/plan-my-day`/`/end-of-day` don't touch reminders; they only *read* today's Calendar as hard anchors. Subcommands OWNED here: `add`/`list`/`done`/`cancel` (alias of done)/`calendar-access`/`help`/NL-entry. | `PBRAIN_CALENDAR` (target calendar, default `Calendar`), `PBRAIN_CAL_MARKER`, `PBRAIN_CALENDAR_APP`, `PBRAIN_VAULT` (prefs/self-improve only) |
| `/remind-blocking <text>` | blocking reminders in the `reminders` table, distinguished by a non-NULL `block_seconds` (overlay stay/countdown seconds; 0 = until skipped) + `hold_seconds` (Control-hold to skip, default 5). Recurrence is a **5-field cron expression** in the `cron` column (`min hour dom month dow`) — the flexible source of truth (multi-time, multi-day, `*/step`); `due_at` holds the next computed fire and the tick recomputes it via `cron_next` after each fire (legacy `daily/weekly/...` tokens still work when `cron` is NULL). NL→cron is done by the model; `pbrain_cron_next` (lib/reminders.sh) validates + computes the first fire. Fire as a full-screen "Take a break" overlay (`pbrain-overlay.app`, compiled on demand from `lib/pbrain-overlay.swift` by `pbrain_overlay_build`; degrades to a notification when `swiftc` is absent; resolved by holding **Control** for `hold_seconds` → cancelled, **Return** → done, or waiting out the countdown → done; writes status to the row via the SQLite3 C API when passed `--id`/`--db`, leaving repeating rows untouched). **Serialized: at most ONE overlay on screen at a time** — the tick `pgrep`s for a running `pbrain-overlay` and, if busy (or after launching one this tick), defers the rest WITHOUT stamping/advancing, so they fire on a later tick (no lost reminders). **Fire ONLY via the background poller** (~60s, near due time) — there are NO opportunistic callers (other commands don't tick or surface these; time-sensitive overlays must never fire late as a catch-up). `add`/`list`/`done`/`cancel`/`test` (immediate overlay)/`tick`/`install`/`uninstall` are all OWNED here (the poller plist runs `remind-blocking.sh tick`; first `add` auto-installs it). `tick` bypasses `lib/vault.sh`. | `PBRAIN_DB_FILE`, `PBRAIN_OVERLAY_APP`, `PBRAIN_OVERLAY_BG` |
| `/codex-install` | Codex interop generator — Claude-side setup. Generates `$CODEX_HOME/skills/pbrain-<cmd>/SKILL.md` (one Codex *agent skill* per command, wrapping the SAME `.sh`) + a managed `AGENTS.md` block, from the same `commands/*.md` sources; cleans up any legacy custom prompts from earlier versions. Also writes a `codex-pbrain` shell function to the user's RC file(s) so they can launch Codex with the correct sandbox flags from the terminal. Bypasses `lib/vault.sh` (must run pre-vault; resolves the vault read-only). Excludes `init-obsidian` + itself. | `CODEX_HOME`, `PBRAIN_DEV_DIR` (baked into skills when set) |

`/init-obsidian` and `/codex-install` are the only commands in this table that don't go through `lib/vault.sh` — they're setup commands that must run before/around a vault being configured. `/init-obsidian` writes the config every other command reads; `/codex-install` only reads it (read-only resolve, never exits if absent). (`/remind-blocking tick`, the background poller path, also bypasses `lib/vault.sh` on purpose — it only needs the DB, and must not exit when no vault dir exists.)

### Upgrade prompt

Every command that sources `lib/vault.sh` runs a cached version check (`lib/update-check.sh`). If pbrain on GitHub is newer than the local install, the command's stdout will include a single line:

```
UPGRADE_AVAILABLE <local> <remote>
```

When you see that line, briefly tell the user a newer pbrain is out and suggest `/plugin update pbrain`, then continue the command's real work. Don't block — it's a nudge, not a gate. The check is cached (1h up-to-date, 12h pending), so the marker may re-appear once per cache window until the user actually upgrades.

### Self-improvement loop

Two shared helpers, defined in `lib/prefs.sh` and `lib/self-improve.sh` and sourced through `lib/vault.sh`, ride along on every command except `/init-obsidian` (which runs before a vault exists). Each command calls them by name:

- `pbrain_emit_prefs <cmd>` — near the top of output. Injects two preference files into context (each emitted only if present/non-empty): `~/.config/pbrain/prefs/_global.md` (standing preferences that apply to **every** command) first, then `~/.config/pbrain/prefs/<cmd>.md` (preferences for that command). Apply both for the session; they override defaults where they conflict — including built-in suggestions/nudges. The global file is the home for cross-command "stop suggesting X" rules (e.g. silencing the morning-sequence journal/gratitude check, which fires from many commands and so can't be silenced by a single command's pref). The write side (`pbrain_emit_self_improve`) classifies a captured preference as GLOBAL (→ `_global.md`) or COMMAND (→ `<cmd>.md`) by whether it spans commands.
- `pbrain_emit_self_improve <cmd> [plan-file] [plan-label]` — at the end of output. Emits a `--- SELF-IMPROVE CHECK (mode: …) ---` block telling you to reflect on whether the user gave a genuine standing preference or correction *this session*. **Fire only on explicit feedback — stay silent on neutral sessions.** Then capture per the block: preferences consolidate into `prefs/<cmd>.md` (read existing first, update don't duplicate), quality fixes append to `~/.config/pbrain/feedback/<cmd>.md` with an optional `gh issue` offer. When a `plan-file`+`plan-label` are passed (the plan-owning commands — `/plan-my-day` → goals profile, `/diet-journal` → diet plan, `/fitness-journal` → fitness plans), the block also gains a **PLAN UPDATE** route: a lasting plan change raised in-session is proposed against the plan file and written only on an explicit per-change yes (keeping any fenced JSON valid). `/weekly-review` does plan enrichment via its richer Step 4 instead, so it calls this with no plan args.

Mode comes from `PBRAIN_SELF_IMPROVE` (`prefs` default / `off` / `dev`). `dev` is honoured only when `PBRAIN_DEV_DIR` is set, and lets you *propose* edits to live command source — always as a diff requiring explicit yes, never auto-applied. Both helpers are written to never exit non-zero (they're sourced into commands under `set -euo pipefail`); call sites add `|| true` as belt-and-suspenders. Tests live in `tests/*.bats` (run `bats tests/`).

### Shared SQLite layer + habit extraction

`lib/db.sh`, `lib/habits.sh`, and `lib/reminders.sh` are sourced through `lib/vault.sh` too (after `lib/profile.sh`, in that dependency order). They back `/habits` and `/remind-blocking` on one local SQLite DB (`~/.config/pbrain/pbrain.db`, override `PBRAIN_DB_FILE`) — operational state (habit events + the blocking-overlay reminder queue) that's better queried than grepped. (`/remind` no longer uses the DB at all — it's Apple Calendar-only; `lib/reminders.sh` carries its Calendar helpers too.) Human-facing definitions stay markdown in the vault (habits profile, food library), browsable in Obsidian.

**Habit logging is markdown-first.** The human-facing log is a dated checklist file per day (`life/habit-tracking/<date>.md`, generated from the profile); the SQLite DB is *derived* from it. `pbrain_emit_habits_extract <cmd>` rides along like the self-improve helpers: it appends a HABIT EXTRACTION block telling you to MARK any tracked habits the user evidenced this session (via `commands/habits.sh mark …`, which ticks today's md and rejects untracked names — NOT a direct DB write), plus a gated HABIT SUGGEST block that nudges adding a NEW habit on a standing intention (once/session, suppressed per-candidate for ~14d via `PBRAIN_HABIT_SUGGEST_FILE`). It is **silent when no habits profile exists** — so it costs nothing until the user opts in. It's wired into `/journal`, `/gratitude-journal`, `/fitness-journal`, `/diet-journal`, `/plan-my-day`, `/end-of-day`, and the `/habits` dashboard itself (so the dashboard can auto-mark a habit the user evidences mid-session — e.g. an unclean meal — rather than only reflecting marks already in the md). Read commands (`/plan-my-day`, `/end-of-day`, `/weekly-review`, the `/habits` dashboard) call `pbrain_habits_sync_range` to mirror recent md into the DB before reading; `/plan-my-day` offers to create today's tracker (`habits.sh track`); `/end-of-day` runs `habits.sh consolidate` (sync today + prune unchecked rows). The last three also surface habit progress (rollup vs each habit's criteria) inline; they do NOT surface or fire reminders (Calendar fires `/remind`; the poller fires `/remind-blocking`). All these helpers follow the same never-exit-non-zero discipline (tests in `tests/db.bats`, `tests/habits.bats`, `tests/reminders.bats`).

### Codex interoperability

pbrain is a Claude Code plugin first; the OpenAI **Codex CLI** is a supported *secondary* runner. `/codex-install` (run from Claude Code, after `/init-obsidian`) generates Codex entry points **from the same `commands/*.md` sources** — there is no second copy of any logic. The contract that makes this work cleanly:

- **The `.sh` files are agent-agnostic and the single source of truth.** They resolve the vault via `lib/vault.sh` (env → `~/.config/pbrain/vault` → iCloud default), read/write `~/.config/pbrain/*` + the SQLite DB, and emit self-describing `INSTRUCTIONS:` / ride-along blocks (`USER PREFERENCES`, `SELF-IMPROVE CHECK`, `HABIT EXTRACTION`/`SUGGEST`, `UPGRADE_AVAILABLE`). Nothing in them is Claude-specific (`update-check.sh` falls back to `$lib_dir/..` when `CLAUDE_PLUGIN_ROOT` is unset). **Do not fork behaviour per agent** — keep the `.sh` the shared truth.
- **What the installer generates** (in `$CODEX_HOME`, default `~/.codex`): `skills/pbrain-<cmd>/SKILL.md` — one Codex *agent skill* per command (Codex auto-discovers them; invoked by plain name, `$pbrain-<cmd>`, or implicitly by description), plus a delimited, managed `AGENTS.md` block (how to invoke, morning sequence, ride-along handling, vault write rules, launch command), scoped so it never affects non-pbrain Codex sessions. It also removes any legacy `prompts/pbrain-*.md` carrying the managed marker (one-time migration off deprecated custom prompts).
- **The skill-body transform** (deterministic, in a Python heredoc): (1) lift the source `.md` `description:` into the skill's required frontmatter (`name: pbrain-<cmd>` + double-quoted `description`); (2) bake a literal `.sh` path in place of the `${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-…}}` token (Codex has no `CLAUDE_PLUGIN_ROOT`; `PBRAIN_DEV_DIR` set *at install time* is baked instead); (3) soften "the Bash tool" → "your shell". **No `$`-escaping**: Codex reads a `SKILL.md` from disk verbatim and does NOT expand `$NAME` placeholders in a skill body (unlike the deprecated custom prompts), so `$VAULT_DIR`/`$ARGUMENTS`/prose survive intact — the body's own prose ("substituting the user's topic for `$ARGUMENTS`") tells the agent to splice input in. pbrain's own `/<cmd>` refs and non-pbrain refs (`/office-hours`) are left verbatim. Each generated `SKILL.md` carries a `pbrain-codex-managed` marker; stale-prune (and the legacy-prompt cleanup) only ever deletes files/dirs bearing it.
- **No conflicts by construction.** Codex and Claude Code share one vault, one config dir, one DB, one set of scripts. There is no agent-specific state to desync — alternating runners is safe. Re-running the installer is idempotent (refresh skills, re-bake path, merge the AGENTS block between markers, prune orphans).
- **Why skills, not custom prompts:** custom prompts are deprecated by OpenAI and regressed on current Codex (they stopped surfacing in the slash menu — issue #15941, closed not-planned — so commands were undiscoverable). A literal `/journal` is also rejected by Codex's CLI before the model sees it. Agent skills are the supported, **default-on** replacement (no `--enable` flag): auto-discovered and invokable by name, `$name`, or implicit description-match — verified against codex-cli 0.137.0. `init-obsidian` is intentionally Claude-only for now (running it from Codex can come later if it stays simple). Tests: `tests/codex-install.bats`.

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
