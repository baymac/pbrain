---
description: Bootstrap pbrain — Obsidian install checks, vault setup, optional iCloud sync, private notes dir. Idempotent; safe to re-run.
---
Before anything else, run this with the Bash tool to probe the machine state:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/init-obsidian.sh" probe
```

Then walk the user through pbrain setup using the probe output. Be terse — short Y/N prompts, no long paragraphs.

## Step 1 — Obsidian Desktop (required)

- If `OBSIDIAN_APP_INSTALLED=yes`: say "Obsidian Desktop ✓" and continue.
- If `no`: ask the user to install from <https://obsidian.md/download> and reply once installed. Don't proceed until they confirm.

## Step 2 — Obsidian Mobile (optional)

Ask: "Want Obsidian on phone too?" Y/N.
- If yes: tell them to search "Obsidian" in App Store (iOS) or Play Store (Android). iOS sync uses iCloud (step 4); Android needs a different sync layer (out of scope here).

## Step 3 — Obsidian Web Clipper (optional)

Ask: "Install the Web Clipper Chrome extension for saving articles?" Y/N.
- If yes: point to <https://obsidian.md/clipper>. Mention that clippings land in `vault/Clippings/` and `/organize-clippings` sorts them later.

## Step 4 — Vault location

Read the probe values. Branch:

- If `PBRAIN_CONFIG_EXISTS=yes` and `PBRAIN_CONFIG_VAULT_EXISTS=yes`: ask "Vault already configured at `$PBRAIN_CONFIG_VAULT` — keep it?" Y/N. If yes, skip ahead to the recap. If no, fall through to the choice below.

- Else, present the choice:
  1. **New vault in iCloud** (recommended for mobile sync) → `$ICLOUD_DEFAULT_VAULT_PATH`
  2. **New vault elsewhere** — user gives a path
  3. **Import existing vault** — user gives the current vault path

  If `ICLOUD_DEFAULT_VAULT_EXISTS=yes`, surface that explicitly: "An Obsidian iCloud vault already exists at `$ICLOUD_DEFAULT_VAULT_PATH`. Use it?" Y/N before offering the menu.

### Choice 1 or 2 — new vault
Call: `init-obsidian.sh bootstrap <path>` (this creates the dir, runs `git init`, writes `.gitignore` + vault-level `CLAUDE.md`, makes the initial commit, and writes `~/.config/pbrain/vault`).

### Choice 3 — existing vault
Ask: "Migrate to iCloud for mobile sync?" Y/N.
- **No (keep where it is)** → call `init-obsidian.sh write-config <path>`. Note: mobile sync won't work unless the path is under iCloud.
- **Yes (migrate)** → call `init-obsidian.sh migrate <from> <icloud-path>`. After it prints `MIGRATE_VERIFIED=yes`, call `init-obsidian.sh write-config <icloud-path>`. **Do not** auto-delete the source — the script prints the `rm -rf` command for the user to run manually once they've opened the new vault in Obsidian and verified everything's there.

## Step 5 — Private notes dir (iCloud vaults only)

Only ask if the chosen vault path is under iCloud (starts with `$ICLOUD_OBSIDIAN_BASE` from the probe, or matches `$ICLOUD_DEFAULT_VAULT_PATH`).

Ask: "Set up `vault/private.nosync/` for notes that never leave this Mac (excluded from iCloud + git)?" Y/N.
- If yes: call `init-obsidian.sh setup-private <vault>`.

## Step 6 — Git remote (optional)

Skip if the vault was imported and `git remote get-url origin` already returns a URL — just print "git remote already configured: <url>" and move on.

Otherwise ask: "Push the vault to a git remote as backup / cross-device sync?" Y/N.

If yes, ask which path:

- **(a) Auto-create a private GitHub repo via `gh`** (only offer if `gh auth status` succeeds in a Bash probe).
  - Ask for a repo name (default: `vault`).
  - Run `gh repo create <user>/<name> --private --source <vault> --remote origin --push` from inside the vault dir. That single command creates the repo, adds the remote, and pushes in one shot — no need to call `init-obsidian.sh setup-git` afterward.
  - If the user wants a public repo, replace `--private` with `--public`.
- **(b) Use an existing remote URL** — ask the user to paste it (e.g. `git@github.com:you/vault.git`).
  - Call `init-obsidian.sh setup-git <vault> <url>`. This adds/updates `origin` and pushes the current branch.
  - If push fails (remote not empty, no permission, etc.) the script prints the cause and exits non-zero — surface that to the user and let them fix it before continuing.

If no, just say "Skipped — vault stays local-only" and move on.

## Step 7 — Recap

Print a short summary:
- Vault path
- Config file path (`~/.config/pbrain/vault`)
- Whether private dir was set up
- Git remote (if any)
- Next: "Open Obsidian → **Open folder as vault** → `<vault path>`"
- If they chose iCloud and want mobile: "Open the Obsidian app on your phone — it'll auto-detect the vault. First sync can take a few minutes."

That's it. No further prompting unless they ask.
