# TODOS

Features and improvements for pbrain, organized by priority. Each item names where the idea came from so the design intent is traceable.

Sources studied:
- [`AgriciDaniel/claude-obsidian`](https://github.com/AgriciDaniel/claude-obsidian) — Karpathy-LLM-Wiki pattern. Autonomous knowledge engine that ingests sources, extracts entities, and cross-references everything.
- [`ballred/obsidian-claude-pkm`](https://github.com/ballred/obsidian-claude-pkm) — Goal-cascade PKM starter kit with `/onboard`, `/adopt`, and a hierarchical review cadence (daily → weekly → monthly).
- [`rvk7895/llm-knowledge-bases`](https://github.com/rvk7895/llm-knowledge-bases) — `/kb compile`, `/kb query`, `/kb lint`, `/kb evolve` — LLM-as-wiki-maintainer philosophy.

---

## High priority (small effort, real lift)

- [ ] **`/monthly-review`** — natural extension above `/weekly-review`. Pull all 4-5 weekly reviews in the calendar month, plus monthly aggregates of fitness/diet/plans. Synthesize themes that only show up at a month's resolution. Writes to `life/monthly-reviews/YYYY-MM.md`. *(inspired by ballred — they have `/monthly` with quarterly milestone tracking.)*

- [ ] **`/review` smart router** — date-aware dispatch. Sunday → `/weekly-review`. End of month (last 3 days or first 3 days of next) → `/monthly-review`. Otherwise → `/end-of-day`. Saves the user from picking the right cadence command. *(ballred has this exact pattern.)*

- [ ] **`/vault-doctor`** — health check: orphan files (zero inbound links), broken `[[wikilinks]]`, dated files with gaps ("you didn't journal Tue-Thu last week"), stale brainstorms in `tbd/` older than 90 days, empty stub files, frontmatter inconsistencies. Read-only; prints a report. *(AgriciDaniel has 8-category vault linting; rvk7895 has `/kb lint`.)*

- [ ] **`/push`** — one-shot "commit + push vault changes" helper for the standalone vault git repo. Auto-generates a commit message from the diff (e.g. "journal 2026-05-27, gratitude 2026-05-27, brainstorm: pivot-to-ai"), runs `git add -A && git commit && git push`. Optional `--no-push` for offline. *(ballred has `/push`; pbrain currently leaves day-to-day vault commits manual.)*

- [ ] **Comparison table in README** — single table near the top: pbrain vs claude-obsidian vs obsidian-claude-pkm vs llm-knowledge-bases. Columns: philosophy, primary workflow, autonomy level, structure assumption. Helps visitors pick the right tool fast. *(AgriciDaniel does this well — it's the second thing you see on their README.)*

- [ ] **Demo video or animated GIF** — currently `docs/images/` has only a capture guide. A 30-second screen recording of `/plan-my-day` → `/end-of-day` → next-day `/recall` is the single biggest conversion driver. *(AgriciDaniel leads with a demo video; pbrain has none.)*

---

## Medium priority

- [ ] **`/recall` depth modes** — currently grep-only. Add three depth levels:
  - `quick` (default, current behavior) — pure grep, agent synthesizes.
  - `deep` — grep + read every matching file in full, not just the 2-line context.
  - `wide` — grep + WebSearch for the same topic, then synthesize how the user's notes compare to current external thinking.
  *(rvk7895 `/kb query` has quick/standard/deep — same shape.)*

- [ ] **Entity auto-suggest in `/journal` and `/brainstorm`** — after the user writes, the agent detects mentioned people, projects, and books, then asks once: "I noticed you mentioned Sarah, Project Atlas, and 'Thinking in Bets' — want me to backlink each to its `agent-work/people/` or `startup/<project>/` page (create if missing)?" Opt-in per session, never automatic — pbrain's philosophy is human-writes-first. *(AgriciDaniel does this autonomously; pbrain's version should keep the user in the loop.)*

- [ ] **Contradiction detection in `/weekly-review`** — when synthesizing the week, surface inconsistencies: "Mon you wrote 'cut sugar'; Wed dinner log has dessert. Worth noting?" Render as `[!contradiction]` callouts in the review file so the user can decide whether they reflect honest drift, evolved thinking, or a real conflict. *(AgriciDaniel pattern.)*

- [ ] **Goal cascade in `/plan-my-day` profile** — current profile is flat (horizon goals, current focus, anti-patterns, anchors). Add explicit hierarchy: 3-year vision → yearly goals → active projects → this month → this week → today. Daily plan would then surface the relevant rung downward ("this week's ONE Big Thing"). Profile-file schema change → migration needed for existing users. *(ballred's goal-cascade is the cleanest version of this; pbrain's profile is opinionated but flatter.)*

- [ ] **`/adopt` mode for `/init-obsidian`** — detect existing vault organization (PARA, Zettelkasten, LYT, flat). If found, map pbrain's `agent-work/` and `life/` subpaths into the user's existing convention instead of forcing pbrain's structure. Print the chosen mapping for confirmation before writing. *(ballred has `/adopt` specifically for this.)*

---

## Multi-agent (Codex) follow-ups

- [ ] **Agent-aware `update-check.sh`** — the upgrade nudge currently emits a Claude-only suggestion (`/plugin update pbrain`) and reads `.claude-plugin/plugin.json`. Once pbrain installs on Codex (via generated `~/.codex/skills/pbrain-*`), Codex users who hit `UPGRADE_AVAILABLE` get a meaningless instruction. **Fix:** keep the neutral `UPGRADE_AVAILABLE <local> <remote>` marker as-is, but let each agent's instruction file carry the right upgrade command — Codex path is `git pull` + re-run `install-commands.sh --host codex`. **Context:** surfaced during the multi-agent (Codex skills) eng review, 2026-05-29; deferred from the initial dual-target scope (decisions D10/D11). Depends on the Codex skills install path landing first. *(see `.context/multi-agent-plan.md` decision log.)*

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
