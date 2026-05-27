# /brainstorm

Start a brainstorming session. The topic becomes a slugified filename. Lifecycle dirs are `tbd/` (active), `backlog/` (parked), `done/` (actioned).

**How the conversation runs:** brainstorm is a fast idea dump, not a working session. You pitch, the agent explodes the pitch — surfaces what's underneath, opines on signal vs noise, names opportunities you may have missed, lists open questions, and points at directions/actionables. It does **not** try to solve the problem; it validates or invalidates the idea. For deeper exploration use `/office-hours`; for scope or strategy use `/plan-ceo-review`.

**Default destination:** `$VAULT_DIR/agent-work/brainstorms/{tbd,backlog,done}`

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_BRAINSTORMS_DIR` | Brainstorms parent dir (tbd/backlog/done are subdirs of this) |

**Example:**

```bash
/brainstorm "should i open source X"
/brainstorm landing-page-rewrite
```

If a brainstorm with the same slug already exists in any of the three lifecycle dirs (`tbd/`, `backlog/`, `done/`), the command prints that path and exits instead of overwriting — open it to continue.

Run it to see the template.
