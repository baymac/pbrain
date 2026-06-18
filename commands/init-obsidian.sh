#!/usr/bin/env bash
# init-obsidian.sh — pbrain setup wizard backend.
#
# This script is dispatched by /init-obsidian (init-obsidian.md). Each subcommand is idempotent;
# re-running on an already-configured machine is safe.
#
# Subcommands:
#   probe                       Print machine state for the wizard. Default.
#   bootstrap <path>            Create + scaffold a vault at <path>. Writes
#                               ~/.config/pbrain/vault.
#   migrate <from> <to>         Copy an existing vault to <to> (typically iCloud).
#                               Verifies file count; never deletes source.
#   setup-private <vault>       Create <vault>/private.nosync/ + README, ensure
#                               .gitignore covers it. (For iCloud vaults.)
#   write-config <path>         Write <path> to ~/.config/pbrain/vault.
#   setup-git <vault> <url>     Add (or update) git remote 'origin' on the vault
#                               and push the current branch. Vault must already
#                               be a git repo (bootstrap handles that).
#
# All <path> args accept leading ~ and tilde expansion.
set -euo pipefail

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
REPO_ROOT="$(cd -P -- "$_SCRIPT_DIR/.." && pwd -P)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain"
CONFIG_FILE="$CONFIG_DIR/vault"
ICLOUD_OBSIDIAN_BASE="$HOME/Library/Mobile Documents/iCloud~md~obsidian"
ICLOUD_DEFAULT_VAULT="$ICLOUD_OBSIDIAN_BASE/Documents/vault"

# Shared vault-scaffold helpers (pbrain_scaffold_vault, pbrain_write_vault_config).
# Sourced standalone — scaffold.sh has no lib/vault.sh dependency, so it's safe
# here in this deliberately pre-vault command.
source "$_SCRIPT_DIR/../lib/scaffold.sh"

_expand_tilde() {
  local p="$1"
  printf '%s\n' "${p/#\~/$HOME}"
}

