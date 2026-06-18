---
description: Automated off-iCloud backup of the Obsidian vault (PB-10). A nightly tarball of the vault shipped to a local dir, an external volume, or a VPS over rsync — with retention, a guarded non-destructive restore, a daily LaunchAgent, a per-run log in vault/.pbrain/backup-log.md, and a macOS notification when the last good backup is older than 48h. VPS credentials are inherited from the Plane backup (same VPS, no re-entry).
argument-hint: status | now | enable [--dest local|external|vps] [--time HH:MM] [--keep N] | config … | disable | list | restore <snapshot|latest> --into <dir> | check
---
Run this with the Bash tool first (substituting the user's words for `$ARGUMENTS`), then relay the result:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/vault-backup.sh" $ARGUMENTS
```

The script acts directly and prints a `VBK_*` block per action — just relay it concisely. iCloud is *sync*, not backup; this keeps an independent copy somewhere iCloud can't reach.

## Mapping the user's words → an action

- **"set up / turn on nightly vault backups"** → `enable`. Default destination is `local` (`~/.config/pbrain/vault-backups`, Time-Machine-covered). For the user's stated intent — *the same VPS as the Plane backup* — use `enable --dest vps`. The VPS **host / port / ssh-key are inherited** from the Plane backup config (`~/.config/pbrain/plane-backup.json`); the remote **path** defaults to a distinct `vault-backups` dir alongside the Plane one. Only pass `--vps-host/--vps-path/--vps-port/--ssh-key` to override. Suggest running `estimate` first to show the footprint, and confirm the nightly time (default `03:45`, offset from Plane's `03:30`).
- **"back up now"** → `now`.
- **"how's the backup / when did it last run"** → `status` (shows schedule, destination, retention, snapshot count, and the age of the last good backup).
- **"list backups"** → `list`.
- **"restore / recover the vault"** → `restore <snapshot|latest> --into <dir>`. This is **non-destructive**: it extracts into `--into <dir>` (a fresh dir by default), never over the live vault. Only if the user explicitly wants to overwrite the live vault do you add `--yes` with `--into` pointing at the vault path — confirm first, it's destructive.
- **"change destination / retention / time / excludes"** → `config` (e.g. `config --keep 30`, `config --time 04:00`, `config --exclude '.obsidian'`). If a schedule is live it refreshes automatically.
- **"stop / turn off"** → `disable` (existing snapshots are kept).
- **"is my backup stale?"** → `check` (notifies if the last good backup is older than 48h; `--threshold H` overrides).

Keep confirmations to one line. The nightly LaunchAgent runs `vault-backup.sh run` and logs to `~/.config/pbrain/vault-backup.log`; each run also appends an `ok`/`fail` line to `vault/.pbrain/backup-log.md` (synced, so visible across devices).
