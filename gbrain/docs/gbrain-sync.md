# gbrain sync — architecture, lock model, upgrade path

How `gbrain/scripts/gbrain-sync-wrapper.sh` works, why it's shaped this way, and when to consider switching gbrain from PGLite to Postgres / Supabase.

---

## ⚠️ Current state: DEGRADED MODE (launchd disabled)

As of 2026-05-24, the scheduled launchd sync is **unloaded**. `gbrain sync` (and the `gbrain call sync_brain` proxy when no serve is running) hangs indefinitely after a `89 → 92` schema migration. See `gbrain/docs/gbrain-bug-report.md` for the full repro to send upstream.

**While degraded:**
- The brain stays fresh as long as Claude is open (gbrain MCP writes go directly through the running serve).
- Vault edits made outside Claude (Obsidian on phone, Obsidian on Mac with Claude closed) won't enter the brain automatically.
- To pull them in, open Claude and ask it to run the `sync_brain` MCP tool, or invoke it manually with `gbrain call sync_brain '{"repo":"<vault>"}'` *while gbrain serve is running*.

**To restore normal scheduled sync once upstream fixes the bug:**
```bash
launchctl load ~/Library/LaunchAgents/com.pbrain.sync.plist
```

The wrapper script is intact and ready — no changes needed on the user side once the gbrain hang is fixed.

---

## The PGLite lock model (why this is non-obvious)

gbrain ships with **PGLite** by default — an embedded Postgres build that runs *in-process* inside whatever Node/Bun process loads it. There is no separate database daemon. PGLite places an OS file lock on `~/.gbrain/brain.pglite/` so only **one process at a time** can open the data directory.

When Claude Code is running, it launches `gbrain serve` as its MCP server. That process opens the brain and **holds the lock for its entire lifetime** — minutes, hours, or however long Claude is open.

This becomes a problem when *another* gbrain process tries to open the same directory:

| Command | While `gbrain serve` is running |
|---|---|
| `gbrain sync` (CLI) | ❌ Hangs forever waiting for the lock |
| `gbrain upgrade` (runs migrations) | ❌ Hangs |
| `gbrain import <dir>` | ❌ Hangs |
| `gbrain migrate --to ...` | ❌ Hangs |
| `gbrain call <tool> '<json>'` | ✅ Safe — proxies via stdio MCP to the running serve |
| Any MCP tool from Claude (search, query, sync_brain, ...) | ✅ Safe — runs in-process inside serve |
| `gbrain doctor`, `search`, `query` (read-mostly) | ✅ Mostly safe |

**Rule of thumb:** if a gbrain command writes to the DB, it must either go through `gbrain call` (proxy via serve) or run while serve is down.

---

## What the wrapper does

`gbrain/scripts/gbrain-sync-wrapper.sh` is invoked by the launchd job `~/Library/LaunchAgents/com.pbrain.sync.plist` every 30 minutes (`StartInterval=1800`).

Sequence per run:

1. **Lockfile guard** — if a previous wrapper run is still alive (PID check), skip and log.
2. **Vault dir check** — fail fast if the iCloud-backed vault isn't mounted.
3. **Upgrade strategy** (non-fatal):
   - `gbrain serve` UP → pre-stage only: `git pull` on `~/code/gbrain` source clone. New binary takes effect at next Claude restart. Schema migrations apply automatically through MCP usage.
   - `gbrain serve` DOWN → full upgrade: `gbrain check-update && gbrain upgrade` (pulls + bun install + migrations).
4. **Sync** — `gbrain call sync_brain '{"repo":"<vault>"}'`. Proxies through serve, no lock conflict. Works whether or not Claude is open.
5. **Log** — append a JSON line to `.logs/sync-runs.jsonl` with timing, exit code, and a short note (`up_to_date +N ~N -N RN` or error tail).

---

## Why we don't use `gbrain sync` (CLI) directly

The original wrapper called `gbrain sync --repo . --skip-failed`. This worked when Claude wasn't running but hung indefinitely whenever Claude (and its MCP-spawned `gbrain serve`) was up.

`gbrain call sync_brain` is the documented IPC bridge: it sends a JSON-RPC call over stdio to the running serve, which executes the same `sync_brain` MCP tool in-process. Since serve already holds the lock, there's no contention.

The upgrade step is split for the same reason — see the wrapper header comment for the full rationale.

---

## Migration limits and failure modes

The current setup handles the common case cleanly but has known limits:

| Scenario | Behavior |
|---|---|
| `gbrain serve` dies mid-call | Wrapper exits with error (clean fail, no hang). Next launchd fire retries. |
| Two `gbrain serve` instances (e.g. two Claude sessions) | Second one fails to start — can't acquire lock. That session loses MCP gbrain access until the first quits. |
| User runs `gbrain sync` directly from terminal while Claude is open | Hangs. Use `gbrain call sync_brain '{}'` instead. |
| User runs `gbrain upgrade` directly while Claude is open | Hangs on migration lock. Quit Claude first, or just let the wrapper handle upgrades. |
| Large file exceeds embedding context | Logged in `~/.gbrain/sync-failures.jsonl`. Doesn't block sync. Acknowledge with `gbrain sync --skip-failed` once. |

---

## When to upgrade to Postgres or Supabase

The PGLite single-writer constraint is the root limitation. Migrating gbrain to a real Postgres backend removes it entirely — Postgres is a server, multiple clients connect simultaneously via TCP/socket, MVCC serializes only the actual conflicting row writes.

**Consider migrating when any of these become true:**

- You want to run gbrain across **multiple machines** (laptop + desktop + phone) all writing to the same brain.
- You run **multiple Claude sessions in parallel** that all need MCP gbrain access (currently only one session gets it; the rest fail to start serve).
- You need **heavy concurrent batch jobs** (large imports, parallel embedding workers) while Claude is open.
- You want **scheduled syncs** to run reliably during foreground use without relying on the `gbrain call` proxy path.

**Cost / benefit:**

| Concern | PGLite (today) | Local Postgres (brew) | Supabase (managed) |
|---|---|---|---|
| Concurrent writers | ❌ single | ✅ many | ✅ many |
| Setup cost | none | install + daemon + config | account + project setup |
| Backups | copy a dir | `pg_dump` cron | managed |
| Offline use | ✅ always | ✅ always | ❌ requires network |
| Encryption at rest | filesystem | manual | managed |
| Failure modes | lock conflicts (fixed by `gbrain call`) | daemon crashes, port conflicts, disk full | network outages, auth, quotas |

**For solo / single-machine use the current setup is fine** — the `gbrain call` proxy + 30-minute wrapper covers the realistic workload. Don't migrate just for theoretical concurrency.

**To migrate when ready:**

```bash
# Quit Claude first (release the PGLite lock)
gbrain migrate --to supabase    # or --to <postgres-url>
```

This is a one-way operation. Run with a backup of `~/.gbrain/brain.pglite/`.

---

## Files

- `gbrain/scripts/gbrain-sync-wrapper.sh` — the wrapper
- `~/Library/LaunchAgents/com.pbrain.sync.plist` — launchd job, 30 min interval
- `~/Library/Logs/pbrain/sync.{log,error.log}` — stdout/stderr from runs
- `.logs/sync-runs.jsonl` — structured per-run log (start, duration, exit, note)
- `~/.gbrain/brain.pglite/` — the brain (data directory)
- `~/.gbrain/config.json` — engine + embed model config
- `~/.gbrain/sync-failures.jsonl` — files that failed to embed (e.g. oversized)
- `~/code/gbrain/` — gbrain source clone (used by `gbrain upgrade` / pre-stage)
