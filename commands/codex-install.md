---
description: Make pbrain interoperable with the OpenAI Codex CLI — generate Codex agent skills + a managed AGENTS.md block from the same command sources. Run from Claude Code after /init-obsidian. Idempotent.
---
Run this with the Bash tool, then relay its recap to the user:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/codex-install.sh"
```

pbrain is primarily a Claude Code plugin. This installer lets the OpenAI **Codex** CLI run the *same* pbrain commands against the *same* vault and config — one source of truth, no per-agent fork. It writes, under `$CODEX_HOME` (default `~/.codex`):

- `skills/pbrain-<command>/SKILL.md` — one Codex **agent skill** per pbrain command, each a thin wrapper that runs the same `commands/<command>.sh`. Skills are Codex's supported, default-on capability (custom prompts are deprecated); Codex discovers them automatically. (`init-obsidian` and `codex-install` stay Claude-only.)
- a managed, clearly-delimited **pbrain block** in `AGENTS.md` carrying the cross-command behaviour Codex needs (how to invoke, morning sequence, ride-along blocks, vault write rules, the launch command), scoped so it won't affect unrelated Codex sessions.

Any custom prompts an earlier pbrain version installed (`prompts/pbrain-*.md`) are cleaned up — skills replace them.

The script prints a `PBRAIN_CODEX_INSTALLED` recap ending in an `INSTRUCTIONS` block. **Follow that block**: relay, concisely, what was installed, the exact launch command (it bakes in the resolved vault path), one example invocation (just say `journal` — or `$pbrain-journal`; **not** `/journal`), and — if the recap says so — that the user should run `/init-obsidian` first (vault not configured) or install the Codex CLI (not detected). Don't paste the whole recap back; a short confirmation is enough.

It's idempotent — safe to re-run after moving/reinstalling pbrain or when new commands ship (it re-bakes paths, refreshes every skill, and prunes stale ones).
