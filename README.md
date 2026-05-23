# pbrain

Local-first personal knowledge management, designed to work with Claude Code. Obsidian as writing surface, an iCloud-synced markdown vault as the corpus, gbrain as the AI memory layer, and Claude Code (plus Claude Desktop) as the chat-time interface that reads and writes through gbrain's MCP.

---

## Architecture

```
┌──────────────────────┐
│  Obsidian (Mac+iOS)  │  ← you write here
└──────────┬───────────┘
           │ iCloud (auto-sync between devices)
           ▼
┌────────────────────────────────────────────────────────────┐
│  vault/  (standalone git repo, lives in iCloud Drive)      │
│  ├── life/                ← your daily journal + life      │
│  │   └── daily-tracking/YYYY-MM-DD.md                      │
│  ├── fitness/, startup/, side-quests/, software-dev/, ...  │
│  └── agent-work/          ← everything Claude generates    │
│      ├── brainstorms/     ← /brainstorm outputs            │
│      ├── chat-history/    ← saved chat takeaways           │
│      ├── drafts/, notes/, research/, people/               │
└──────────┬─────────────────────────────────────────────────┘
           │ gbrain sync (launchd, every 30 min)
           ▼
┌──────────────────────┐
│  gbrain index        │  ← PGLite + Ollama embeddings
│  ~/.gbrain/          │     (local-only, free, private)
└──────────┬───────────┘
           │ MCP (stdio)
     ┌─────┴──────┐
     ▼            ▼
┌─────────────┐  ┌──────────────────────┐
│ Claude Code │  │ Claude Desktop       │
└─────────────┘  └──────────────────────┘
```

---

## Quick start

Full step-by-step in **[docs/setup.md](docs/setup.md)**. Short version:

```bash
# Vault (creates dir, git init, .gitignore, CLAUDE.md, initial commit)
./scripts/init-vault.sh

# Obsidian → install from obsidian.md → Open folder as vault → pick the path above

# Ollama (local embeddings)
brew install ollama && brew services start ollama
ollama pull nomic-embed-text

# gbrain
git clone https://github.com/garrytan/gbrain.git ~/code/gbrain
cd ~/code/gbrain && bun install && bun link
cd ~/Library/Mobile\ Documents/iCloud~md~obsidian/Documents/vault
gbrain init --pglite --embedding-model ollama:nomic-embed-text --embedding-dimensions 768
gbrain config set embedding_model ollama:nomic-embed-text
gbrain sync --repo . --skip-failed

# Claude Code MCP
claude mcp add gbrain "$HOME/.bun/bin/gbrain" serve

# Scheduled sync every 30 min (renders plist template, loads launchd, starts dashboard logging)
./scripts/install-launchd.sh
```

---

## Vault structure

User-curated topical folders live at the root. Claude-generated content lives under `agent-work/`.

| Directory | What goes here |
|---|---|
| `life/daily-tracking/` | Daily journal entries (created by `/journal`) |
| `life/`, `fitness/`, `startup/`, `side-quests/`, etc. | Your hand-curated topical notes |
| `agent-work/brainstorms/` | `/brainstorm` outputs |
| `agent-work/chat-history/` | Chat takeaways saved on request |
| `agent-work/drafts/` | Drafts written by Claude |
| `agent-work/notes/` | Misc agent-captured notes |
| `agent-work/research/` | Web summaries, research outputs |
| `agent-work/people/` | People pages (auto-enriched or hand-written) |

Concepts, sources, ideas, etc. are **co-located** with their topic — e.g., `startup/Apps/Lettuce/ideas/`, `side-quests/DJ/sources/` — not in vault root.

---

## Slash commands

Defined in `.claude/commands/`. Each `.md` file registers as a slash command; the `.sh` file does the work.

| Command | What it does |
|---|---|
| `/journal` | Create or open today's daily note in `life/daily-tracking/` |
| `/brainstorm <topic>` | Create a brainstorming file in `agent-work/brainstorms/` |

---

## Private notes

Notes you want off git **and** off iCloud:

1. Create `vault/private/` (any name works as long as it's gitignored)
2. Add to `vault/.gitignore`:
   ```
   private/
   ```
3. Exclude from iCloud — the cleanest way: append `.nosync` to the folder name (macOS convention iCloud respects):
   ```bash
   mv vault/private vault/private.nosync
   ```
   Or use Obsidian iOS Selective Sync (Settings → Sync → exclude `private/`) to keep it on Mac only.

Files in `private.nosync/` stay on your Mac, never reach git, never sync to iCloud or iPhone.

---

## Repository structure

```
pbrain/                          ← outer repo (tooling only)
├── .claude/
│   └── commands/
│       ├── journal.{md,sh}
│       └── brainstorm.{md,sh}
├── docs/
│   ├── setup.md                 ← full setup walkthrough
│   ├── mobile-sync.md           ← iOS sync details
│   └── gbrain-beyond-notes.md   ← capabilities beyond search
├── launchd/
│   └── com.pbrain.sync.plist.template  ← rendered by scripts/install-launchd.sh
├── scripts/
│   ├── init-vault.sh                   ← initialize vault dir + git + CLAUDE.md
│   ├── install-launchd.sh              ← render plist template + load launchd
│   ├── gbrain-sync-wrapper.sh          ← wraps sync with lockfile + JSONL log
│   └── gbrain-dashboard.sh             ← status: stuck procs, sync stats, brain stats
├── CLAUDE.md                    ← agent instructions for this repo
└── README.md
```

The vault is a **separate** git repo at the iCloud path above. Not a submodule.

---

## What not to do

- Don't write notes in this outer repo — use the vault
- Don't `bun install -g github:garrytan/gbrain` — broken postinstall hook; clone and link manually (see `docs/setup.md`)
- Don't init gbrain at the pbrain root — it'll index your scripts as notes. Always init from inside the vault.
