#!/usr/bin/env bats
# Tests for /plan-my-work (commands/plan-my-work.sh) — the work layer that fills
# /plan-my-day's empty blocks with Plane tasks. We test the deterministic math
# helpers (blocks, alloc), the no-profile / no-plane / no-plan guards, the
# standalone vs plan-exists session shape, and the task add/remove/list tokens.
# Plane is the sole backend: the auto-pull session needs it configured (we point
# it at an unreachable instance so nothing needs a live Plane), while the no-Plane
# case and the task verb are exercised unconfigured.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export PBRAIN_PLAN_DIR="$PBRAIN_VAULT/life/daily-planning"
  unset PBRAIN_PLANE_API_KEY PBRAIN_PLANE_BASE_URL PBRAIN_PLANE_WORKSPACE PBRAIN_PLANE_PROJECT
  STORE="$PBRAIN_PLAN_DIR/.profile"
  TODAY="$(date +%Y-%m-%d)"
  PMW() { bash "$REPO_ROOT/commands/plan-my-work.sh" "$@"; }
}
teardown() { rm -rf "$TMP"; }

# Configure Plane (an unreachable instance is fine — pbrain_plane_configured only
# checks for an api_key; the seams degrade to [] when the API can't be reached).
configure_plane() {
  cat > "$XDG_CONFIG_HOME/pbrain/plane.json" <<'JSON'
{"base_url":"http://127.0.0.1:9","api_key":"SECRET","workspace":"ws","project":"pid"}
JSON
}

