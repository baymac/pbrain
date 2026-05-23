# Setup

Full setup for the pbrain stack: Obsidian + iCloud + Ollama + gbrain + Claude.

---

## Prerequisites

- macOS with iCloud signed in
- Homebrew
- bun (`curl -fsSL https://bun.sh/install | bash`)

---

## 1. Vault

Run the init script — creates the vault directory at the Obsidian iCloud path, `git init`s it, writes `.gitignore` + `CLAUDE.md`, and makes the initial commit.

```bash
./scripts/init-vault.sh
```

Override the location with `VAULT_DIR=/path ./scripts/init-vault.sh` or pass it as `$1`. Idempotent — safe to re-run.

Then install Obsidian from https://obsidian.md and **Open folder as vault** → select the path the script printed.

---

## 2. iCloud

1. System Settings → Apple Account → iCloud → See All → iCloud Drive → toggle **Obsidian** ON.
2. iOS: install Obsidian from App Store, open it once. The vault auto-appears.

The vault syncs as a normal iCloud folder. Finder access: ⌘+Shift+G →
`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault`

---

## 3. Ollama (local embeddings)

```bash
brew install ollama
brew services start ollama
ollama pull nomic-embed-text
```

Runs as a background service. Auto-starts at login. ~30MB RAM idle.

---

## 4. gbrain

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
cd ~/Library/Mobile\ Documents/iCloud~md~obsidian/Documents/vault
gbrain init --pglite --embedding-model ollama:nomic-embed-text --embedding-dimensions 768
gbrain config set embedding_model ollama:nomic-embed-text
```

Brain lives at `~/.gbrain/brain.pglite/` (global, not per-vault).

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

## 5. MCP wiring

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

## 6. Scheduled sync

```bash
./scripts/install-launchd.sh
launchctl list | grep pbrain   # should appear
```

The installer renders the plist template with your local paths, copies to `~/Library/LaunchAgents/`, and loads it. Runs every 30 min via `scripts/gbrain-sync-wrapper.sh` which adds a lockfile (no zombie syncs) and JSONL timing log.

View status anytime:

```bash
./scripts/gbrain-dashboard.sh
```

Logs:
- `~/Library/Logs/pbrain/sync.log` — raw gbrain output
- `<repo>/.logs/sync-runs.jsonl` — structured timing log (gitignored)

---

## 7. Private notes (off git + off iCloud)

Two layers of exclusion:

```bash
cd ~/Library/Mobile\ Documents/iCloud~md~obsidian/Documents/vault

# 1. Create a private folder with .nosync suffix — macOS keeps it off iCloud
mkdir private.nosync

# 2. Add to .gitignore so it stays off git too
echo "private.nosync/" >> .gitignore
```

Files in `private.nosync/` live only on this Mac — never syncing to iCloud, iPhone, or git remote. Obsidian on Mac still indexes and opens them normally.

For iOS-only exclusion (still on Mac + Git): Obsidian iOS → Settings → Sync → Selective Sync → exclude the folder.

---

## 8. Vault `.gitignore`

The vault is a standalone git repo. Required entries:

```
.gbrain/
.DS_Store
```

---

## File locations

| What | Where |
|---|---|
| Vault | `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault/` |
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
