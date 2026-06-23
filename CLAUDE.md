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
4. **Zero-config fallback**: if nothing above is configured (no `$PBRAIN_VAULT`, no config file) and the default iCloud path doesn't exist, `lib/vault.sh` auto-creates a plain local vault at `~/pbrain-vault` (via the shared `lib/scaffold.sh` — git init + `.gitignore` + `CLAUDE.md` + initial commit + config file, exactly like `/init-obsidian bootstrap`, with git treated as optional) and continues, so commands never hard-fail on a fresh machine without Obsidian. Only the unset (default) case auto-creates — an explicit but missing env/config path still errors (a typo shouldn't silently spawn a vault elsewhere). `PBRAIN_NO_AUTOVAULT=1` opts back into the hard-fail.

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
| `agent-work/clips/<platform>/` | `/clipper` outputs — videos saved as clean, faithful transcripts (`x/`, `yt/`). |

If a new content type doesn't fit any of these, ask before creating a new subdir.

**Daily journal lives at `vault/life/daily-tracking/YYYY-MM-DD.md`** — not under `agent-work/`, because it's user-owned content. `/journal` creates a stub for the user to fill in; the content is the user's personal log, not agent output.

**`/laptop-tracking` writes `vault/life/laptop-tracking/YYYY-MM-DD.md`** — also a sanctioned `life/` path (a derived per-day usage report, domain-level only). The granular DB stays local at `~/.config/pbrain/tracker.db` and is never synced to the vault.

---

## Morning sequence (journal → gratitude → everything else)

The day starts on `/journal` (a raw brain dump that clears the head), then `/gratitude-journal` (anchors baseline on cleared ground). When the user invokes any other slash command — or asks for personal reflection / capture / brainstorming — check today's files in order: (1) if `vault/life/daily-tracking/YYYY-MM-DD.md` is missing, suggest `/journal`; (2) else if `vault/life/gratitude-journal/YYYY-MM-DD.md` is missing, suggest `/gratitude-journal`; (3) otherwise proceed. **Suggest once, never block** — the user can override and continue.

Exempt (never trigger the check): `/journal`, `/gratitude-journal`, `/init-obsidian`, `/codex-install`, `/remind`, `/thoughts`, `/discuss`, `/laptop-tracking`, `/loose-ends`, `/vault-backup`. `/habits` is **not** exempt (it runs after the morning sequence). **Overridable by a standing preference**: if the user's injected USER PREFERENCES block says to skip the journal/gratitude nudge, don't make it — the morning-sequence skip is a *global* preference at `.pbrain/_global/prefs.md`. More broadly, any built-in suggestion/nudge yields to a standing preference that silences it.

---

## Linking a Claude Code chat to a filed issue ("ref chat")

When you file a `/project-manager` Plane issue from a Claude Code session **and** the user says to reference the chat (e.g. "ref chat", "ref this chat", "reference the cc session", or any equivalent), append a reference to the **current session's transcript path** at the **bottom of the issue description**, as the last line, in this exact form:

```
---
Claude Code chat ref: <full path to the current session .jsonl>
```

Resolve the path to the live session transcript, which on macOS is:

```
~/.claude/projects/<sanitized-cwd>/<session-id>.jsonl
```

— where `<sanitized-cwd>` is the working directory with `/` replaced by `-` (e.g. `-Users-parichay-dev`) and `<session-id>` is this session's UUID. Verify the file exists before writing the line (`find ~/.claude/projects -name '<session-id>.jsonl'`); if it can't be resolved, say so rather than guessing.

Rules:
- The ref goes **in the description body** (last line), not as a comment — `update --edits` with a `description` field replaces the whole field, so re-send the full existing description with the ref line appended.
- Only add it when the user asks ("ref chat" or similar) — never automatically on every issue.
- One ref line per issue; if one already exists, replace it rather than stacking.

---

## Repository layout (monorepo)

Each file carries its own implementation detail in its header comment / docstring; the lines below are one-clause pointers. Slash-command behavior is in the index further down + each `commands/<cmd>.md`.

