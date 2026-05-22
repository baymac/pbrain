# gbrain Setup

gbrain provides hybrid vector + keyword search and an entity graph over your vault.

---

## Prerequisites

- **bun** — https://bun.sh (`curl -fsSL https://bun.sh/install | bash`)
- **vault** cloned and containing at least some notes

---

## 1. Install gbrain (do NOT use global install)

The global install (`bun install -g github:garrytan/gbrain`) has a broken postinstall hook. Clone and link manually:

```bash
git clone https://github.com/garrytan/gbrain.git ~/code/gbrain
cd ~/code/gbrain
bun install
bun link
```

Verify:

```bash
gbrain --version
```

---

## 2. Initialize the brain inside vault/

**Critical**: run `gbrain init` from inside `vault/`, not from the pbrain root.

If you init at the pbrain root, gbrain will index your scripts, templates, and tooling as notes. That's wrong — gbrain's brain should only contain your actual notes.

```bash
cd ~/code/pbrain/vault
gbrain init
```

This creates `vault/.gbrain/brain.pglite` — a PGLite (embedded Postgres) database. It is gitignored in `vault/.gitignore`.

---

## 3. Verify with gbrain doctor

```bash
cd ~/code/pbrain/vault
gbrain doctor
```

Should show green checks for:
- brain.pglite exists
- pgvector extension loaded
- schema up to date

---

## 4. Wire gbrain MCP to Claude Code

```bash
claude mcp add gbrain -- gbrain serve
```

This registers gbrain as an MCP server. When you open a CC session from `vault/`, CC can:
- Call `gbrain_query` for hybrid search
- Call `gbrain_graph_query` for entity graph traversal
- Call `gbrain_put_page` to write entity pages to `agent-work/`
- Call `gbrain_get_page` to read pages by slug

Verify the MCP is registered:

```bash
claude mcp list
# Should show: gbrain → gbrain serve
```

---

## 5. First sync

```bash
cd ~/code/pbrain/vault
gbrain sync
```

This indexes all `.md` files under `vault/`. For a large vault this may take a minute. Subsequent syncs are incremental.

---

## 6. Schedule gbrain sync

Run gbrain sync on a schedule so the index stays fresh as you add notes in Obsidian. Use the provided launchd plist (see `launchd/com.pbrain.sync.plist`) or add to cron:

```bash
*/30 * * * * cd <your-vault-path> && gbrain sync >> ~/Library/Logs/pbrain/sync.log 2>&1
```

The launchd plist uses a `StartInterval` of 1800s (30 min). See the install instructions in the plist file's comments.

---

## 7. Test gbrain

```bash
cd ~/code/pbrain/vault
gbrain query "your search terms"
gbrain graph-query --entity "concept name"
```

From a CC session in `vault/`:

```
What do I know about <topic>?
```

CC will use the `gbrain_query` MCP tool to search.

---

## What gbrain does in this setup

- Indexes every `.md` file under `vault/` (all of `agent-work/` and historical `notion-mirror/`)
- Builds a typed entity graph from `[[wikilinks]]` and bare slug references
- Provides hybrid search (vector + BM25 keyword) via `gbrain query`
- Auto-creates entity pages in `agent-work/people/` and `agent-work/concepts/` when references accumulate

## What gbrain does NOT do

- Run autonomous background jobs unless you configure recipes (we skip recipes for pbrain)

---

## Troubleshooting

**"gbrain: command not found"** — Run `bun link` again from `~/code/gbrain`. Make sure `~/.bun/bin` is in your `$PATH`.

**"brain.pglite not found"** — Run `gbrain init` from inside `vault/` (not the pbrain root).

**gbrain sync is slow** — Normal on first run. Subsequent syncs are incremental (only changed files).

**MCP not showing in CC** — Run `claude mcp list`. If gbrain is missing, re-run `claude mcp add gbrain -- gbrain serve`.
