#!/usr/bin/env bash
# Migration 0006 (AUTO): move the food library into the diet profile store.
#
#   old: $VAULT_DIR/fitness/Food Library.md
#   new: <diet-dir>/.profile/food-library.v1.md  (committed: true; the library
#        is a LIVING document — rows keep being appended in place, the version
#        only bumps on a structural rebuild)
#
# Pure in-vault move; the original is parked under .pbrain/backup/.

MIGRATION_KIND=auto
MIGRATION_OWNER=""

_pbrain_m0006_store() {
  printf '%s\n' "${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}/.profile"
}

migration_applicable() {
  local store
  store="$(_pbrain_m0006_store)"
  compgen -G "$store/food-library.v*.md" >/dev/null 2>&1 && return 1
  [[ -f "$VAULT_DIR/fitness/Food Library.md" ]]
}

migration_apply() {
  local store src dest backup
  store="$(_pbrain_m0006_store)"
  src="$VAULT_DIR/fitness/Food Library.md"
  dest="$store/food-library.v1.md"
  backup="$VAULT_DIR/.pbrain/backup"
  mkdir -p "$store" "$backup"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$src" "$dest" <<'PYEOF' || return 1
import os, re, sys, tempfile
src, dest = sys.argv[1], sys.argv[2]
with open(src) as fh:
    text = fh.read()
m = re.match(r"^---\n(.*?)\n---\n?", text, re.DOTALL)
if m:
    fm, body = m.group(1), text[m.end():]
else:
    fm, body = "type: food-library", text
lines = [l for l in fm.splitlines()
         if not re.match(r"^(version|committed):", l)]
lines.append("version: 1")
lines.append("committed: true")
out = "---\n" + "\n".join(lines) + "\n---\n" + body
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), suffix=".tmp")
with os.fdopen(fd, "w") as fh:
    fh.write(out)
os.replace(tmp, dest)
PYEOF
  mv "$src" "$backup/Food Library.md"
  echo "food library moved to $dest (original parked in .pbrain/backup/)"
}
