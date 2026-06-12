#!/usr/bin/env bash
# Migration 0002 (STAGED, owner: plan-my-day): rebuild the plans profile
# from the old Goals Profile.md (or legacy plan-profile.json) into the
# versioned store.
#
#   old: $VAULT_DIR/life/Goals Profile.md  (or legacy ~/.config/pbrain/plan-profile.json)
#   new: <plan-dir>/.profile/plans-profile.v1.md   (current_focus list;
#        working_style + planning_guidelines + daily_anchors etc.)
#        <plan-dir>/.profile/work-library.v1.md    (stable project cards)
#        <plan-dir>/.profile/goals-library.v1.md   (stable goal cards)
#
# This rebuild needs the user (validate old values part by part, ask what is
# new, drop what is gone), so the runner leaves it pending; plan-my-day.sh
# detects it via pbrain_migration_pending and drives the rebuild in-session,
# then records it with `bash lib/migrations.sh record 0002_plans_profile_rebuild`.

MIGRATION_KIND=staged
MIGRATION_OWNER="plan-my-day"

migration_applicable() {
  local store
  store="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}/.profile"
  # Already rebuilt → nothing to do.
  compgen -G "$store/plans-profile.v*.md" >/dev/null 2>&1 && return 1
  [[ -f "$VAULT_DIR/life/Goals Profile.md" ]] && return 0
  [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/plan-profile.json" ]] && return 0
  return 1
}
