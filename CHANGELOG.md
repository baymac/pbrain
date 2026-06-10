# Changelog

All notable changes to pbrain are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/).

## [0.10.0] — 2026-06-10

### Added

- **`/laptop-tracking report` — full-day vs in-progress window.** Past days now show the complete 00:00→24:00 window so away time includes any untracked tail (laptop off/asleep before midnight). Today's report shows "so far" with the actual last activity as the endpoint — no more inflated away time on live days.
- **`/laptop-tracking report` — browser attribution table.** When Chrome or Safari time has no recorded domain (permission not granted, tab lookup timed out, non-web window), a new `## Browser attribution` section explains exactly why — so unaccounted browser time is visible, not silently dropped.
- **`/laptop-tracking report` — YouTube per-video tracking.** Watch time on `youtube.com/watch`, `m.youtube.com`, and `music.youtube.com` now breaks out by video ID (`?v=`) so each video gets its own page row. Previously all YouTube watch time collapsed to a single `youtube.com/watch` line.
- **`/habits reminders-reschedule` — align a habit's Apple Reminder to its planned time.** When `/plan-my-day` places a habit at a specific time in the plan table, it now silently reschedules the habit's one-shot reminder to match. Returns `RESCHEDULED`, `NOT_LINKED`, `NOT_FOUND`, or `UNAVAILABLE` — never blocks or fails loudly.
- **`/habits reminders-sync --sweep` — end-of-day cleanup.** Running `reminders-sync` with `--sweep` now cancels any pending one-shot reminders for habits that weren't completed today, keeping the Apple Reminders list clean after EOD.
- **`/end-of-day --date YYYY-MM-DD` — close a past day.** Pass a date (or a bare YYYY-MM-DD positional arg) to fill in the "How it went" section for a previous day. The habit rollup and laptop report key off the given date, not today.
- **`lib/profile_lock.py` — atomic profile writes.** `habits add/edit/archive` now use an exclusive file lock + tempfile-then-rename write path, preventing profile corruption under concurrent invocations or disk-full failures.

### Changed

- **`/plan-my-day` — rescheduling habit reminders is now a silent step (Step 5c).** After writing the plan table, Claude automatically calls `reminders-reschedule` for any habit placed at a specific clock time. No user output unless the reschedule fails.
- **`/plan-my-day` — habit marks pushed to Apple Reminders after check-in.** After the habit check-in step, Claude now calls `reminders-sync --date` to propagate any marks to their linked Apple Reminders in one pass.
- **`/laptop-tracking` tracker daemon** — the `v=` query parameter is now preserved for YouTube URLs (video ID allowlist), and all other query parameters are still dropped. Video IDs are validated (alphanumeric + `-_`, max 16 chars) before storage.

### Fixed

- Full-day window now uses calendar arithmetic (`datetime + timedelta(days=1)`) instead of `+86400` to correctly handle DST-transition days (spring-forward/fall-back no longer inflate or deflate the reported away time by one hour).
- YouTube video ID extraction now caps at 16 characters to prevent unbounded `raw_path` values from malformed URLs.
- `reminders-reschedule` now validates the `--date` argument format before querying the DB, consistent with `end-of-day.sh`.

## [0.9.0] — 2026-06-06

### Added