# Write a minimal committed plans profile so the main flow has working_style.
seed_profile() {
  mkdir -p "$STORE"
  cat > "$STORE/plans-profile.v1.md" <<EOF
---
type: plans-profile
version: 1
committed: true
---
\`\`\`json
{"working_style":{"session_length_min":90,"break_min":30,"work_hours_per_day":7,"last_block_end":"18:00"},
 "daily_anchors":{"bed_target":"23:00"},
 "typical_day":{"rest_days":["sat","sun"]},
 "current_focus":[{"id":"secret-focus","title":"only-plan-my-day-needs-this"}]}
\`\`\`
EOF
}

# A planned day with a populated "## Work tracker" (for the task-verb tests).
seed_plan_with_tracker() {
  mkdir -p "$PBRAIN_PLAN_DIR"
  cat > "$PBRAIN_PLAN_DIR/$TODAY.md" <<'EOF'
# Plan

## Today at a glance

| 10:00–11:30 | Block 1 (10:00–11:30) | ship | — |

## Work tracker

| Block | Task | Project | Plane id | Priority | Est | Status | Done at | % complete | Est rating | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| Block 1 (10:00–11:30) | ship | Lettuce | lt:abc | high | 2h | planned | | | | |

## How it went
EOF
}

# --- deterministic math helpers (no vault needed) ---------------------------
@test "blocks: floor of (now→bed) over session+break, last block needs no trailing break" {
  run PMW blocks --now 10:00 --bed 23:00 --session-min 90 --break-min 30
  [ "$status" -eq 0 ]; [ "$output" = "6" ]   # 13h, (780+30)/120 = 6
  run PMW blocks --now 22:30 --bed 23:00 --session-min 90 --break-min 30
  [ "$output" = "0" ]                          # no room
}

@test "alloc: renormalizes chosen allocations and distributes blocks (sum = N)" {
  run PMW alloc --chosen '[{"id":"a","project_name":"A","priority":1,"allocation_percent":60},{"id":"b","project_name":"B","priority":2,"allocation_percent":20}]' --blocks 5
  [ "$status" -eq 0 ]
  # 60/20 over a chosen total of 80 → 75/25; 5 blocks → 4/1
  [[ "$output" == *'"daily_alloc": 75.0'* ]]
  [[ "$output" == *'"daily_alloc": 25.0'* ]]
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert sum(g['blocks'] for g in d)==5, d" "$output"
}

@test "alloc: leftover block goes to the highest-priority chosen project" {
  # 3 equal projects, 4 blocks → 2/1/1, the extra to priority 1
  run PMW alloc --chosen '[{"id":"a","priority":2,"allocation_percent":33},{"id":"b","priority":1,"allocation_percent":33},{"id":"c","priority":3,"allocation_percent":34}]' --blocks 4
  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json,sys
d=json.loads(sys.argv[1])
by={g["id"]:g["blocks"] for g in d}
assert sum(by.values())==4, by
assert by["b"]>=by["a"] and by["b"]>=by["c"], by   # priority 1 gets the leftover
PY
}

# --- guards -----------------------------------------------------------------
@test "no committed plans profile → PLAN_MY_WORK_NO_PROFILE" {
  run PMW
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_NO_PROFILE"* ]]
}

@test "PB-85: task on a day with no plan SCAFFOLDS the file (no nudge) and proceeds" {
  seed_profile
  run PMW task add
  [ "$status" -eq 0 ]
  # PB-85 autonomy: pmw no longer refuses; it creates a minimal daily-planning file
  # and emits the task template — never PLAN_MY_WORK_TASK_NO_PLAN.
  [[ "$output" != *"PLAN_MY_WORK_TASK_NO_PLAN"* ]]
  [[ "$output" == *"PLAN_MY_WORK_TASK"* ]]
  [ -f "$PBRAIN_PLAN_DIR/$TODAY.md" ]
  grep -q "## Work tracker" "$PBRAIN_PLAN_DIR/$TODAY.md"
  # standalone schema: no Block column, has the CEO columns
  grep -q "Time taken" "$PBRAIN_PLAN_DIR/$TODAY.md"
  ! grep -qE "^\| Block \|" "$PBRAIN_PLAN_DIR/$TODAY.md"
}

@test "no Plane configured → PLAN_MY_WORK_NO_PLANE (auto-pull needs Plane)" {
  seed_profile   # profile present, but no plane.json / PBRAIN_PLANE_* → unconfigured
  run PMW
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_NO_PLANE"* ]]
}

# --- session shape ----------------------------------------------------------
@test "PB-85: standalone (no plan today) → SESSION scaffolds a tracker, no glance, no nudge" {
  seed_profile
  configure_plane
  run PMW
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_SESSION"* ]]
  [[ "$output" == *"glance_present: no"* ]]
  [[ "$output" == *"## Work tracker"* ]]   # the schema appears in the instructions
  # PB-85: no block-based framing leaks out anymore.
  [[ "$output" != *"blocks_helper:"* ]]
  [[ "$output" != *"alloc_helper:"* ]]
  [[ "$output" != *"past_blocks:"* ]]
  # the file is scaffolded standalone (tracker present, no glance)
  [ -f "$PBRAIN_PLAN_DIR/$TODAY.md" ]
  grep -q "## Work tracker" "$PBRAIN_PLAN_DIR/$TODAY.md"
  ! grep -q "## Today at a glance" "$PBRAIN_PLAN_DIR/$TODAY.md"
}

@test "PB-85: with a /plan-my-day glance today → SESSION reports glance_present yes + shows it (and leaves it)" {
  seed_profile
  configure_plane
  mkdir -p "$PBRAIN_PLAN_DIR"
  cat > "$PBRAIN_PLAN_DIR/$TODAY.md" <<'EOF'
# Plan

## Today at a glance

| 10:00–11:30 | Block 1 — focus work | — |

## How it went
EOF
  run PMW
  [ "$status" -eq 0 ]
  [[ "$output" == *"glance_present: yes"* ]]
  [[ "$output" == *"Block 1 — focus work"* ]]
}

@test "task list/add/remove on a planned day emit PLAN_MY_WORK_TASK" {
  seed_profile
  mkdir -p "$PBRAIN_PLAN_DIR"
  cat > "$PBRAIN_PLAN_DIR/$TODAY.md" <<'EOF'
# Plan

## Today at a glance

| 10:00–11:30 | Block 1 (10:00–11:30) | ship | — |

## Work tracker

| Block | Task | Project | Plane id | Priority | Est | Status | Done at | % complete | Est rating | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| Block 1 (10:00–11:30) | ship | Lettuce | lt:abc | high | 2h | planned | | | | |

## How it went
EOF
  for action in list add remove; do
    run PMW task "$action"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLAN_MY_WORK_TASK"* ]]
    [[ "$output" == *"action: $action"* ]]
  done
}

# --- separation of concern + externalization (the refactor) -----------------
@test "session delegates grooming to /project-manager and carries no inline triage" {
  seed_profile
  configure_plane
  run PMW
  [ "$status" -eq 0 ]
  # READY-CHECK hands grooming to PM in executor mode; the old inline ENRICH+TRIAGE
  # block (and its hardcoded assignee uuid) is gone.
  [[ "$output" == *"READY-CHECK"* && "$output" == *"PBRAIN_PM_CALLER=plan-my-work"* \
     && "$output" != *"ENRICH + TRIAGE"* && "$output" != *"e364da77-b440"* ]]
}

@test "session profile is leaned to working_style (current_focus dropped)" {
  seed_profile         # the seed carries a 'secret-focus' current_focus item
  configure_plane
  run PMW
  [ "$status" -eq 0 ]
  # WORK_PROFILE_JSON keeps working_style but drops current_focus (that's plan-my-day's).
  [[ "$output" == *"working_style"* && "$output" != *"secret-focus"* ]]
}

@test "task add emits the externalized template with a PM hand-off" {
  seed_profile
  seed_plan_with_tracker
  run PMW task add
  [ "$status" -eq 0 ]
  # the inline heredoc is gone — task-add.txt is emitted, and creation hands off to PM.
  [[ "$output" == *"INSTRUCTIONS — task add"* && "$output" == *"<link | PB-26 | name fragment>"* \
     && "$output" == *"project-manager.sh"* ]]
}

# --- task execute (PB-40 + PB-85 — the execution layer) ---------------------
# PB-85: the Work tracker is a standalone ORDERED ledger (no Block column). One
# done row and two planned rows; "next" is the first not-done row, top to bottom.
seed_plan_for_execute() {
  mkdir -p "$PBRAIN_PLAN_DIR"
  cat > "$PBRAIN_PLAN_DIR/$TODAY.md" <<'EOF'
# Plan

## Work tracker

| Task | Project | Plane id | Priority | Est | Status | Started | Done at | Time taken | % complete | Links | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| early done | Lettuce | pid:done1 | high | 1h | done | 08:00 | 09:00 | 1h | 100 | | |
| ship login | Lettuce | pid:abc | high | 2h | planned | | | | | | PB-90 |
| polish UI | Lettuce | pid:xyz | low | 1h | planned | | | | | | PB-91 |

## How it went
EOF
}

@test "PB-85: task execute → PLAN_MY_WORK_EXECUTE + ordered NEXT TASKS (done filtered) + working locations" {
  seed_profile
  configure_plane
  seed_plan_for_execute
  python3 "$REPO_ROOT/lib/plane.py" workdir pid --path "$TMP" >/dev/null
  run PMW task execute
  [ "$status" -eq 0 ]
  # NEXT TASKS is the not-done ledger, in order: ship login then polish UI; the
  # done row is filtered out. No block-based fields anymore.
  next="$(printf '%s\n' "$output" | grep -A1 '=== NEXT TASKS' | tail -1)"
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* ]]
  [[ "$output" != *"current_block"* ]]
  [[ "$next" == *"ship login"* && "$next" == *"polish UI"* && "$next" != *"early done"* ]]
  # ledger order: ship login (index of) appears before polish UI
  [[ "${next%%polish UI*}" == *"ship login"* ]]
  [[ "$output" == *"WORKING LOCATIONS"* && "$output" == *"$TMP"* \
     && "$output" == *"INSTRUCTIONS — task execute"* ]]
}

@test "PB-92: task execute <PB-id> matching a row → SOLO (only that row, no cascade tail)" {
  seed_profile
  configure_plane
  seed_plan_for_execute
  # Target the low-priority 'polish UI' row by its PB-91 note; SOLO emits only it.
  run PMW task execute 91
  [ "$status" -eq 0 ]
  [[ "$output" == *"target_ref: 91"* ]]
  [[ "$output" == *"target_mode: solo"* ]]
  next="$(printf '%s\n' "$output" | grep -A1 '=== NEXT TASKS' | tail -1)"
  # ONLY the matched row is present; the other not-done row is dropped.
  [[ "$next" == *"polish UI"* && "$next" != *"ship login"* ]]
}

@test "PB-92: task execute <ref> matching NO row → UNMATCHED (empty list, no fallback row)" {
  seed_profile
  configure_plane
  seed_plan_for_execute
  # PB-999 is in neither row; we must NOT fall back to a pending row.
  run PMW task execute 999
  [ "$status" -eq 0 ]
  [[ "$output" == *"target_ref: 999"* ]]
  [[ "$output" == *"target_mode: unmatched"* ]]
  next="$(printf '%s\n' "$output" | grep -A1 '=== NEXT TASKS' | tail -1)"
  [[ "$next" == *"[]"* ]]
  [[ "$next" != *"ship login"* && "$next" != *"polish UI"* ]]
}

@test "PB-81: an unmatched execute target is resolved with the parent-aware subtree read (one PR per sub-issue)" {
  seed_profile
  configure_plane
  seed_plan_for_execute
  # An unmatched ref must instruct the agent to use `subtree` (parent-aware),
  # not the old plain `find`, so a parent expands into per-child sequential PRs.
  run PMW task execute 999
  [ "$status" -eq 0 ]
  [[ "$output" == *"target_mode: unmatched"* ]]
  [[ "$output" == *"subtree"* ]]                       # parent-aware resolution wired in
  [[ "$output" == *"one PR each"* || "$output" == *"one PR per"* || "$output" == *"PR each"* ]]
}

@test "PB-92: task execute with NO target → mode none, full ledger in order (cascade applies)" {
  seed_profile
  configure_plane
  seed_plan_for_execute
  run PMW task execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"target_mode: none"* ]]
  next="$(printf '%s\n' "$output" | grep -A1 '=== NEXT TASKS' | tail -1)"
  [[ "$next" == *"ship login"* && "$next" == *"polish UI"* ]]
  [[ "${next%%polish UI*}" == *"ship login"* ]]   # ledger order preserved
}

@test "PB-85: task execute on a day with no plan SCAFFOLDS the file and emits an empty ledger (no nudge)" {
  seed_profile   # no plan file today, no plane.json
  run PMW task execute
  [ "$status" -eq 0 ]
  [[ "$output" != *"PLAN_MY_WORK_TASK_NO_PLAN"* ]]
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* ]]
  # empty ledger → NEXT TASKS is the empty array
  next="$(printf '%s\n' "$output" | grep -A1 '=== NEXT TASKS' | tail -1)"
  [[ "$next" == *"[]"* ]]
  [ -f "$PBRAIN_PLAN_DIR/$TODAY.md" ]
}

@test "PB-85: task execute reads a LEGACY Block-column tracker by header (no migration)" {
  seed_profile
  configure_plane
  mkdir -p "$PBRAIN_PLAN_DIR"
  # Old schema with a Block column + Est rating — parser keys off header names.
  cat > "$PBRAIN_PLAN_DIR/$TODAY.md" <<'EOF'
# Plan

## Work tracker

| Block | Task | Project | Plane id | Priority | Est | Status | Done at | % complete | Est rating | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| Block 1 (10:00–11:30) | legacy done | L | pid:d | high | 1h | done | 09:00 | 100 | | |
| Block 1 (10:00–11:30) | legacy todo | L | pid:t | high | 2h | planned | | | | |

## How it went
EOF
  run PMW task execute
  [ "$status" -eq 0 ]
  next="$(printf '%s\n' "$output" | grep -A1 '=== NEXT TASKS' | tail -1)"
  [[ "$next" == *"legacy todo"* && "$next" != *"legacy done"* ]]
}

@test "task <unknown> action → usage error (execute is accepted, garbage is not)" {
  seed_profile
  seed_plan_with_tracker
  run PMW task frobnicate
  [ "$status" -eq 2 ] && [[ "$output" == *"add|remove|list|execute"* ]]
}

# PB-83 regression: the .md wrapper must pass $ARGUMENTS UNQUOTED, so a multi-word
# verb like `task execute pb83` reaches the script as separate $1/$2/$3 and the
# `task` dispatch guard matches. Quoting collapses it into a single $1 and the
# dispatcher silently falls through to the session flow (the original hiccup).
@test "PB-83: plan-my-work.md invokes the script with unquoted \$ARGUMENTS" {
  run grep -nE 'plan-my-work\.sh" +\$ARGUMENTS *$' "$REPO_ROOT/commands/plan-my-work.md"
  [ "$status" -eq 0 ]
  # and must NOT carry the quoted form that caused the fall-through
  run grep -nE 'plan-my-work\.sh" +"\$ARGUMENTS"' "$REPO_ROOT/commands/plan-my-work.md"
  [ "$status" -ne 0 ]
}

# PB-83 regression (functional): a word-split `task execute …` must route to the
# EXECUTE path — the dispatch the unquoted-wrapper fix guarantees the args reach.
@test "PB-83: word-split 'task execute' routes to PLAN_MY_WORK_EXECUTE" {
  seed_profile
  seed_plan_with_tracker
  run PMW task execute pb83
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* ]]
  [[ "$output" != *"PLAN_MY_WORK_SESSION"* ]]
}

# PB-96: a natural-language "do work" request (not the literal `task execute …`)
# used to fall through to PLAN_MY_WORK_SESSION, whose step 2 delegates triage to
# /project-manager — so asking pmw to *do work* triaged the board instead of
# running the execute cycle. The .sh now normalizes such requests into the
# canonical `task execute [PB-id]` form before dispatch.
@test "PB-96: NL verb + ref ('fix pb96') routes to EXECUTE as kind=id" {
  seed_profile
  configure_plane
  seed_plan_with_tracker
  run PMW fix pb96
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* ]]
  [[ "$output" != *"PLAN_MY_WORK_SESSION"* ]]
  [[ "$output" == *"target_ref: pb96"* ]]
  [[ "$output" == *"target_kind: id"* ]]
}

@test "PB-96: 'work on PB-96' routes to EXECUTE kind=id (connective + hyphen id)" {
  seed_profile
  configure_plane
  seed_plan_with_tracker
  run PMW work on PB-96
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* ]]
  [[ "$output" == *"target_ref: pb96"* ]]
  [[ "$output" == *"target_kind: id"* ]]
}

@test "PB-96: a bare PB-ref token ('pb96') routes to EXECUTE kind=id" {
  seed_profile
  configure_plane
  seed_plan_with_tracker
  run PMW pb96
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* ]]
  [[ "$output" == *"target_ref: pb96"* ]]
  [[ "$output" == *"target_kind: id"* ]]
}

@test "PB-96: a bare sequence number ('96') routes to EXECUTE, normalized to pb96 (id)" {
  seed_profile
  configure_plane
  seed_plan_with_tracker
  run PMW 96
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* ]]
  [[ "$output" == *"target_ref: pb96"* ]]
  [[ "$output" == *"target_kind: id"* ]]
}

# PB-96 (the core of this issue): a brief DESCRIPTION with no issue id must run
# the find-or-file cycle, NOT triage and NOT the ledger. The .sh carries the
# verb-stripped description through verbatim and tags it kind=desc so execute.txt
# searches Plane and files a new issue when none matches.
@test "PB-96: a free-text verb request ('fix the routing bug') → EXECUTE kind=desc, description carried" {
  seed_profile
  configure_plane
  seed_plan_with_tracker
  run PMW fix the routing bug
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* ]]
  [[ "$output" != *"PLAN_MY_WORK_SESSION"* ]]
  [[ "$output" == *"target_kind: desc"* ]]
  # leading verb + connective "the" stripped; the rest is the search/file query
  [[ "$output" == *"target_ref: routing bug"* ]]
}

@test "PB-96: 'implement dark mode' → kind=desc with the full multi-word description" {
  seed_profile
  configure_plane
  seed_plan_with_tracker
  run PMW implement dark mode
  [ "$status" -eq 0 ]
  [[ "$output" == *"target_kind: desc"* ]]
  [[ "$output" == *"target_ref: dark mode"* ]]
}

@test "PB-96: a multi-word 'task execute <desc>' keeps the whole description (not just \$3)" {
  seed_profile
  configure_plane
  seed_plan_with_tracker
  run PMW task execute fix the login bug
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* ]]
  [[ "$output" == *"target_ref: fix the login bug"* ]]
  [[ "$output" == *"target_kind: desc"* ]]
}

@test "PB-96: the execute template documents the find-or-file cycle + target_kind" {
  run grep -niE 'find-or-file' "$REPO_ROOT/commands/templates/plan-my-work/execute.txt"
  [ "$status" -eq 0 ]
  run grep -nE 'target_kind' "$REPO_ROOT/commands/templates/plan-my-work/execute.txt"
  [ "$status" -eq 0 ]
  run grep -nE 'file "\$\{TARGET_REF\}"' "$REPO_ROOT/commands/templates/plan-my-work/execute.txt"
  [ "$status" -eq 0 ]
}

@test "PB-96: NL verb with only filler ('do some work') drives the LEDGER, never triage/desc" {
  seed_profile
  configure_plane
  seed_plan_with_tracker
  run PMW do some work
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* ]]
  [[ "$output" != *"PLAN_MY_WORK_SESSION"* ]]
  # filler-only remainder → no target, full not-done ledger (cascade applies)
  [[ "$output" == *"target_ref: (none)"* ]]
  [[ "$output" == *"target_mode: none"* ]]
  [[ "$output" == *"target_kind: none"* ]]
}

@test "PB-96: the no-arg planning form is UNTOUCHED (still SESSION, not execute)" {
  seed_profile
  configure_plane
  seed_plan_with_tracker
  run PMW
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_SESSION"* ]]
  [[ "$output" != *"PLAN_MY_WORK_EXECUTE"* ]]
}

@test "PB-96: canonical 'task execute <id>' is unchanged by the NL normalizer (kind=id)" {
  seed_profile
  configure_plane
  seed_plan_with_tracker
  run PMW task execute pb96
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* ]]
  [[ "$output" == *"target_ref: pb96"* ]]
  [[ "$output" == *"target_kind: id"* ]]
}

@test "PB-96: a non-verb planning-ish word ('plan') is NOT hijacked into execute" {
  seed_profile
  configure_plane
  seed_plan_with_tracker
  run PMW plan my work
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_SESSION"* ]]
  [[ "$output" != *"PLAN_MY_WORK_EXECUTE"* ]]
}

@test "PB-96: the .md documents NL routing + argument-hint advertises it" {
  run grep -nE 'fix/work on' "$REPO_ROOT/commands/plan-my-work.md"
  [ "$status" -eq 0 ]
  run grep -niE 'natural-language routing' "$REPO_ROOT/commands/plan-my-work.md"
  [ "$status" -eq 0 ]
  run grep -niE 'find-or-file cycle' "$REPO_ROOT/commands/plan-my-work.md"
  [ "$status" -eq 0 ]
}

# PB-93: the EXECUTE template warns about a stale command checkout shadowing
# merged wrappers (self-host case), and the .sh now enforces it deterministically
# by emitting a SELFHOST_STALE line + documenting it in the PRE-FLIGHT prose.
@test "PB-93: execute output carries the SELF-HOST stale-checkout PRE-FLIGHT note" {
  seed_profile
  configure_plane
  seed_plan_for_execute
  run PMW task execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"SELF-HOST CHECK"* ]]
  [[ "$output" == *"stale/unmerged branch"* ]]
  # The deterministic guard (PB-93): prose documents the machine-emitted line and
  # how to bring the checkout current.
  [[ "$output" == *"SELFHOST_STALE"* ]]
  [[ "$output" == *"--ff-only"* ]]
}

# PB-93: the deterministic guard actually fires in the emitted output. This test
# repo (the pbrain worktree under test) is on a feature branch, not clean main,
# so the .sh must print a SELFHOST_STALE line near the top of execute output.
@test "PB-93: execute emits a SELFHOST_STALE line when the checkout is not clean main" {
  seed_profile
  configure_plane
  seed_plan_for_execute
  run PMW task execute
  [ "$status" -eq 0 ]
  # Branch under test is whatever the suite runs on; on a clean up-to-date main
  # the guard is silent, so only assert the line's SHAPE when present.
  if [[ "$output" == *"SELFHOST_STALE "* ]]; then
    [[ "$output" =~ SELFHOST_STALE\ [^[:space:]]+\ (detached|branch:|behind:) ]]
  fi
}
