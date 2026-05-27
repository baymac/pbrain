# /journal

Create or open today's daily journal entry.

If today's file already exists, prints its path (does not overwrite).

**Default destination:** `$VAULT_DIR/life/daily-tracking/YYYY-MM-DD.md`

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root (default: iCloud Obsidian path) |
| `PBRAIN_JOURNAL_DIR` | Full path to journal dir (overrides default subpath) |

**Example:**

```bash
# Use a different vault
PBRAIN_VAULT=~/notes /journal

# Write to a completely different location
PBRAIN_JOURNAL_DIR=~/work/standup /journal
```

Run it to see the template.
