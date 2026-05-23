# Mobile Sync

How vault syncs between Mac and iPhone via iCloud (free, no Obsidian Sync needed).

---

## How it works

The vault lives in Obsidian's iCloud app container:

```
~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault
```

iCloud syncs this folder between your Mac and iPhone automatically. Obsidian for iOS auto-detects vaults in this location.

Git history stays on the Mac — the phone just reads/writes markdown.

---

## iOS setup

1. Install **Obsidian** from the App Store (free)
2. Sign in to the same Apple ID as your Mac
3. Open Obsidian → it auto-detects the vault under iCloud
4. Tap to open — all notes sync down on first launch (can take a few minutes for ~400 files)

No git on iPhone. No Working Copy. iCloud handles file sync; git only runs on Mac.

---

## Mac visibility

The Obsidian iCloud container doesn't always show up in Finder → iCloud Drive sidebar by default. Two ways to fix:

**Option 1** — System Settings → Apple Account → iCloud → See All → iCloud Drive → "Apps syncing to iCloud Drive" → toggle **Obsidian** ON.

**Option 2** — In Finder, ⌘+Shift+G → paste the path above → drag the folder to Finder sidebar for permanent access.

---

## What iCloud syncs

- All `.md` files under `vault/`
- Obsidian config (`.obsidian/`)
- `.gbrain/` — gitignored but **not** iCloud-excluded by default. Currently this isn't an issue because gbrain stores its DB globally at `~/.gbrain/`, not inside the vault. If you ever see a `vault/.gbrain/` appear, exclude it from iCloud by renaming to `.gbrain.nosync` or moving it elsewhere.

---

## Private notes

To keep notes off git **and** off iCloud:

```bash
mv vault/private vault/private.nosync   # iCloud respects .nosync suffix
echo "private.nosync/" >> vault/.gitignore
```

Files in `private.nosync/` stay only on the Mac, never syncing or committing.

Alternative for iOS-only exclusion (still on Mac and Git): in Obsidian for iOS, Settings → Sync → Selective Sync → exclude the folder.

---

## Conflict handling

iCloud uses last-write-wins. If you edit the same file on Mac and iPhone before iCloud syncs, one version wins; the other is saved as `filename (conflict).md`. Git on Mac preserves both — `git log` will show what was overwritten.

To minimize: let iCloud finish syncing before switching devices. Watch the iCloud icon in Finder.

---

## Troubleshooting

**Files exist on Mac but not on iPhone** — wait 15-30 min for iCloud to propagate. Force-quit and reopen Obsidian iOS. Check iOS WiFi (iCloud throttles cellular sync).

**iCloud says "Up to date" on Mac, but iPhone is empty** — toggle airplane mode for 10 sec on iPhone to force iCloud reconnect.

**Filenames with many spaces fail to sync** — iCloud is fine but iOS may struggle. Trim filenames with `<` 100 chars and avoid runs of consecutive spaces.
