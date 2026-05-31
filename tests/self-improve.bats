#!/usr/bin/env bats
# Tests for lib/self-improve.sh — pbrain_emit_self_improve.
#
# Covers the mode-resolution matrix (off / prefs / dev±PBRAIN_DEV_DIR), the
# dev-repo git-state warnings, the fail-safe for unknown values, and the
# critical "never exits non-zero" guard (these libs are sourced into every
# command under `set -euo pipefail`, so a non-zero exit would break all 12).
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TMP/config"
  mkdir -p "$XDG_CONFIG_HOME/pbrain"
  source "$REPO_ROOT/lib/self-improve.sh"
}

teardown() {
  rm -rf "$TMP"
}

make_dev_repo() {
  # Args: branch name. Echoes the repo path.
  local repo="$TMP/repo"
  mkdir -p "$repo/commands"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  git -C "$repo" checkout -q -b "${1:-feature}" 2>/dev/null || true
  echo "$repo"
}

@test "off mode emits nothing and returns 0" {
  PBRAIN_SELF_IMPROVE=off run pbrain_emit_self_improve journal
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unset (default) resolves to prefs mode, no dev section" {
  unset PBRAIN_SELF_IMPROVE
  run pbrain_emit_self_improve journal
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: prefs"* ]]
  [[ "$output" != *"DEV MODE"* ]]
}

@test "explicit prefs mode emits the prefs tail" {
  PBRAIN_SELF_IMPROVE=prefs run pbrain_emit_self_improve journal
  [[ "$output" == *"mode: prefs"* ]]
  [[ "$output" == *"SELF-IMPROVE CHECK"* ]]
}

@test "dev mode WITHOUT PBRAIN_DEV_DIR falls back to prefs" {
  unset PBRAIN_DEV_DIR
  PBRAIN_SELF_IMPROVE=dev run pbrain_emit_self_improve journal
  [[ "$output" == *"mode: prefs"* ]]
  [[ "$output" != *"DEV MODE"* ]]
}

@test "dev mode WITH PBRAIN_DEV_DIR emits the dev source-edit section" {
  local repo; repo="$(make_dev_repo feature)"
  PBRAIN_SELF_IMPROVE=dev PBRAIN_DEV_DIR="$repo" run pbrain_emit_self_improve journal
  [[ "$output" == *"mode: dev"* ]]
  [[ "$output" == *"DEV MODE"* ]]
  [[ "$output" == *"commands/journal.sh"* ]]
}

@test "dev mode on main branch warns about the branch" {
  local repo; repo="$(make_dev_repo main)"
  PBRAIN_SELF_IMPROVE=dev PBRAIN_DEV_DIR="$repo" run pbrain_emit_self_improve journal
  [[ "$output" == *"on 'main'"* ]]
}

@test "dev mode with a dirty tree warns about uncommitted changes" {
  local repo; repo="$(make_dev_repo feature)"
  echo "x" > "$repo/commands/foo.sh"
  PBRAIN_SELF_IMPROVE=dev PBRAIN_DEV_DIR="$repo" run pbrain_emit_self_improve journal
  [[ "$output" == *"uncommitted changes"* ]]
}

@test "unknown mode value fails safe to prefs (not off)" {
  unset PBRAIN_DEV_DIR
  PBRAIN_SELF_IMPROVE=garbage run pbrain_emit_self_improve journal
  [[ "$output" == *"mode: prefs"* ]]
}

@test "no command name returns 0 with no output" {
  run pbrain_emit_self_improve
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "never exits non-zero even when PBRAIN_DEV_DIR points at a non-repo" {
  PBRAIN_SELF_IMPROVE=dev PBRAIN_DEV_DIR="$TMP/not-a-repo" run pbrain_emit_self_improve journal
  [ "$status" -eq 0 ]
}

@test "plan args add a PLAN UPDATE section naming the plan + label" {
  run pbrain_emit_self_improve diet-journal "/v/fitness/Diet Plan.md" "diet plan"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN UPDATE"* ]]
  [[ "$output" == *"diet plan"* ]]
  [[ "$output" == *"/v/fitness/Diet Plan.md"* ]]
  [[ "$output" == *"explicit per-change yes"* ]]
}

@test "no plan args means no PLAN UPDATE section" {
  run pbrain_emit_self_improve journal
  [[ "$output" != *"PLAN UPDATE"* ]]
}

@test "only one plan arg (label missing) omits the PLAN UPDATE section" {
  run pbrain_emit_self_improve diet-journal "/v/Diet Plan.md"
  [[ "$output" != *"PLAN UPDATE"* ]]
}

@test "off mode stays fully silent even with plan args" {
  PBRAIN_SELF_IMPROVE=off run pbrain_emit_self_improve diet-journal "/v/Diet Plan.md" "diet plan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
