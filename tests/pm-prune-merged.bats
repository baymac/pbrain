#!/usr/bin/env bats
# Tests for `/project-manager prune-merged` — the post-merge worktree GC verb
# (PB-141 follow-on). Unlike the rest of project-manager.bats, this verb operates
# on a REAL git repo (not PBRAIN_VAULT), so setup() builds a throwaway repo in $TMP
# with several worktrees covering every gate:
#   pbrain/merged   — fast-forwarded into base            → PRUNED (empty-files arm)
#   pbrain/squash   — branch commit + unrelated base commit, content in base
#                                                          → PRUNED (file-scoped arm,
#                                                            the squash-safety guarantee)
#   pbrain/unmerged — divergent change never landed        → KEPT-unmerged
#   pbrain/dirty    — content-merged but uncommitted edits  → KEPT-dirty
# Plane is never configured — prune-merged is pure git and not Plane-gated.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  PM() { bash "$REPO_ROOT/commands/project-manager.sh" "$@"; }

  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

  R="$TMP/repo"; mkdir -p "$R"
  git -C "$R" init -q -b main
  echo base > "$R/file.txt"; git -C "$R" add -A; git -C "$R" commit -qm init
  # Simulate origin/main without a network remote: a local ref both gates read.
  git -C "$R" update-ref refs/remotes/origin/main main

  # --- merged-clean (fast-forward arm): branch's change is landed into base verbatim
  git -C "$R" worktree add -q -b pbrain/merged "$TMP/wt-merged" main
  echo landed > "$TMP/wt-merged/file.txt"
  git -C "$TMP/wt-merged" commit -qam "merge me"
  git -C "$R" merge -q --ff-only pbrain/merged
  git -C "$R" update-ref refs/remotes/origin/main main

  # --- squash-arm: branch commits, then base gets an UNRELATED commit afterward, so
  # the fork-point differs from base tip (files non-empty) but the branch's own file
  # content is already in base (file-scoped diff == 0). This is the squash-merge case.
  git -C "$R" worktree add -q -b pbrain/squash "$TMP/wt-squash" main
  echo squashed > "$TMP/wt-squash/s.txt"
  git -C "$TMP/wt-squash" add -A; git -C "$TMP/wt-squash" commit -qm "squash work"
  # land the same content into base via a separate commit (the squash), THEN an unrelated one
  echo squashed > "$R/s.txt"; git -C "$R" add -A; git -C "$R" commit -qm "squash of pbrain/squash"
  echo unrelated > "$R/u.txt"; git -C "$R" add -A; git -C "$R" commit -qm "unrelated base change"
  git -C "$R" update-ref refs/remotes/origin/main main

  # --- unmerged: a divergent change that never landed into base
  git -C "$R" worktree add -q -b pbrain/unmerged "$TMP/wt-unmerged" main
  echo wip > "$TMP/wt-unmerged/other.txt"
  git -C "$TMP/wt-unmerged" add -A; git -C "$TMP/wt-unmerged" commit -qm "wip"

  # --- merged-but-dirty: branch points at base (merged) but tree has uncommitted edits
  git -C "$R" worktree add -q -b pbrain/dirty "$TMP/wt-dirty" main   # tip == base now
  echo scratch > "$TMP/wt-dirty/file.txt"                            # uncommitted → dirty
}
teardown() { rm -rf "$TMP"; }

@test "prune-merged removes merged + squash-merged worktrees, keeps unmerged + dirty" {
  run PM prune-merged --repo "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PM_PRUNE_MERGED"* ]]
  [[ "$output" == *"PRUNED $TMP/wt-merged pbrain/merged"* ]]
  [[ "$output" == *"PRUNED $TMP/wt-squash pbrain/squash"* ]]
  [[ "$output" == *"KEPT-unmerged $TMP/wt-unmerged pbrain/unmerged"* ]]
  [[ "$output" == *"KEPT-dirty $TMP/wt-dirty pbrain/dirty"* ]]
  # merged worktrees + branches actually gone
  [ ! -d "$TMP/wt-merged" ]
  [ ! -d "$TMP/wt-squash" ]
  run git -C "$R" rev-parse --verify -q pbrain/merged
  [ "$status" -ne 0 ]
  run git -C "$R" rev-parse --verify -q pbrain/squash
  [ "$status" -ne 0 ]
  # the others survive (worktree + branch)
  [ -d "$TMP/wt-unmerged" ]
  [ -d "$TMP/wt-dirty" ]
  run git -C "$R" rev-parse --verify -q pbrain/unmerged
  [ "$status" -eq 0 ]
}

@test "prune-merged summary line counts pruned/kept/skipped" {
  run PM prune-merged --repo "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pruned=2 kept=2 skipped=0"* ]]
}

@test "dry-run previews PRUNED but removes nothing" {
  run PM prune-merged --repo "$R" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRUNED $TMP/wt-merged pbrain/merged (dry-run"* ]]
  [[ "$output" == *"(dry-run)"* ]]
  [ -d "$TMP/wt-merged" ]   # still there
  run git -C "$R" rev-parse --verify -q pbrain/merged
  [ "$status" -eq 0 ]
}

@test "non-pbrain worktrees are skipped, never touched" {
  git -C "$R" worktree add -q -b feature/x "$TMP/wt-feat" main
  run PM prune-merged --repo "$R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIPPED-not-pbrain $TMP/wt-feat feature/x"* ]]
  [ -d "$TMP/wt-feat" ]
}

@test "the primary checkout is never pruned even when on a pbrain branch" {
  # Put the main checkout itself on a pbrain/* branch — it must be exempt.
  git -C "$R" checkout -q -b pbrain/onmain
  run PM prune-merged --repo "$R"
  [ "$status" -eq 0 ]
  # main checkout dir still exists and its branch survives
  [ -d "$R" ]
  run git -C "$R" rev-parse --verify -q pbrain/onmain
  [ "$status" -eq 0 ]
  [[ "$output" != *"PRUNED $R "* ]]
}

@test "not-a-git-repo degrades to PMR_ERR, never a stack trace" {
  run PM prune-merged --repo "$TMP/nope"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PMR_ERR not-a-git-repo"* ]]
  [[ "$output" != *"Traceback"* ]]
  [[ "$output" != *"fatal:"* ]]
}

@test "missing base ref falls back gracefully to PMR_ERR" {
  run PM prune-merged --repo "$R" --base origin/does-not-exist
  [ "$status" -eq 0 ]
  [[ "$output" == *"PMR_ERR base-ref-missing: origin/does-not-exist"* ]]
}

@test "prune-merged is recognized as a verb (not routed to NL)" {
  run PM prune-merged --repo "$R" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"PM_PRUNE_MERGED"* ]]
  [[ "$output" != *"PM_ROUTE"* ]]
}
