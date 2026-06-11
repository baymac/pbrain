#!/usr/bin/env bash
# Migration 0005 (AUTO): move the habits profile into the versioned store.
#
#   old: $VAULT_DIR/life/Habits Profile.md
#   new: <habit-track-dir>/.profile/habits-profile.v1.md  (committed: true —
#        the existing profile is the active one, not a draft)
#
# Pure in-vault move: content is preserved verbatim (frontmatter gains
# version/committed); the original is parked under .pbrain/backup/ rather than
# deleted. The habits resolution (lib/habits.sh) reads the store first, so
# nothing else changes.

MIGRATION_KIND=auto
MIGRATION_OWNER=""

_pbrain_m0005_store() {
  printf '%s\n' "${PBRAIN_HABIT_TRACK_DIR:-$VAULT_DIR/life/habit-tracking}/.profile"
}

migration_applicable() {
  local store
  store="$(_pbrain_m0005_store)"
  compgen -G "$store/habits-profile.v*.md" >/dev/null 2>&1 && return 1
  [[ -f "$VAULT_DIR/life/Habits Profile.md" ]]
}

migration_apply() {
  local store src dest backup
  store="$(_pbrain_m0005_store)"
  src="$VAULT_DIR/life/Habits Profile.md"
  dest="$store/habits-profile.v1.md"
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
    fm, body = "type: habits-profile", text
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
  mv "$src" "$backup/Habits Profile.md"
  echo "habits profile moved to $dest (original parked in .pbrain/backup/)"
}
