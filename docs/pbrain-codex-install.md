# /pbrain-codex-install

Make pbrain work from the **OpenAI Codex CLI**, sharing one source of truth with Claude Code.

pbrain is, first and foremost, a Claude Code plugin. But every command's real logic lives in a plain shell script (`commands/<command>.sh`) that resolves the vault and reads `~/.config/pbrain/*` on its own and prints an `INSTRUCTIONS:` block any capable agent can follow. So Codex can run the *same* scripts. This command wires that up.

Run it **from Claude Code, after `/init-obsidian`.** (Vault setup and this installer stay on the Claude side; the day-to-day commands then work from either agent.)

## What it generates

Under `$CODEX_HOME` (default `~/.codex`):

| Path | What |
|---|---|
| `prompts/pbrain-<command>.md` | One Codex **custom prompt** per pbrain command — a thin wrapper that runs the same `commands/<command>.sh`. Invoke as `/prompts:pbrain-<command>`. |
| `AGENTS.md` | A delimited, **managed pbrain block** carrying the cross-command behaviour Codex needs (morning sequence, ride-along blocks, vault write rules, the launch command). |

`init-obsidian` and `pbrain-codex-install` themselves are **not** exposed to Codex — they're Claude-side setup.

The per-command prompt is genuinely thin (just path + argument routing → the shared `.sh`); the behaviour Codex needs to act the same as Claude Code (the morning sequence, the ride-along blocks, vault-write rules) lives once in the managed `AGENTS.md` block, not copied into every prompt.

## How interop stays bug-free

- **Single source of truth.** The prompts don't reimplement anything — they run the same `.sh` files. There's no second copy of the logic to drift.
- **One shared state.** Both agents resolve the vault the same way (`PBRAIN_VAULT` → `~/.config/pbrain/vault` → iCloud default) and share the same config, preferences, and SQLite DB under `~/.config/pbrain`. Alternating between Codex and Claude Code on the same machine **cannot conflict** — there's nothing agent-specific to get out of sync.
- **Codex-safe prompt bodies.** Codex's custom prompts are deprecated-but-supported and expand `$NAME` placeholders. The generator bakes a literal `.sh` path (Codex has no `CLAUDE_PLUGIN_ROOT`) and escapes every `$` except `$ARGUMENTS`, so shell variables and prose like `$VAULT_DIR` survive intact.
- **Non-destructive + idempotent.** The AGENTS.md block is merged between markers (your other content is preserved). Re-running refreshes every prompt, re-bakes the path, and prunes only stale prompts that carry pbrain's own marker — never your own Codex prompts.

## Launching Codex so pbrain can write

pbrain writes to the vault and to `~/.config/pbrain`. Launch Codex with both writable (the recap prints this with your real vault path filled in):

```bash
codex --sandbox workspace-write \
  --add-dir "/path/to/your/vault" \
  --add-dir "$HOME/.config/pbrain"
```

A handy alias:

```bash
alias pbrain-codex='codex --sandbox workspace-write --add-dir "/path/to/your/vault" --add-dir "$HOME/.config/pbrain"'
```

Then inside Codex:

```
/prompts:pbrain-journal
/prompts:pbrain-plan-my-day
/prompts:pbrain-brainstorm "should I build X"
```

**Include both `--add-dir` flags every time.** Without `~/.config/pbrain`, commands still run but preferences, reminders, and habit state can't be saved — they silently desync from Claude Code.

A few writes land outside those two dirs and so are best done from **Claude Code**: vault creation (`/init-obsidian`) and the background reminder poller (`/remind install`, which writes `~/Library/LaunchAgents`). Everyday `/prompts:pbrain-remind` (add / list / done) works fine in Codex. Reminders fire as macOS notifications via `osascript`; if your Codex setup restricts that, the notification just won't pop (the reminder is still recorded). The background version check wants network and silently no-ops without it — expected and harmless.

## Re-run it when…

It's idempotent and safe to re-run any time. You'll want to after:

- moving or reinstalling pbrain (re-bakes the `.sh` path), or
- a pbrain update that ships new commands (adds their prompts; prunes removed ones).

You do **not** need to re-run just because you edited a command's `.sh` — the prompt runs it directly, so the change is live. (If you also use the launchd reminder poller and you *move* pbrain, run `/remind uninstall` then `/remind install` from the new location so the poller points at the new path.)

## Notes / limits

- **Codex skills** (the newer mechanism) are gated behind `--enable skills` and aren't universally available, so this uses custom prompts — the path that works on any Codex CLI today.
- `init-obsidian` runs from Claude Code for now. Running it from Codex may come later; it isn't needed for day-to-day use once the vault is set up.
- macOS only, same as the rest of pbrain.

## Overrides

| Env var | Effect |
|---|---|
| `CODEX_HOME` | Codex home dir to install into (default `~/.codex`) |
| `PBRAIN_DEV_DIR` | Live repo path baked into the generated prompts so a dev's Codex runs the live clone too. **Export it in your shell *before* running `/pbrain-codex-install`** — it's read at generation time; if unset, the marketplace install path is baked instead. |
