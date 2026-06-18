#!/usr/bin/env bash
# Migration 0010 (AUTO, owner: habits): clear the profile `notes` of the DEFAULT
# scored habits.
#
# Scoring for the shipped default scored habits is owned by the SCRIPT
# (`score_from_spec` in lib/habits.sh computes the number) and the MODEL-facing
# classification + marking guidance lives ONCE in the /habits spec
# (commands/habits.md → "Default scored habits"). Duplicating that into each
# habit's profile `notes` is what let the prose drift out of sync with the scale
# (it still read "Max score = 100" after the 0–1 rescale). So the default scored
# habits carry NO notes — the script + the command spec are the single sources.
#
# User-DEFINED scored habits are the opposite: the script can't know a custom
# classification, so their logic stays in `notes` (the model reads it, passes
# raw values to `habits.sh mark`, the rule computes, it's saved). This migration
# therefore only blanks the notes of the known default ids; any other scored
# habit is left untouched.
#
# Default scored ids: eat-clean, sleep-well, work-the-plan, train, deep-work,
# supplements. Idempotent (stops firing once they all have empty notes) and
# non-destructive (the profile is copied to .pbrain/backup/ before the edit).

MIGRATION_KIND=auto
MIGRATION_OWNER="habits"

_pbrain_m0010_profile() {
  if declare -F pbrain_habits_profile_file >/dev/null 2>&1; then
    pbrain_habits_profile_file
    return 0
  fi
  local f store latest
  f="${PBRAIN_HABITS_PROFILE_FILE:-}"
  if [[ -n "$f" && -f "$f" ]]; then printf '%s\n' "$f"; return 0; fi
  store="${PBRAIN_HABIT_TRACK_DIR:-$VAULT_DIR/life/habit-tracking}/.profile"
  latest="$(ls -1 "$store"/habits-profile.v*.md 2>/dev/null \
            | sed -E 's/.*habits-profile\.v([0-9]+)\.md/\1 &/' \
            | sort -n | tail -n1 | cut -d' ' -f2-)"
  if [[ -n "$latest" && -f "$latest" ]]; then printf '%s\n' "$latest"; return 0; fi
  [[ -f "$VAULT_DIR/life/Habits Profile.md" ]] && printf '%s\n' "$VAULT_DIR/life/Habits Profile.md"
  return 0
}

# Shared Python core. argv: <mode> <profile> <backupdir>
# mode "check" -> exit 0 iff a default scored habit still carries notes;
# mode "apply" -> blank those notes.
_pbrain_m0010_py() {
  python3 - "$1" "$(_pbrain_m0010_profile)" "$VAULT_DIR/.pbrain/backup" <<'PYEOF'
import json, os, re, sys, shutil

mode, profile, backup = sys.argv[1:4]

DEFAULT_SCORED_IDS = {
    "eat-clean", "sleep-well", "work-the-plan", "train", "deep-work", "supplements",
}

try:
    with open(profile) as fh:
        ptext = fh.read()
except Exception:
    sys.exit(1)

m = re.search(r"(```json\s*\n)(.*?)(```)", ptext, re.DOTALL)
if not m:
    sys.exit(1)
try:
    pdata = json.loads(m.group(2))
except Exception:
    sys.exit(1)

changed = False
for h in (pdata.get("habits") or []):
    if str(h.get("id", "")).strip() not in DEFAULT_SCORED_IDS:
        continue
    if not isinstance(h.get("scoring"), dict):
        continue  # only clear a default that is actually scored
    if str(h.get("notes", "")).strip() == "":
        continue  # already cleared
    if mode == "check":
        sys.exit(0)  # work exists
    h["notes"] = ""
    changed = True

if mode == "check":
    sys.exit(1)  # nothing to clear

if changed:
    os.makedirs(backup, exist_ok=True)
    shutil.copy2(profile, os.path.join(backup, os.path.basename(profile) + ".pre-0010"))
    new_json = json.dumps(pdata, indent=2)
    out = ptext[:m.start()] + m.group(1) + new_json + "\n" + m.group(3) + ptext[m.end():]
    with open(profile, "w") as fh:
        fh.write(out)
sys.exit(0)
PYEOF
}

migration_applicable() {
  command -v python3 >/dev/null 2>&1 || return 1
  local profile
  profile="$(_pbrain_m0010_profile)"
  [[ -n "$profile" && -f "$profile" ]] || return 1
  _pbrain_m0010_py check
}

migration_apply() {
  command -v python3 >/dev/null 2>&1 || return 1
  mkdir -p "$VAULT_DIR/.pbrain/backup"
  _pbrain_m0010_py apply || return 1
  echo "Cleared the default scored habits' profile notes (scoring lives in lib/habits.sh + the /habits spec; original profile parked in .pbrain/backup/)"
}
