#!/usr/bin/env bash
# pbrain goals-profile helper — sourced by lib/vault.sh.
#
# The goals profile is a vault markdown file (so it lives in Obsidian alongside
# the diet and fitness plans) whose structured data is carried in a fenced
# ```json code block. This keeps the file human-readable in Obsidian while
# preserving cheap, validated structured access for the commands that read it
# (`/plan-my-day`, `/loose-ends`, `/weekly-review`).
#
# Defines one function:
#
#   pbrain_profile_json <file>
#
# Prints the profile's JSON to stdout:
#   - the contents of the first ```json fenced block, if present;
#   - otherwise the whole file IF it parses as raw JSON (back-compat with the
#     pre-vault `~/.config/pbrain/plan-profile.json` format, and the migration
#     path);
#   - otherwise nothing (caller treats empty as "no usable profile").
#
# Never exits non-zero — sourced into commands under `set -euo pipefail`.

pbrain_profile_json() {
  local file="${1:-}"
  [[ -n "$file" && -f "$file" ]] || return 0
  command -v python3 >/dev/null 2>&1 || { cat "$file" 2>/dev/null || true; return 0; }
  python3 - "$file" <<'PYEOF' 2>/dev/null || true
import json, re, sys
try:
    with open(sys.argv[1]) as fh:
        text = fh.read()
except Exception:
    sys.exit(0)

# Prefer the first ```json fenced block.
m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
candidate = m.group(1).strip() if m else text.strip()

# Only emit if it's valid JSON; otherwise emit nothing.
try:
    json.loads(candidate)
    print(candidate)
except Exception:
    pass
PYEOF
}
