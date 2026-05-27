# /organize-clippings

Walk through every clipping and move each into one of your top-level vault folders (or any subpath underneath). Renames the file when the current name is messy or generic (typical Obsidian Web Clipper output).

Decision policy: high confidence → just announces and moves; close call → presents 2–3 options and asks you to pick.

**Default source:** `$VAULT_DIR/Clippings/`

**Destinations are discovered dynamically.** At the start of the session you pick which top-level vault dirs to file into:

- Reply `all` for everything (still excludes `agent-work/` and `Clippings/` itself).
- Or give a comma-separated subset, e.g. `life, notes, software-dev`.

The agent infers categorization from the dir names and the sample files/subdirs it sees inside them — no hardcoded rules. Subpaths underneath are unrestricted, so a clipping can land in `side-quests/dj/sets/` or `notes/books/non-fiction/` if the content warrants it.

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root (also determines destination candidates) |
| `PBRAIN_CLIPPINGS_DIR` | Where the script reads clippings from |
| `PBRAIN_CLIPPINGS_TARGETS` | Pre-set the destination subset (e.g. `life,notes` or `all`) to skip the interactive prompt |

**Example:**

```bash
/organize-clippings

# or, skip the destination question:
PBRAIN_CLIPPINGS_TARGETS=all /organize-clippings
PBRAIN_CLIPPINGS_TARGETS="notes,software-dev,side-quests" /organize-clippings
```

Run it to walk through your inbox.
