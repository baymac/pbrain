#!/usr/bin/env bash
set -euo pipefail

# Symlinks every file in <repo>/commands/ into ~/.claude/commands/ individually.
# Idempotent: re-running re-points stale symlinks and skips ones already correct.
# Preserves any non-pbrain files already in ~/.claude/commands/.
#
# Also registers this repo as PBRAIN_DEV_DIR in ~/.claude/settings.json so the
# slash-command wrappers resolve their .sh from here (realtime edits), without
# needing a plugin/marketplace install or a shell-profile export. The harness
# reads settings.json regardless of how it was launched (GUI or terminal),
# which a ~/.zshrc export does not cover for GUI-launched apps.

_SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P -- "$_SCRIPT_DIR/.." && pwd -P)"
SRC_DIR="$REPO_ROOT/commands"
DEST_DIR="$HOME/.claude/commands"
SETTINGS_FILE="$HOME/.claude/settings.json"

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

# --- Register PBRAIN_DEV_DIR in ~/.claude/settings.json (idempotent) ---
echo
python3 - "$SETTINGS_FILE" "$REPO_ROOT" <<'PYEOF'
import json, os, sys

settings_file, repo_root = sys.argv[1], sys.argv[2]

if os.path.exists(settings_file):
    try:
        with open(settings_file) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"WARN: could not parse {settings_file} ({e}) — leaving it untouched", file=sys.stderr)
        sys.exit(0)
    if not isinstance(data, dict):
        print(f"WARN: {settings_file} is not a JSON object — leaving it untouched", file=sys.stderr)
        sys.exit(0)
else:
    data = {}

env = data.get("env")
if not isinstance(env, dict):
    env = {}
    data["env"] = env

current = env.get("PBRAIN_DEV_DIR")
if current == repo_root:
    print(f"settings: PBRAIN_DEV_DIR already correct ({repo_root})")
    sys.exit(0)

env["PBRAIN_DEV_DIR"] = repo_root

os.makedirs(os.path.dirname(settings_file), exist_ok=True)
tmp = settings_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, settings_file)

if current is None:
    print(f"settings: added PBRAIN_DEV_DIR -> {repo_root}")
else:
    print(f"settings: updated PBRAIN_DEV_DIR ({current} -> {repo_root})")
print("NOTE: restart Conductor / Claude Code for the env change to take effect.")
PYEOF
