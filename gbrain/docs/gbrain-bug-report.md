# gbrain bug report — `gbrain sync` hangs indefinitely after 89→92 schema migration

**Filed:** ready to send to upstream (Garry Tan / gbrain repo)
**Version:** `gbrain 0.40.8.0`
**Install:** bun-link from `~/code/gbrain`
**Engine:** PGLite (`~/.gbrain/brain.pglite`)
**Embed model:** `ollama:nomic-embed-text` (768d)
**Host:** macOS 15.5 (Darwin 24.5.0), Apple Silicon

---

## Summary

`gbrain sync` (and even `gbrain sync --dry-run --no-pull`) hangs indefinitely producing zero output. CPU pegged at ~99% in a JS execution loop. SIGTERM kills it cleanly but leaves a stale advisory lock at `~/.gbrain/brain.pglite/.gbrain-lock/lock` pointing to the dead PID. Subsequent gbrain invocations block on this stale lock.

The hang appeared immediately after a `gbrain call sync_brain '{...}'` invocation applied three pending migrations (`89 → 92`: `contextual_retrieval_columns`, `pages_generation_trigger_and_bookmark`, `sources_github_repo_index`).

---

## Repro

```bash
# State: brain at schema v92, no gbrain serve running, no stale lock files,
# clean ~/.gbrain/brain.pglite/.gbrain-lock/ directory.

cd /path/to/vault    # vault is on iCloud Drive, but issue reproduces regardless
gtimeout 30 gbrain sync --repo . --skip-failed --dry-run --no-pull
# exit 124 (gtimeout SIGTERM), zero output during the 30s

ls ~/.gbrain/brain.pglite/.gbrain-lock/lock
# {"pid":<dead-pid>,"acquired_at":<ms>,"command":"... sync ..."}
```

After SIGTERM, the lock file persists. Next `gbrain sync` reads the lock, observes "owner PID dead," and... still hangs.

## What works

- `gbrain --version` — instant
- `gbrain check-update --json` — instant (network call, returns `error: no_releases`)
- `gbrain doctor --fast --json` — instant (skips DB checks)
- `gbrain stats` — works in isolation when serve is also running (proxy path), but hangs the same way as sync when no serve is up
- `gbrain call sync_brain '{...}'` while `gbrain serve` is running — ~3s, returns clean JSON. Used as a workaround.
- `gbrain call sync_brain '{...}'` with NO serve running — hangs (same failure mode as `gbrain sync`)

## What was tried (did not fix)

- Multi-source drift cleanup: removed the empty `vault` source, leaving only `default` with 439 pages. Doctor reported drift fixed, health 55→80. Sync still hangs.
- Deleted stale `.gbrain-lock/lock` file. Fresh `gbrain sync` still hangs and recreates the stale lock on SIGTERM.
- Reproduced with `--dry-run --no-pull` (no git ops, no writes) — still hangs. The hang is not in git pull, embedding, or writes.

## Stack at hang time

`sample <pid> 1` shows pure JS execution in JIT-compiled regions (no kernel calls, no I/O wait). Tight loop in `bun` runtime. ~290 MB RSS, ~99% CPU.

## Timeline

- Healthy syncs (4-7 sec each, "Already up to date") on 30-min launchd cadence for hours.
- At UTC 10:31 something flipped — sync ran 1 hour before SIGTERM.
- Next sync ran 3 hours before SIGTERM.
- Old DB renamed to `brain.pglite.broken-20260523-120636` at 12:06 UTC (suggests an attempted recovery).
- After a `gbrain call sync_brain` run applied migrations 89→92, the sync CLI began hanging deterministically.

## Files / config

```json
// ~/.gbrain/config.json
{
  "engine": "pglite",
  "database_path": "<HOME>/.gbrain/brain.pglite",
  "embedding_model": "ollama:nomic-embed-text",
  "embedding_dimensions": 768
}
```

```
~/.gbrain/sync-failures.jsonl  — 2 acknowledged failures (file too large for embed context, non-blocking)
~/.gbrain/import-checkpoint.json — 17 KB, tracks completedPaths
~/.gbrain/brain.pglite/         — schema v92, 439 pages, 1 source ("default")
```

---

## Workaround currently in use

`gbrain/scripts/gbrain-sync-wrapper.sh` calls `gbrain call sync_brain '{"repo":"<vault>"}'` instead of `gbrain sync`. Works in ~3s while `gbrain serve` is up (Claude open). When Claude is closed, `gbrain call` hangs the same way as `gbrain sync`, so the launchd job has been **unloaded** until a fix lands.

In degraded mode the brain is fresh while Claude is open (MCP writes go through serve in-process). Vault edits made outside Claude (Obsidian on phone, Obsidian on Mac while Claude is closed) accumulate and are picked up the next time the user manually triggers a sync via Claude's MCP `sync_brain` tool.
