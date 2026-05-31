# tests

Bats tests for the shared `lib/` helpers that ride along on every command.

These cover the highest-blast-radius code in the repo: `lib/prefs.sh` and
`lib/self-improve.sh` are sourced by `lib/vault.sh` into all 12 commands, so a
fault there (especially a non-zero exit under `set -euo pipefail`) would break
every command at once. The suite pins the mode-resolution matrix and the
never-fatal guard.

## Running

```bash
# macOS
brew install bats-core

# then, from the repo root:
bats tests/
```

## Scope

- `prefs.bats` — `pbrain_emit_prefs`: silent on missing/empty/whitespace files,
  emits a labelled block when content exists, honours `PBRAIN_PREFS_DIR`.
- `self-improve.bats` — `pbrain_emit_self_improve`: `off`/`prefs`/`dev` mode
  resolution, the `dev`-without-`PBRAIN_DEV_DIR` fallback, dev-repo git-state
  warnings (dirty tree / `main` branch), unknown-value fail-safe, and the
  "never exits non-zero" guard.

The prompt-behaviour half of the self-improve loop (when it fires, how it
consolidates, the dev diff+confirm flow) is agent behaviour, not shell logic,
and is validated manually rather than here.
