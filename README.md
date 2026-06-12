# pbrain

> **Daily-ritual scaffolding for Obsidian + Claude Code.** Local-first slash commands for journaling, gratitude, fitness, diet, daily planning, brainstorming, and clipping triage. macOS only. Your vault stays on your machine — no accounts, no servers, no telemetry.

## Demo

<img src="docs/media/pbrain-promo.gif" alt="pbrain demo — a daily ritual in your terminal" width="100%">

<!-- GIF autoplays inline on GitHub. mp4 link above for HD+audio. Source composition: promo-video/ (HyperFrames). -->

**Obsidian** is the writing surface. A markdown **vault** is the corpus (iCloud-synced or plain local — your choice). **pbrain** slash commands handle the rituals. Optionally, **gbrain** adds an AI memory layer exposed to Claude via MCP.

**Compatibility:** macOS only (Obsidian Desktop + iCloud Drive container). iOS works for read/write through the synced vault on iPhone/iPad, but the slash commands themselves run from Claude Code on macOS (or the OpenAI Codex CLI — see [Codex interoperability](#codex-interoperability)). Linux, Windows, and Android aren't supported.

The pbrain slash commands work against **any** vault directory you point them at — `PBRAIN_VAULT` env var, a path written to `~/.config/pbrain/vault`, or the default iCloud Obsidian path. `/init-obsidian` handles the setup.

---

## Architecture

![pbrain architecture](docs/diagrams/architecture.svg)

<!-- Source: docs/diagrams/architecture.d2 — re-render with:
     d2 --theme 0 --dark-theme 200 --pad 20 docs/diagrams/architecture.d2 docs/diagrams/architecture.svg -->

The flow:

- **Obsidian (Mac + iOS)** — where you write — syncs the **vault/** (a standalone git repo) across devices over iCloud.
- The vault holds `life/` (daily journal), domain folders (`fitness/`, `startup/`, `side-quests/`, `software-dev/`, …), and `agent-work/` (everything Claude generates — `brainstorms/`, `chat-history/`, `drafts/`, `notes/`, `research/`, `people/`).
- A launchd job runs **gbrain sync** every 30 min, indexing the vault into a local **gbrain index** (PGLite + Ollama embeddings, `~/.gbrain/` — local-only, free, private).
- **Claude Code** and **Claude Desktop** both reach that index over MCP (stdio).

---

## Quick start

The stack is three independent layers — pick what you need.

### Minimal: plugin + vault (everyone starts here)

```bash
# 1. Install the plugin — two steps (register the marketplace, then install)
/plugin marketplace add baymac/pbrain
/plugin install pbrain@pbrain
#    If either step fails, use the Local development path below — same
#    commands, just symlinked from a local clone.

# 2. Bootstrap a vault — checks for Obsidian, creates the vault,
#    optionally migrates it to iCloud for mobile sync, sets up a private
#    notes dir, writes config. Idempotent.
/init-obsidian

# 3. Start using it
/journal              # morning anchor — raw dump first, clears the head
/gratitude-journal    # then gratitude, on cleared ground (second)
/brainstorm "idea"    # quick idea dump
/plan-my-day          # goal-anchored daily planner (first run sets up your goals)
```

That's it for the core experience. `/init-obsidian` writes `~/.config/pbrain/vault` so every other command knows where to write.

### What `/init-obsidian` does

First-run setup — you only need it once. Every other command reads `~/.config/pbrain/vault` and just works after this is done. Re-running is safe (idempotent) but only useful if you're switching vault locations, adding a git remote later, or adding the private dir after the fact.

![/init-obsidian flow](docs/diagrams/init-obsidian.svg)

<!-- Source: docs/diagrams/init-obsidian.d2 — re-render with:
     d2 --theme 0 --dark-theme 200 --pad 20 docs/diagrams/init-obsidian.d2 docs/diagrams/init-obsidian.svg -->

Step by step:

1. **PROBE state** — checks whether Obsidian.app is installed, `~/.config/pbrain/vault` is valid, and the iCloud Obsidian container is present.
2. **Already configured?** → if yes, report status and exit (or offer the optional add-ons below).
3. **Obsidian.app missing?** → prompt `brew install --cask obsidian`.
4. **PICK vault location** — default (`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault`) or any custom path.
5. **BOOTSTRAP** (idempotent — re-running on an existing vault leaves it alone): `mkdir` the vault dir, `git init`, write `vault/.gitignore` (`.gbrain/`, `.DS_Store`, `private.nosync/`), write `vault/CLAUDE.md` (project-level CC instructions for sessions opened inside the vault — *not* slash commands, those live in `~/.claude/commands`), initial commit, then write `~/.config/pbrain/vault` (the pointer every other command reads).
6. **Optional add-ons** (asked one-by-one): MIGRATE from an existing vault (rsync old → new, verify file count, source preserved for manual delete); SET UP `vault/private.nosync/` for off-iCloud / off-git notes; ADD a git remote + push.

**What's written inside the vault:** `vault/.gitignore`, `vault/CLAUDE.md`, optionally `vault/private.nosync/README.md`. That's it. Slash commands are *never* installed into the vault — they live in `~/.claude/commands` (via `/plugin install` or `scripts/install-commands.sh`).

**What's written outside the vault:** `~/.config/pbrain/vault` (one-line text file with the vault path).

### Local development

Clone the repo and run the install script — it symlinks each command into `~/.claude/commands/` individually, so every CC session anywhere picks them up with no re-install, and any non-pbrain commands you already have there are preserved:

```bash
git clone https://github.com/baymac/pbrain.git ~/code/pbrain
~/code/pbrain/scripts/install-commands.sh
```

The script is idempotent — re-run it after `git pull` if new commands land. If you previously symlinked the whole `commands/` directory, the script detects that and replaces it with per-file links.

The install script also makes **live edits to `.sh` scripts take effect immediately**: it registers your clone as `PBRAIN_DEV_DIR` in `~/.claude/settings.json`, so the command wrappers always execute from your live repo instead of the marketplace snapshot. Restart Claude Code / Conductor once after the first install for the env change to load. `scripts/uninstall-commands.sh` removes that entry again (only if it still points at this clone).

> Prefer `settings.json` over a `~/.zshrc` export here: GUI-launched apps (Conductor, the desktop app) don't source `~/.zshrc`, so a shell-profile export is invisible to them — the wrappers fall back to the stale marketplace snapshot and your edits don't run. The `settings.json env` block is read regardless of how the app was launched. The install script writes it for you, but if you set it by hand, put it there.

Run pbrain commands from **any directory** — your current project, a Conductor workspace, the tooling repo, wherever you are. The vault path is resolved from your config (`$PBRAIN_VAULT` → `~/.config/pbrain/vault` → iCloud default), never from cwd. Notes always land in the right place.

#### Troubleshooting

Commands not showing up after running the install script?

1. **Restart Claude Code.** Slash commands are loaded at session start; sessions opened before the symlinks existed won't see them.
2. **Stale startup cache.** Rare, but if a full restart still doesn't surface them: `rm ~/.claude/.last-cleanup` and restart CC.
3. **Broken symlinks.** If you deleted or moved the cloned repo, the per-file symlinks under `~/.claude/commands/` will be dangling. Re-clone and re-run `scripts/install-commands.sh`.

---

## Vault structure

User-curated topical folders live at the root. Claude-generated content lives under `agent-work/`.

| Directory | What goes here |
|---|---|
| `life/daily-tracking/` | Daily journal entries (created by `/journal`) |
| `life/`, `fitness/`, `startup/`, `notes/`, etc. | Your hand-curated topical folders (whatever shape you want) |
| `agent-work/brainstorms/tbd/` | `/brainstorm` outputs (active, default landing). |
| `agent-work/brainstorms/backlog/` | Parked ideas — not now, not dropped. |
| `agent-work/brainstorms/done/` | Actioned, shipped, or set aside. |
| `agent-work/chat-history/` | Chat takeaways saved on request |
| `agent-work/drafts/` | Drafts written by Claude |
| `agent-work/notes/` | Misc agent-captured notes |
| `agent-work/research/` | Web summaries, research outputs |
| `agent-work/people/` | People pages (auto-enriched or hand-written) |

Concepts, sources, ideas, etc. are **co-located** with their topic — e.g. `startup/<your-app>/ideas/`, `side-quests/<your-hobby>/sources/` — not at the vault root.

---

## Slash commands

Packaged as the **pbrain** Claude plugin (manifest at `.claude-plugin/plugin.json`). One short doc per command under [`docs/`](docs/).

| Command | What it does | Default path |
|---|---|---|
| `/journal` | Today's daily note | `$VAULT/life/daily-tracking/` |
| `/gratitude-journal` | Gratitude + reflection (runs after `/journal`) | `$VAULT/life/gratitude-journal/` |
| `/plan-my-day` | Goal-anchored daily planner | `$VAULT/life/daily-planning/` |
| `/end-of-day` | Close-of-day completion pass (bookend to `/plan-my-day`) | fills `## How it went` (executive summary + carry-forward) in `$VAULT/life/daily-planning/<date>.md` (in place) |
| `/weekly-review` | 7-day synthesis across journal, gratitude, plan, fitness, diet; weekly goals lifecycle | `$VAULT/life/weekly-tracking/YYYY-Www.md` |
| `/monthly-review` | Month-end synthesis across weekly reviews; monthly goals versioning; plans-profile hygiene pass | `$VAULT/life/monthly-tracking/YYYY-MM.md` |
| `/brainstorm <topic>` | New brainstorm file | `$VAULT/agent-work/brainstorms/tbd/` |
| `/discuss <topic>` | Personal dilemma discussion — Socratic, one question at a time, saves insight note | `$VAULT/agent-work/notes/` |
| `/recall <topic>` | Grep-based search across vault narrative folders | (read-only — prints matches) |
| `/loose-ends` | Surfaces stale ideas, open questions, todos, deferred seeds, focus drift | (read-only — surfacing dashboard) |
| `/habits` | Track habits, each with its own criteria (daily / N-per-week / N-per-month, build or cap); day-to-day log in dated `life/habit-tracking/<date>.md` files (DB synced from them for analysis); progress vs each, top 20 by priority; auto-marked from your journals | `$VAULT/life/Habits Profile.md` + `$VAULT/life/habit-tracking/` + local DB |
| `/thoughts [<text>]` | Explode and log a timestamped thought mid-day; on-demand, any time | `$VAULT/life/thought-tracking/` |
| `/remind <text>` | Real Apple Reminders (EKReminder) — timed due date, cron-based recurrence, priority, early alarms; create/list/edit/done/cancel. Reminders + iCloud fire and sync. NOT a calendar anchor for `/plan-my-day` | Apple Reminders (no vault file, no DB) |
| `/remind-blocking <text>` | Reminders that fire as a full-screen blocking overlay ("Take a break"; hold Control to skip / let countdown run for done); cron-flexible schedules, fires via its own background poller. 10s warning panel before the overlay drops; overlay persists across screen lock/unlock (re-appears with countdown adjusted) | local SQLite DB (no vault file) |
| `/laptop-tracking` | Resident macOS daemon: which app + for how long, and browser DOMAIN (+ per-video YouTube rows), excluding locked/idle/asleep time (a playing video still counts). Background audio/video (music, PiP) tracked separately as `bg_media` — excluded from focus time, shown in its own section. `report` shows the full 00:00→24:00 window for past days, a browser attribution table for unresolved domain time, and per-video YouTube rows. `start \| access \| status \| report \| stop` | `$VAULT/life/laptop-tracking/YYYY-MM-DD.md` (domain-level; granular DB is local-only, never synced) |
| `/diet-journal` | Diet log + nutrition analysis + named-food library | `$VAULT/fitness/diet-tracking/` |
| `/fitness-journal` | Adaptive workout for today | `$VAULT/fitness/daily-tracking/` |
| `/organize-clippings` | Sort `Clippings/` into the right folders | source: `$VAULT/Clippings/` |

### Daily flow

The commands compose into a full-day ritual. Run them top-to-bottom — most are zero-input, just type the slash command and answer the prompts.

![pbrain daily flow](docs/diagrams/daily-flow.svg)

<!-- Source: docs/diagrams/daily-flow.d2 — re-render with:
     d2 --theme 0 --dark-theme 200 --pad 20 docs/diagrams/daily-flow.d2 docs/diagrams/daily-flow.svg -->

| When | Command | What you do |
|---|---|---|
| Morning, before anything else | `/journal` | Raw dump first: today's mood, yesterday's residue, random thoughts, whatever's loud. Then answer the open questions it asks. Clears the head. |
| Right after journaling | `/gratitude-journal` | Just run it — answers the prompts. With the head cleared, gratitude anchors the day to *enough* before agent work starts. |
| Pre/post workout | `/fitness-journal` | Just run it — it picks today's session based on your activity rotation and asks you to log sets/reps. |
| With meals (or end of day) | `/diet-journal` | Just run it — log what you ate, get a nutrition + plan-adherence read. Say "nothing yet" and it plans the full day from your food library. |
| Once mind is clear | `/plan-my-day` | Just run it — goal-anchored daily plan. First run sets up your goals; subsequent runs reuse them. |
| End of day | `/end-of-day` | Just run it — close-of-day reflection. Bookends `/plan-my-day`: what shipped, what slipped, what carries over. |

`/thoughts [<text>]`, `/brainstorm <topic>`, `/discuss <topic>`, `/recall <query>`, `/loose-ends`, `/weekly-review`, `/monthly-review`, `/habits`, `/remind <text>`, `/remind-blocking <text>`, `/laptop-tracking`, and `/organize-clippings` are on-demand — not part of the daily loop. Pull them in when needed. (`/habits` also surfaces automatically inside `/plan-my-day` and `/end-of-day`, and habits get logged from your journaling sessions without you asking. `/remind` lives in Apple Reminders and does not surface there.)

![pbrain on-demand commands](docs/diagrams/on-demand.svg)

<!-- Source: docs/diagrams/on-demand.d2 — re-render with:
     d2 --theme 0 --dark-theme 200 --pad 20 docs/diagrams/on-demand.d2 docs/diagrams/on-demand.svg -->

Each command's default path is overrideable via env var. Full reference:

| Env var | Used by | Default |
|---|---|---|
| `PBRAIN_DEV_DIR` | all commands | — (see Local dev below) |
| `PBRAIN_VAULT` | all | iCloud Obsidian path |
| `PBRAIN_SELF_IMPROVE` | all commands (self-improve loop) | `prefs` — also `off` (disable) or `dev` (propose source edits; needs `PBRAIN_DEV_DIR`) |
| `PBRAIN_PREFS_DIR` | all commands — preferences ROOT (`_global/prefs.md` + per-command `<cmd>/prefs.md`) | `$VAULT/.pbrain` |
| `PBRAIN_FEEDBACK_DIR` | all commands — quality-fix ROOT (`<cmd>/feedback.md`) | `$VAULT/.pbrain` |
| `PBRAIN_MIGRATIONS` | all commands — set `0` to disable the vault migration runner | `1` |
| `PBRAIN_DB_FILE` | `/habits`, `/remind-blocking` (shared SQLite store: habit events + blocking-reminder queue; `/remind` does NOT use the DB) | `~/.config/pbrain/pbrain.db` |
| `PBRAIN_REMINDERS_LIST` | `/remind` (which Apple Reminders list to create/read in) | unset → system default list |
| `PBRAIN_REMINDER_MARKER` | `/remind` (hidden notes marker tagging pbrain reminders) | `⟦pbrain-reminder⟧` |
| `PBRAIN_REMINDERS_APP` | `/remind` (cached build of the EventKit Reminders helper app) | `~/.config/pbrain/pbrain-reminders.app` |
| `PBRAIN_NOTIFY_APP` | `/remind-blocking` (cached build of pbrain's macOS notifier — the overlay's no-swiftc fallback) | `~/.config/pbrain/pbrain-notify.app` |
| `PBRAIN_NOTIFY_IDENTITY` | `/remind-blocking` (bundle id the notifier delivers under; `""` = no impersonation) | unset → `com.apple.Terminal` |
| `PBRAIN_OVERLAY_APP` | `/remind-blocking` (cached build of pbrain's full-screen overlay app) | `~/.config/pbrain/pbrain-overlay.app` |
| `PBRAIN_OVERLAY_BG` | `/remind-blocking` (default overlay background colour, hex) | unset → slate |
| `PBRAIN_TRACKER_DB_FILE` | `/laptop-tracking` (its OWN local SQLite DB — segments; never synced to the vault) | `~/.config/pbrain/tracker.db` |
| `PBRAIN_TRACKER_APP` | `/laptop-tracking` (cached build of the resident tracker daemon app) | `~/.config/pbrain/pbrain-tracker.app` |
| `PBRAIN_TRACKER_DIR` | `/laptop-tracking` (daily report write dir) | `$VAULT/life/laptop-tracking` |
| `PBRAIN_TRACKER_POLL` / `PBRAIN_TRACKER_IDLE` | `/laptop-tracking` (daemon poll interval / idle-away threshold, seconds) | `10` / `300` |
| `PBRAIN_THOUGHTS_DIR` | `/thoughts` | `$VAULT/life/thought-tracking` |
| `PBRAIN_JOURNAL_DIR` | `/journal`, read by `/plan-my-day`, `/loose-ends` | `$VAULT/life/daily-tracking` |
| `PBRAIN_BRAINSTORMS_DIR` | `/brainstorm`, read by `/loose-ends` | `$VAULT/agent-work/brainstorms` |
| `PBRAIN_NOTES_DIR` | `/discuss` | `$VAULT/agent-work/notes` |
| `PBRAIN_DIET_DIR` | `/diet-journal` | `$VAULT/fitness/diet-tracking` |
| `PBRAIN_DIET_PROFILE_FILE` | `/diet-journal` (explicit file override; bypasses the versioned store) | latest committed `diet-profile.vN.md` in `$VAULT/fitness/diet-tracking/.profile/` |
| `PBRAIN_FOOD_LIBRARY_FILE` | `/diet-journal` (named-food library — log by name; override) | latest `food-library.vN.md` in the diet store |
| `PBRAIN_FITNESS_DIR` | `/fitness-journal`, read by `/diet-journal`, `/plan-my-day` | `$VAULT/fitness/daily-tracking` |
| `PBRAIN_GYM_PLAN_FILE` / `PBRAIN_FITNESS_PLANS_DIR` / `PBRAIN_FITNESS_ACTIVITIES_FILE` | legacy paths — read only by the one-time fitness migration (0003) | — |
| `PBRAIN_GRATITUDE_DIR` | `/gratitude-journal` | `$VAULT/life/gratitude-journal` |
| `PBRAIN_PLAN_DIR` | `/plan-my-day`, `/end-of-day`, `/weekly-review`, `/loose-ends` | `$VAULT/life/daily-planning` |
| `PBRAIN_PLAN_PROFILE_FILE` | `/plan-my-day`, read by `/loose-ends`, `/discuss`, `/weekly-review` (explicit override) | latest committed `plans-profile.vN.md` in `$VAULT/life/daily-planning/.profile/` |
| `PBRAIN_HABITS_PROFILE_FILE` | `/habits`, read by `/plan-my-day`, `/end-of-day`, `/weekly-review` (explicit override) | latest committed `habits-profile.vN.md` in `$VAULT/life/habit-tracking/.profile/` |
| `PBRAIN_HABIT_TRACK_DIR` | `/habits` (dated tracking files), synced→DB by `/plan-my-day`, `/end-of-day`, `/weekly-review` | `$VAULT/life/habit-tracking/` |
| `PBRAIN_HABIT_SUGGEST_FILE` | `/habits` + journaling commands (new-habit nudge suppress-list) | `~/.config/pbrain/habit-suggest-seen` |
| `PBRAIN_HABIT_SUGGEST_TTL_DAYS` | `/habits` + journaling commands | `14` (days a suggested habit stays suppressed) |
| `PBRAIN_WEEKLY_DIR` | `/weekly-review` | `$VAULT/life/weekly-tracking` |
| `PBRAIN_MONTHLY_DIR` | `/monthly-review` | `$VAULT/life/monthly-tracking` |
| `PBRAIN_RECALL_SCOPE` | `/recall` | `life agent-work startup side-quests software-dev notes` (space-separated subdirs relative to vault) |
| `PBRAIN_STALE_DAYS` | `/loose-ends` | `7` (age at which an item counts as stale) |
| `PBRAIN_LOOSE_ENDS_LOOKBACK` | `/loose-ends` | `30` (days of journals/plans to scan) |
| `PBRAIN_CLIPPINGS_DIR` | `/organize-clippings` | `$VAULT/Clippings` |
| `PBRAIN_CLIPPINGS_TARGETS` | `/organize-clippings` | (interactive prompt — set to `all` or a comma-separated subset to skip it) |
| `CODEX_HOME` | `/codex-install` | Codex home dir to install skills + AGENTS.md into (default `~/.codex`) |


The vault root is resolved via `PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud path, in that order.

---

## Codex interoperability

pbrain is primarily a Claude Code plugin, but the same commands can run from the **OpenAI Codex CLI** — useful if you (or someone you share with) live in Codex. Run `/codex-install` **from Claude Code, once, after `/init-obsidian`**:

```bash
/init-obsidian            # set up the vault (Claude Code)
/codex-install            # wire pbrain into Codex   (Claude Code)
```

It generates, under `$CODEX_HOME` (default `~/.codex`):

- `skills/pbrain-<command>/SKILL.md` — one Codex **agent skill** per pbrain command, each a thin wrapper that runs the *same* `commands/<command>.sh`. Codex discovers them automatically; invoke by plain name (`journal`, `plan my day`, `brainstorm should I build X`), explicitly as `$pbrain-journal`, or just describe the task and let Codex auto-select. (`init-obsidian` and the installer itself stay Claude-only.)
- a managed, clearly-delimited **pbrain block** in `AGENTS.md` with the cross-command behaviour Codex needs (how to invoke, morning sequence, ride-along blocks, vault write rules, launch command) — scoped so it won't affect unrelated Codex sessions.

> Don't type `/journal` in Codex — its CLI rejects unknown `/slash` commands before the model sees them. Invoke pbrain by plain name.

**One source of truth, no conflicts.** The skills reimplement nothing — they run the same shell scripts and resolve the same vault + `~/.config/pbrain` config + SQLite DB at runtime. Alternating between Codex and Claude Code on the same machine can't get out of sync. Re-run `/codex-install` after moving/reinstalling pbrain or when new commands ship (idempotent; prunes only its own stale skills, never yours).

**Launching Codex** so pbrain can write to the vault and config without per-write approval: the installer writes a `codex-pbrain` shell function to your RC file — `source ~/.zshrc`, then just run `codex-pbrain`. Equivalent manual launch (the installer prints it with your real vault path):

```bash
codex --sandbox workspace-write --add-dir "/path/to/your/vault" --add-dir "$HOME/.config/pbrain"
```

Full details: [`docs/codex-install.md`](docs/codex-install.md). (pbrain originally used Codex *custom prompts*; those are now deprecated and were undiscoverable on recent Codex builds, so it moved to **agent skills** — the supported, default-on mechanism. Re-running `/codex-install` migrates you automatically.)

---

## Private notes

If you went with the iCloud-synced vault, you can keep notes off git **and** off iCloud using the `.nosync` suffix convention. `/init-obsidian` offers to set up `vault/private.nosync/` automatically.

---

## Optional: gbrain (AI search over the vault) — 🚧 not working, fix coming in a future release

gbrain adds hybrid vector + keyword search and exposes it to Claude via MCP — so Claude can recall what you wrote weeks ago. **Not required for any of the commands above.**

> 🚧 **Currently broken.** A recent upstream schema migration causes the scheduled launchd sync to hang. The brain only stays fresh while Claude is open (MCP writes go through `gbrain serve` in-process); scheduled background sync is **disabled by default**. Skip this section for now — everything else in pbrain works without it. **Will be fixed in a future release.** Details: [`gbrain/docs/gbrain-sync.md`](gbrain/docs/gbrain-sync.md) · upstream repro: [`gbrain/docs/gbrain-bug-report.md`](gbrain/docs/gbrain-bug-report.md).

```bash
brew install ollama && brew services start ollama && ollama pull nomic-embed-text
git clone https://github.com/garrytan/gbrain.git ~/code/gbrain
cd ~/code/gbrain && bun install && bun link
cd "$(cat ~/.config/pbrain/vault)" && gbrain init --pglite --embedding-model ollama:nomic-embed-text --embedding-dimensions 768
gbrain config set embedding_model ollama:nomic-embed-text
gbrain sync --repo . --skip-failed
claude mcp add gbrain "$HOME/.bun/bin/gbrain" serve
# Optional (currently degraded — see note above):
# ./gbrain/scripts/install-launchd.sh
```

Full setup: [`gbrain/docs/setup.md`](gbrain/docs/setup.md). What gbrain unlocks beyond search: [`gbrain/docs/gbrain-beyond-notes.md`](gbrain/docs/gbrain-beyond-notes.md).

---

## Repository structure

The repo *is* the plugin — a single-plugin Claude marketplace would just nest the same files under `plugins/pbrain/` for no gain. `gbrain/` stays separate because it's not part of the plugin distribution; it's local sync glue.

```
pbrain/
├── .claude-plugin/
│   └── plugin.json                     ← Claude plugin manifest
├── commands/                           ← .md + .sh pairs for each slash command
├── lib/
│   ├── vault.sh                        ← shared VAULT_DIR resolver + entry point for helpers
│   ├── update-check.sh                 ← upgrade nudge (sourced by vault.sh)
│   ├── prefs.sh                        ← per-command preference injection
│   ├── self-improve.sh                 ← end-of-session feedback capture
│   ├── profile.sh                      ← plans-profile JSON extractor
│   ├── db.sh                           ← shared SQLite store (habit events + reminders)
│   ├── habits.sh                       ← habits profile/criteria + dated tracking layer
│   ├── habit_schedule.py               ← habit schedule engine (is_due, derive_schedule, spacing helpers)
│   ├── profiles.sh                     ← versioned profile store (.profile dirs: latest/new/commit)
│   ├── migrations.sh + migrations/     ← vault migration runner + ordered migration scripts
│   ├── profile_lock.py                 ← atomic read-modify-write for Habits Profile.md (flock + tempfile-rename)
│   ├── launchd.sh                      ← shared native-helper build + LaunchAgent helpers (pbrain_swift_build, pbrain_launchagent_install)
│   ├── reminders.sh                    ← Apple Reminders helpers + cron→recurrence mapper (/remind); blocking overlay/tick/cron (/remind-blocking); Calendar read for plan-my-day
│   ├── pbrain-reminders.swift          ← source for the EventKit Reminders helper app (/remind)
│   ├── pbrain-notify.swift             ← source for pbrain's macOS notifier app
│   ├── pbrain-overlay.swift            ← source for pbrain's full-screen blocking overlay app (warning panel + lock-persist)
│   └── pbrain-tracker.swift            ← source for the laptop-tracking daemon (foreground + bg_media tracking)
├── scripts/
│   ├── install-commands.sh             ← symlink commands into ~/.claude/commands/
│   └── uninstall-commands.sh           ← reverse of install
├── tests/                              ← bats test suite for lib/ helpers
├── docs/                               ← one short doc per command (user-facing)
├── gbrain/                             ← gbrain ops (sync, launchd, docs)
│   ├── scripts/
│   │   ├── install-launchd.sh          ← render plist + load launchd
│   │   ├── gbrain-sync-wrapper.sh      ← wraps sync with lockfile + JSONL log
│   │   ├── gbrain-dashboard.sh         ← stuck procs, sync stats, brain stats
│   │   └── gbrain-upgrade.sh           ← bun-link based upgrade flow
│   ├── launchd/
│   │   └── com.pbrain.sync.plist.template
│   ├── docs/
│   │   ├── setup.md                    ← gbrain-only setup (Ollama, init, MCP, launchd)
│   │   ├── gbrain-sync.md              ← sync architecture + lock model
│   │   ├── gbrain-beyond-notes.md      ← capabilities beyond search
│   │   └── gbrain-bug-report.md        ← upstream bug repro
│   └── .logs/                          ← gitignored: sync-runs.jsonl, upgrade-status.json
├── promo-video/                        ← HyperFrames source composition for the promo video (renders excluded via .gitignore)
├── CLAUDE.md
└── README.md
```

The vault is a **separate** git repo (or just a directory). Not a submodule of this repo.

---

## Pairs well with

[**Claudian**](https://github.com/YishenTu/claudian) — an Obsidian plugin that runs Claude Code **inside** Obsidian, with word-level diff previews, vault-wide search, and three safety modes (Safe / Plan / YOLO). pbrain pushes structured notes *into* the vault from Claude Code on the terminal; Claudian lets Claude read, edit, and connect notes *inside* the Obsidian UI itself. The two are complementary — install both and you can write a `/journal` entry from the terminal, then ask Claude to enrich and backlink it inside Obsidian without leaving the editor.

---

## License

MIT — see [LICENSE](LICENSE).

---

## What not to do

- Don't write notes in this outer repo — use the vault
- Don't bypass the global `~/.claude/commands` symlink with per-vault copies — edit `commands/` here and every session picks up the change.
- Don't put gbrain scripts inside `commands/` or `lib/` (or pbrain scripts inside `gbrain/`). Plugin = slash commands. Gbrain ops = `gbrain/`.
- Don't `bun install -g github:garrytan/gbrain` — broken postinstall hook; clone and link manually (see `gbrain/docs/setup.md`)
- Don't init gbrain at the pbrain root — it'll index your scripts as notes. Always init from inside the vault.
