#!/usr/bin/env bash
# Migration 0003 (STAGED, owner: fitness-journal): rebuild the fitness base
# config into the versioned store.
#
#   old: ~/.config/pbrain/fitness-activities.json
#        $VAULT_DIR/fitness/Gym Plan.md
#        $VAULT_DIR/fitness/plans/*.md
#   new: <fitness-dir>/.profile/fitness-profile.v1.md   (NEW overall profile:
#        sleep bed/wake times + hours, steps/day, health-tracker metrics — the
#        interview asks for these since the old data has none)
#        <fitness-dir>/.profile/fitness-library.v1.md   (activities + stable
#        metadata + occurrence per week|month)
#        <fitness-dir>/.profile/activities/<slug>.v1.md (per-activity profiles
#        with FIXED, non-conflicting days of week; equipment captured here
#        once — the daily session no longer asks)
#
# Needs the user (occurrences, day assignment, the new overall-profile fields),
# so the runner leaves it pending; fitness-journal.sh drives the rebuild and
# records it with `bash lib/migrations.sh record 0003_fitness_profiles`.

MIGRATION_KIND=staged
MIGRATION_OWNER="fitness-journal"

migration_applicable() {
  local store
  store="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}/.profile"
  # Already rebuilt → nothing to do.
  compgen -G "$store/fitness-library.v*.md" >/dev/null 2>&1 && return 1
  [[ -f "${PBRAIN_FITNESS_ACTIVITIES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/fitness-activities.json}" ]] && return 0
  [[ -f "$VAULT_DIR/fitness/Gym Plan.md" ]] && return 0
  compgen -G "$VAULT_DIR/fitness/plans/*.md" >/dev/null 2>&1 && return 0
  return 1
}
