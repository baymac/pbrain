# /vault-backup — off-iCloud vault snapshots (PB-10)

The vault is the source of truth for every pbrain note and lives in iCloud Drive for cross-device sync. **iCloud is sync, not backup** — a bad sync, an accidental delete, or an account problem propagates everywhere. `/vault-backup` keeps an independent, automated copy somewhere iCloud can't reach.

It is the vault-side sibling of `/project-manager backup` (PB-17): a nightly tarball of the vault shipped to a local dir, an external volume, or a VPS over `rsync`, with N-day retention, a daily LaunchAgent, and a guarded restore.

```
/vault-backup estimate                          # how big is a snapshot + the retention footprint?
/vault-backup now                               # take one right now
/vault-backup enable --dest vps --time 03:45    # nightly snapshot to the VPS, kept 14 days
/vault-backup status                            # schedule, destination, latest snapshot, last-good age
/vault-backup restore latest --into ~/vault-restore   # NON-destructive: extract into a dir
```

| Subcommand | What it does |
|---|---|
| `estimate` | Measure the current vault tarball size (no write) and the projected retention footprint. |
| `now [--dir <path>]` | Take a snapshot immediately into the configured destination (or a one-off `--dir`). |
| `enable [--time HH:MM] [--dest local\|external\|vps] [--dir <p>] [--keep N] [--exclude <pat>] [--vps-host …] [--vps-path …] [--vps-port …] [--ssh-key …]` | Save the settings and install a daily LaunchAgent. |
| `disable` | Stop the schedule (existing snapshots are kept). |
| `config …` | Change settings; refreshes a live schedule in place. |
| `status` / `list` | Schedule + destination + retention + last-good-backup age; the list of snapshots with sizes. |
| `restore <file\|latest> --into <dir> [--yes]` | Extract a snapshot **into a directory** — non-destructive. `--yes` is only required to extract over the live vault. |
| `check [--threshold H]` | Fire a macOS notification if the last good backup is older than 48h (override with `--threshold`). |

**Where it lands.** Three destinations, same as the Plane backup:

- **local** (default) — `~/.config/pbrain/vault-backups`, which Time Machine backs up by default.
- **external** — a mounted volume, e.g. `--dest external --dir /Volumes/Backup/vault`. Won't write if the volume isn't mounted.
- **vps** — `rsync`/`scp` over ssh. The VPS **host / port / ssh-key are inherited from the Plane backup** (`~/.config/pbrain/plane-backup.json`) so you don't re-enter them — it's the *same VPS*. The remote **path** stays distinct (defaults to a `vault-backups` dir alongside the Plane one); override any field with `--vps-host/--vps-path/--vps-port/--ssh-key`. Uploads run non-interactively, so set up key auth.

**The snapshot.** `vault-YYYYMMDD-HHMMSS.tar.gz` containing a `manifest.json` (created-at, vault path, file count, total bytes, git HEAD) and the whole vault tree, honoring the exclude patterns (`--exclude`, default `.DS_Store`).

**Restore is non-destructive.** Unlike the Plane backup's in-place DB restore, `/vault-backup restore` extracts the tarball into the directory you name (`--into`, a fresh dir by default), so you inspect/copy what you need — it never overwrites your live iCloud vault unless you explicitly point `--into` at the vault and pass `--yes`.

**Logging + staleness.** Every run appends an `ok`/`fail` line to `vault/.pbrain/backup-log.md` (in the vault, so it syncs and is visible across devices). The scheduled run also self-checks staleness and fires a macOS notification if the last good backup is older than 48h. Config lives at `~/.config/pbrain/vault-backup.json` (mode `0600`); the scheduled run logs to `~/.config/pbrain/vault-backup.log`.
