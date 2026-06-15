#!/usr/bin/env bats
# Tests for lib/vault.sh — the shared VAULT_DIR resolver — focused on the
# zero-config ~/pbrain-vault auto-fallback (resolution step 4) and its opt-out.
#
# Run with:  bats tests/

setup() {
  bats_require_minimum_version 1.5.0
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  # Sandbox HOME + config so the iCloud default path doesn't exist and the
  # auto-created vault lands inside TMP.
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  export XDG_CONFIG_HOME="$TMP/home/.config"
  # Keep the run hermetic: no migrations, no network update-check (dev install).
  export PBRAIN_MIGRATIONS=0
  export PBRAIN_DEV_DIR="$REPO_ROOT"
  unset PBRAIN_VAULT PBRAIN_NO_AUTOVAULT
}

teardown() {
  rm -rf "$TMP"
}

# Source vault.sh in a clean subshell and report the resolved VAULT_DIR.
resolve() {
  bash -c "source '$REPO_ROOT/lib/vault.sh'; echo \"RESOLVED=\$VAULT_DIR\""
}

@test "no vault configured → auto-creates ~/pbrain-vault and resolves to it" {
  run resolve
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESOLVED=$HOME/pbrain-vault"* ]]
  [ -d "$HOME/pbrain-vault" ]
  [ -f "$HOME/pbrain-vault/.gitignore" ]
  [ -f "$HOME/pbrain-vault/CLAUDE.md" ]
  # config file now points at the new vault
  [ "$(cat "$XDG_CONFIG_HOME/pbrain/vault")" = "$HOME/pbrain-vault" ]
}

@test "auto-create notice goes to stderr, not stdout" {
  run --separate-stderr resolve
  [ "$status" -eq 0 ]
  # The only stdout line is the RESOLVED= echo; the notice + scaffold chatter
  # are redirected to stderr so parseable command tokens stay clean.
  [[ "$output" != *"no vault configured"* ]]
  [[ "$output" != *"Vault dir:"* ]]
  [[ "$stderr" == *"no vault configured"* ]]
}

@test "idempotent: second run resolves via config, no re-scaffold, no notice" {
  run resolve
  [ "$status" -eq 0 ]
  # capture commit count after first create (git available on the test box)
  if command -v git >/dev/null 2>&1; then
    first_count="$(cd "$HOME/pbrain-vault" && git rev-list --count HEAD)"
  fi
  run resolve
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESOLVED=$HOME/pbrain-vault"* ]]
  [[ "$output" != *"no vault configured"* ]]
  if command -v git >/dev/null 2>&1; then
    second_count="$(cd "$HOME/pbrain-vault" && git rev-list --count HEAD)"
    [ "$first_count" = "$second_count" ]
  fi
}

@test "PBRAIN_NO_AUTOVAULT=1 → hard-fails, creates nothing" {
  export PBRAIN_NO_AUTOVAULT=1
  run resolve
  [ "$status" -eq 1 ]
  [[ "$output" == *"no vault is set up yet"* ]]
  [ ! -d "$HOME/pbrain-vault" ]
}

@test "explicit PBRAIN_VAULT that's missing still errors (no auto-create)" {
  export PBRAIN_VAULT="$TMP/does-not-exist"
  run resolve
  [ "$status" -eq 1 ]
  [[ "$output" == *"points to a directory that doesn't exist"* ]]
  [ ! -d "$HOME/pbrain-vault" ]
}
