# pbrain — Tool Development Context

This is the **pbrain tooling repo**. You are in the outer repo, not the vault.

- Write code here: scripts, slash commands, templates, docs.
- Write notes in `vault/` (open a separate CC session from `vault/`).
- Never create personal notes, ideas, or journal entries here.

See `README.md` for the full spec and architecture.

---

## Conventions for editing scripts

- Shell: `#!/usr/bin/env bash` with `set -euo pipefail` on every script.
- Complex logic (JSON parsing, markdown conversion): inline Python 3 heredoc inside the shell script. No external deps — stdlib only (no pip packages). Modules in use: `json`, `re`, `sys`, `os`, `datetime`, `subprocess`, `shutil`, `glob`, `random`, `collections`, `uuid`.
- Scripts must be idempotent. Re-running on unchanged state should produce the same result without side effects.
- All `.sh` files must be executable (`chmod +x`).
- Slash commands live **only** in `.claude/commands/`. Never duplicate them in `vault/`.
- `vault/` path is always resolved relative to the script's own location (assumes script lives at `.claude/commands/`, two levels below repo root):
  ```bash
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PBRAIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  VAULT_DIR="$PBRAIN_ROOT/vault"
  ```

---

## Slash commands

All commands live in `.claude/commands/` and are available from both the outer repo and vault sessions.

| Command | File | What it does |
|---|---|---|
| `/journal` | `journal.sh` | Create or open today's daily journal entry in `vault/agent-work/daily/`. |
| `/brainstorm` | `brainstorm.sh` | Start a brainstorming session saved to `vault/agent-work/ideas/`. Requires a topic argument: `/brainstorm <topic>`. |

---

## Stack

- **Obsidian** — GUI for browsing and editing vault notes
- **gbrain** — hybrid vector + keyword search over vault, MCP server for Claude sessions
- **vault/** — markdown corpus (git submodule); source of truth for all notes

See `docs/gbrain-setup.md` for gbrain setup and `docs/claude-desktop.md` for Claude Desktop MCP wiring.

---

## What not to do here

- Don't write notes or ideas in the outer repo — that's what `vault/agent-work/` is for.
- Don't `bun install -g github:garrytan/gbrain` — broken postinstall hook. Clone and link manually (see `docs/gbrain-setup.md`).

---

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
