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
# Two kinds of migration (declared by each script via MIGRATION_KIND):
#
#   auto    — pure data moves (file relocations, format wraps). Applied
#             instantly in bash by this runner and recorded. No LLM, no user.
#   staged  — needs an LLM rebuild with user input (e.g. rebuilding a profile
#             from old data + new interview questions). The runner leaves these
#             PENDING; the OWNING command (MIGRATION_OWNER) checks
#             `pbrain_migration_pending <id>` at startup, drives the rebuild in
#             its session, then records via `migrations.sh record <id>`.
#
# Both kinds are recorded VACUOUSLY (no-op) when there is nothing to migrate
# (fresh user, already-migrated data) — so the hot path on every command run
# is just a glob over marker files: no LLM, no python, near-zero cost.
#
# Migration script contract (each lib/migrations/<id>.sh defines):
#   MIGRATION_KIND=auto|staged
#   MIGRATION_OWNER="<command>"        # staged only; "" for auto
#   migration_applicable()             # exit 0 iff there is work to do
#   migration_apply()                  # auto only; do the move (idempotent)
#
# AUTO migrations must be IDEMPOTENT and NON-DESTRUCTIVE: copy or move WITHIN
# the vault freely, but never delete user data — displaced originals go to
# $VAULT_DIR/.pbrain/backup/. Migrations that read ~/.config/pbrain COPY
# (never move): the ledger is per-vault, so a second vault (or a test vault)
# must be able to run the same migration again without having destroyed the
# source.
#
# Env knobs:
#   PBRAIN_MIGRATIONS=0          disable the runner entirely (tests, debugging)
#   PBRAIN_MIGRATIONS_SRC        override the migration-scripts dir
#   PBRAIN_MIGRATIONS_LEDGER     override the ledger dir
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
# owning command. Prints one `PBRAIN_MIGRATED <id>` line per applied migration
# (plus whatever the migration itself echoed). Never exits non-zero.
pbrain_run_migrations() {
  [[ "${PBRAIN_MIGRATIONS:-1}" == "0" ]] && return 0
  [[ -n "${VAULT_DIR:-}" && -d "${VAULT_DIR:-}" ]] || return 0
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
      pbrain_run_migrations
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
