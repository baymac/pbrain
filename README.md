# pbrain

Local-first personal knowledge management. Obsidian as the writing surface, vault as the markdown corpus, gbrain as the AI memory layer.

---

## Architecture

```
┌──────────────────────┐
│  Obsidian (Mac+iOS)  │  ← you write here
└──────────┬───────────┘
           │ iCloud (auto-sync)
           ▼
┌──────────────────────────────────────────────────────┐
│  vault/  (git submodule, private remote)              │
│  ├── agent-work/                                      │
│  │   ├── daily/          ← daily notes (/journal)    │
│  │   ├── ideas/          ← brainstorms (/brainstorm) │
│  │   ├── concepts/       ← gbrain entity pages       │
│  │   ├── sources/        ← books, links, papers      │
│  │   ├── people/         ← person pages              │
│  │   ├── chat-history/   ← saved AI conversations    │
│  │   └── archive/                                    │
│  └── CLAUDE.md                                       │
└──────────┬───────────────────────────────────────────┘
           │ gbrain sync (launchd, every 30 min)
           ▼
┌──────────────────────┐
│  gbrain index        │  ← PGLite, local-only
│  (vault/.gbrain/)    │
└──────────┬───────────┘
           │ MCP
     ┌─────┴──────┐
     ▼            ▼
┌─────────────┐  ┌──────────────────────┐
│ Claude Code │  │ Claude Desktop       │
│ (coding)    │  │ (general chat)       │
│             │  │ "save takeaways" →   │
│             │  │ vault/chat-history/  │
└─────────────┘  └──────────────────────┘
```

---

## Quick start

1. **Clone**
   ```bash
   git clone --recurse-submodules git@github.com:<you>/pbrain.git
   cd pbrain
   ```

2. **Init gbrain** (must run from inside vault)
   ```bash
   cd vault
   gbrain init
   gbrain sync
   cd ..
   ```
   See `docs/gbrain-setup.md` for the full gbrain install.

3. **Open in Obsidian** — point Obsidian's vault to `<pbrain-root>/vault/`

4. **Wire Claude Desktop MCP** — see `docs/claude-desktop.md`

---

## Vault structure

| Directory | What goes here |
|---|---|
| `agent-work/daily/` | Daily notes — created by `/journal` |
| `agent-work/ideas/` | Brainstorms — created by `/brainstorm <topic>` |
| `agent-work/concepts/` | Compiled concept pages (yours or gbrain-generated) |
| `agent-work/sources/` | Books, papers, links |
| `agent-work/people/` | Person pages |
| `agent-work/chat-history/` | AI conversations worth keeping — saved via Claude Desktop |
| `agent-work/archive/` | Archived drafts |
| `notion-mirror/` | Historical Notion export — read-only archive, do not edit |

---

## Slash commands

All commands live in `.claude/commands/` and work from both the outer repo and vault sessions.

| Command | What it does |
|---|---|
| `/journal` | Create or open today's daily note in `agent-work/daily/` |
| `/brainstorm <topic>` | Create a brainstorming file in `agent-work/ideas/` |

---

## Mobile sync

iCloud Drive syncs vault to iPhone automatically via Obsidian for iOS (free). See `docs/mobile-sync.md`.

---

## Private notes

Create `vault/private/` and add it to `vault/.gitignore`. Files there are never pushed to the git remote. If using iCloud, use Obsidian's Selective Sync to exclude `private/` from cloud upload.

---

## Repository structure

```
pbrain/                          ← outer repo (tooling only)
├── .claude/
│   └── commands/
│       ├── journal.sh
│       └── brainstorm.sh
├── docs/
│   ├── gbrain-setup.md
│   ├── claude-desktop.md
│   └── mobile-sync.md
├── launchd/
│   └── com.pbrain.sync.plist    ← gbrain sync every 30 min
├── templates/                   ← frontmatter templates
├── vault/                       ← git submodule (your notes)
└── CLAUDE.md
```

---

## What not to do

- Don't write notes in the outer repo — use `vault/agent-work/`
- Don't edit `vault/notion-mirror/` — historical archive, treat as read-only
- Don't `bun install -g github:garrytan/gbrain` — broken postinstall hook; clone and link manually (see `docs/gbrain-setup.md`)
