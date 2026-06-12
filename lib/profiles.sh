#!/usr/bin/env bash
# pbrain versioned profile store — sourced by lib/vault.sh.
#
# Every profile-owning command (fitness, diet, plan-my-day, habits) keeps its
# base configuration as VERSIONED markdown profiles under a hidden `.profile/`
# dir inside its tracking dir:
#
#   <tracking-dir>/.profile/<base>.v<N>.md
#
# Each file is an Obsidian-compatible markdown note whose structured data lives
# in a fenced ```json block (read with pbrain_profile_json from lib/profile.sh).
# Frontmatter carries `version: N` + `committed: true|false`:
#
#   - A profile is EDITABLE while it is a draft (committed: false). The user
#     iterates on a draft during the building phase.
#   - `commit` flips it to committed: true. From then on the file is FINAL —
#     changes mean minting the NEXT version (`new`), iterating on that draft,
#     and committing it. Old versions stay on disk as history.
#   - Commands always READ the highest COMMITTED version.
#
# Libraries (food library, work library, fitness library, …) live in the same
# store. They are LIVING documents — rows/entries are appended over time
# WITHOUT a version bump; the version only increments on a structural rebuild.
#
# Functions (all safe under `set -euo pipefail`; read functions echo nothing
# and return 0 when the store/profile does not exist — callers test for empty):
#
#   pbrain_profile_store <tracking_dir>          → echo "<tracking_dir>/.profile"
#   pbrain_profile_latest <store> <base>         → path of highest COMMITTED version
#   pbrain_profile_latest_any <store> <base>     → path of highest version (draft or committed)
#   pbrain_profile_draft <store> <base>          → path of highest version IFF it is a draft
#   pbrain_profile_version <file>                → version number parsed from the filename
#   pbrain_profile_is_committed <file>           → exit 0 iff frontmatter has committed: true
#   pbrain_profile_new <store> <base> [from]     → mint next-version draft (copies [from],
#                                                  else the highest existing version, else a
#                                                  minimal stub); echo the new path
#   pbrain_profile_commit <store> <base>         → mark the highest version committed
#                                                  (idempotent); echo its path

pbrain_profile_store() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 0
  printf '%s\n' "$dir/.profile"
}

# Internal: print "version<TAB>path" for every version of <base> in <store>,
# sorted ascending by version. Silent when the store is missing/empty.
_pbrain_profile_versions() {
  local store="${1:-}" base="${2:-}" f v
  [[ -n "$store" && -n "$base" && -d "$store" ]] || return 0
  for f in "$store/$base".v*.md; do
    [[ -f "$f" ]] || continue
    v="${f##*.v}"; v="${v%.md}"
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    printf '%s\t%s\n' "$v" "$f"
  done | sort -n -k1,1
  return 0
}

pbrain_profile_version() {
  local f="${1:-}" v
  [[ -n "$f" ]] || return 0
  v="${f##*.v}"; v="${v%.md}"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$v"
  return 0
}