- **`/remind-blocking` — full-screen "take a break" overlays.** Set time-sensitive interruption reminders that are hard to ignore. Fires as a full-screen overlay (compiled from `lib/pbrain-overlay.swift` on demand — no install needed; degrades to a notification if Swift isn't available). Hold **Control** for 5 seconds to skip, **Return** to mark done, or let the countdown expire. Supports cron-based recurrence (`*/30 9-17 * * 1-5` = every 30 min on weekdays 9–5) in addition to simple `daily`/`weekly` tokens. A background launchd poller fires overlays on schedule; first `add` auto-installs it. Subcommands: `add`, `list`, `done`, `cancel`, `test`, `tick`, `install`, `uninstall`.
- **`/thoughts [<text>]` — timestamped thought capture.** Explode a single thought into a structured entry in `vault/life/thought-tracking/<date>.md`. Run with no args and Claude asks you for one. Exempt from the morning-sequence check — fire it any time.
- **`/discuss <topic>` — Socratic thinking partner.** Work through a personal dilemma one question at a time. Reads your journal, gratitude note, and goals profile silently for context before engaging. Saves a structured insight note (`## The dilemma / What surfaced / Resolution`) to `vault/agent-work/notes/`. Resumes if you run it again on the same topic today. Exempt from the morning-sequence check.

### Changed

- **`/remind` is now Apple Calendar-only.** Reminders are stored as real Calendar events (via `pbrain-calendar.app` compiled from `lib/pbrain-calendar.swift`) instead of the SQLite DB. Existing reminder subcommands (`add`, `list`, `done`, `cancel`) work the same way; notifications fire through the OS. Use `/remind-blocking` for the time-sensitive overlay reminders that previously required DB-backed polling.
- **`/plan-my-day` no longer fires pending reminders opportunistically.** Blocking reminders must arrive via the dedicated poller so they're never shown late as catch-up. Regular reminder notifications continue to fire through the OS on schedule.
- **Habit extraction wired into `/habits` dashboard.** The auto-mark ride-along (`pbrain_emit_habits_extract`) now runs inside the `/habits` dashboard session, so you can mark a habit mid-session (e.g. "just had an unclean meal") without having to be in a journaling or planning session.
- **`/plan-my-day` habit check-in shows today's tracker inline.** After planning blocks, Claude shows the current day's habit checklist and offers to mark anything you've already done — one round, no loop.

### Fixed

- `lib/db.sh` migration safely adds `block_seconds`, `hold_seconds`, and `cron` columns to existing reminder databases via `PRAGMA table_info` guards (no data loss, idempotent).

## [0.8.3] — 2026-06-05

### Added

- **`/diet-journal` — plan the rest of today.** Ask "What have you eaten today?" (no more a/b/c choice upfront). After logging, the command offers to plan remaining meal slots using your food library and recent history — rotating variety, respecting conditions, and cross-referencing today's fitness session. Works on blank days too: say "nothing yet" and it plans the full day from scratch.
- **Meal type column in food library.** Library entries now carry a `Meal type` tag (`breakfast`, `lunch`, `dinner`, `snack`, `post-workout`, `any`, or comma-separated combinations). Meal-slot filtering in the planner uses this column; older entries without the column are treated as `any` for full backward compatibility.

### Changed

- **Simplified `/diet-journal` opening.** The old `(a) log / (b) suggest / (c) both` prompt is gone. Just describe what you ate; the command infers intent from context and offers planning if there are open slots remaining.

## [0.8.2] — 2026-06-05

### Added

- **`/habits refresh` command.** Recompute the Progress column in any historical tracking file from the DB without touching Done marks — useful after a formula change or data correction. Supports `--date YYYY-MM-DD` for a single day and `--days N` to backfill the last N trackers oldest-to-newest (so weekly totals build correctly across the window).

### Changed

- **Live progress on `mark`.** Marking a habit now rewrites the Progress cell in the same commit — no more stale "0/2 wk" the instant you tick something done. The cell reflects the day's actual count immediately.
- **Accurate daily-limit progress format.** A `daily (limit)` habit (at_most direction) now shows `N/cap day` (today's count vs the cap) instead of a weekly sum, matching the semantics of "how many times today vs the per-day limit."

### Fixed

- **Consolidate respects absent tracking files.** `/end-of-day` no longer errors when today's tracking file doesn't exist (e.g. if habits were skipped for the day); it exits cleanly with "consolidated."
- **Archived habits excluded from habit extraction.** `pbrain_emit_habits_extract` no longer surfaces archived habits in the mark-command list, preventing stale habit names from appearing in ride-along HABIT EXTRACTION blocks.

## [0.8.1] — 2026-06-04

### Added

- **Promo demo video.** README now leads with a 44-second screen recording showing `/journal`, `/fitness-journal`, `/diet-journal`, `/habits`, and `/remind` writing live into an Obsidian vault, plus a one-year compounding view. Poster image links to the video in GitHub's media viewer. Source composition (HyperFrames) committed under `promo-video/`.

## [0.8.0] — 2026-06-04

### Changed

- **`/plan-my-day` anchor-first scheduling.** The planner now learns your typical workout, lunch, dinner, walk, and bed times from the last 21 plans (TIMING_SIGNAL) and uses them as the fixed schedule skeleton. Maximum 15–30 min deviation from any confirmed anchor.
- **Step 1.5 — Anchor confirmation.** Before asking for your day's blocks, `/plan-my-day` now shows a pre-filled list of your anchor times (from `daily_anchors` in your profile, or inferred from past plans) and asks you to confirm or adjust. One message, all anchors at once.
- **Block 1/2/3 model replaces Now/Next/Later.** The three main intentional blocks of the day are now chronological (wake→sleep), not relative to current time. Running `/plan-my-day` at 10pm still produces a full-day plan. Each block can be any type — work, creative, social, outdoor — and must be at least `deep_work_block_min` minutes wide.
- **Table confirmation before write.** The generated schedule table is shown to the user for review before the plan is saved to disk. Times, rows, and labels can be adjusted; the file is only written on confirmation.
- **Step 5b — Anchor profile update.** After planning, if today's anchor times differ from the profile's `daily_anchors` (or the profile has none yet), Claude offers to save them as new defaults.
- **`daily_anchors` field added to profile schema.** The Goals Profile JSON now includes `wake_time`, `workout_time`, `lunch_time`, `dinner_time`, `walk_time`, `bed_target`, and `focused_hours_per_day`. The profile setup interview now asks for these during first-time setup.

## [0.7.0] — 2026-06-04

Combines the markdown-first habits line (0.4.0/0.4.1) with the Codex interop line (0.5.0/0.6.0) — both shipped here together. Detailed notes for each are in their version sections below.

### Added

- **Markdown-first habit tracking.** The day-to-day habit log is now a dated checklist markdown file (`life/habit-tracking/<date>.md`, generated from the profile like `/fitness-journal`); the SQLite DB is a *derived* analysis store synced from those files. `mark` ticks the md, `track`/`sync`/`consolidate` own the md→DB flow, and the criteria model moved into the profile (per-habit `schedule_type`/`direction`/`target_count`). See 0.4.0/0.4.1 below.
- **Measured (quantity) habits.** A habit can carry a `unit` + `measure_target` (e.g. 4 L water, 20 km/week); `mark`/`log` take `--amount` and fulfillment sums the amount over the period. See 0.4.0 below.

### Fixed

- **Reliable background reminder notifications** via the bundled `pbrain-notify.app` (compiled on demand from `lib/pbrain-notify.swift`), plus `/remind list` fired-one-shot relabeling and `remind add` non-zero exit on DB write failure. See 0.4.1 below.

## [0.6.0] — 2026-06-04

### Changed

- **`/codex-install` now generates Codex *agent skills* instead of custom prompts.** OpenAI deprecated Codex custom prompts, and on recent Codex builds (≥ 0.117) they stopped appearing in the slash menu (openai/codex#15941, closed not-planned), so the generated commands were effectively undiscoverable — and a literal `/journal` is rejected by Codex's CLI before the model ever sees it. The installer now writes one **agent skill** per command at `$CODEX_HOME/skills/pbrain-<cmd>/SKILL.md` (the source `.md` `description:` becomes the skill's frontmatter; the body still just runs the **same** `commands/<cmd>.sh`). Skills are Codex's supported, **default-on** mechanism (no `--enable` flag) — auto-discovered and invokable by plain name (`journal`), explicitly (`$pbrain-journal`), or implicitly by description-match. Verified end-to-end against codex-cli 0.137.0. Because Codex reads a `SKILL.md` from disk **verbatim** (no `$NAME` placeholder expansion, unlike custom prompts), the old `$`→`$$` escaping is gone — `$VAULT_DIR`/`$ARGUMENTS`/prose survive intact, and the `AGENTS.md` block now documents skill-based invocation (and that `/journal` won't work) instead of a `/prompts:` routing table. Re-running migrates automatically: it installs the skills and removes any pbrain-managed `prompts/pbrain-*.md` left by earlier versions (your own Codex prompts/skills are never touched). Idempotent as before. Tests rewritten in `tests/codex-install.bats`; docs updated (`docs/codex-install.md`, README, CLAUDE.md).

## [0.5.0] — 2026-06-04

### Added

- **`/codex-install` — run pbrain from the OpenAI Codex CLI, one source of truth.** pbrain stays a Claude Code plugin first, but this Claude-side setup command (run after `/init-obsidian`) makes every command usable from Codex without forking any logic. It generates, under `$CODEX_HOME` (default `~/.codex`): one Codex **custom prompt** per command (`prompts/pbrain-<cmd>.md`, invoked `/prompts:pbrain-journal`, `/prompts:pbrain-brainstorm "idea"`, …) — each a thin wrapper that runs the **same** `commands/<cmd>.sh` — plus a delimited, managed **pbrain block** in `AGENTS.md` carrying the cross-command behaviour Codex needs (morning sequence, ride-along blocks, vault write rules, launch command), scoped so it can't affect unrelated Codex sessions. Both agents resolve the same vault and read the same `~/.config/pbrain` config + SQLite DB at runtime, so alternating between Codex and Claude Code **cannot conflict** — there's no agent-specific state to desync. The prompt-body transform is deterministic: it bakes a literal `.sh` path (Codex has no `CLAUDE_PLUGIN_ROOT`; a `PBRAIN_DEV_DIR` set at install time is baked instead), rewrites pbrain's own `/<cmd>` references to `/prompts:pbrain-<cmd>` (non-pbrain refs left alone), and **escapes every `$` except `$ARGUMENTS`** so Codex's prompt-placeholder expansion can't mangle shell vars or prose like `$VAULT_DIR`. Idempotent and non-destructive: re-running refreshes every prompt, re-bakes the path, merges the `AGENTS.md` block between its markers (your other content preserved), and prunes only stale prompts carrying pbrain's own marker — never your own Codex prompts. `init-obsidian` and the installer itself stay Claude-only. Uses custom prompts rather than Codex *skills* (which are gated behind `--enable skills`) so it works on any Codex CLI today. New env var: `CODEX_HOME`. New tests: `tests/codex-install.bats`. New doc: `docs/pbrain-codex-install.md`.

### Fixed

- **`/habits sync` now accepts `--date YYYY-MM-DD`** to target a specific end date for the sync window. Previously, `sync --days 0` always used today's date, so marks written for a past date (e.g. in tests or after a missed day) were silently skipped. Now `habits sync --days 0 --date 2026-06-03` syncs exactly that date; `--date` defaults to today when omitted.
- **`/codex-install` installer hardening:** the `AGENTS.md` update step now skips the write (rather than overwriting with empty content) if the file exists but cannot be read due to permissions; `os.makedirs` is now guarded against an empty dirname when `CODEX_HOME` resolves to a bare filename.

## [0.4.1] — 2026-06-04

### Fixed

- **`/remind` notifications now fire reliably from the background poller.** Notifications delivered via `osascript display notification` were *silently dropped* when fired from the launchd poller — from that context there's no trusted app for macOS's notification-permission check, so reminders never appeared even though `tick` ran and stamped `fired_at`. pbrain now ships its own tiny notifier, **`pbrain-notify.app`**, compiled on demand from a new ~60-line Swift source (`lib/pbrain-notify.swift`) via `swiftc` (Apple Command Line Tools — no Xcode, no brew, no external deps) and cached at `~/.config/pbrain/pbrain-notify.app`. Because it runs inside a real app bundle it has a stable identity, and it borrows the always-trusted **`com.apple.Terminal`** notification permission (the technique the `alerter` tool uses — `UNUserNotificationCenter` was evaluated and rejected: it requires code signing plus a first-run authorization grant that an unattended poller can't satisfy). `pbrain_notify` (`lib/reminders.sh`) prefers the bundled app, builds it lazily on first fire and eagerly at `/remind install`, and falls back to `osascript` only when `swiftc` is unavailable. Notifications appear under the "Terminal" identity (clicking opens Terminal); override with `PBRAIN_NOTIFY_IDENTITY` (or `""` to use pbrain's own `com.pbrain.notify` identity), and relocate the build with `PBRAIN_NOTIFY_APP`. New tests in `tests/reminders.bats` cover the build, the osascript fallback, and a real `swiftc` compile.
- **`/remind list` no longer shows a fired one-shot as OVERDUE forever.** A one-shot reminder that had already fired (so `fired_at` is set) but wasn't yet marked done kept reading as `OVERDUE` in the pending list. It now reads as **`fired — mark done`**, so the list reflects that it already notified you (repeats are unaffected — they clear `fired_at` as they roll forward).
- **`habits sync --date` param added for pinning the end date.** `habits sync --days N` now accepts an optional `--date YYYY-MM-DD` to fix the end date of the sync window. Previously the end date was always today, so syncing habits marked on a past date required passing a large `--days` value. The default remains today.
- **`remind add` now exits non-zero when the DB write fails.** A failed SQLite insert left `NEW_ID` empty but the command printed `REMIND_ADDED` and fired a confirmation notification anyway. The reminder was never stored. `remind add` now detects an empty `NEW_ID` and exits 1 with an error message before notifying.

### Also in this release

- Measured habit tracking (`--unit`, `--measure-target`, `--amount`) shipped in v0.4.0 but was missing two test-harness fixes: `habits sync` date-pinning (above) + the `tests/habits.bats` calls that now pass `--date` when marking habits in the past. All 114 tests pass.

## [0.4.0] — 2026-06-03

### Added

- **`/habits` first-class quantity tracking.** A habit can now carry an optional *measure* — a `unit` and a `measure_target` (e.g. `L`/4 for "drink 4L water", `km`/20 for "run 20 km a week", `g`/30 for "keep sugar under 30g/day") — set via `add`/`edit --unit "L" --measure-target 4` (pass `--measure-target ""` to clear it back to a plain yes/no habit). For a measured habit, `mark`/`log` take `--amount` (fractional OK, e.g. `--amount 2.5`); the value lands in the **Count** cell of the dated tracking markdown and in a new nullable `amount REAL` column on `habit_events`. Fulfillment then sums the amount over the habit's schedule period and checks it against the target — `2.5/4 L today ⏳`, `12/20 km this week`, `45/30 g today — OVER ⚠️` — instead of done/not-done, so `target_count` is irrelevant for measured habits. The status evaluator, text rollup, dashboard, `list`, and the ride-along extraction emitter (which tags measured habits and prompts the agent to pass `--amount`) all understand the measure; the surfacing commands (`/plan-my-day`, `/end-of-day`, `/weekly-review`) inherit it for free through the shared rollup. Existing DBs gain the `amount` column via a guarded, idempotent migration in `lib/db.sh`; unmeasured habits keep working unchanged (`amount` stays NULL, occurrence `count` still drives fulfillment). New tests cover measured add/edit/status/rollup/mark/sync/log in `tests/habits.bats`. *(Closes the "first-class quantity tracking" habits follow-up in `TODOS.md`.)*

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
