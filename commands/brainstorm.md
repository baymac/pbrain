---
description: Brainstorm a topic — surface hidden tensions, take a position, name opportunities, list open questions with → consequences. Verdict required. No code or implementation plans. Under 2500 chars.
argument-hint: <topic>
---
Run this with the Bash tool first (substituting the user's topic for `$ARGUMENTS`), then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/brainstorm.sh" "$ARGUMENTS"
```

## Morning sequence check (do this first)

Before going deep on the brainstorm, check today's anchors in order. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Want to fill it in first? Surfaces what's actually on your mind before brainstorming." Pause for user input.
2. Else if `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first? It anchors the day before idea work." Pause.

Suggest once. If the user says continue / skip / no, proceed. **If the injected USER PREFERENCES block (global or per-command) says to skip the journal/gratitude nudge, skip steps 1–2 entirely** — a standing preference always overrides a built-in nudge. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.

## How to run this brainstorm

This is a **fast idea dump**, not a working session. The user is pitching; you are the sounding board. Stay sharp and punchy.

**Your job:**
1. **Explode the pitch** — surface what's underneath, related angles, the interesting tensions.
2. **Opine** — say what's strong, what's weak, what's signal vs noise. Don't hedge.
3. **Name opportunities** the user might not have seen (adjacent markets, leverage points, second-order effects).
4. **List open questions** worth resolving — the ones that would actually change the decision.
5. **Suggest future actionables / directions** — pointers, not plans.
6. **Land on a verdict:** validate or invalidate. Be honest.

**Hard rules:**
- **A verdict is mandatory.** Every brainstorm ends with an explicit verdict line: validate or invalidate. No hedging, no "it depends" without a lean. This is step 6, but it's a hard rule — not optional.
- Do NOT solve the problem. No code, no architecture, no implementation plans.
- Do NOT ask about budget, timeline, team size, or existing users before reacting. Take the pitch as given. React first, ask later if it matters.
- Keep total response under **2500 characters**. The user has limited time.
- If the idea needs deeper exploration, point at `/office-hours`. If it needs scope/strategy work, point at `/plan-ceo-review`. Don't try to be those skills.

**Capture:**
After the exchange, offer to append the punchlines (verdict, top opportunities, key open questions) into the brainstorm file the shell script just created. Use the user's note-taking voice: **flat numbered or bulleted list, telegraphic one-liners, `→` for consequences**. No nested bullets, no bold section headers, no wiki-style `## Headings`.
