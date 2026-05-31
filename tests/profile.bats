#!/usr/bin/env bats
# Tests for lib/profile.sh — pbrain_profile_json.
#
# The goals profile is a vault markdown note carrying its structured data in a
# fenced ```json block. This extractor is the single point that pulls that JSON
# back out for /plan-my-day, /loose-ends, and /weekly-review, plus the
# back-compat path for the old raw-JSON config file.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  source "$REPO_ROOT/lib/profile.sh"
}

teardown() {
  rm -rf "$TMP"
}

@test "extracts JSON from a fenced block in a markdown note" {
  cat > "$TMP/p.md" <<'EOF'
---
type: profile
date: 2026-05-31
tags: []
---

# Goals profile

intro line

```json
{ "current_focus": [ { "goal": "ship pbrain" } ] }
```
EOF
  run pbrain_profile_json "$TMP/p.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"goal": "ship pbrain"'* ]]
  # Output must itself be valid JSON (no frontmatter / prose bleed-through).
  echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "falls back to whole-file raw JSON (old config format)" {
  echo '{ "current_focus": [] }' > "$TMP/p.json"
  run pbrain_profile_json "$TMP/p.json"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; json.load(sys.stdin)'
}

@test "emits nothing when the fenced block is malformed JSON" {
  cat > "$TMP/bad.md" <<'EOF'
```json
{ not valid json,, }
```
EOF
  run pbrain_profile_json "$TMP/bad.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emits nothing for a missing file" {
  run pbrain_profile_json "$TMP/nope.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emits nothing and returns 0 with no argument" {
  run pbrain_profile_json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prose with no JSON block emits nothing" {
  printf '# Goals\n\njust some notes, no data block\n' > "$TMP/prose.md"
  run pbrain_profile_json "$TMP/prose.md"
  [ -z "$output" ]
}
