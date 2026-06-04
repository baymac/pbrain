# /codex-install

Make pbrain work from the **OpenAI Codex CLI**, sharing one source of truth with Claude Code.

pbrain is, first and foremost, a Claude Code plugin. But every command's real logic lives in a plain shell script (`commands/<command>.sh`) that resolves the vault and reads `~/.config/pbrain/*` on its own and prints an `INSTRUCTIONS:` block any capable agent can follow. So Codex can run the *same* scripts. This command wires that up.

Run it **from Claude Code, after `/init-obsidian`.** (Vault setup and this installer stay on the Claude side; the day-to-day commands then work from either agent.)

## What it generates

Under `$CODEX_HOME` (default `~/.codex`):

| Path | What |
|---|---|
| `skills/pbrain-<command>/SKILL.md` | One Codex **agent skill** per pbrain command — a thin wrapper that runs the same `commands/<command>.sh`. Codex discovers it automatically; invoke by name (`journal`), explicitly (`$pbrain-journal`), or just describe the task and Codex auto-selects it. |
| `AGENTS.md` | A delimited, **managed pbrain block** carrying the cross-command behaviour Codex needs (how to invoke, morning sequence, ride-along blocks, vault write rules, the launch command). |

`init-obsidian` and `codex-install` themselves are **not** exposed to Codex — they're Claude-side setup.

The per-command skill is genuinely thin (just path + argument routing → the shared `.sh`); the behaviour Codex needs to act the same as Claude Code (the morning sequence, the ride-along blocks, vault-write rules) lives once in the managed `AGENTS.md` block, not copied into every skill.

## Why skills (not custom prompts)

Earlier versions generated Codex **custom prompts** (`prompts/pbrain-*.md`, invoked `/prompts:pbrain-<command>`). OpenAI has since **deprecated custom prompts** and they regressed on recent Codex builds — they stopped appearing in the slash menu, so the commands were effectively undiscoverable. **Agent skills** are the supported replacement: enabled by default, auto-discovered, and invokable three ways (by name, with `$name`, or implicitly by description). Re-running `/codex-install` migrates you automatically — it installs the skills and removes any pbrain-managed custom prompts left behind.

> A literal `/journal` does **not** work in Codex: its CLI rejects unknown `/slash` commands before the model sees them. Invoke pbrain by plain name instead.

## How interop stays bug-free

- **Single source of truth.** The skills don't reimplement anything — they run the same `.sh` files. There's no second copy of the logic to drift.
- **One shared state.** Both agents resolve the vault the same way (`PBRAIN_VAULT` → `~/.config/pbrain/vault` → iCloud default) and share the same config, preferences, and SQLite DB under `~/.config/pbrain`. Alternating between Codex and Claude Code on the same machine **cannot conflict** — there's nothing agent-specific to get out of sync.
- **Verbatim skill bodies.** Codex reads a `SKILL.md` from disk as-is (no `$NAME` placeholder expansion, unlike custom prompts), so the generator just bakes a literal `.sh` path (Codex has no `CLAUDE_PLUGIN_ROOT`) — no `$`-escaping needed. `$VAULT_DIR`, `$ARGUMENTS`, and prose survive intact.
- **Non-destructive + idempotent.** The AGENTS.md block is merged between markers (your other content is preserved). Re-running refreshes every skill, re-bakes the path, and prunes only stale skills that carry pbrain's own marker — never your own Codex skills.

## Launching Codex so pbrain can write

pbrain writes to the vault and to `~/.config/pbrain`. The installer writes a **`codex-pbrain`** shell function to your RC file(s) that launches Codex with both dirs writable (resolving your vault at call-time). After `source ~/.zshrc` (or a new terminal):

```bash
codex-pbrain
```

Or launch manually (the recap prints this with your real vault path filled in):

```bash
codex --sandbox workspace-write \
  --add-dir "/path/to/your/vault" \
  --add-dir "$HOME/.config/pbrain"
```

Then inside Codex, invoke a command by **name** (no slash):

```
journal
plan my day
brainstorm should I build X
```

You can also reference a skill explicitly as `$pbrain-journal`, or just describe what you want and let Codex auto-select the matching skill.

**Include both `--add-dir` flags every time** (the `codex-pbrain` function does this for you). Without `~/.config/pbrain`, commands still run but preferences, reminders, and habit state can't be saved — they silently desync from Claude Code.

A few writes land outside those two dirs and so are best done from **Claude Code**: vault creation (`/init-obsidian`) and the background reminder poller (`/remind install`, which writes `~/Library/LaunchAgents`). Everyday `remind` (add / list / done) works fine in Codex. Reminders fire as macOS notifications via `osascript`; if your Codex setup restricts that, the notification just won't pop (the reminder is still recorded). The background version check wants network and silently no-ops without it — expected and harmless.

## Re-run it when…

It's idempotent and safe to re-run any time. You'll want to after:

- moving or reinstalling pbrain (re-bakes the `.sh` path), or
- a pbrain update that ships new commands (adds their skills; prunes removed ones).

You do **not** need to re-run just because you edited a command's `.sh` — the skill runs it directly, so the change is live. (If you also use the launchd reminder poller and you *move* pbrain, run `/remind uninstall` then `/remind install` from the new location so the poller points at the new path.)

## Notes / limits

- **Skills are enabled by default** on current Codex CLI — no `--enable` flag needed. If a freshly installed skill doesn't show up, restart Codex.
- `init-obsidian` runs from Claude Code for now. Running it from Codex may come later; it isn't needed for day-to-day use once the vault is set up.
- macOS only, same as the rest of pbrain.

## Overrides

| Env var | Effect |
|---|---|
| `CODEX_HOME` | Codex home dir to install into (default `~/.codex`) |
| `PBRAIN_DEV_DIR` | Live repo path baked into the generated skills so a dev's Codex runs the live clone too. The install script writes this to `~/.claude/settings.json`, so it's automatically available when running `/codex-install` from Claude Code. If running the installer directly from a terminal instead, export it in your shell first. |
