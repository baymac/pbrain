# /thoughts

Capture and expand a passing thought any time during the day. Claude surfaces what's underneath — the pattern, the implication, the question worth sitting with — then logs the expanded entry with a timestamp.

Optional. Some days have no thoughts; that's fine.

**Default destination:** `$VAULT_DIR/life/thought-tracking/YYYY-MM-DD.md`

**Format per entry:**

```
---

**14:32** — noticed I keep deferring auth refactor when energy is low
→ pattern: high-energy slots filling up with lighter tasks
→ auth refactor needs clear head, not a grind session — protect 9–11am
```

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root (default: iCloud Obsidian path) |
| `PBRAIN_THOUGHTS_DIR` | Full path to thoughts dir (overrides default subpath) |

**Examples:**

```
/thoughts noticed I keep deferring the auth refactor when energy is low
/thoughts what if onboarding started with the use-case picker instead?
/thoughts                   ← Claude asks what's on your mind
```

Entries land in `life/thought-tracking/` and are searchable via `/recall`.
