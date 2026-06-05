# /discuss

A personal thinking partner for working through dilemmas. Not a brainstorm (that's for professional ideas) — this is for the personal stuff: decisions you're sitting with, tensions you can't shake, things that feel unresolved.

**How it works:** The agent reads your recent journal, gratitude entry, and goals profile silently before engaging — so it already knows where you're at. Then it asks one question at a time, following the thread you give it. No advice unless you ask for it. Ends when you feel resolved. Saves a short note with the insight.

**Default destination:** `$VAULT_DIR/agent-work/notes/`

**Override:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_NOTES_DIR` | Override the notes directory |

**Example:**

```
/discuss "should I move cities or am I just running from something"
/discuss feeling stuck at work but I don't know if it's the job or me
```

If you run the same topic again today, the existing note resumes.