```
pbrain/
├── .claude-plugin/plugin.json   ← Claude plugin manifest (this repo IS the plugin)
├── commands/                    ← all slash command .md + .sh pairs (see the index below; spec in each commands/<cmd>.md)
├── lib/vault.sh                 ← shared VAULT_DIR resolver, sourced by every command (zero-config fallback auto-creates ~/pbrain-vault; PBRAIN_NO_AUTOVAULT=1 hard-fails). Sourcing order: scaffold → update-check → prefs → self-improve → profile → profiles → projects; db before habits/reminders; launchd before reminders
├── lib/scaffold.sh              ← standalone vault-scaffold helpers (mkdir + git init + .gitignore + CLAUDE.md + config); sourced by init-obsidian.sh (pre-vault) AND vault.sh (auto-fallback)
├── lib/update-check.sh          ← upgrade nudge
├── lib/prefs.sh                 ← per-command preference injection (pbrain_emit_prefs; profile-owning cmds read prefs from the profile's "prefs" array, else <cmd>/prefs.md)
├── lib/self-improve.sh          ← feedback capture: pbrain_emit_self_improve_batch (PB-47: the sole self-improve pass — end-of-day, transcript-mining, correction-driven; the old inline per-command reflection was removed)
├── lib/profile.sh               ← fenced-JSON-block extractor (pbrain_profile_json — reads ANY profile file)
├── lib/profiles.sh              ← versioned profile store (.profile/<base>.vN.md); store/latest/draft/new/commit API in its header
├── lib/projects.sh              ← shared Plane seam layer for the daily loop (degrades to []/{} when Plane is unconfigured); never exits non-zero; detail in its header
├── lib/plane.py                 ← pbrain ↔ Plane backend (multi-project, stdlib urllib); the sole project source; seams + config in its header (incl. `workdir`/`workdirs` for PB-40 per-project working locations; `projects --sync` preserves `work`)
├── lib/plane-backup.sh          ← /project-manager backup (PB-17): pg_dump + uploads-volume snapshot → tarball, retention, local/external/vps dest, launchd schedule, restore; drives Docker directly (no plane.json); detail in its header
├── lib/vault-backup.sh          ← /vault-backup (PB-10): off-iCloud vault snapshot (tar of $VAULT_DIR + manifest) → tarball, retention, local/external/vps dest (inherits Plane's VPS host/key from plane-backup.json), launchd schedule, NON-destructive restore (extract into a dir), backup-log.md + >48h stale macOS notify; detail in its header
├── lib/plane-host.sh            ← /project-manager host (PB-18): move Plane off localhost onto a VPS — probe / deploy+domain GUIDES (setup.sh is interactive, so walked not automated) / quick-vpn no-domain access (reuse-or-install, full|split tunnel) / remote backup import (pg_restore + uploads, over SSH) / wire (repoint base_url + email-password internal auth, password → macOS Keychain). Reuses the VPS host/key from plane-backup.json; detail in its header
├── lib/migrations.sh            ← vault migration runner (lib/migrations/<NNNN_slug>.sh; ledger per vault); AUTO vs STAGED in its header. PBRAIN_MIGRATIONS=0 disables
├── lib/migrations/              ← the ordered migrations 0001–0011 (each script self-documents); see "Versioned profiles + migrations" below
├── lib/db.sh                    ← shared SQLite store (habit events incl. 3-state `status` done/skipped/missed + blocking-reminder queue + habit_reminders) + separate tracker.db init for /laptop-tracking
├── lib/launchd.sh               ← native-helper build (pbrain_swift_build) + LaunchAgent helpers; sourced before reminders.sh
├── lib/habits.sh                ← habits profile + md tracking (3-state done/skipped/missed Done-column tokens; skipped=off day, missed=real miss) + schedule-aware rollup + scored-habit evaluator (score_from_spec); formulae / auto-seed rules / habit↔reminder link in its header
├── lib/habit_schedule.py        ← habit schedule engine (is_due / derive_schedule / spacing); stdlib-only
├── lib/profile_lock.py          ← atomic read-modify-write helper for the habits profile JSON block
├── lib/reminders.sh             ← /remind (Apple Reminders) + /remind-blocking (overlay poller); FIRE/DEFER/MISS state machine + cron→recurrence mapping in its header
├── lib/pbrain-reminders.swift   ← EventKit Reminders helper source (built on demand → pbrain-reminders.app)
├── lib/pbrain-notify.swift      ← macOS notifier source (overlay's no-swiftc fallback)
├── lib/pbrain-overlay.swift     ← full-screen blocking-overlay source (/remind-blocking); plays the lifecycle chime at notif-start / blocking-start / blocking-end (--chime / --no-chime)
├── lib/assets/chime.mp3         ← bundled lifecycle chime; copied into pbrain-overlay.app/Contents/Resources on build (gate: PBRAIN_OVERLAY_CHIME, override: PBRAIN_CHIME_FILE)
├── lib/pbrain-tracker.swift     ← /laptop-tracking daemon source (resident LaunchAgent)
├── tests/                       ← bats tests for the shared lib/ helpers
├── docs/                        ← one short user-facing doc per command
├── gbrain/                      ← gbrain operations (separate from the plugin): scripts/, launchd/, docs/, .logs/ (gitignored)
├── promo-video/                 ← HyperFrames source composition for the promo video (renders gitignored)
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
- **URLs in chat output (PB-95).** `pbrain_emit_prefs` ships a baseline CHAT OUTPUT HYGIENE rule on every command run telling the agent to wrap chat URLs as `[label](url)` or in backticks and never paste a bare URL with punctuation jammed against it (the renderer swallows a trailing `.,;:)]}>` into the link target and breaks it). Author instruction text and `echo`s the same way: prefer backtick-wrapped or markdown-link URLs over bare `(https://…)` / `https://…​.` in any `.md`/`.sh`/`.txt` the agent reads or relays.
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

Sources live in `commands/`. Available in every CC session once the user symlinks `~/.claude/commands` → this repo's `commands/`, or after `/plugin marketplace add baymac/pbrain` + `/plugin install pbrain@pbrain` once it's published.

**The per-command contract lives in each `commands/<cmd>.md`** (the spec the agent reads when running/editing the command); user-facing docs are `README.md` (overview) + `docs/<command>.md`. **Env vars:** see README.md's env-var table and each command's `.sh` defaults. The index below is one line per command — purpose + default write path only.

| Command | Purpose | Default write path |
|---|---|---|
| `/init-obsidian` | bootstrap a vault (optional iCloud migration + private dir + git remote) | writes `~/.config/pbrain/vault` |
| `/init-plane` | local Plane self-host wizard (bypasses `lib/vault.sh`); superseded by `/project-manager` once a vault exists, kept as the vault-free setup path | `~/.config/pbrain/plane.json` |
| `/journal` | quiet daily journal — morning brain dump, then timestamped activity log | `life/daily-tracking/<date>.md` |
| `/brainstorm <topic>` | brainstorm a topic → idea note | `agent-work/brainstorms/tbd/` |
| `/discuss <topic>` | Socratic personal-dilemma partner; saves an insight note | `agent-work/notes/` |
| `/diet-journal` | daily diet log + versioned diet profile (targets/slots/meal-times) + food library; meal times fitness-anchored | `fitness/diet-tracking/` |
| `/fitness-journal` | flexible daily fitness journal — **logger-first with on-request session generation**. Describe your session in plain words and it derives the activity's per-activity KPIs (gym→sets, swim→distance, dance→min), tolerating partial logs; when you PLAN AHEAD (accept the owed/scheduled session, or ask to plan it) it GENERATES a complete session (gym = Block/Day rotation + progressive overload + training-gap deload; non-gym = concrete KPI targets) written as coaching note + warmup + weighted `## Planned` + cooldown + empty `## Logged` table — the same `## Planned`/`## Logged` contract Train scoring + `/end-of-day` read. KPIs live in the fitness library + are user-extensible; an activity missing `kpis` derives archetype defaults on the fly (no migration — graceful fallback + lazy save). fitness profile + activity library (fixed weekly days, per-activity KPIs) + per-activity profiles (gym Block/Day DRIVES generated gym sessions); `activity:`/`focus:`/`sleep_*` frontmatter + Train habit + `fitness-reconcile` preserved; training-gap band drives generation when planning ahead | `fitness/daily-tracking/` |
| `/finance` | personal financial tracker (analytics, not a spend limiter), **two trackers sharing one profile + month file**: EXPENSE tracker (core, always on) — `## Expenses`: transactions, spend-by-category + month total, recurring statuses, a **planned one-off expenses (rest-of-year) ledger**, and a **next-month forecast**; BALANCES tracker (**opt-in** via `track_balances`) — `## Balances`: accounts/investments net worth, income, savings rate, **runway**, planned-expense affordability. Quick-add `expense <amount> <what>` (shell extracts amount, model parses item/merchant/date, defaults to now). `ingest` paste statement/CSV/list → parse → dedupe (date+amount+normalized-desc) → categorize exactly-one (`other` fallback) → recompute. `balances on\|off` toggles the opt-in; `expense`/`ingest`/`balances`/`profile` subcommands; living merchant→category library; diet/fitness categories label-link to the journals (v1) | `life/finance-tracking/<YYYY-MM>.md` |
| `/gratitude-journal` | gratitude (3–6) + one rotated reflection question | `life/gratitude-journal/` |
| `/plan-my-day` | lays the day's LIFE structure (calendar/fitness/meals/walk/bed/habit reminders) + EMPTY work blocks; no longer assigns tasks. Reads today's fitness `focus:` (`fitness_today_activity`) and reconciles fitness-habit reminders to it (`habits.sh fitness-reconcile` — set the chosen activity's reminder, cancel + auto-skip the scheduled-but-not-chosen ones). Owns the plans profile + work/goals libraries + goals tiers; `focus`/`library`/`profile` subcommands | `life/daily-planning/<date>.md` |
| `/plan-my-work` | the WORK layer; owns goals → ready tasks → a **standalone `## Work tracker`** — a CEO-overview ledger (PB-85) that lives below daily planning and is **decoupled** from the glance work-blocks (no Block column; columns Task/Project/Plane id/Priority/Est/Status/Started/Done at/Time taken/% complete/Links/Notes). **Autonomous (PB-85):** never nudges to run another command first; scaffolds today's daily-planning file if absent (only `PLAN_MY_WORK_NO_PROFILE` still gates — the plans profile is the working-style source). Grooming/triage **delegated to `/project-manager`** (executor mode). Thin dispatcher → `templates/plan-my-work/*.txt`; `task add\|remove\|list\|execute [PB-id]` subcommand. `task execute` (PB-40) is the EXECUTION layer (the only command that touches code/branches/PRs/merges): drives the **ordered ledger** to Done one task at a time (the `.sh` emits `NEXT TASKS` = not-done rows in order, optional `PB-id` arg leads; pick→in-progress→**spec/approval gate** [PB-45]→implement→finish→PR→**double-gated merge** [CI green + typed `merge <PB-id>`]→done) in each project's `workdir` (isolated worktree/branch off fresh `origin/<base>`), then cascades row→project. **Parallel-safe (PB-85):** each session drives its own task in its own worktree; no "one in-progress at a time" rule, other in-progress rows/worktrees ignored. Auto-pull **requires Plane** (`PLAN_MY_WORK_NO_PLANE`); `task …` edits work without it | `life/daily-planning/<date>.md` |
| `/end-of-day` | fills `## How it went`, reconciles `## Work tracker` (PB-85: works in all 4 combos — pmw-only, pmd-only, both, neither — and reconciles manual Plane changes cancelled/done back into the tracker, both directions), Plane sync + unplanned detection, marks scored-habit defaults, runs `habits autostatus` (due-but-unmarked build habits → missed) before consolidate, writes `### Scoreboard` (incl. missed/skipped counts); `--date` closes a past day | `life/daily-planning/<date>.md` |
| `/weekly-review` | weekly synthesis + per-project Work review + one-at-a-time Improvements walk (mints new profile versions) + weekly-goals versioning | `life/weekly-tracking/YYYY-Www.md` |
| `/monthly-review` | monthly synthesis across the month's weekly reviews + monthly-goals versioning + optional plans-profile hygiene | `life/monthly-tracking/YYYY-MM.md` |
| `/thoughts [<text>]` | explode + append a timestamped thought (no args: asks first) | `life/thought-tracking/<date>.md` |
| `/recall <query>` | read-only case-insensitive markdown grep across the vault | — (read-only) |
| `/loose-ends` | read-only dashboard of unresolved threads (stale brainstorms, open questions, carry-forward, focus drift) | — (read-only) |
| `/organize-clippings` | file `Clippings/` into chosen top-level vault dirs | user-chosen vault dirs |
| `/habits` | habits profile + dated md tracking + scored-habit defaults + Apple-Reminder linking; see `commands/habits.md` | `life/habit-tracking/` |
| `/remind <text>` | natural-language Apple Reminders (EKReminder), not Calendar; recurrence via cron→RRULE; see `commands/remind.md` | Apple Reminders (no vault write) |
| `/remind-blocking <text>` | full-screen blocking reminders; SOLE owner of the SQLite reminders store; poller tick | SQLite DB (no vault write) |
| `/laptop-tracking` | resident macOS usage tracker → per-day report; focus-breakdown feeds the Deep-work score | `life/laptop-tracking/<date>.md` |
| `/project-manager` | the Plane commander and **sole** project backend (absorbs `/init-plane` setup + Plane ops). The **sole writer** of Plane — drive it in plain words ("bump PB-26 to high, tag backend"): a **natural-language router** resolves the issue (`find` by link/id/fuzzy name) and edits ANY field (priority/dates/description/labels/assignee-by-name/comments/re-parent/cycle/module/relations/sub-issues) via the verb catalogue. Also `explode <ref>` (PB-24): interactively break ONE issue into sub-issues via a Socratic AskUserQuestion walk (like `/discuss`). Also `spec <ref>` (PB-45): the spec/approval gate — a Socratic walk that drafts a `## Implementation Plan` into the issue description and, on explicit approval, adds the `plan-approved` label; an approved issue lets `/plan-my-work task execute` skip its live planning gate (`spec <ref> --read` = JSON-only read of plan + approval). Also `file "<dump>"` (aliases `create`/`track`/`capture`, PB-67): the generic work-item intake & triage convention — explodes a free-text dump into a triage-ready item of ANY type (bug/feature/docs/chore/refactor/improvement, inferred), with a `--fast` infer+one-confirm path and a default full Socratic build-up (type → body → sub-issues → labels → estimate → priority → deadline), dedupes against open items, and sets the type's convention label + a severity-derived priority for bugs. The convention labels `bug`/`feature`/`chore`/`docs` are seeded into every project on create and backfillable via `labels --seed [--projects R,…]` (PB-70). **Dual-mode** (executor when `/plan-my-work` calls it, goal-aware when direct); label-creation guardrails; manual-UI fallback for the ~10% the API can't do. Also `backup` (PB-17): daily Plane snapshots (pg_dump + uploads) → local/external/vps with retention + restore, runs without Plane wired (drives Docker directly). Also `workdir` (PB-40): records the per-project working location (`projects[].work` in plane.json) that `/plan-my-work task execute` runs tasks in — the sole-writer rule extends to this config write. Needs a vault; ops emit `PM_NOT_CONFIGURED` when unset | Plane (no vault write) |
| `/vault-backup` | off-iCloud vault backup (PB-10) — nightly `tar.gz` of `$VAULT_DIR` → local/external/**vps** (inherits Plane's VPS host/key from `plane-backup.json`; distinct remote path) with retention, daily launchd, per-run `vault/.pbrain/backup-log.md`, **non-destructive** restore (extract into a dir), >48h stale macOS notify. Sibling of `/project-manager backup`; sources `lib/vault-backup.sh`. `status\|estimate\|now\|enable\|disable\|config\|list\|restore\|check` | `~/.config/pbrain/vault-backups/` (config `vault-backup.json`, mode `0600`) |
| `/clipper <platform> <url>` | save an online video as a clean, faithful long-form transcript ("clip"); platform subcommands (`x` / `yt`); the `.sh` does cookies/download/VTT-cleanup/transcription fallback, the model only reframes prose | `agent-work/clips/<platform>/<slug>.md` |
| `/codex-install` | Codex interop generator — skills + managed `AGENTS.md` from the same `commands/*.md` sources | `$CODEX_HOME/skills/pbrain-<cmd>/` |

`/init-obsidian`, `/codex-install`, and `/init-plane` are the commands that don't go through `lib/vault.sh` — they're setup commands that must run before/around a vault being configured (or, for `/init-plane`, need no vault at all). `/init-obsidian` writes the config every other command reads; `/codex-install` only reads it (read-only resolve, never exits if absent); `/init-plane` is independent of the vault entirely. (`/remind-blocking tick`, the background poller path, also bypasses `lib/vault.sh` on purpose — it only needs the DB, and must not exit when no vault dir exists.)

### Versioned profiles + migrations

**Every profile-owning command keeps its base config in a versioned store** (`lib/profiles.sh`): `<tracking-dir>/.profile/<base>.vN.md` — markdown + frontmatter (`version: N`, `committed: true|false`) + a fenced ```json block (read with `pbrain_profile_json`). The rules:

- Commands READ the highest **committed** version (`pbrain_profile_latest`). An explicit `PBRAIN_<X>_PROFILE_FILE` env override always wins (no versioning, also bypasses that command's staged-migration prompt).
- **Committed = final.** Changes mint the next version: each owning command exposes `profile show|new|commit [base]` — `new` mints an editable draft (copied from the latest; refuses while a draft is open), `commit` freezes it. `/weekly-review`'s Improvements walk drives this for approved week-end changes.
- **Libraries are living documents** (food-library, work-library, goals-library, fitness-library; the habits profile behaves the same for `add`/`edit`/`archive`): entries append/amend in place on the latest version — version mints only on structural rebuilds.
- Which `.profile/` bases each command owns is listed in its `commands/<cmd>.md` (plan-my-day, habits, fitness-journal, diet-journal).

**Migrations** (`lib/migrations.sh` + `lib/migrations/<NNNN_slug>.sh`) move old data into this shape exactly once per vault, DB-migration style: the applied-set ledger is `$VAULT_DIR/.pbrain/migrations/<id>.done` — correctness is **ledger-based, not semver-based**. `pbrain_run_migrations` (called from `vault.sh` on every command) applies unapplied AUTO migrations in id order (file moves; originals parked in `.pbrain/backup/`) and records vacuously when there is nothing to do. STAGED migrations (need an LLM rebuild validating old data **part by part** with the user) stay pending until their owning command's next run emits the rebuild block; recording happens via `bash lib/migrations.sh record <id>`. `PBRAIN_MIGRATIONS=0` disables (set in every bats suite that runs command scripts).

**Editing a migration that hasn't shipped yet — DON'T stack a new one on top.** A migration is only "live" once it has merged to `main` (and so may already sit in someone's ledger as `.done`). Before you add a *new* migration that builds on or supersedes one introduced in this same unmerged branch, check the branch state first: if the prior migration is **not merged** (still on a working/PR/uncommitted branch, never run against a real vault), then **edit that migration in place** instead of appending the next-numbered one. When the work involves the build agent (you), pause and **ask the user**: do they want a *new* migration, or to fold the change into the unmerged one (or drop the unmerged migration's changes entirely)? The default for unshipped work is fold-in-place.

Why: a never-applied migration has no ledger entries anywhere, so rewriting it is safe and loses nothing — whereas a merged migration is immutable history you must never rewrite (someone may already have run it; only a *new* higher-numbered migration can change its outcome). Example: migration `0006` (unmerged) does "move life profile → goals profile". You then decide goals profile should split into v1 + v2. Do **not** add `0007` "migrate goals profile → goals-profile v1 + v2" — just rewrite `0006` so it does "life profile → goals-profile v1 + v2" directly. Only once `0006` is on `main` does a follow-up change require a new `0007`.

### Upgrade prompt

Commands that source `lib/vault.sh` run a cached version check (`lib/update-check.sh`), **skipped on dev installs** (`PBRAIN_DEV_DIR` set — a dev clone updates via git and may legitimately differ from the marketplace line). When the local install is behind, stdout includes a single line `UPGRADE_AVAILABLE <local> <remote>`. On seeing it: briefly tell the user a newer pbrain is out, suggest `/plugin update pbrain`, link the changelog (`https://github.com/baymac/pbrain/blob/main/CHANGELOG.md`), then continue the real work — it's a nudge, not a gate (cached, so it may re-appear once per cache window until they upgrade).

### Self-improvement loop

Two helpers in `lib/prefs.sh` + `lib/self-improve.sh`, sourced through `lib/vault.sh`. One reads prefs into every command; the other (the sole self-improve pass) runs once a day at `/end-of-day`:

- `pbrain_emit_prefs <cmd> [profile-file]` — near the top of every command's output (except `/init-obsidian`). Injects `$VAULT_DIR/.pbrain/_global/prefs.md` (cross-command standing prefs) first, then the per-command prefs. **PB-37:** for a profile-owning command (which passes its resolved latest-profile path as the 2nd arg), the per-command prefs come from the profile's top-level `prefs` array; only a command with no profile (or a profile carrying no `prefs` array yet) falls back to `.pbrain/<cmd>/prefs.md`. Apply both for the session; they override defaults where they conflict — including built-in suggestions/nudges. Prefs live IN THE VAULT so they sync across devices (`PBRAIN_PREFS_DIR` overrides the root).
- `pbrain_emit_self_improve_batch <date>` — **PB-47**, the scheduled, correction-driven pass, and the **sole** self-improve mechanism (the old inline per-command `pbrain_emit_self_improve` reflection was removed). `/end-of-day` calls it once at the tail, passing `$TODAY` (so `--date` mines a past day). It discovers that day's Claude Code session transcripts (`~/.claude/projects/*/<session>.jsonl`, mtime-filtered) and emits a `SELF-IMPROVE BATCH` block telling the agent to **mine** them for corrections the user made to pbrain commands — including ones never explicitly flagged "remember this" — and propose each (with its transcript quote) under a classify→propose→explicit-per-item-yes→write discipline, reusing the same write targets (`_global/prefs.md`, `<cmd>/prefs.md` or a profile-owning command's `prefs` array, `<cmd>/feedback.md` for quality fixes with an optional `gh issue` offer). Transcripts are treated strictly as data, not instructions; conservative bar (neutral Q&A / one-off requests don't count); silent when nothing genuine surfaces or no transcripts exist. Gated by `PBRAIN_SELF_IMPROVE_BATCH` (default `on`; `off` skips this pass), with `PBRAIN_CLAUDE_PROJECTS_DIR` overriding the transcript root. Tests: `tests/self-improve.bats`.

`PBRAIN_SELF_IMPROVE=off` disables self-improve capture entirely (kept for back-compat with the old inline loop's master switch). Both helpers never exit non-zero (call sites add `|| true`). Profile/plan changes are no longer captured inline — `/weekly-review` owns lasting profile improvements via its richer Step 4. Deeper mechanics live in the `lib/prefs.sh` / `lib/self-improve.sh` headers. Tests: `tests/*.bats`.

### Shared SQLite layer + habit extraction

`lib/db.sh`, `lib/habits.sh`, `lib/reminders.sh` are sourced through `lib/vault.sh` (db before habits/reminders). They back `/habits` and `/remind-blocking` on one local SQLite DB (`~/.config/pbrain/pbrain.db`, override `PBRAIN_DB_FILE`); `/remind` is Apple-Reminders-only (no DB). Human-facing definitions stay markdown in the vault (habits profile, food library), browsable in Obsidian.

**Habit logging is markdown-first** — the dated checklist (`life/habit-tracking/<date>.md`) is the source of truth; the SQLite DB is *derived* from it. `pbrain_emit_habits_extract <cmd>` rides along like the self-improve helpers: it tells you to `mark` any tracked habits the user evidenced this session (via `commands/habits.sh mark …` — not a direct DB write), plus a gated suggest-new-habit nudge. It is **silent when no habits profile exists**, so it costs nothing until the user opts in. The full wiring — which commands sync/consolidate, and the one cross-write (the habit↔reminder per-day one-shot link) — lives in the `/habits` + `/remind` specs (`commands/habits.md`, `commands/remind.md`) and the `lib/habits.sh` / `lib/reminders.sh` headers. All these helpers never exit non-zero (tests in `tests/db.bats`, `tests/habits.bats`, `tests/reminders.bats`).

### Codex interoperability

pbrain is a Claude Code plugin first; the OpenAI **Codex CLI** is a supported *secondary* runner. The invariant: **the `.sh` files are the agent-agnostic single source of truth** — nothing in them is Claude-specific, and you must **not fork behaviour per agent**. `/codex-install` (run from Claude Code after `/init-obsidian`) generates Codex entry points from the same `commands/*.md` sources — one `skills/pbrain-<cmd>/SKILL.md` per command + a managed, delimited `AGENTS.md` block — and shares one vault / config dir / DB / script set with Claude Code, so alternating runners is safe and re-running the installer is idempotent. The skill-body-transform mechanics + the why-skills-not-custom-prompts rationale live in `commands/codex-install.sh` / `docs/codex-install.md`. Tests: `tests/codex-install.bats`.

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
