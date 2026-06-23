#!/usr/bin/env bash
# Shared helper for pbrain commands. Source this from each command .sh.
#
# Exports:
#   VAULT_DIR  — resolved vault root.
#
# Resolution order:
#   1. $PBRAIN_VAULT env var (highest priority)
#   2. $XDG_CONFIG_HOME/pbrain/vault   (or ~/.config/pbrain/vault) — file containing just the path
#   3. Default: ~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault
#   4. Zero-config fallback: if NONE of the above is set (no $PBRAIN_VAULT, no
#      config file) and the default iCloud path doesn't exist, auto-create a
#      plain local vault at ~/pbrain-vault (scaffold + config file) and keep
#      going — so pbrain runs on a fresh machine without Obsidian/iCloud and
#      without ever running /init-obsidian. Set PBRAIN_NO_AUTOVAULT=1 to opt
#      back into the old hard-fail. Only the unset (default) case auto-creates;
#      an explicit env/config path that's missing still errors.
#
# Per-command subpath overrides are handled inside each command via its own
# PBRAIN_<COMMAND>_DIR env var (see each command's docs).
#
# Set the vault once for all commands:
#   echo "/path/to/my/vault" > ~/.config/pbrain/vault
# Or per-invocation:
#   PBRAIN_VAULT=/tmp/test-vault /journal

_PBRAIN_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/vault"

_pbrain_resolve_vault() {
  # Sets VAULT_DIR and _PBRAIN_VAULT_SOURCE in the caller's scope.
  if [[ -n "${PBRAIN_VAULT:-}" ]]; then
    _PBRAIN_VAULT_SOURCE=env
    VAULT_DIR="$PBRAIN_VAULT"
    return
  fi

  if [[ -f "$_PBRAIN_CONFIG_FILE" ]]; then
    local from_file
    from_file="$(head -n1 "$_PBRAIN_CONFIG_FILE")"
    # Trim leading and trailing whitespace without touching internal spaces
    # (paths like ".../Mobile Documents/..." have valid internal spaces).
    from_file="${from_file#"${from_file%%[![:space:]]*}"}"
    from_file="${from_file%"${from_file##*[![:space:]]}"}"
    if [[ -n "$from_file" ]]; then
      _PBRAIN_VAULT_SOURCE=config
      # Expand leading ~ if present
      VAULT_DIR="${from_file/#\~/$HOME}"
      return
    fi
  fi

  _PBRAIN_VAULT_SOURCE=default
  VAULT_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault"
}

_pbrain_resolve_vault

# Shared vault-scaffold helpers — needed for the zero-config auto-fallback in the
# default missing-vault case below. Sourced before the existence check so
# pbrain_scaffold_vault / pbrain_write_vault_config are in scope here.
_PBRAIN_SCAFFOLD_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ -f "$_PBRAIN_SCAFFOLD_DIR/scaffold.sh" ]] && source "$_PBRAIN_SCAFFOLD_DIR/scaffold.sh" || true
unset _PBRAIN_SCAFFOLD_DIR

if [[ ! -d "$VAULT_DIR" ]]; then
  # Zero-config fallback: only the unset (default) case auto-creates a vault.
  # An explicit env/config path that's missing still errors — silently creating
  # a vault elsewhere would mask a typo. PBRAIN_NO_AUTOVAULT=1 disables the
  # fallback so power users / tests get the old hard-fail back.
  if [[ "$_PBRAIN_VAULT_SOURCE" == "default" && "${PBRAIN_NO_AUTOVAULT:-0}" != "1" ]] \
     && declare -F pbrain_scaffold_vault >/dev/null; then
    VAULT_DIR="$HOME/pbrain-vault"
    echo "pbrain: no vault configured — creating a local vault at $VAULT_DIR." >&2
    echo "        Run /init-obsidian to switch to an Obsidian/iCloud vault." >&2
    pbrain_scaffold_vault "$VAULT_DIR" >&2
    pbrain_write_vault_config "$VAULT_DIR" >&2
    # Fall through (no exit): the rest of this file runs against the new vault.
  else
    case "$_PBRAIN_VAULT_SOURCE" in
      env)
        echo "pbrain: PBRAIN_VAULT points to a directory that doesn't exist:" >&2
        echo "        $VAULT_DIR" >&2
        echo "        Either fix PBRAIN_VAULT, create the directory, or run /init-obsidian to set up a vault." >&2
        ;;
      config)
        echo "pbrain: vault path in $_PBRAIN_CONFIG_FILE no longer exists:" >&2
        echo "        $VAULT_DIR" >&2
        echo "        Re-run /init-obsidian to point pbrain at a vault that exists, or edit the config file directly." >&2
        ;;
      default)
        echo "pbrain: no vault is set up yet." >&2
        echo "        Run /init-obsidian to bootstrap one (interactive: Obsidian checks, vault creation," >&2
        echo "        optional iCloud + private dir + git remote, writes ~/.config/pbrain/vault)." >&2
        echo "        Or set PBRAIN_VAULT / write a path to $_PBRAIN_CONFIG_FILE manually." >&2
        ;;
    esac
    exit 1
  fi