_usage() {
  sed -n '/^# Subcommands:/,/^# All <path>/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cmd="${1:-probe}"

case "$cmd" in
  probe)
    echo "PBRAIN_INIT_PROBE"
    echo "REPO_ROOT=$REPO_ROOT"
    echo "CONFIG_FILE=$CONFIG_FILE"

    if [[ -d /Applications/Obsidian.app ]]; then
      echo "OBSIDIAN_APP_INSTALLED=yes"
    else
      echo "OBSIDIAN_APP_INSTALLED=no"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
      echo "PBRAIN_CONFIG_EXISTS=yes"
      cfg_vault="$(head -n1 "$CONFIG_FILE")"
      cfg_vault="${cfg_vault#"${cfg_vault%%[![:space:]]*}"}"
      cfg_vault="${cfg_vault%"${cfg_vault##*[![:space:]]}"}"
      cfg_vault="$(_expand_tilde "$cfg_vault")"
      echo "PBRAIN_CONFIG_VAULT=$cfg_vault"
      if [[ -d "$cfg_vault" ]]; then
        echo "PBRAIN_CONFIG_VAULT_EXISTS=yes"
      else
        echo "PBRAIN_CONFIG_VAULT_EXISTS=no"
      fi
    else
      echo "PBRAIN_CONFIG_EXISTS=no"
    fi

    if [[ -d "$ICLOUD_OBSIDIAN_BASE" ]]; then
      echo "ICLOUD_OBSIDIAN_CONTAINER=yes"
    else
      echo "ICLOUD_OBSIDIAN_CONTAINER=no"
    fi
    echo "ICLOUD_DEFAULT_VAULT_PATH=$ICLOUD_DEFAULT_VAULT"
    if [[ -d "$ICLOUD_DEFAULT_VAULT" ]]; then
      echo "ICLOUD_DEFAULT_VAULT_EXISTS=yes"
    else
      echo "ICLOUD_DEFAULT_VAULT_EXISTS=no"
    fi
    ;;

  bootstrap)
    [[ $# -ge 2 ]] || { echo "bootstrap requires <path>" >&2; exit 2; }
    target="$(_expand_tilde "$2")"
    pbrain_scaffold_vault "$target"
    pbrain_write_vault_config "$target"
    ;;

  migrate)
    [[ $# -ge 3 ]] || { echo "migrate requires <from> <to>" >&2; exit 2; }
    from="$(_expand_tilde "$2")"
    to="$(_expand_tilde "$3")"
    [[ -d "$from" ]] || { echo "source does not exist: $from" >&2; exit 1; }
    if [[ "$from" == "$to" ]]; then
      echo "source and target are the same path; nothing to migrate" >&2
      exit 0
    fi

    src_count="$(find "$from" -type f ! -name '.DS_Store' 2>/dev/null | wc -l | tr -d ' ')"
    echo "Source: $from ($src_count files)"
    echo "Target: $to"

    mkdir -p "$to"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --exclude='.DS_Store' "$from/" "$to/"
    else
      cp -a "$from/." "$to/"
    fi

    dst_count="$(find "$to" -type f ! -name '.DS_Store' 2>/dev/null | wc -l | tr -d ' ')"
    echo "Copied. Target now has $dst_count files."
    if [[ "$dst_count" -lt "$src_count" ]]; then
      echo "MIGRATE_VERIFIED=no" >&2
      echo "WARNING: target file count ($dst_count) < source ($src_count). Investigate before deleting source." >&2
      exit 1
    fi
    echo "MIGRATE_VERIFIED=yes"
    echo "Source preserved at: $from"
    echo "Delete source manually after opening the new vault in Obsidian:"
    echo "    rm -rf \"$from\""
    ;;

  setup-private)
    [[ $# -ge 2 ]] || { echo "setup-private requires <vault>" >&2; exit 2; }
    vault="$(_expand_tilde "$2")"
    [[ -d "$vault" ]] || { echo "vault does not exist: $vault" >&2; exit 1; }
    pdir="$vault/private.nosync"
    mkdir -p "$pdir"
    if [[ ! -f "$pdir/README.md" ]]; then
      cat > "$pdir/README.md" <<'PRV'
# private.nosync — local-only notes

Everything in this folder:

- Never syncs to iCloud (the `.nosync` suffix is honored by macOS).
- Never gets committed to git (entry in the vault `.gitignore`).
- Stays only on this Mac.

Use for anything you'd rather not have on your phone, in iCloud backups, or
in a git remote: passwords, sensitive drafts, work-in-progress that isn't ready.

Obsidian on this Mac still indexes and edits these notes normally.
PRV
      echo "  ✓ wrote $pdir/README.md"
    else
      echo "  · $pdir/README.md exists (left as-is)"
    fi
    if [[ -f "$vault/.gitignore" ]]; then
      if ! grep -q '^private\.nosync/' "$vault/.gitignore"; then
        printf '\nprivate.nosync/\n' >> "$vault/.gitignore"
        echo "  ✓ added private.nosync/ to .gitignore"
      else
        echo "  · .gitignore already covers private.nosync/"
      fi
    else
      printf 'private.nosync/\n' > "$vault/.gitignore"
      echo "  ✓ created .gitignore with private.nosync/"
    fi
    echo "Private dir ready: $pdir"
    ;;

  write-config)
    [[ $# -ge 2 ]] || { echo "write-config requires <path>" >&2; exit 2; }
    path="$(_expand_tilde "$2")"
    pbrain_write_vault_config "$path"
    ;;

  setup-git)
    [[ $# -ge 3 ]] || { echo "setup-git requires <vault> <remote-url>" >&2; exit 2; }
    vault="$(_expand_tilde "$2")"
    remote="$3"
    [[ -d "$vault/.git" ]] || { echo "vault is not a git repo (run bootstrap first): $vault" >&2; exit 1; }
    cd "$vault"
    if git remote get-url origin >/dev/null 2>&1; then
      current_remote="$(git remote get-url origin)"
      if [[ "$current_remote" == "$remote" ]]; then
        echo "  · origin already set to $remote"
      else
        git remote set-url origin "$remote"
        echo "  ✓ updated origin: $current_remote → $remote"
      fi
    else
      git remote add origin "$remote"
      echo "  ✓ added origin: $remote"
    fi
    branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"
    if git push -u origin "$branch"; then
      echo "  ✓ pushed $branch to origin"
    else
      echo "  ✗ push failed — see error above. Common causes:" >&2
      echo "    - remote doesn't exist yet (create it on GitHub / GitLab first)" >&2
      echo "    - remote isn't empty (run \`git pull --rebase origin $branch\` in $vault first)" >&2
      echo "    - no push permission (check ssh key / token)" >&2
      exit 1
    fi
    ;;

  -h|--help|help)
    _usage
    ;;

  *)
    echo "Unknown subcommand: $cmd" >&2
    _usage >&2
    exit 2
    ;;
esac
