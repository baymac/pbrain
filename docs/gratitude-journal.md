# /gratitude-journal

Daily gratitude journal — two prompts: a gratitude list and a themed reflection question generated fresh per session (12 themes rotating, with dedup against the last 30 entries).

Runs **after `/journal`** in the morning sequence. The raw brain dump (including how you're feeling) lands in the journal first, which clears the head; gratitude then grounds you on cleared ground. That's why there's no "how are you feeling" prompt here anymore — the mood is already captured next door.

Opens with a short **timing nudge**: a one-line affirmation if run before noon, or a stronger encouragement to do it first thing tomorrow if run after noon. Gratitude lands hardest early in the day — it anchors your baseline to *enough*, so the rest of the day runs on overflow instead of comparison. The nudge never blocks; it just sets context, then the prompts continue.

**Default destination:** `$VAULT_DIR/life/gratitude-journal/YYYY-MM-DD.md`

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_GRATITUDE_DIR` | Where today's entry is written |

**Example:**

```bash
/gratitude-journal
```

If today's entry already exists, it's shown and the command exits.

Run it to see the prompts.