# Exit 0 iff the file's frontmatter says `committed: true`. A file with no
# frontmatter or no committed line counts as NOT committed (a draft).
pbrain_profile_is_committed() {
  local f="${1:-}"
  [[ -n "$f" && -f "$f" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$f" <<'PYEOF'
import re, sys
try:
    with open(sys.argv[1]) as fh:
        text = fh.read()
except Exception:
    sys.exit(1)
m = re.match(r"^---\n(.*?)\n---(\n|$)", text, re.DOTALL)
fm = m.group(1) if m else ""
sys.exit(0 if re.search(r"^committed:\s*true\s*$", fm, re.MULTILINE) else 1)
PYEOF
}

pbrain_profile_latest() {
  local store="${1:-}" base="${2:-}" v f
  [[ -n "$store" && -n "$base" ]] || return 0
  while IFS=$'\t' read -r v f; do
    [[ -n "${f:-}" && -f "$f" ]] || continue
    if pbrain_profile_is_committed "$f"; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(_pbrain_profile_versions "$store" "$base" | sort -rn -k1,1)
  return 0
}

pbrain_profile_latest_any() {
  local store="${1:-}" base="${2:-}" line
  [[ -n "$store" && -n "$base" ]] || return 0
  line="$(_pbrain_profile_versions "$store" "$base" | tail -n1)"
  [[ -n "$line" ]] && printf '%s\n' "${line#*$'\t'}"
  return 0
}

# The current draft, if any: the highest version, but only when it is NOT yet
# committed. Empty output when the highest version is committed (or none exist).
pbrain_profile_draft() {
  local store="${1:-}" base="${2:-}" f
  f="$(pbrain_profile_latest_any "$store" "$base")"
  [[ -n "$f" ]] || return 0
  pbrain_profile_is_committed "$f" && return 0
  printf '%s\n' "$f"
  return 0
}

# Mint the next-version DRAFT. Content is copied from [from] when given, else
# from the highest existing version, else a minimal stub is created. The new
# file's frontmatter is rewritten to version: N+1, committed: false,
# date: today. Echoes the new path. Refuses (rc 1) when a draft already exists
# — finish or commit it first (one draft at a time keeps "latest" unambiguous).
pbrain_profile_new() {
  local store="${1:-}" base="${2:-}" from="${3:-}" next src draft
  [[ -n "$store" && -n "$base" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  draft="$(pbrain_profile_draft "$store" "$base")"
  if [[ -n "$draft" ]]; then
    echo "pbrain: a draft already exists: $draft (edit it, or commit it first)" >&2
    return 1
  fi
  next="$(_pbrain_profile_versions "$store" "$base" | tail -n1)"
  next="${next%%$'\t'*}"
  next=$(( ${next:-0} + 1 ))
  [[ -n "$from" ]] || from="$(pbrain_profile_latest_any "$store" "$base")"
  src="$from"
  mkdir -p "$store" 2>/dev/null || return 1
  python3 - "$store/$base.v$next.md" "$next" "$base" "${src:-}" <<'PYEOF' || return 1
import datetime, os, re, sys, tempfile
dest, version, base, src = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
today = datetime.date.today().isoformat()
text = ""
if src and os.path.isfile(src):
    with open(src) as fh:
        text = fh.read()
if not text.strip():
    text = ("---\n"
            "type: profile\n"
            f"date: {today}\n"
            "tags: []\n"
            "---\n\n"
            f"# {base}\n\n"
            "```json\n{}\n```\n")
m = re.match(r"^---\n(.*?)\n---\n?", text, re.DOTALL)
if m:
    fm = m.group(1)
    body = text[m.end():]
else:
    fm = f"type: profile\ndate: {today}\ntags: []"
    body = text
# Drop any existing version/committed/date lines, then set fresh ones.
lines = [l for l in fm.splitlines()
         if not re.match(r"^(version|committed|date):", l)]
lines.append(f"date: {today}")
lines.append(f"version: {version}")
lines.append("committed: false")
out = "---\n" + "\n".join(lines) + "\n---\n" + body
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), suffix=".tmp")
with os.fdopen(fd, "w") as fh:
    fh.write(out)
os.replace(tmp, dest)
PYEOF
  printf '%s\n' "$store/$base.v$next.md"
  return 0
}

# Commit the highest version: committed: false → true. Idempotent — committing
# an already-committed profile just echoes its path. rc 1 when nothing exists.
pbrain_profile_commit() {
  local store="${1:-}" base="${2:-}" f
  [[ -n "$store" && -n "$base" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  f="$(pbrain_profile_latest_any "$store" "$base")"
  if [[ -z "$f" ]]; then
    echo "pbrain: no $base profile exists in $store — nothing to commit" >&2
    return 1
  fi
  if pbrain_profile_is_committed "$f"; then
    printf '%s\n' "$f"
    return 0
  fi
  python3 - "$f" <<'PYEOF' || return 1
import os, re, sys, tempfile
path = sys.argv[1]
with open(path) as fh:
    text = fh.read()
m = re.match(r"^---\n(.*?)\n---\n?", text, re.DOTALL)
if m:
    fm, body = m.group(1), text[m.end():]
else:
    fm, body = "type: profile", text
lines = [l for l in fm.splitlines() if not re.match(r"^committed:", l)]
lines.append("committed: true")
out = "---\n" + "\n".join(lines) + "\n---\n" + body
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
with os.fdopen(fd, "w") as fh:
    fh.write(out)
os.replace(tmp, path)
PYEOF
  printf '%s\n' "$f"
  return 0
}

# Resolve the profile whose json block has `"period": "<period>"`.
# Iterates versions newest-first (draft or committed); returns the first
# match path, or empty string when no version matches the given period.
# Typical use: pbrain_profile_latest_for_period "$STORE" weekly-goals "2026-W24"
pbrain_profile_latest_for_period() {
  local store="${1:-}" base="${2:-}" period="${3:-}" v f
  [[ -n "$store" && -n "$base" && -n "$period" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r v f; do
    [[ -n "${f:-}" && -f "$f" ]] || continue
    local _match
    _match="$(python3 - "$f" "$period" <<'PYEOF' 2>/dev/null || true
import re, sys, json
try:
    with open(sys.argv[1]) as fh:
        text = fh.read()
except Exception:
    sys.exit(0)
m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
try:
    data = json.loads(m.group(1) if m else "{}")
except Exception:
    sys.exit(0)
if data.get("period") == sys.argv[2]:
    print("match")
PYEOF
)"
    [[ "$_match" == "match" ]] && printf '%s\n' "$f" && return 0
  done < <(_pbrain_profile_versions "$store" "$base" | sort -rn -k1,1)
  return 0
}