fi

export VAULT_DIR

# Define the per-command preference + self-improvement helpers so every command
# that sources this file can call them. Sourcing only DEFINES the functions
# (pbrain_emit_prefs, pbrain_emit_self_improve_batch); nothing is emitted until a
# command calls them with its own name. Guarded so a missing/faulty helper file
# can never take a command down.
_PBRAIN_LIB_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ -f "$_PBRAIN_LIB_DIR/prefs.sh" ]] && source "$_PBRAIN_LIB_DIR/prefs.sh" || true
[[ -f "$_PBRAIN_LIB_DIR/self-improve.sh" ]] && source "$_PBRAIN_LIB_DIR/self-improve.sh" || true
[[ -f "$_PBRAIN_LIB_DIR/profile.sh" ]] && source "$_PBRAIN_LIB_DIR/profile.sh" || true
# Versioned profile store (.profile dirs) + the vault migration runner. The
# runner itself is CALLED at the bottom of this file, after every lib is in
# scope, so migrations may use any helper.
[[ -f "$_PBRAIN_LIB_DIR/profiles.sh" ]] && source "$_PBRAIN_LIB_DIR/profiles.sh" || true
# Plane seam helpers (lib/plane.py engine). Sourced after profiles so the daily
# loop (/plan-my-work, /plan-my-day, /end-of-day, reviews) shares one backend.
[[ -f "$_PBRAIN_LIB_DIR/projects.sh" ]] && source "$_PBRAIN_LIB_DIR/projects.sh" || true
[[ -f "$_PBRAIN_LIB_DIR/migrations.sh" ]] && source "$_PBRAIN_LIB_DIR/migrations.sh" || true
# Shared SQLite store + the habits / reminders helpers built on it. Order
# matters: db.sh first (defines PBRAIN_DB_FILE), then habits.sh (needs
# pbrain_profile_json from profile.sh and the DB) and reminders.sh. launchd.sh
# (shared swiftc-build + LaunchAgent helpers) is sourced before reminders.sh,
# which calls pbrain_swift_build.
[[ -f "$_PBRAIN_LIB_DIR/db.sh" ]] && source "$_PBRAIN_LIB_DIR/db.sh" || true
[[ -f "$_PBRAIN_LIB_DIR/launchd.sh" ]] && source "$_PBRAIN_LIB_DIR/launchd.sh" || true
[[ -f "$_PBRAIN_LIB_DIR/habits.sh" ]] && source "$_PBRAIN_LIB_DIR/habits.sh" || true
[[ -f "$_PBRAIN_LIB_DIR/reminders.sh" ]] && source "$_PBRAIN_LIB_DIR/reminders.sh" || true
unset _PBRAIN_LIB_DIR

# Migration preflight: apply any unapplied AUTO migrations (file moves into
# the new vault layout) and record them in the per-vault ledger; STAGED
# migrations are left pending for their owning command. Ledger-gated, so the
# steady-state cost is a glob over marker files. PBRAIN_MIGRATIONS=0 disables.
declare -F pbrain_run_migrations >/dev/null && pbrain_run_migrations || true

# Best-effort version check. Prints `UPGRADE_AVAILABLE <old> <new>` to stdout
# when a newer pbrain is on GitHub; silent otherwise. Cached. Never fatal.
# shellcheck source=./update-check.sh
_PBRAIN_UPDATE_CHECK_SCRIPT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/update-check.sh"
[[ -f "$_PBRAIN_UPDATE_CHECK_SCRIPT" ]] && source "$_PBRAIN_UPDATE_CHECK_SCRIPT" || true
unset _PBRAIN_UPDATE_CHECK_SCRIPT
