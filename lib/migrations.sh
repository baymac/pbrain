#!/usr/bin/env bash
# pbrain migration runner — sourced by lib/vault.sh, runs on EVERY command.
#
# Works like a database migration system, but for the vault + config files.
# Each migration is one ordered script in lib/migrations/<NNNN_slug>.sh; the
# applied-set is tracked per vault in a LEDGER of marker files:
#
#   $VAULT_DIR/.pbrain/migrations/<NNNN_slug>.done
#
# Correctness is LEDGER-based, not semver-based: whatever version a user
# upgrades from/to, exactly the unapplied migrations run, in id order, once.
#
# A migration is any ONE-TIME pbrain state transition — not only vault-file
# moves. Three kinds (declared by each script via MIGRATION_KIND):
#
#   auto      — pure data moves (file relocations, format wraps) on the LOCAL
#               vault/config. Applied instantly in bash by this runner and
#               recorded. No LLM, no user, no network.
#   staged    — needs an LLM rebuild with user input (e.g. rebuilding a profile
#               from old data + new interview questions). The runner leaves
#               these PENDING; the OWNING command (MIGRATION_OWNER) checks
#               `pbrain_migration_pending <id>` at startup, drives the rebuild
#               in its session, then records via `migrations.sh record <id>`.
#   effectful — mutates an EXTERNAL / live system (e.g. re-pointing Plane issues
#               onto new states). Like auto it runs in bash with no LLM, but it
#               is NOT applied on the silent hot path: live external writes must
#               never fire as a side effect of running an unrelated command on
#               some other machine. The runner only applies an effectful
#               migration when explicitly opted in (PBRAIN_MIGRATIONS_EFFECTFUL=1
#               in the env, or `migrations.sh run --effectful`); otherwise it is
#               left PENDING (printed as a one-line notice) for an on-demand run.
#               Idempotency is the migration BODY's responsibility (re-running
#               must be safe), because the ledger is per-vault while the effect
#               is per-workspace — a second machine sharing the workspace would
#               otherwise re-apply. Effectful migrations declare an OWNER so a
#               command/skill can surface "pending" the same way staged does.
#
# All kinds are recorded VACUOUSLY (no-op) when there is nothing to migrate
# (fresh user, already-migrated data) — so the hot path on every command run
# is just a glob over marker files: no LLM, no python, no network, near-zero cost.
#
# Migration script contract (each lib/migrations/<id>.sh defines):
#   MIGRATION_KIND=auto|staged|effectful
#   MIGRATION_OWNER="<command>"        # staged/effectful; "" for auto
#   migration_applicable()             # exit 0 iff there is work to do
#   migration_apply()                  # auto + effectful; do it (idempotent)
#
# AUTO migrations must be IDEMPOTENT and NON-DESTRUCTIVE: copy or move WITHIN
# the vault freely, but never delete user data — displaced originals go to
# $VAULT_DIR/.pbrain/backup/. Migrations that read ~/.config/pbrain COPY
# (never move): the ledger is per-vault, so a second vault (or a test vault)
# must be able to run the same migration again without having destroyed the
# source. EFFECTFUL migrations must likewise be idempotent (re-running is a
# no-op) and should degrade gracefully when the external system is unreachable
# (leave themselves unrecorded so a later opted-in run retries).
#
# Env knobs:
#   PBRAIN_MIGRATIONS=0            disable the runner entirely (tests, debugging)
#   PBRAIN_MIGRATIONS_EFFECTFUL=1  opt the silent runner into applying effectful
#                                  migrations too (default: leave them pending)
#   PBRAIN_MIGRATIONS_SRC          override the migration-scripts dir
#   PBRAIN_MIGRATIONS_LEDGER       override the ledger dir
#
# Sourcing this file only defines functions; lib/vault.sh calls
# pbrain_run_migrations once per command. Never exits non-zero.
#
# This file is ALSO directly executable (for Claude to record a staged
# migration after driving its rebuild):
#   bash lib/migrations.sh record <id> | pending <id> | run | list

