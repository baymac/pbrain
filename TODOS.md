# TODOS

Features and improvements for pbrain, organized by priority. Each item names where the idea came from so the design intent is traceable.

Sources studied:
- [`AgriciDaniel/claude-obsidian`](https://github.com/AgriciDaniel/claude-obsidian) — Karpathy-LLM-Wiki pattern. Autonomous knowledge engine that ingests sources, extracts entities, and cross-references everything.
- [`ballred/obsidian-claude-pkm`](https://github.com/ballred/obsidian-claude-pkm) — Goal-cascade PKM starter kit with `/onboard`, `/adopt`, and a hierarchical review cadence (daily → weekly → monthly).
- [`rvk7895/llm-knowledge-bases`](https://github.com/rvk7895/llm-knowledge-bases) — `/kb compile`, `/kb query`, `/kb lint`, `/kb evolve` — LLM-as-wiki-maintainer philosophy.

---

## High priority (small effort, real lift)

- [x] **`/monthly-review`** — natural extension above `/weekly-review`. Pull all 4-5 weekly reviews in the calendar month, plus monthly aggregates of fitness/diet/plans. Synthesize themes that only show up at a month's resolution. Writes to `life/monthly-tracking/YYYY-MM.md`. *(inspired by ballred — they have `/monthly` with quarterly milestone tracking.)* **Completed: v0.21.0 (2026-06-12)** — also drives monthly-goals versioning + optional goals-profile hygiene pass.

- [ ] **`/review` smart router** — date-aware dispatch. Sunday → `/weekly-review`. End of month (last 3 days or first 3 days of next) → `/monthly-review`. Otherwise → `/end-of-day`. Saves the user from picking the right cadence command. *(ballred has this exact pattern.)*

- [ ] **`/vault-doctor`** — health check: orphan files (zero inbound links), broken `[[wikilinks]]`, dated files with gaps ("you didn't journal Tue-Thu last week"), stale brainstorms in `tbd/` older than 90 days, empty stub files, frontmatter inconsistencies. Read-only; prints a report. *(AgriciDaniel has 8-category vault linting; rvk7895 has `/kb lint`.)*

- [ ] **`/push`** — one-shot "commit + push vault changes" helper for the standalone vault git repo. Auto-generates a commit message from the diff (e.g. "journal 2026-05-27, gratitude 2026-05-27, brainstorm: pivot-to-ai"), runs `git add -A && git commit && git push`. Optional `--no-push` for offline. *(ballred has `/push`; pbrain currently leaves day-to-day vault commits manual.)*

- [ ] **Comparison table in README** — single table near the top: pbrain vs claude-obsidian vs obsidian-claude-pkm vs llm-knowledge-bases. Columns: philosophy, primary workflow, autonomy level, structure assumption. Helps visitors pick the right tool fast. *(AgriciDaniel does this well — it's the second thing you see on their README.)*

- [x] **Demo video or animated GIF** — currently `docs/images/` has only a capture guide. A 30-second screen recording of `/plan-my-day` → `/end-of-day` → next-day `/recall` is the single biggest conversion driver. *(AgriciDaniel leads with a demo video; pbrain has none.)* **Completed: v0.8.1 (2026-06-04)** — 44s promo in `docs/media/pbrain-promo.mp4`; source composition in `promo-video/` (HyperFrames).

---

## Medium priority

- [ ] **`/recall` depth modes** — currently grep-only. Add three depth levels:
  - `quick` (default, current behavior) — pure grep, agent synthesizes.
  - `deep` — grep + read every matching file in full, not just the 2-line context.
  - `wide` — grep + WebSearch for the same topic, then synthesize how the user's notes compare to current external thinking.
  *(rvk7895 `/kb query` has quick/standard/deep — same shape.)*

- [ ] **Entity auto-suggest in `/journal` and `/brainstorm`** — after the user writes, the agent detects mentioned people, projects, and books, then asks once: "I noticed you mentioned Sarah, Project Atlas, and 'Thinking in Bets' — want me to backlink each to its `agent-work/people/` or `startup/<project>/` page (create if missing)?" Opt-in per session, never automatic — pbrain's philosophy is human-writes-first. *(AgriciDaniel does this autonomously; pbrain's version should keep the user in the loop.)*

- [ ] **Contradiction detection in `/weekly-review`** — when synthesizing the week, surface inconsistencies: "Mon you wrote 'cut sugar'; Wed dinner log has dessert. Worth noting?" Render as `[!contradiction]` callouts in the review file so the user can decide whether they reflect honest drift, evolved thinking, or a real conflict. *(AgriciDaniel pattern.)*

- [x] **Goal cascade in `/plan-my-day` profile** — current profile is flat (horizon goals, current focus, anti-patterns, anchors). Add explicit hierarchy: 3-year vision → yearly goals → active projects → this month → this week → today. Daily plan would then surface the relevant rung downward ("this week's ONE Big Thing"). Profile-file schema change → migration needed for existing users. *(ballred's goal-cascade is the cleanest version of this; pbrain's profile is opinionated but flatter.)* **Completed: v0.21.0 (2026-06-12)** — shipped as the 4-tier altitude (goals profile → monthly → weekly → daily), with weekly/monthly goals resolved by period tag.

- [ ] **`/adopt` mode for `/init-obsidian`** — detect existing vault organization (PARA, Zettelkasten, LYT, flat). If found, map pbrain's `agent-work/` and `life/` subpaths into the user's existing convention instead of forcing pbrain's structure. Print the chosen mapping for confirmation before writing. *(ballred has `/adopt` specifically for this.)*

---

## Multi-agent (Codex) follow-ups

- [ ] **Agent-aware `update-check.sh`** — the upgrade nudge currently emits a Claude-only suggestion (`/plugin update pbrain`) and reads `.claude-plugin/plugin.json`. Once pbrain installs on Codex (via generated `~/.codex/skills/pbrain-*`), Codex users who hit `UPGRADE_AVAILABLE` get a meaningless instruction. **Fix:** keep the neutral `UPGRADE_AVAILABLE <local> <remote>` marker as-is, but let each agent's instruction file carry the right upgrade command — Codex path is `git pull` + re-run `install-commands.sh --host codex`. **Context:** surfaced during the multi-agent (Codex skills) eng review, 2026-05-29; deferred from the initial dual-target scope (decisions D10/D11). Depends on the Codex skills install path landing first. *(see `.context/multi-agent-plan.md` decision log.)*

---

## Habits follow-ups

Deferred from the `/habits` criteria-model redesign (eng review 2026-06-03).

- [ ] **`habits log` count is overwritten by `sync_one`** — `habits log --count 3` writes `count=3` to the DB with `MAX` semantics. `sync_one` (called by every read command via `pbrain_habits_sync_range`) does `count=excluded.count` (last-write-wins), so the next `/plan-my-day` or `/end-of-day` run overwrites the manually logged count with the md cell value (blank → defaults to 1). Fix: either (a) change `sync_one` to use `MAX(habit_events.count, excluded.count)` or (b) have `habits log` also write the count into the md Count cell so sync mirrors the right value. **Priority: P2** — affects `habits log` users; the main `habits mark` → `habits sync` flow is unaffected since mark writes to the md and sync just mirrors it. *(Surfaced in adversarial review of v0.4.1, 2026-06-04.)* The redesign deliberately kept a markdown-only data model (stable `habit_id` slugs in the profile JSON, events keyed by id) and per-period yes/no fulfillment, to stay simple and avoid premature infra.

- [ ] **Habits dimension table (star schema)** — when a real analysis dashboard exists, mirror habit definitions from `life/Habits Profile.md`'s JSON into a synced SQLite `habits` table (upserted each run, keyed by `habit_id`) so the dashboard runs pure SQL (`habits ⨝ habit_events`) without parsing markdown. **Why deferred:** the markdown-only model is already dashboard-capable by parsing one JSON block; a second source of truth isn't justified until a dashboard consumer actually exists and query volume demands it. **Depends on:** a real dashboard being built. *(scope option B, declined in favor of stable-ids-in-markdown during the redesign.)*

- [x] **First-class quantity tracking** — habits can carry an optional measure (`unit` + `measure_target`, e.g. `L`/4 for "drink 4L water", `km`/20 for "run 20 km/week"). `mark`/`log` take `--amount`; the amount lands in the Count cell of the tracking md and a new `amount REAL` column on `habit_events`. Fulfillment sums the amount over the schedule period and checks it against the target (`2.5/4 L`, `12/20 km this week`) instead of done/not-done; `target_count` is ignored for measured habits. Rollup/status/dashboard render amount-based progress with the unit. Shipped in v0.4.0 (`add`/`edit --unit/--measure-target`, `--measure-target ""` clears it). Tests in `tests/habits.bats` + the `amount` column migration in `tests/db.bats` coverage.

---

## Code-quality follow-ups (from the v0.21.0 ship review, 2026-06-12)

Deferred INFORMATIONAL findings from the pre-landing review army + adversarial pass. None block correctness; all are DRY / efficiency cleanups of working, tested code.

- [ ] **Extract the `profile new`/`commit`/draft-open emission into a shared helper.** The draft-open guard + "a new DRAFT version was minted… finalize with `profile commit`" INSTRUCTIONS block is duplicated near-verbatim across `plan-my-day.sh`, `diet-journal.sh`, `fitness-journal.sh`, and `habits.sh` (bodies differ only by the label prefix + script name). Move into `lib/profiles.sh` (e.g. `pbrain_profile_emit_new`/`_emit_commit` parameterized on prefix + script path). **Priority: P3.** *(maintainability specialist.)*
- [ ] **Share the migration "move-into-store-with-frontmatter-stamp" heredoc.** Migrations 0005 and 0006 carry a byte-identical 19-line Python heredoc (strip + re-stamp `version`/`committed`, atomic tempfile→rename). Extract a `_pbrain_mig_move_to_store <src> <dest> <type-default>` helper so future store-move migrations stay consistent. **Priority: P3.** *(maintainability specialist.)*
- [ ] **Share the "core profiles dump" between `/weekly-review` and `/monthly-review`.** The `cat_profile()` helper + the fixed list of profile invocations + the activity-profile glob block are duplicated verbatim across `weekly-review.sh` and the new `monthly-review.sh`. Extract into `lib/profiles.sh` so adding a new profile base doesn't require editing both. **Priority: P3.** *(maintainability specialist.)*
- [ ] **`pbrain_profile_version` has no production caller.** It's exercised only by `tests/profiles.bats` — either wire it where a version label is derived (the `profile show` headers re-derive this inline) or accept it as intentional public API. **Priority: P4.** *(maintainability specialist.)*
- [ ] **Batch the end-of-day `reminders-sync` Apple-Reminder calls.** PULL/PUSH/SWEEP each spawn one Swift-app cold launch (`open -W -n` + `sleep 0.3` poll) per pending habit reminder, so `/end-of-day` issues O(N) sequential ~0.5–2s launches. Tolerable (small N, ~once/day) but if it gets noticeable, add a batch op to the Swift helper (`status --ids a,b,c` / `complete --ids …`) so one launch resolves all ids, and fold the per-row `_hr_set_status` python spawns into a single UPDATE. **Priority: P3.** *(performance specialist.)*
- [ ] **`reminders-ensure` create-then-record ordering can double-spawn on a DB-write failure.** The Apple Reminder is created (`pbrain_reminders_run add`) before the `habit_reminders` DB row is inserted, and the insert is swallowed by `|| true`; if `add` succeeds but the INSERT fails, the next run's dedup set won't know about it and creates a duplicate. Matches the established best-effort pattern, so acceptable — but make `add` re-findable by title+due so a retry reconciles instead of duplicating, or comment the trade-off. **Priority: P3.** *(maintainability specialist.)*

---

## Laptop-tracking follow-ups

Deferred from the `/laptop-tracking` design + eng review (2026-06-07). The core
ships a Swift launchd daemon → `~/.config/pbrain/tracker.db` (active-only
segments: app + raw browser host + attribution reason) → an end-of-day-rendered
`life/laptop-tracking/<date>.md`. These are the named future consumers.

- [ ] **Dashboard consumer on `tracker.db`** — a visual dashboard reading the
  granular segments: the deferred Approach B (self-refreshing local HTML: day
  timeline + top apps/domains + active-vs-away) or Approach C (always-on
  NSStatusItem menubar popover). **Why:** it's the entire justification for storing
  extensive granular data now — instrument richly once, render many views later.
  **Pros:** the data is already captured; this is pure read-side work (same
  normalize + aggregate as the daily-md renderer). **Cons:** may never be built
  (flagged speculative in the outside-voice plan review). **Depends on:** the core
  daemon + `tracker.db` schema shipping first. *(Approaches B/C, deferred in the design.)*

- [ ] **`tracker.db` retention / vacuum policy** — a retention knob (e.g.
  `PBRAIN_TRACKER_RETAIN_DAYS`) + periodic `VACUUM`, since active segments
  accumulate permanently. **Why:** forever-retention was flagged in review; at a
  few hundred active rows/day the DB stays small for years, but unbounded growth
  deserves a documented escape hatch. **Pros:** cheap insurance; bundles naturally
  with the end-of-day finalize job. **Cons:** genuinely YAGNI for v1 — not needed
  for a long time. **Depends on:** schema + end-of-day finalize shipping. *(scope
  deferred in the eng review.)*

---

## Explicit non-goals

Document opinions, not just todos. These patterns exist in the adjacent tools but **pbrain deliberately does not adopt them.**

- ❌ **Autonomous note creation from raw sources.** AgriciDaniel and rvk7895 both have `/kb compile` / `/save` patterns where the LLM ingests sources and writes the vault. Pbrain's philosophy: *the human writes; the agent prompts, records, and synthesizes*. Source ingestion belongs in `/organize-clippings` (one-shot triage), not as a continuous autonomous loop.

- ❌ **"LLM owns the wiki."** rvk7895 explicitly says "you rarely edit it manually." Pbrain is the opposite — the user owns the vault, the agent operates within carefully-bounded `agent-work/` subdirs and writes templates the user fills in. This boundary is load-bearing for trust.

- ❌ **Multi-agent research pipelines.** `/brainstorm` is meant to stay a fast idea-dump, not a `/kb research-deep` parallel-agent fanout. Power users who want that should reach for `/office-hours` (from gstack) or a dedicated research tool.

- ❌ **Visual canvas integration.** AgriciDaniel's `/canvas` is Obsidian-native territory; pbrain stays out of the editor's surface.

- ❌ **Cross-session AI memory layer baked into pbrain.** Pbrain reads files from disk each run; that's the contract. Memory belongs in gbrain (when it's fixed) or in an external MCP server, not as a hidden state inside slash commands.

---

## Implementation notes for future me

- New commands follow the existing pattern: `commands/<name>.{md,sh}` + `docs/<name>.md` + entries in `README.md` (command + env-var tables) and `CLAUDE.md`.
- Anything that reads multiple vault subdirs should source `lib/vault.sh` first, then derive subpaths via `PBRAIN_<NAME>_DIR` env-var overrides. Never hardcode paths.
- For commands that write a new file type, add the destination dir to the vault-structure section of `README.md` so users know what `agent-work/...` subdir to expect.
- Profile-schema changes (`/plan-my-day` goal cascade, etc.) need a migration step in the .sh script that detects v1 profile JSON and upgrades it in place. Don't silently break users on upgrade.
- Don't over-fit to the comparison set. Pbrain's wedge is **daily rituals + opinionated structure + bounded agent surface**. Every new feature should sharpen the wedge, not blunt it.
