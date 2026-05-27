# /init-obsidian

Bootstrap pbrain end-to-end. Idempotent — safe to re-run.

Walks you through:

1. Obsidian Desktop install check (auto-detected; otherwise prompted to install).
2. Optional Obsidian Mobile and Web Clipper Chrome extension.
3. Vault location — new in iCloud (recommended for mobile sync), new elsewhere, or import an existing vault. Existing vaults can optionally be migrated to iCloud (copy + verified file count; source never auto-deleted).
4. If the vault ends up in iCloud, offers to create `vault/private.nosync/` — a folder excluded from both iCloud and git for local-only notes.
5. Optional git remote setup — either auto-creates a private GitHub repo via `gh repo create` (if `gh` is installed and authenticated), or registers a remote URL you provide and pushes the initial commit.
6. Writes `~/.config/pbrain/vault` so every other pbrain command knows where the vault is.

**Default destination:** `~/.config/pbrain/vault` (config file) + whatever vault path you pick.

**Overrides:** none — `/init-obsidian` writes the config that every other command reads. Re-run any time to change the vault location.

**Slash command availability is separate** — `/init-obsidian` no longer touches `<vault>/.claude/commands`. Make commands available globally by symlinking `<repo>/commands` → `~/.claude/commands` (one time, covers every CC session). See the README's Quick start.

**What it doesn't do:** set up gbrain. See [`gbrain/docs/setup.md`](../gbrain/docs/setup.md) for the AI search layer (optional).

**Direct subcommand access** (for scripting or recovery):

```bash
commands/init-obsidian.sh probe                   # print state
commands/init-obsidian.sh bootstrap <path>        # create + scaffold + write config
commands/init-obsidian.sh migrate <from> <to>     # copy vault, verify, never auto-delete
commands/init-obsidian.sh setup-private <vault>   # vault/private.nosync/ + README + .gitignore
commands/init-obsidian.sh write-config <path>     # register an existing path
commands/init-obsidian.sh setup-git <vault> <url> # add/update remote origin, push current branch
```
