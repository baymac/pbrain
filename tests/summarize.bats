#!/usr/bin/env bats
# Tests for /summarize (commands/summarize.sh) — summarize a vault folder of
# notes/transcripts into a faithful, prompt-driven summary under agent-work/.
# We exercise the pure, network-free pieces: the `gather` corpus builder
# (recursive .md/.txt walk + file headers + dotdir skipping) and the
# argument-routing / input-resolution guards (usage, unknown type, missing
# input, not-found, outside-vault, empty folder). The actual reframing is the
# model's job and isn't covered here.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  SUM() { bash "$REPO_ROOT/commands/summarize.sh" "$@"; }
}
teardown() { rm -rf "$TMP"; }

# A small webinar folder under the vault with two transcript files + a dotdir
# that must be ignored.
write_webinar_folder() {
  mkdir -p "$PBRAIN_VAULT/Trading/Webinars/June/.obsidian"
  cat > "$PBRAIN_VAULT/Trading/Webinars/June/part1.md" <<'MD'
Use the scanner to find breakouts on SPY.
MD
  cat > "$PBRAIN_VAULT/Trading/Webinars/June/part2.txt" <<'TXT'
Risk one percent per trade on crude oil futures.
TXT
  # Noise that must NOT be gathered: a dotfile and a non-text extension.
  echo "ignore me" > "$PBRAIN_VAULT/Trading/Webinars/June/.notes.md"
  echo "binary-ish" > "$PBRAIN_VAULT/Trading/Webinars/June/cover.png"
  echo "from obsidian config" > "$PBRAIN_VAULT/Trading/Webinars/June/.obsidian/app.json"
}

# ---- gather (pure) ---------------------------------------------------------

@test "gather concatenates .md/.txt with per-file headers in sorted order" {
  write_webinar_folder
  run SUM gather "$PBRAIN_VAULT/Trading/Webinars/June"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--- part1.md ---"* ]]
  [[ "$output" == *"Use the scanner to find breakouts on SPY."* ]]
  [[ "$output" == *"--- part2.txt ---"* ]]
  [[ "$output" == *"Risk one percent per trade on crude oil futures."* ]]
  # part1 sorts before part2.
  [[ "$output" == *"part1.md"*"part2.txt"* ]]
}

@test "gather skips dotfiles, dotdirs, and non-text extensions" {
  write_webinar_folder
  run SUM gather "$PBRAIN_VAULT/Trading/Webinars/June"
  [ "$status" -eq 0 ]
  [[ "$output" != *".notes.md"* ]]
  [[ "$output" != *"app.json"* ]]
  [[ "$output" != *"cover.png"* ]]
}

@test "gather on a missing dir is silent and non-fatal" {
  run SUM gather "$TMP/nope"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "gather honors PBRAIN_SUMMARIZE_EXTS" {
  write_webinar_folder
  export PBRAIN_SUMMARIZE_EXTS="txt"
  run SUM gather "$PBRAIN_VAULT/Trading/Webinars/June"
  [ "$status" -eq 0 ]
  [[ "$output" == *"part2.txt"* ]]
  [[ "$output" != *"part1.md"* ]]
}

# ---- routing + resolution guards -------------------------------------------

@test "no args prints usage" {
  run SUM
  [ "$status" -eq 0 ] && [[ "$output" == *"SUMMARIZE_USAGE"* ]]
}

@test "usage lists the webinar subcommand" {
  run SUM
  [ "$status" -eq 0 ] && [[ "$output" == *"webinar"* ]]
}

@test "unknown content type is reported, not crashed" {
  run SUM podcast "$PBRAIN_VAULT/whatever"
  [ "$status" -eq 0 ] && [[ "$output" == *"SUMMARIZE_UNKNOWN_TYPE"* ]]
}

@test "type with no folder asks for one" {
  run SUM webinar
  [ "$status" -eq 0 ] && [[ "$output" == *"SUMMARIZE_NO_INPUT"* ]]
}

@test "filler tokens between type and path are ignored (still need a real path)" {
  run SUM webinar summarize this folder
  [ "$status" -eq 0 ] && [[ "$output" == *"SUMMARIZE_NO_INPUT"* ]]
}

@test "a missing vault folder is reported as not found" {
  run SUM webinar "Trading/Does/Not/Exist"
  [ "$status" -eq 0 ] && [[ "$output" == *"SUMMARIZE_NOT_FOUND"* ]] \
    && [[ "$output" == *"reason: missing"* ]]
}

@test "a path outside the vault is refused" {
  run SUM webinar "/etc"
  [ "$status" -eq 0 ] && [[ "$output" == *"SUMMARIZE_NOT_FOUND"* ]] \
    && [[ "$output" == *"reason: outside-vault"* ]]
}

@test "an empty folder (no md/txt) is reported" {
  mkdir -p "$PBRAIN_VAULT/Empty"
  echo "binary" > "$PBRAIN_VAULT/Empty/cover.png"
  run SUM webinar "Empty"
  [ "$status" -eq 0 ] && [[ "$output" == *"SUMMARIZE_EMPTY"* ]]
}

@test "a real webinar folder routes to SUMMARIZE_WRITE with corpus + output path" {
  write_webinar_folder
  run SUM webinar "Trading/Webinars/June"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUMMARIZE_WRITE"* ]]
  [[ "$output" == *"type: webinar"* ]]
  [[ "$output" == *"file_count: 2"* ]]
  [[ "$output" == *"RAW CORPUS"* ]]
  [[ "$output" == *"crude oil futures"* ]]
  # output path lands under agent-work/summaries/webinar/ with the folder slug.
  [[ "$output" == *"agent-work/summaries/webinar/june.md"* ]]
  # the per-type template instructions are appended.
  [[ "$output" == *"WEBINAR SUMMARIZE PROMPT"* ]]
}

@test "an Obsidian [[link]] resolves the same as a plain path" {
  write_webinar_folder
  run SUM webinar "[[Trading/Webinars/June]]"
  [ "$status" -eq 0 ] && [[ "$output" == *"SUMMARIZE_WRITE"* ]] \
    && [[ "$output" == *"file_count: 2"* ]]
}

@test "PBRAIN_SUMMARIZE_DIR overrides the output parent" {
  write_webinar_folder
  export PBRAIN_SUMMARIZE_DIR="$TMP/out"
  run SUM webinar "Trading/Webinars/June"
  [ "$status" -eq 0 ] && [[ "$output" == *"$TMP/out/webinar/june.md"* ]]
}
