#!/usr/bin/env bash
# scaffold.sh — shared vault-scaffold helpers.
#
# Standalone and dependency-free: this file must NOT source lib/vault.sh, because
# both lib/vault.sh (for the zero-config ~/pbrain-vault auto-fallback) and
# commands/init-obsidian.sh (which deliberately runs pre-vault) source it.
#
# Exposes:
#   pbrain_scaffold_vault <path>      — mkdir, git init, .gitignore, vault-level
#                                       CLAUDE.md, initial commit. Idempotent.
#                                       git steps are skipped (not fatal) when git
#                                       is absent, so a no-git machine still gets a
#                                       usable plain-markdown vault.
#   pbrain_write_vault_config <path>  — write <path> to ~/.config/pbrain/vault
#                                       (honors $XDG_CONFIG_HOME). Idempotent.

# Scaffold a vault at $1: mkdir, git init, .gitignore, vault-level CLAUDE.md,
# initial commit. Idempotent — re-running on an existing vault leaves it alone.
# git is optional: if `git` isn't on PATH, the dir + files are still created and
# the commit is skipped (so "never hard-fail" holds on a machine without git).
pbrain_scaffold_vault() {
  local vault="$1"
  local have_git=0
  command -v git >/dev/null 2>&1 && have_git=1
  echo "Vault dir: $vault"
  mkdir -p "$vault"
  (
    cd "$vault"

    if [[ "$have_git" -eq 1 ]]; then
      if [[ ! -d .git ]]; then
        git init -q
        echo "  ✓ git initialized"
      else
        echo "  · git already initialized"
      fi
    else
      echo "  · git not found — creating a plain (non-git) vault"
    fi

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
| `/brainstorm` outputs | `agent-work/brainstorms/tbd/` (move to `backlog/` to park, `done/` when actioned) |
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

Defined in the pbrain repo's `commands/` (Claude plugin). Work from a CC session opened inside the vault.

| Command | What it does |
|---|---|
| `/journal` | Create or open today's daily entry in `life/daily-tracking/` |
| `/brainstorm <topic>` | Create a brainstorming file in `agent-work/brainstorms/tbd/`. Move to `backlog/` (parked) or `done/` (actioned) manually. |

---

## Morning sequence (journal → gratitude → everything else)

Before any other slash command or personal-reflection task, check daily files in order:

1. If `life/daily-tracking/YYYY-MM-DD.md` is missing, suggest `/journal` first. The raw dump clears the head and surfaces what's on your mind.
2. If the journal exists but `life/gratitude-journal/YYYY-MM-DD.md` is missing, suggest `/gratitude-journal` next. With the head cleared, gratitude anchors baseline to *enough*.
3. Otherwise proceed.

Suggest once, never block. `/init-obsidian`, `/journal`, and `/gratitude-journal` are exempt. If a standing preference (in the injected USER PREFERENCES block — global or per-command) says to skip this nudge, don't make it. Any built-in suggestion yields to a standing preference that turns it off.

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

    if [[ "$have_git" -eq 1 ]] && ! git rev-parse HEAD >/dev/null 2>&1; then
      git -c user.name="$(git config --global user.name || echo 'pbrain')" \
          -c user.email="$(git config --global user.email || echo 'pbrain@local')" \
          add .gitignore CLAUDE.md
      git -c user.name="$(git config --global user.name || echo 'pbrain')" \
          -c user.email="$(git config --global user.email || echo 'pbrain@local')" \
          commit -q -m "init: pbrain vault structure"
      echo "  ✓ initial commit"
    elif [[ "$have_git" -eq 1 ]]; then
      echo "  · vault already has commits"
    fi
  )
}

# Write $1 to the pbrain vault-config file (~/.config/pbrain/vault, honoring
# $XDG_CONFIG_HOME). Idempotent.
pbrain_write_vault_config() {
  local path="$1"
  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain"
  local config_file="$config_dir/vault"
  mkdir -p "$config_dir"
  printf '%s\n' "$path" > "$config_file"
  echo "  ✓ wrote $config_file → $path"
}
