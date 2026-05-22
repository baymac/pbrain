# Claude Desktop Setup

How to use Claude Desktop as a unified AI chat interface with gbrain and vault integration.

---

## Goal

One place for all AI chats. Interesting conversations get saved to `vault/agent-work/chat-history/`, gbrain indexes them, and future sessions can recall them.

---

## 1. Wire gbrain MCP to Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "gbrain": {
      "command": "gbrain",
      "args": ["serve"]
    }
  }
}
```

This gives Claude Desktop access to `gbrain_query`, `gbrain_put_page`, and `gbrain_get_page` — enough to search your vault and save chat takeaways without needing a separate filesystem MCP.

Restart Claude Desktop after editing the config.

**iCloud vault path:** If your vault is in iCloud Drive (see `docs/mobile-sync.md`), gbrain needs to be initialized from the iCloud path:
```
~/Library/Mobile Documents/iCloud~md~obsidian/Documents/<vault-name>/
```

---

## 2. Create the chat-history directory

```bash
mkdir -p <your-vault-path>/agent-work/chat-history
```

Replace `<your-vault-path>` with your actual vault location (e.g. `~/conductor/workspaces/pbrain/douala/vault` or the iCloud path above).

---

## 3. Add Project instructions in Claude Desktop

Create a Project in Claude Desktop for general chat. Add these instructions:

```
When I say "save takeaways", "save this", or "log the key points":
1. Extract 3-7 key insights from our conversation
2. Write a markdown file to vault/agent-work/chat-history/ using gbrain_put_page
3. Filename: YYYY-MM-DD-[short-slug].md (e.g. 2026-05-21-workout-plan.md)
4. Use this format:

---
type: chat
date: YYYY-MM-DD
topic: [short label]
tags: []
---

# [date] — [topic]

## Summary
[one sentence]

## Key Takeaways
- ...
- ...

5. Confirm with the filename when done.
```

---

## 4. Trigger phrases

Say any of these mid-conversation to save:

- *"save takeaways"*
- *"save this to vault"*
- *"log the key points"*

Claude calls `gbrain_put_page` → file lands in `vault/agent-work/chat-history/` → launchd gbrain sync picks it up within 30 minutes → available in future sessions via `gbrain_query`.

---

## 5. Make sure gbrain is initialized

gbrain must be initialized from inside vault before it can index chat saves:

```bash
cd <your-vault-path>
gbrain init
gbrain sync
```

See `docs/gbrain-setup.md` for the full gbrain install and MCP wiring.
