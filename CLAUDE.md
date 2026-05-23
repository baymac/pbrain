# pbrain — Tool Development Context

This is the **pbrain tooling repo**. You are in the outer repo, not the vault.

- Write code here: scripts, slash commands, templates, docs.
- Write notes in the vault (open a separate CC session from the vault).
- Never create personal notes, ideas, or journal entries here.

See `README.md` for the full spec and architecture.

---

## Vault location

```
~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault
```

Vault is a standalone git repo (not a submodule). It lives in iCloud Drive for iOS sync.

---

## Where agents write in the vault

When Claude (or any agent) writes content into the vault, it goes under `agent-work/`. User-curated folders (life/, fitness/, startup/, daily/, etc.) are off-limits — never write or modify those without explicit instruction.

| Subdir | Contents |
|---|---|
| `agent-work/brainstorms/` | `/brainstorm` outputs, idea exploration |
| `agent-work/chat-history/` | Chat session takeaways saved on request |
| `agent-work/drafts/` | Drafts of blog posts, docs, longer writeups |
| `agent-work/notes/` | Misc captured notes from agent conversations |
| `agent-work/research/` | Research outputs, web summaries, references |
| `agent-work/people/` | People pages (auto-enriched contacts from gbrain or hand-written) |

If a new content type doesn't fit any of these, ask before creating a new subdir.

**Daily journal lives at `vault/life/daily-tracking/YYYY-MM-DD.md`** — not under `agent-work/`, because it's user-owned content. `/journal` creates a stub for the user to fill in; the content is the user's personal log, not agent output.

---

## Journal-first behavior

When the user invokes any slash command other than `/journal`, OR asks for help with personal reflection / capture, first check whether today's daily journal exists at `vault/life/daily-tracking/YYYY-MM-DD.md`. If it doesn't, suggest running `/journal` first before proceeding. The user can override and continue — never block, just prompt once.

Same applies for brainstorming, idea capture, or anything reflective: if today's journal is empty, suggest starting there since journaling first surfaces what's actually on the user's mind.

---

## Conventions for editing scripts

- Shell: `#!/usr/bin/env bash` with `set -euo pipefail` on every script.
- Complex logic (JSON parsing, markdown conversion): inline Python 3 heredoc inside the shell script. No external deps — stdlib only (no pip packages). Modules in use: `json`, `re`, `sys`, `os`, `datetime`, `subprocess`, `shutil`, `glob`, `random`, `collections`, `uuid`.
- Scripts must be idempotent. Re-running on unchanged state should produce the same result without side effects.
- All `.sh` files must be executable (`chmod +x`).
- Slash commands live **only** in `.claude/commands/`. Never duplicate them in `vault/`.
- `vault/` path in scripts:
  ```bash
  VAULT_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault"
  ```

---

## Slash commands

All commands live in `.claude/commands/` and are available from both the outer repo and vault sessions.

| Command | File | What it does |
|---|---|---|
| `/journal` | `journal.sh` | Create or open today's daily journal entry in `vault/life/daily-tracking/`. |
| `/brainstorm` | `brainstorm.sh` | Start a brainstorming session saved to `vault/agent-work/brainstorms/`. Requires a topic argument: `/brainstorm <topic>`. |

---

## Stack

- **Obsidian** — GUI for browsing and editing vault notes
- **gbrain** — hybrid vector + keyword search over vault, MCP server for Claude sessions
- **vault/** — markdown corpus (standalone git repo in iCloud Drive); source of truth for all notes

See `docs/setup.md` for the full stack setup including Claude Desktop MCP wiring.

---

## What not to do here

- Don't write notes or ideas in the outer repo — use the vault at `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault`.
- Don't `bun install -g github:garrytan/gbrain` — broken postinstall hook. Clone and link manually (see `docs/setup.md`).
