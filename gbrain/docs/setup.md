# gbrain setup

How to get gbrain running over your Obsidian vault — Ollama embeddings, PGLite store, MCP wiring for Claude Code + Desktop, and a launchd job for scheduled sync.

Assumes you already have a vault. If not, run `/init-obsidian` from the repo root (interactive setup wizard).

(All `./gbrain/...` and `./scripts/...` paths below are from the repo root.)

---

## Prerequisites

- macOS
- Homebrew
- bun (`curl -fsSL https://bun.sh/install | bash`)
- A vault directory with at least one `.md` file

---

## 1. Ollama (local embeddings)

```bash
brew install ollama
brew services start ollama
ollama pull nomic-embed-text
```

Runs as a background service, auto-starts at login, ~30 MB RAM idle.

---

## 2. gbrain

Install:

```bash
git clone https://github.com/garrytan/gbrain.git ~/code/gbrain
cd ~/code/gbrain && bun install && bun link
```

Verify:

```bash
gbrain --version
```

Init the brain configured for Ollama:

```bash
cd ~/Library/Mobile\ Documents/iCloud~md~obsidian/Documents/vault   # or your vault path
gbrain init --pglite --embedding-model ollama:nomic-embed-text --embedding-dimensions 768
gbrain config set embedding_model ollama:nomic-embed-text
```

Brain lives globally at `~/.gbrain/brain.pglite/` (not per-vault).

First sync:

```bash
gbrain sync --repo . --skip-failed
```

Verify:

```bash
gbrain doctor
gbrain query "test phrase"
```

---

## 3. MCP wiring

**Claude Code:**

```bash
claude mcp add gbrain "$HOME/.bun/bin/gbrain" serve
claude mcp list   # gbrain should show ✓ Connected
```

(Use the absolute path — Claude Code spawns the MCP from an env that may not include `~/.bun/bin` in `$PATH`.)

**Claude Desktop** — add to `~/Library/Application Support/Claude/claude_desktop_config.json`, replacing `<HOME>` with your home directory:

```json
{
  "mcpServers": {
    "gbrain": {
      "command": "<HOME>/.bun/bin/gbrain",
      "args": ["serve"]
    }
  }
}
```

Restart Claude Desktop.

---

## 4. Scheduled sync

```bash
./gbrain/scripts/install-launchd.sh
launchctl list | grep pbrain   # should appear
```

The installer renders the plist template with your local paths, copies to `~/Library/LaunchAgents/`, and loads it. Runs every 30 min via `gbrain/scripts/gbrain-sync-wrapper.sh` which adds a lockfile (no zombie syncs) and JSONL timing log.

View status anytime:

```bash
./gbrain/scripts/gbrain-dashboard.sh
```

Logs:
- `~/Library/Logs/pbrain/sync.log` — raw gbrain output
- `gbrain/.logs/sync-runs.jsonl` — structured timing log (gitignored)

For architecture details on the sync wrapper and the PGLite single-writer lock, see [gbrain-sync.md](gbrain-sync.md).

---

## File locations

| What | Where |
|---|---|
| Vault | wherever you put it (default: `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault/`) |
| gbrain brain | `~/.gbrain/brain.pglite/` |
| gbrain source | `~/code/gbrain/` |
| launchd plist | `~/Library/LaunchAgents/com.pbrain.sync.plist` |
| Sync logs | `~/Library/Logs/pbrain/sync.log` |
| Claude Code MCP config | `~/.claude.json` |
| Claude Desktop MCP config | `~/Library/Application Support/Claude/claude_desktop_config.json` |

---

## Troubleshooting

**`gbrain: command not found`** — `cd ~/code/gbrain && bun link`. Ensure `~/.bun/bin` in `$PATH`.

**`Failed to connect` in `claude mcp list`** — use absolute path `$HOME/.bun/bin/gbrain`, not bare `gbrain`. Claude Code's MCP spawn env may not include `~/.bun/bin`.

**`ZeroEntropy embedding requires ZEROENTROPY_API_KEY`** — schema was created with ZE default. Fix: `rm -rf ~/.gbrain && gbrain init --pglite --embedding-model ollama:nomic-embed-text --embedding-dimensions 768`.

**`input length exceeds the context length`** — file >8192 tokens. Split or live without it (gbrain skips and continues).

**launchd `getcwd: Operation not permitted`** — benign warning when iCloud path is involved; sync still completes.

**Ollama not responding** — `brew services restart ollama`.
