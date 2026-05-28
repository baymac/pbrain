#!/usr/bin/env bash
set -euo pipefail

# Removes the per-file symlinks that install-commands.sh placed in
# ~/.claude/commands/. Only removes a symlink if it points at the matching
# file in <repo>/commands/ — anything else is left alone.
# Idempotent: re-running on an already-uninstalled state is a no-op.

_SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P -- "$_SCRIPT_DIR/.." && pwd -P)"
SRC_DIR="$REPO_ROOT/commands"
DEST_DIR="$HOME/.claude/commands"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "error: source dir not found: $SRC_DIR" >&2
  exit 1
fi

if [[ ! -d "$DEST_DIR" ]]; then
  echo "nothing to do: $DEST_DIR does not exist"
  exit 0
fi

removed=0
foreign=0
missing=0
not_a_link=0

shopt -s nullglob
for src in "$SRC_DIR"/*; do
  name="$(basename "$src")"
  target="$DEST_DIR/$name"

  if [[ -L "$target" ]]; then
    current="$(readlink "$target")"
    if [[ "$current" == "$src" ]]; then
      rm "$target"
      echo "removed: $name"
      removed=$((removed + 1))
    else
      echo "skip (foreign symlink): $name -> $current" >&2
      foreign=$((foreign + 1))
    fi
  elif [[ -e "$target" ]]; then
    echo "skip (not a symlink): $target" >&2
    not_a_link=$((not_a_link + 1))
  else
    missing=$((missing + 1))
  fi
done

echo
echo "done. removed=$removed foreign-symlinks=$foreign not-a-symlink=$not_a_link already-gone=$missing"
echo "dest: $DEST_DIR"

# Clean up the dest dir only if it's now empty AND not a symlink itself.
if [[ -d "$DEST_DIR" && ! -L "$DEST_DIR" ]] && [[ -z "$(ls -A "$DEST_DIR" 2>/dev/null)" ]]; then
  rmdir "$DEST_DIR" 2>/dev/null && echo "removed empty: $DEST_DIR" || true
fi
