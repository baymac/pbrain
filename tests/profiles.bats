#!/usr/bin/env bats
# Tests for lib/profiles.sh — the versioned profile store.
#
#   <store>/<base>.v<N>.md ; frontmatter version: N + committed: true|false
#   new → next-version draft; commit → freeze; latest → highest committed.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  STORE="$TMP/tracking/.profile"
  source "$REPO_ROOT/lib/profiles.sh"
}

teardown() {
  rm -rf "$TMP"
}

@test "pbrain_profile_store appends .profile to the tracking dir" {
  run pbrain_profile_store "/some/tracking"
  [ "$status" -eq 0 ]
  [ "$output" = "/some/tracking/.profile" ]
}

@test "latest/latest_any/draft are silent on a missing store" {
  run pbrain_profile_latest "$STORE" plans-profile
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run pbrain_profile_latest_any "$STORE" plans-profile
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run pbrain_profile_draft "$STORE" plans-profile
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "new on an empty store mints v1 as an editable draft" {
  run pbrain_profile_new "$STORE" plans-profile
  [ "$status" -eq 0 ]
  [ "$output" = "$STORE/plans-profile.v1.md" ]
  [ -f "$STORE/plans-profile.v1.md" ]
  grep -q '^version: 1$' "$STORE/plans-profile.v1.md"
  grep -q '^committed: false$' "$STORE/plans-profile.v1.md"
  # a draft is not committed
  ! pbrain_profile_is_committed "$STORE/plans-profile.v1.md"
  # and latest (committed-only) still returns nothing
  run pbrain_profile_latest "$STORE" plans-profile
  [ -z "$output" ]
  run pbrain_profile_draft "$STORE" plans-profile
  [ "$output" = "$STORE/plans-profile.v1.md" ]
}

@test "commit freezes the draft and latest starts returning it" {
  pbrain_profile_new "$STORE" plans-profile >/dev/null
  run pbrain_profile_commit "$STORE" plans-profile
  [ "$status" -eq 0 ]
  [ "$output" = "$STORE/plans-profile.v1.md" ]
  pbrain_profile_is_committed "$STORE/plans-profile.v1.md"
  grep -q '^committed: true$' "$STORE/plans-profile.v1.md"
  run pbrain_profile_latest "$STORE" plans-profile
  [ "$output" = "$STORE/plans-profile.v1.md" ]
  # no draft remains
  run pbrain_profile_draft "$STORE" plans-profile
  [ -z "$output" ]
}

@test "commit is idempotent" {
  pbrain_profile_new "$STORE" plans-profile >/dev/null
  pbrain_profile_commit "$STORE" plans-profile >/dev/null
  run pbrain_profile_commit "$STORE" plans-profile
  [ "$status" -eq 0 ]
  [ "$output" = "$STORE/plans-profile.v1.md" ]
  # exactly one committed: line survived the double-commit
  [ "$(grep -c '^committed:' "$STORE/plans-profile.v1.md")" -eq 1 ]
}

@test "new after commit mints v2 copying v1 content; latest stays v1 until v2 commits" {
  pbrain_profile_new "$STORE" plans-profile >/dev/null
  cat >> "$STORE/plans-profile.v1.md" <<'EOF'
UNIQUE-CONTENT-MARKER
EOF
  pbrain_profile_commit "$STORE" plans-profile >/dev/null
  run pbrain_profile_new "$STORE" plans-profile
  [ "$status" -eq 0 ]
  [ "$output" = "$STORE/plans-profile.v2.md" ]
  grep -q '^version: 2$' "$STORE/plans-profile.v2.md"
  grep -q '^committed: false$' "$STORE/plans-profile.v2.md"
  grep -q 'UNIQUE-CONTENT-MARKER' "$STORE/plans-profile.v2.md"
  # latest committed is still v1; latest_any is the v2 draft
  run pbrain_profile_latest "$STORE" plans-profile
  [ "$output" = "$STORE/plans-profile.v1.md" ]
  run pbrain_profile_latest_any "$STORE" plans-profile
  [ "$output" = "$STORE/plans-profile.v2.md" ]
  # commit v2 → latest moves to v2, v1 stays on disk as history
  pbrain_profile_commit "$STORE" plans-profile >/dev/null
  run pbrain_profile_latest "$STORE" plans-profile
  [ "$output" = "$STORE/plans-profile.v2.md" ]
  [ -f "$STORE/plans-profile.v1.md" ]
}

@test "new refuses while a draft is open" {
  pbrain_profile_new "$STORE" plans-profile >/dev/null
  run pbrain_profile_new "$STORE" plans-profile
  [ "$status" -ne 0 ]
  [[ "$output" == *"draft already exists"* ]]
}

@test "version numbers sort numerically (v10 > v9)" {
  mkdir -p "$STORE"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf -- '---\nversion: %s\ncommitted: true\n---\nbody v%s\n' "$i" "$i" \
      > "$STORE/plans-profile.v$i.md"
  done
  run pbrain_profile_latest "$STORE" plans-profile
  [ "$output" = "$STORE/plans-profile.v10.md" ]
}

@test "latest skips an uncommitted head and falls back to the highest committed" {
  mkdir -p "$STORE"
  printf -- '---\nversion: 1\ncommitted: true\n---\nv1\n'  > "$STORE/p.v1.md"
  printf -- '---\nversion: 2\ncommitted: false\n---\nv2\n' > "$STORE/p.v2.md"
  run pbrain_profile_latest "$STORE" p
  [ "$output" = "$STORE/p.v1.md" ]
}

@test "pbrain_profile_version parses the filename" {
  run pbrain_profile_version "/x/y/diet-profile.v7.md"
  [ "$output" = "7" ]
}

@test "is_committed is false for a file without frontmatter" {
  mkdir -p "$STORE"
  echo "just text" > "$STORE/p.v1.md"
  ! pbrain_profile_is_committed "$STORE/p.v1.md"
}

@test "two bases coexist independently in one store" {
  pbrain_profile_new "$STORE" work-library >/dev/null
  pbrain_profile_commit "$STORE" work-library >/dev/null
  pbrain_profile_new "$STORE" goals-library >/dev/null
  run pbrain_profile_latest "$STORE" work-library
  [ "$output" = "$STORE/work-library.v1.md" ]
  run pbrain_profile_latest "$STORE" goals-library
  [ -z "$output" ]
  run pbrain_profile_draft "$STORE" goals-library
  [ "$output" = "$STORE/goals-library.v1.md" ]
}

@test "stub created for a fresh base carries a fenced json block" {
  pbrain_profile_new "$STORE" fitness-library >/dev/null
  grep -q '```json' "$STORE/fitness-library.v1.md"
}

@test "pbrain_profile_latest_for_period returns file matching the period" {
  mkdir -p "$STORE"
  # v1 committed, period 2026-05
  printf -- '---\nversion: 1\ncommitted: true\n---\n# weekly\n```json\n{"period":"2026-W20","goals":[]}\n```\n' \
    > "$STORE/weekly-goals.v1.md"
  # v2 committed, period 2026-W24
  printf -- '---\nversion: 2\ncommitted: true\n---\n# weekly\n```json\n{"period":"2026-W24","goals":[]}\n```\n' \
    > "$STORE/weekly-goals.v2.md"
  run pbrain_profile_latest_for_period "$STORE" weekly-goals "2026-W24"
  [ "$status" -eq 0 ]
  [ "$output" = "$STORE/weekly-goals.v2.md" ]
}

@test "pbrain_profile_latest_for_period returns empty on no match" {
  mkdir -p "$STORE"
  printf -- '---\nversion: 1\ncommitted: true\n---\n# weekly\n```json\n{"period":"2026-W20","goals":[]}\n```\n' \
    > "$STORE/weekly-goals.v1.md"
  run pbrain_profile_latest_for_period "$STORE" weekly-goals "2026-W99"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pbrain_profile_latest_for_period returns draft if it matches period" {
  mkdir -p "$STORE"
  # committed v1 is a different week; v2 is a draft for the target week
  printf -- '---\nversion: 1\ncommitted: true\n---\n# weekly\n```json\n{"period":"2026-W20","goals":[]}\n```\n' \
    > "$STORE/weekly-goals.v1.md"
  printf -- '---\nversion: 2\ncommitted: false\n---\n# weekly\n```json\n{"period":"2026-W24","goals":[]}\n```\n' \
    > "$STORE/weekly-goals.v2.md"
  run pbrain_profile_latest_for_period "$STORE" weekly-goals "2026-W24"
  [ "$status" -eq 0 ]
  [ "$output" = "$STORE/weekly-goals.v2.md" ]
}
