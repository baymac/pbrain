#!/usr/bin/env bash
# Migration 0004 (STAGED, owner: diet-journal): merge the diet profile JSON and
# the Diet Plan markdown into ONE versioned diet profile.
#
#   old: ~/.config/pbrain/diet-profile.json   (body/state/conditions/prefs)
#        $VAULT_DIR/fitness/Diet Plan.md      (computed targets + meal structure)
#   new: <diet-dir>/.profile/diet-profile.v1.md  (one profile carrying both:
#        the old JSON fields PLUS targets/meal_pattern/meal_slots/macro_approach
#        in its fenced json block, with the plan sections as the body)
#
# Needs the user (validate old values part by part before importing; targets
# may be stale), so the runner leaves it pending; diet-journal.sh drives the
# rebuild and records it with `bash lib/migrations.sh record 0004_diet_profile_combine`.

MIGRATION_KIND=staged
MIGRATION_OWNER="diet-journal"

migration_applicable() {
  local store
  store="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}/.profile"
  # Already rebuilt → nothing to do.
  compgen -G "$store/diet-profile.v*.md" >/dev/null 2>&1 && return 1
  [[ -f "${PBRAIN_DIET_PROFILE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/diet-profile.json}" ]] && return 0
  [[ -f "$VAULT_DIR/fitness/Diet Plan.md" ]] && return 0
  return 1
}
