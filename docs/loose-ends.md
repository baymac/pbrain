# /loose-ends

Surfaces the open loops scattered across your vault and flags what's gone stale. pbrain *generates* a lot of "unresolved thread" data — brainstorms you started, open questions you logged, todos you checked off (or didn't), tomorrow-seeds you keep deferring, focus areas you set — but nothing reflects it back at you. `/loose-ends` is that reflection: a read-only dashboard that aggregates the threads and lands on one thing to pick up first.

It writes nothing. Re-run it as often as you like — it's idempotent and safe.

**Five signals it gathers:**

| Signal | Source | Flag |
|---|---|---|
| Stale ideas | `agent-work/brainstorms/tbd/*.md` | older than the stale threshold (default 7d) |
| Unanswered questions | `## Open questions` in recent journals (empty/`—` answer) + open-question bullets in `tbd/` brainstorms | — |
| Open todos | unchecked `- [ ]` boxes in recent daily plans | — |
| Recurring tomorrow-seeds | `### Tomorrow seed` bullets repeated across plans | deferred ≥ 2 days |
| Focus drift | work + life goals from the goals profile | quiet ≥ stale threshold |

**Default destination:** none — `/loose-ends` is read-only.

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_STALE_DAYS` | Age (days) at which an item counts as stale. Default `7`. |
| `PBRAIN_LOOSE_ENDS_LOOKBACK` | How far back (days) to scan recent journals/plans. Default `30`. |
| `PBRAIN_JOURNAL_DIR` | Daily journals (open questions). Default `$VAULT/life/daily-tracking`. |
| `PBRAIN_BRAINSTORMS_DIR` | Brainstorms parent (`tbd/` is the active bucket). Default `$VAULT/agent-work/brainstorms`. |
| `PBRAIN_PLAN_DIR` | Daily plans (todos + tomorrow-seeds). Default `$VAULT/life/daily-planning`. |
| `PBRAIN_PLAN_PROFILE_FILE` | Goals profile JSON (focus drift). Default `~/.config/pbrain/plan-profile.json`. |

**Examples:**

```bash
/loose-ends
PBRAIN_STALE_DAYS=14 /loose-ends      # only flag things idle for 2+ weeks
PBRAIN_LOOSE_ENDS_LOOKBACK=60 /loose-ends   # scan two months of journals/plans
```

The agent groups what it finds oldest-first, quotes you back to yourself, cites the source file for each loop, and ends on a single "what I'd pick up first." It may *offer* to act on a loop (move a stale idea to `backlog/`, start a `/brainstorm`, draft an answer) — but it never writes without an explicit yes.

Empty subdirs, a missing `plan-profile.json`, or a malformed profile all degrade gracefully — that section just reports `(none)` and the rest of the scan continues.
