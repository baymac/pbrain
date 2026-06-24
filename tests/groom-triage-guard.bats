#!/usr/bin/env bats
# Tests the autonomous-groom PreToolUse gatekeeper (lib/hooks/groom-triage-guard.sh):
# it must HARD-BLOCK execution/git/PR/edit commands while ALLOWING Plane triage, and
# stay inert unless PBRAIN_GROOM_TRIAGE_GUARD=1.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HOOK="$REPO_ROOT/lib/hooks/groom-triage-guard.sh"
}

# emit a PreToolUse event and return 0 if the hook DENIED it.
denied() {
  local tool="${1:?}" cmd="${2-}"
  local payload
  payload="$(python3 -c '
import json,sys
print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"command": sys.argv[2]}}))
' "$tool" "$cmd")"
  printf '%s' "$payload" | PBRAIN_GROOM_TRIAGE_GUARD=1 bash "$HOOK" | grep -q '"deny"'
}

@test "guard is INERT unless PBRAIN_GROOM_TRIAGE_GUARD=1" {
  run bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push\"}}' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # no deny emitted when the guard isn't armed
}

@test "guard BLOCKS git in command position (and via separators / rtk / sudo)" {
  denied Bash 'git status'
  denied Bash 'git push origin main'
  denied Bash 'cd /x && git commit -m y'
  denied Bash 'rtk git status'
  denied Bash 'sudo git pull'
  denied Bash 'echo hi | git apply'
}

@test "guard BLOCKS gh / PR / shipping verbs" {
  denied Bash 'gh pr create --fill'
  denied Bash 'make deploy'
  denied Bash 'npm run deploy'
}

@test "guard BLOCKS /plan-my-work (execution) anywhere" {
  denied Bash 'bash plan-my-work.sh task execute PB-1'
  denied Bash 'bash "$X/commands/plan-my-work.sh" PB-9'
}

@test "guard BLOCKS repo-edit tools" {
  denied Edit ''
  denied Write ''
  denied NotebookEdit ''
}

@test "guard ALLOWS Plane triage commands (no false positives on 'git' in text)" {
  ! denied Bash 'python3 lib/plane.py tag --tie x --add auto:plan,auto:implement'
  ! denied Bash 'python3 lib/plane.py enrich --edits "[{\"field\":\"description\",\"value\":\"set up git hooks\"}]"'
  ! denied Bash 'python3 lib/plane.py comment --tie x --body "this needs a git workflow doc"'
  ! denied Bash 'bash "${PBRAIN_DEV_DIR:-x}/commands/project-manager.sh" groom run'
  ! denied Bash 'echo digital && python3 lib/plane.py ready --ordered'
}
