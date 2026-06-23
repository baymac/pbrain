#!/usr/bin/env bats
# Tests for the PB-93 self-host staleness guard
# (pbrain_selfhost_staleness_line in lib/projects.sh).
#
# The guard resolves the pbrain repo as PBRAIN_PROJECTS_LIB_DIR/.. — i.e. the
# parent of the dir projects.sh is sourced from. To control the git state under
# test we copy projects.sh (and the libs it needs to source cleanly) into a
# throwaway git repo's lib/ and drive the branch/upstream from there. The guard
# never fetches, so a bare local "origin" we advance by hand stands in for the
# last-fetched origin/main.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off

  # A self-contained "pbrain repo": <root>/lib/projects.sh, so the guard's
  # PBRAIN_PROJECTS_LIB_DIR/.. resolves to <root>.
  FAKE="$TMP/fakerepo"
  mkdir -p "$FAKE/lib"
  cp "$REPO_ROOT/lib/projects.sh" "$FAKE/lib/projects.sh"

  git -C "$FAKE" init -q
  git -C "$FAKE" config user.email t@t.t
  git -C "$FAKE" config user.name t
  # Ensure the default branch is main regardless of git's init.defaultBranch.
  git -C "$FAKE" checkout -q -b main 2>/dev/null || git -C "$FAKE" branch -q -m main
  git -C "$FAKE" add -A
  git -C "$FAKE" commit -q -m "init"
}
teardown() { rm -rf "$TMP"; }

# Source the copied lib and run the guard against $FAKE.
run_guard() {
  run bash -c "source '$FAKE/lib/projects.sh'; pbrain_selfhost_staleness_line"
}

@test "clean main, no origin -> silent" {
  run_guard
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "clean main, up-to-date with origin -> silent" {
  # Bare 'origin' that exactly matches local main.
  git clone -q --bare "$FAKE" "$TMP/origin.git"
  git -C "$FAKE" remote add origin "$TMP/origin.git"
  git -C "$FAKE" fetch -q origin
  git -C "$FAKE" branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
  run_guard
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "detached HEAD -> SELFHOST_STALE HEAD detached" {
  local sha; sha="$(git -C "$FAKE" rev-parse HEAD)"
  git -C "$FAKE" checkout -q "$sha"
  run_guard
  [ "$status" -eq 0 ]
  [ "$output" = "SELFHOST_STALE HEAD detached" ]
}

@test "on a feature branch -> SELFHOST_STALE <branch> branch:<branch>" {
  git -C "$FAKE" checkout -q -b feature/x
  run_guard
  [ "$status" -eq 0 ]
  [ "$output" = "SELFHOST_STALE feature/x branch:feature/x" ]
}

@test "on main but behind origin/main -> SELFHOST_STALE main behind:N" {
  # Build an origin that has 2 commits the local main lacks, WITHOUT advancing
  # local main — emulating a stale checkout against a freshly-fetched origin.
  git clone -q --bare "$FAKE" "$TMP/origin.git"
  git -C "$FAKE" remote add origin "$TMP/origin.git"

  # Advance origin via a second working clone, then fetch into the fake repo.
  git clone -q "$TMP/origin.git" "$TMP/advancer"
  git -C "$TMP/advancer" config user.email t@t.t
  git -C "$TMP/advancer" config user.name t
  echo a > "$TMP/advancer/a"; git -C "$TMP/advancer" add -A; git -C "$TMP/advancer" commit -q -m a
  echo b > "$TMP/advancer/b"; git -C "$TMP/advancer" add -A; git -C "$TMP/advancer" commit -q -m b
  git -C "$TMP/advancer" push -q origin main

  git -C "$FAKE" fetch -q origin
  run_guard
  [ "$status" -eq 0 ]
  [ "$output" = "SELFHOST_STALE main behind:2" ]
}

@test "not a git repo -> silent (never errors)" {
  rm -rf "$FAKE/.git"
  run_guard
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
