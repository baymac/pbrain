#!/usr/bin/env bash
set -euo pipefail

# Symlinks every file in <repo>/commands/ into ~/.claude/commands/ individually.
# Idempotent: re-running re-points stale symlinks and skips ones already correct.
# Preserves any non-pbrain files already in ~/.claude/commands/.

_SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P -- "$_SCRIPT_DIR/.." && pwd -P)"
SRC_DIR="$REPO_ROOT/commands"
DEST_DIR="$HOME/.claude/commands"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "error: source dir not found: $SRC_DIR" >&2
  exit 1
fi

# If ~/.claude/commands is a symlink (e.g. pointing at the whole commands dir),
# replace it with a real directory so we can drop per-file symlinks inside.
if [[ -L "$DEST_DIR" ]]; then
  echo "replacing dir-level symlink at $DEST_DIR with a real directory"
  rm "$DEST_DIR"
fi

mkdir -p "$DEST_DIR"

linked=0
replaced=0
skipped=0
conflicts=0

shopt -s nullglob
for src in "$SRC_DIR"/*; do
  name="$(basename "$src")"
  target="$DEST_DIR/$name"

  if [[ -L "$target" ]]; then
    current="$(readlink "$target")"
    if [[ "$current" == "$src" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    rm "$target"
    ln -s "$src" "$target"
    echo "repointed: $name -> $src"
    replaced=$((replaced + 1))
  elif [[ -e "$target" ]]; then
    echo "WARN: $target exists and is not a symlink — leaving it alone" >&2
    conflicts=$((conflicts + 1))
  else
    ln -s "$src" "$target"
    echo "linked: $name -> $src"
    linked=$((linked + 1))
  fi
done

echo
echo "done. linked=$linked repointed=$replaced already-correct=$skipped conflicts=$conflicts"
echo "source: $SRC_DIR"
echo "dest:   $DEST_DIR"
