#!/usr/bin/env bash
# Initialize a pbrain vault:
#  - creates the vault directory at the Obsidian iCloud path (or $VAULT_DIR)
#  - git init + .gitignore
#  - agent-work/ subdirectory layout
#  - vault-level CLAUDE.md (agent guide) if not present
#  - initial commit
#
# Idempotent — re-running on an existing vault is safe.
#
# Override the destination by exporting VAULT_DIR or passing it as $1:
#   VAULT_DIR=/some/path ./scripts/init-vault.sh
#   ./scripts/init-vault.sh /some/path
set -euo pipefail

VAULT_DIR="${1:-${VAULT_DIR:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault}}"

echo "Vault dir: $VAULT_DIR"
mkdir -p "$VAULT_DIR"
cd "$VAULT_DIR"

# 1. Git init
if [[ ! -d .git ]]; then
  git init -q
  echo "  ✓ git initialized"
else
  echo "  · git already initialized"
fi

# 2. .gitignore
if [[ ! -f .gitignore ]]; then
  cat > .gitignore <<'GI'
.gbrain/
.DS_Store
private.nosync/
GI
  echo "  ✓ .gitignore written"
else
  echo "  · .gitignore exists (leaving as-is)"
fi

# 3. agent-work structure (dirs created on demand; nothing to scaffold up front)
#    Scripts that write into agent-work use mkdir -p, so we don't pre-create empty dirs.

# 4. CLAUDE.md (agent guide) — only write if absent
if [[ ! -f CLAUDE.md ]]; then
  cat > CLAUDE.md <<'CMD'
# vault — Your Brain

This is the vault. Write notes here. The pbrain tooling repo lives elsewhere — scripts and slash commands belong there, not here.

Use Obsidian to browse and edit. Everything is plain markdown — readable in any editor.

---

## Where notes live

**User-curated** (you own these — agents don't write here without asking):

| Content | Directory |
|---|---|
| Daily journal | `life/daily-tracking/YYYY-MM-DD.md` |
| Topical notes | `life/`, `fitness/`, `startup/`, `side-quests/`, `software-dev/`, ... |
| Concepts, ideas, sources | Co-located inside the relevant topical folder |

**Agent-generated** (Claude writes here):

| Content | Directory |
|---|---|
| `/brainstorm` outputs | `agent-work/brainstorms/` |
| Chat takeaways | `agent-work/chat-history/` |
| Drafts | `agent-work/drafts/` |
| Misc agent notes | `agent-work/notes/` |
| Research summaries | `agent-work/research/` |
| People pages | `agent-work/people/` |

---

## Frontmatter

Optional but useful — gbrain uses it for typed retrieval.

```yaml
---
type: idea           # idea | concept | source | person | daily | chat
title: "Human-readable title"
tags: []
created: YYYY-MM-DD
---
```

---

## Wikilinks

Use `[[slug]]` (filename without `.md`) to reference other notes. gbrain builds a graph from these.

---

## Slash commands

Defined in the pbrain repo's `.claude/commands/`. Both work from a CC session opened inside the vault.

| Command | What it does |
|---|---|
| `/journal` | Create or open today's daily entry in `life/daily-tracking/` |
| `/brainstorm <topic>` | Create a brainstorming file in `agent-work/brainstorms/` |

---

## Journal-first behavior

Before any other slash command or personal-reflection task, check whether today's `life/daily-tracking/YYYY-MM-DD.md` exists. If not, suggest journaling first. User can override.

---

## gbrain

gbrain indexes every `.md` here. Brain lives globally at `~/.gbrain/brain.pglite/`. Sync runs every 30 min via launchd.

---

## Private notes

Anything in `private.nosync/` stays off iCloud and off git.
CMD
  echo "  ✓ CLAUDE.md written"
else
  echo "  · CLAUDE.md exists (leaving as-is)"
fi

# 5. Initial commit if nothing committed yet
if ! git rev-parse HEAD >/dev/null 2>&1; then
  git add .gitignore CLAUDE.md
  git -c user.name="$(git config --global user.name || echo 'pbrain')" \
      -c user.email="$(git config --global user.email || echo 'pbrain@local')" \
      commit -q -m "init: pbrain vault structure"
  echo "  ✓ initial commit"
else
  echo "  · vault already has commits (no initial commit)"
fi

echo
echo "Vault ready at: $VAULT_DIR"
echo
echo "Next steps:"
echo "  1. Open Obsidian → \"Open folder as vault\" → select the path above"
echo "  2. Continue with docs/setup.md (Ollama, gbrain, MCP, launchd)"
