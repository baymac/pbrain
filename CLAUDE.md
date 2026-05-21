# pbrain — Tool Development Context

This is the **pbrain tooling repo**. You are in the outer repo, not the vault.

- Write code here: scripts, slash commands, templates, docs.
- Write notes in `vault/` (open a separate CC session from `vault/`).
- Never create personal notes, ideas, or journal entries here.

See `README.md` for the full spec and architecture.

---

## Conventions for editing scripts

- Shell: `#!/usr/bin/env bash` with `set -euo pipefail` on every script.
- Complex logic (API calls, JSON parsing, markdown conversion): inline Python 3 heredoc inside the shell script. No external deps — use only `urllib`, `json`, `re`, `sys`, `os`, `datetime`.
- Scripts must be idempotent. Re-running on unchanged state should produce the same result without side effects.
- All `.sh` files must be executable (`chmod +x`).
- Slash commands live **only** in `.claude/commands/`. Never duplicate them in `vault/`.
- `vault/` path is always resolved relative to the script's own location:
  ```bash
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PBRAIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  VAULT_DIR="$PBRAIN_ROOT/vault"
  ```
- Notion API version header: `Notion-Version: 2022-06-28`
- Add `sleep 0.1` between API calls in bulk operations (rate limit: ~3 req/s).

---

## Slash commands

All commands live in `.claude/commands/` and are available from both the outer repo and vault sessions.

| Command | File | What it does |
|---|---|---|
| `/notion-fetch` | `notion-fetch.sh` | Fetch a Notion page by ID, print as markdown to stdout. Read-only. |
| `/notion-search` | `notion-search.sh` | Search the Notion workspace by query string. |
| `/notion-pull` | `notion-pull.sh` | Fetch a single page, upsert into the SQLite state DB. |
| `/notion-pull-recursive` | `notion-pull-recursive.sh` | Recursive workspace pull. Incremental fast-path + run tracking + JSON log. |
| `/notion-pull-all` | `notion-pull-all.sh` | Re-pull every tracked page individually. Cron-friendly. |
| `/notion-audit` | `notion-audit.sh` | Verify mirror matches Notion (`--deep` for block-coverage diff). Recorded as its own run. |
| `/notion-runs` | `notion-runs.sh` | Inspect past pull/audit runs and their JSON logs. |
| `/notion-push` | `notion-push.sh` | Manually promote a local .md file to Notion. NEVER automate this. |
| `/journal` | `journal.sh` | Create or open today's daily journal entry in `vault/agent-work/daily/`. |
| `/brainstorm` | `brainstorm.sh` | Start a brainstorming session saved to `vault/agent-work/ideas/`. |

Pull state lives in `vault/.pbrain/notion.db` (SQLite, gitignored). Each run also writes a JSON log to `vault/.pbrain/runs/`.

---

## Environment variables required

- `NOTION_TOKEN` — Notion internal integration token (`ntn_...`). Export in `~/.zshrc`.

---

## What not to do here

- Don't run `notion-push` automatically or from cron — promotion is always deliberate.
- Don't edit `vault/notion-mirror/` files — they get overwritten on next pull.
- Don't write notes or ideas in the outer repo — that's what `vault/agent-work/` is for.
- Don't `bun install -g github:garrytan/gbrain` — broken postinstall hook. Clone and link manually.

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
