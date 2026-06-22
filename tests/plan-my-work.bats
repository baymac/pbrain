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

@test "task on a day with no plan → PLAN_MY_WORK_TASK_NO_PLAN" {
  seed_profile
  run PMW task add
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_TASK_NO_PLAN"* ]]
}

@test "no Plane configured → PLAN_MY_WORK_NO_PLANE (auto-pull needs Plane)" {
  seed_profile   # profile present, but no plane.json / PBRAIN_PLANE_* → unconfigured
  run PMW
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_NO_PLANE"* ]]
}

# --- session shape ----------------------------------------------------------
@test "standalone (no plan today) → SESSION with plan_exists no + helper hints" {
  seed_profile
  configure_plane
  run PMW
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_SESSION"* ]]
  [[ "$output" == *"plan_exists: no"* ]]
  [[ "$output" == *"blocks_helper:"* ]]
  [[ "$output" == *"alloc_helper:"* ]]
  [[ "$output" == *"## Work tracker"* ]]   # the schema appears in the instructions
}

@test "with a plan today → SESSION with plan_exists yes + the plan is shown" {
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
  [[ "$output" == *"plan_exists: yes"* ]]
  [[ "$output" == *"Block 1 — focus work"* ]]
}

@test "PB-53: SESSION flags elapsed work blocks as past, leaves future blocks out" {
  seed_profile
  configure_plane
  mkdir -p "$PBRAIN_PLAN_DIR"
  cat > "$PBRAIN_PLAN_DIR/$TODAY.md" <<'EOF'
# Plan

## Today at a glance

| 10:00–11:00 | Block 1 — focus work | — |
| 14:00–15:00 | Block 2 — focus work | — |

## How it went
EOF
  PBRAIN_NOW=12:00 run PMW
  [ "$status" -eq 0 ]
  # now=12:00 → Block 1 (10:00) is past, Block 2 (14:00) is future
  [[ "$output" == *"past_blocks: Block 1 (10:00–11:00)"* ]]
  past_line="$(printf '%s\n' "$output" | grep '^past_blocks:')"
  [[ "$past_line" != *"Block 2"* ]]
}

@test "PB-53: nothing is past on an early-morning run" {
  seed_profile
  configure_plane
  mkdir -p "$PBRAIN_PLAN_DIR"
  cat > "$PBRAIN_PLAN_DIR/$TODAY.md" <<'EOF'
# Plan

## Today at a glance

| 10:00–11:00 | Block 1 — focus work | — |

## How it went
EOF
  PBRAIN_NOW=07:00 run PMW
  [ "$status" -eq 0 ]
  [[ "$output" == *"past_blocks: (none)"* ]]
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

# --- task execute (PB-40 — the execution layer) -----------------------------
# A planned day with a full-day block (always contains `now`), one done row and
# one planned row in its Work tracker. Used by the execute happy-path test.
seed_plan_for_execute() {
  mkdir -p "$PBRAIN_PLAN_DIR"
  cat > "$PBRAIN_PLAN_DIR/$TODAY.md" <<'EOF'
# Plan

## Today at a glance

| 00:00–23:59 | Block 1 (00:00–23:59) | ship | — |

## Work tracker

| Block | Task | Project | Plane id | Priority | Est | Status | Done at | % complete | Est rating | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| Block 1 (00:00–23:59) | early done | Lettuce | pid:done1 | high | 1h | done | 09:00 | 100 | | |
| Block 1 (00:00–23:59) | ship login | Lettuce | pid:abc | high | 2h | planned | | | | |

## How it went
EOF
}

@test "task execute → PLAN_MY_WORK_EXECUTE + current block + not-done tasks + working locations" {
  seed_profile
  configure_plane
  seed_plan_for_execute
  # Record a working location for the lone project (pure config write, no network).
  python3 "$REPO_ROOT/lib/plane.py" workdir pid --path "$TMP" >/dev/null
  run PMW task execute
  [ "$status" -eq 0 ]
  # Isolate the CURRENT BLOCK TASKS json line so done-filtering is checked there,
  # not in the full plan dump (which echoes the done row too).
  tasks="$(printf '%s\n' "$output" | grep -A1 '=== CURRENT BLOCK TASKS' | tail -1)"
  [[ "$output" == *"PLAN_MY_WORK_EXECUTE"* && "$output" == *"current_block: Block 1 (00:00"* \
     && "$tasks" == *"ship login"* && "$tasks" != *"early done"* \
     && "$output" == *"WORKING LOCATIONS"* && "$output" == *"$TMP"* \
     && "$output" == *"INSTRUCTIONS — task execute"* ]]
}

@test "task execute on a day with no plan → PLAN_MY_WORK_TASK_NO_PLAN (no Plane needed)" {
  seed_profile   # no plan file today, no plane.json — the task guard fires first
  run PMW task execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN_MY_WORK_TASK_NO_PLAN"* ]]
}

@test "task execute → current_block none when now is past the day's last block" {
  seed_profile
  configure_plane
  # Build a block that safely ENDS before now (guard the first minute of the day).
  now_min=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  if [ "$now_min" -lt 2 ]; then skip "too close to midnight to place a past block"; fi
  end=$(( now_min - 1 )); start=$(( end - 1 )); [ "$start" -lt 0 ] && start=0
  printf -v range '%02d:%02d–%02d:%02d' $((start/60)) $((start%60)) $((end/60)) $((end%60))
  mkdir -p "$PBRAIN_PLAN_DIR"
  cat > "$PBRAIN_PLAN_DIR/$TODAY.md" <<EOF
# Plan

## Today at a glance

| $range | Block 1 ($range) | ship | — |

## Work tracker

| Block | Task | Project | Plane id | Priority | Est | Status | Done at | % complete | Est rating | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| Block 1 ($range) | ship login | Lettuce | pid:abc | high | 2h | planned | | | | |

## How it went
EOF
  run PMW task execute
  [ "$status" -eq 0 ] && [[ "$output" == *"current_block: none"* ]]
}

@test "task <unknown> action → usage error (execute is accepted, garbage is not)" {
  seed_profile
  seed_plan_with_tracker
  run PMW task frobnicate
  [ "$status" -eq 2 ] && [[ "$output" == *"add|remove|list|execute"* ]]
}