_PBRAIN_MIG_LIB_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

pbrain_migrations_src_dir() {
  printf '%s\n' "${PBRAIN_MIGRATIONS_SRC:-$_PBRAIN_MIG_LIB_DIR/migrations}"
}

pbrain_migrations_ledger() {
  if [[ -n "${PBRAIN_MIGRATIONS_LEDGER:-}" ]]; then
    printf '%s\n' "$PBRAIN_MIGRATIONS_LEDGER"
  elif [[ -n "${VAULT_DIR:-}" ]]; then
    printf '%s\n' "$VAULT_DIR/.pbrain/migrations"
  fi
  return 0
}

pbrain_migration_done() {
  local id="${1:-}" ledger
  ledger="$(pbrain_migrations_ledger)"
  [[ -n "$id" && -n "$ledger" && -f "$ledger/$id.done" ]]
}

pbrain_migration_record() {
  local id="${1:-}" ledger
  ledger="$(pbrain_migrations_ledger)"
  [[ -n "$id" && -n "$ledger" ]] || return 0
  mkdir -p "$ledger" 2>/dev/null || return 0
  date +%Y-%m-%dT%H:%M:%S > "$ledger/$id.done" 2>/dev/null || true
  return 0
}

# Exit 0 iff <id> is pending: not yet recorded AND its script reports work to
# do. Used by the owning command of a STAGED migration to decide whether to
# drive the rebuild this session. Honours the same kill switch as the runner.
pbrain_migration_pending() {
  local id="${1:-}" src
  [[ "${PBRAIN_MIGRATIONS:-1}" == "0" ]] && return 1
  src="$(pbrain_migrations_src_dir)/$id.sh"
  [[ -n "$id" && -f "$src" ]] || return 1
  pbrain_migration_done "$id" && return 1
  (
    set +e
    MIGRATION_KIND=""
    MIGRATION_OWNER=""
    # shellcheck disable=SC1090
    source "$src" >/dev/null 2>&1 || exit 1
    declare -F migration_applicable >/dev/null || exit 1
    migration_applicable
  )
}

