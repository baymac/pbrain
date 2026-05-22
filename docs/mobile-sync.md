# Mobile Sync Setup

How to sync vault to iPhone using iCloud Drive (free).

---

## How it works

iCloud Drive syncs files between your Mac and iPhone automatically. Obsidian for iOS finds vaults stored in iCloud Drive without any extra setup. Git history stays on the Mac side — the phone just reads and writes markdown files.

---

## Mac setup

### Option A — Keep vault in current location (simpler)

Keep vault at `<pbrain-root>/vault/`. Obsidian on Mac opens it there. For iOS sync, use the iCloud Drive approach below instead.

### Option B — Move vault into Obsidian's iCloud folder (recommended for iOS)

Obsidian for iOS looks for vaults in:
```
~/Library/Mobile Documents/iCloud~md~obsidian/Documents/
```

Move your vault there:
```bash
# Quit Obsidian first
mv <pbrain-root>/vault ~/Library/Mobile\ Documents/iCloud\~md\~obsidian/Documents/vault

# Update the git submodule to the new path (if needed, update .gitmodules)
```

Then reopen Obsidian on Mac and point it to the new location.

**Update launchd plist** after moving — change WorkingDirectory in `launchd/com.pbrain.sync.plist`:
```xml
<string>/Users/parichay/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault</string>
```

### Option C — Symlink (keeps git submodule path intact)

```bash
ICLOUD_VAULTS=~/Library/Mobile\ Documents/iCloud\~md\~obsidian/Documents
ln -s <pbrain-root>/vault "$ICLOUD_VAULTS/vault"
```

iCloud sees the symlink as a folder and syncs it. The git submodule path stays unchanged. This is the cleanest approach if you want to avoid touching `.gitmodules`.

---

## iOS setup

1. Install **Obsidian** from the App Store (free)
2. Open Obsidian → tap **Open folder as vault**
3. Navigate to iCloud Drive → Obsidian → vault
4. Done — all notes sync automatically

No Working Copy or git needed on iPhone. iCloud handles file sync; git runs on Mac only.

---

## What iCloud syncs

- All `.md` files in vault (including `notion-mirror/` — ~500 files on first sync)
- Obsidian config files (`.obsidian/`)
- The `.gbrain/` directory is gitignored in pbrain but not excluded from iCloud — add it to vault's `.gitignore` if you don't want it syncing (the PGLite database is large)

To exclude `.gbrain/` from iCloud, add to `vault/.gitignore`:
```
.gbrain/
```

---

## Private notes

To keep certain notes off iCloud and off git:

1. Create `vault/private/`
2. Add to `vault/.gitignore`:
   ```
   private/
   ```
3. In Obsidian for iOS: Settings → Sync → Selective Sync → exclude `private/`

Files in `vault/private/` never leave your Mac.

---

## Conflict handling

iCloud uses last-write-wins. If you edit the same file on Mac and iPhone before iCloud syncs, one version wins and the other is saved as a conflict copy (`filename (conflict).md`). Git history on Mac preserves both — check `git log` if you lose content.

To minimize conflicts: let iCloud finish syncing before switching devices (wait for the iCloud icon to stop spinning in Finder).
