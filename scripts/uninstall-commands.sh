#!/usr/bin/env bash
set -euo pipefail

# Removes the per-file symlinks that install-commands.sh placed in
# ~/.claude/commands/. Only removes a symlink if it points at the matching
# file in <repo>/commands/ — anything else is left alone.
# Idempotent: re-running on an already-uninstalled state is a no-op.
#
# Also removes the PBRAIN_DEV_DIR entry from ~/.claude/settings.json, but only
# if it resolves to this repo (realpath match) — so uninstalling from one clone
# never clobbers a setting that points at a different one.

_SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P -- "$_SCRIPT_DIR/.." && pwd -P)"
SRC_DIR="$REPO_ROOT/commands"
DEST_DIR="$HOME/.claude/commands"
SETTINGS_FILE="$HOME/.claude/settings.json"

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

# --- Remove PBRAIN_DEV_DIR from ~/.claude/settings.json if it points here ---
echo
python3 - "$SETTINGS_FILE" "$REPO_ROOT" <<'PYEOF'
import json, os, sys

settings_file, repo_root = sys.argv[1], sys.argv[2]

if not os.path.exists(settings_file):
    print("settings: no settings.json — nothing to remove")
    sys.exit(0)

try:
    with open(settings_file) as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    print(f"WARN: could not parse {settings_file} ({e}) — leaving it untouched", file=sys.stderr)
    sys.exit(0)

if not isinstance(data, dict):
    sys.exit(0)

env = data.get("env")
if not isinstance(env, dict) or "PBRAIN_DEV_DIR" not in env:
    print("settings: no PBRAIN_DEV_DIR to remove")
    sys.exit(0)

current = env["PBRAIN_DEV_DIR"]
try:
    same = os.path.realpath(current) == os.path.realpath(repo_root)
except OSError:
    same = current == repo_root

if not same:
    print(f"settings: PBRAIN_DEV_DIR points elsewhere ({current}) — leaving it")
    sys.exit(0)

del env["PBRAIN_DEV_DIR"]
if not env:
    del data["env"]

tmp = settings_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, settings_file)
print(f"settings: removed PBRAIN_DEV_DIR ({current})")
print("NOTE: restart Conductor / Claude Code for the env change to take effect.")
PYEOF