# The preflight: apply every unapplied AUTO migration in id order; record
# vacuous ones (nothing to do); leave applicable STAGED ones pending for their
# owning command; apply EFFECTFUL ones only when opted in (else leave pending
# with a one-line notice). Prints one `PBRAIN_MIGRATED <id>` line per applied
# migration (plus whatever the migration itself echoed). Never exits non-zero.
#
# $1 (optional): "--effectful" forces effectful migrations to apply this run even
# without the env opt-in (used by `migrations.sh run --effectful`).
pbrain_run_migrations() {
  [[ "${PBRAIN_MIGRATIONS:-1}" == "0" ]] && return 0
  [[ -n "${VAULT_DIR:-}" && -d "${VAULT_DIR:-}" ]] || return 0
  local apply_effectful=0
  [[ "${PBRAIN_MIGRATIONS_EFFECTFUL:-0}" == "1" ]] && apply_effectful=1
  [[ "${1:-}" == "--effectful" ]] && apply_effectful=1
  local src_dir f id rc
  src_dir="$(pbrain_migrations_src_dir)"
  [[ -d "$src_dir" ]] || return 0
  for f in "$src_dir"/*.sh; do
    [[ -f "$f" ]] || continue
    id="$(basename "$f" .sh)"
    pbrain_migration_done "$id" && continue
    rc=0
    (
      set +e
      MIGRATION_KIND=auto
      MIGRATION_OWNER=""
      # shellcheck disable=SC1090
      source "$f" >/dev/null 2>&1 || exit 3
      if declare -F migration_applicable >/dev/null && ! migration_applicable; then
        exit 10                      # vacuous — nothing to migrate, record
      fi
      if [[ "$MIGRATION_KIND" == "staged" ]]; then
        exit 11                      # applicable + staged — owner drives it
      fi
      if [[ "$MIGRATION_KIND" == "effectful" && "$apply_effectful" != "1" ]]; then
        exit 12                      # applicable + effectful, not opted in — defer
      fi
      declare -F migration_apply >/dev/null || exit 3
      migration_apply
    ) || rc=$?
    case "$rc" in
      0)
        pbrain_migration_record "$id"
        echo "PBRAIN_MIGRATED $id"
        ;;
      10) pbrain_migration_record "$id" ;;   # vacuous
      11) : ;;                               # staged & pending — not ours
      12)                                    # effectful & deferred — notice, don't record
        echo "PBRAIN_MIGRATION_PENDING $id (effectful — run \`bash lib/migrations.sh run --effectful\` or set PBRAIN_MIGRATIONS_EFFECTFUL=1)"
        ;;
      *)  : ;;                               # failed — unrecorded, retried next run
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# Direct-execution mode: `bash lib/migrations.sh record <id>` etc. Resolves
# the vault WITHOUT sourcing lib/vault.sh (vault.sh runs this runner — that
# would recurse) using the same env → config-file → default order.
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  if [[ -z "${VAULT_DIR:-}" ]]; then
    if [[ -n "${PBRAIN_VAULT:-}" ]]; then
      VAULT_DIR="$PBRAIN_VAULT"
    else
      _cfg="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/vault"
      if [[ -f "$_cfg" ]]; then
        _line="$(head -n1 "$_cfg")"
        _line="${_line#"${_line%%[![:space:]]*}"}"
        _line="${_line%"${_line##*[![:space:]]}"}"
        [[ -n "$_line" ]] && VAULT_DIR="${_line/#\~/$HOME}"
      fi
      VAULT_DIR="${VAULT_DIR:-$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault}"
      unset _cfg _line
    fi
  fi
  # Effectful migrations (e.g. Plane re-points) need the project seams. When run
  # standalone (not sourced via vault.sh), source them here so pbrain_plane_engine
  # / pbrain_plane_configured are available and the engine path resolves.
  : "${PBRAIN_PROJECTS_LIB_DIR:=$_PBRAIN_MIG_LIB_DIR}"
  export PBRAIN_PROJECTS_LIB_DIR
  if ! declare -F pbrain_plane_configured >/dev/null \
       && [[ -f "$_PBRAIN_MIG_LIB_DIR/projects.sh" ]]; then
    # shellcheck disable=SC1090
    source "$_PBRAIN_MIG_LIB_DIR/projects.sh" || true
  fi
  case "${1:-}" in
    record)
      [[ -n "${2:-}" ]] || { echo "usage: migrations.sh record <id>" >&2; exit 2; }
      pbrain_migration_record "$2"
      echo "recorded: $2"
      ;;
    pending)
      [[ -n "${2:-}" ]] || { echo "usage: migrations.sh pending <id>" >&2; exit 2; }
      if pbrain_migration_pending "$2"; then echo "pending"; else echo "not-pending"; fi
      ;;
    run)
      # `run` applies auto migrations (and records vacuous/staged as usual);
      # `run --effectful` additionally applies effectful migrations this run.
      pbrain_run_migrations "${2:-}"
      ;;
    list)
      _ledger="$(pbrain_migrations_ledger)"
      for _f in "$(pbrain_migrations_src_dir)"/*.sh; do
        [[ -f "$_f" ]] || continue
        _id="$(basename "$_f" .sh)"
        if [[ -n "$_ledger" && -f "$_ledger/$_id.done" ]]; then
          echo "done    $_id"
        else
          echo "todo    $_id"
        fi
      done
      ;;
    *)
      echo "usage: migrations.sh record|pending|run|list [<id>]" >&2
      exit 2
      ;;
  esac
fi
