#!/usr/bin/env bash
# Migration 0008 (STAGED, owner: habits): categorize existing habits into parts.
#
# Adds a single `category` ("part") slug to every habit in the profile, drawn
# from the seven canonical parts (wellness, fitness-activity, bad-habits, looks,
# cleanliness, work, diet) — custom parts allowed. New habits pick a part at
# `add --category …`; this one-time pass backfills the ones already in the
# profile.
#
# It needs the user: only they know whether "Brush at night" is cleanliness or
# looks, etc. So the runner leaves it PENDING; commands/habits.sh detects it via
# pbrain_migration_pending on the dashboard path, proposes a part per habit,
# confirms PART BY PART, writes each with `edit --id <id> --category <slug>`,
# then records with `bash lib/migrations.sh record 0008_habits_categorize`.
#
# Applicable while the active (latest) habits profile has at least one
# non-archived habit with no `category`. Once every active habit is categorized
# (or the user declines the rest and records it), it stops firing.

MIGRATION_KIND=staged
MIGRATION_OWNER="habits"

# Resolve the profile file the command actually reads/writes. Prefer the shared
# resolver (sourced before the runner in lib/vault.sh); fall back to a direct
# env-based lookup so the script stays self-contained.
_pbrain_m0008_profile() {
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

migration_applicable() {
  local profile
  profile="$(_pbrain_m0008_profile)"
  [[ -n "$profile" && -f "$profile" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  # Exit 0 iff some non-archived habit lacks a non-empty category.
  python3 - "$profile" <<'PYEOF'
import json, re, sys
try:
    with open(sys.argv[1]) as fh:
        text = fh.read()
except Exception:
    sys.exit(1)
m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
if not m:
    sys.exit(1)
try:
    data = json.loads(m.group(1))
except Exception:
    sys.exit(1)
for h in (data.get("habits") or []):
    if h.get("archived"):
        continue
    if not str(h.get("category", "")).strip():
        sys.exit(0)   # work to do
sys.exit(1)           # every active habit already categorized
PYEOF
}
