# /recall

Grep-based recall across the vault. Surfaces every markdown file that mentions a topic, plus 2 lines of context around each hit, then the agent synthesizes what you've actually written about that topic over time.

This is the lightweight stand-in for gbrain's vector search. Embeddings are great, but most of the time the question is "where did I write about X" — and case-insensitive grep across the narrative folders answers that in milliseconds without the infra. Use this even after gbrain comes back online for fast literal lookups.

**Default scope:** `life/`, `agent-work/`, `startup/`, `side-quests/`, `software-dev/`, `notes/` (each, if present under `$VAULT_DIR`). Deliberately skips `Clippings/` (third-party content) and `fitness/daily-tracking/` (mostly numeric logs).

**Behavior:** uses `rg` if available, falls back to `grep -r`. Markdown files only. Case-insensitive. Two lines of context above and below each match.

**Default destination:** none — `/recall` is read-only.

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_RECALL_SCOPE` | Space-separated list of subdirs (relative to vault) to search. Missing subdirs are skipped with a warning. |

**Examples:**

```bash
/recall "fasting"
/recall "deep work"
/recall startup-name-ideas
PBRAIN_RECALL_SCOPE="life agent-work" /recall "rejection"
```

The agent groups matches by source (gratitude vs daily journal vs brainstorm), quotes you back to yourself, and lands on a one-line takeaway. It will not solve, plan, or advise — recall only.

If a query is a single common word (`work`, `today`), the agent warns about noise and suggests a more specific phrase.
