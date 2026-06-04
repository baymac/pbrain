#!/usr/bin/env bats
# Tests for commands/pbrain-codex-install.sh — the Codex CLI interop generator.
#
# Run with:  bats tests/
# Install bats:  brew install bats-core   (macOS)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INSTALLER="$REPO_ROOT/commands/pbrain-codex-install.sh"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  export CODEX_HOME="$TMP/codex"
  export XDG_CONFIG_HOME="$TMP/config"
  # Deterministic baked path: bake the repo under test, not the machine's dev dir.
  export PBRAIN_DEV_DIR="$REPO_ROOT"
  unset PBRAIN_VAULT
  PROMPTS="$CODEX_HOME/prompts"
  AGENTS="$CODEX_HOME/AGENTS.md"
}

teardown() {
  # Defensive: a couple of tests drop a stray .md into the real commands dir.
  [ -n "${STRAY_MD:-}" ] && rm -f "$STRAY_MD" || true
  rm -rf "$TMP"
}

# Configure a vault (as /init-obsidian would). Path has a space on purpose.
_configure_vault() {
  local v="$TMP/My Vault/vault"
  mkdir -p "$v" "$XDG_CONFIG_HOME/pbrain"
  printf '%s\n' "$v" > "$XDG_CONFIG_HOME/pbrain/vault"
  echo "$v"
}

@test "generates one prompt per command, excluding setup commands" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PBRAIN_CODEX_INSTALLED"* ]]
  # A representative sample exists.
  [ -f "$PROMPTS/pbrain-journal.md" ]
  [ -f "$PROMPTS/pbrain-brainstorm.md" ]
  [ -f "$PROMPTS/pbrain-habits.md" ]
  # Setup commands are NOT exposed to Codex.
  [ ! -f "$PROMPTS/pbrain-init-obsidian.md" ]
  [ ! -f "$PROMPTS/pbrain-pbrain-codex-install.md" ]
}

@test "bakes a literal .sh path and drops the Claude path token" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  grep -q "bash \"$REPO_ROOT/commands/journal.sh\"" "$PROMPTS/pbrain-journal.md"
  ! grep -q 'CLAUDE_PLUGIN_ROOT' "$PROMPTS/pbrain-journal.md"
  ! grep -q 'PBRAIN_DEV_DIR' "$PROMPTS/pbrain-journal.md"
}

@test "preserves \$ARGUMENTS but escapes every other dollar sign" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  # The one real placeholder survives un-escaped...
  grep -q '"\$ARGUMENTS"' "$PROMPTS/pbrain-brainstorm.md"
  ! grep -q '\$\$ARGUMENTS' "$PROMPTS/pbrain-brainstorm.md"
  # ...while prose shell vars are escaped to $$ so Codex emits them literally.
  grep -q '\$\$VAULT_DIR' "$PROMPTS/pbrain-brainstorm.md"
  grep -q '\$\$PBRAIN_VAULT' "$PROMPTS/pbrain-brainstorm.md"
}

@test "rewrites pbrain slash refs but leaves non-pbrain refs alone" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  grep -q '/prompts:pbrain-journal' "$PROMPTS/pbrain-brainstorm.md"
  grep -q '/prompts:pbrain-gratitude-journal' "$PROMPTS/pbrain-brainstorm.md"
  # gstack skills are not pbrain commands — left verbatim.
  grep -q '/office-hours' "$PROMPTS/pbrain-brainstorm.md"
  grep -q '/plan-ceo-review' "$PROMPTS/pbrain-brainstorm.md"
}

@test "every generated prompt carries the managed marker" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  for f in "$PROMPTS"/pbrain-*.md; do
    grep -q 'pbrain-codex-managed' "$f"
  done
}

@test "AGENTS.md block is created and preserves pre-existing content" {
  _configure_vault >/dev/null
  mkdir -p "$CODEX_HOME"
  printf '# My notes\n\nKeep me.\n' > "$AGENTS"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  grep -q 'Keep me.' "$AGENTS"
  grep -q '>>> pbrain (managed' "$AGENTS"
  grep -q 'Morning sequence' "$AGENTS"
}

@test "re-running is idempotent: single managed block, stable prompt count" {
  _configure_vault >/dev/null
  bash "$INSTALLER" >/dev/null
  local first
  first="$(ls "$PROMPTS"/pbrain-*.md | wc -l | tr -d ' ')"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGENTS_BLOCK=updated"* ]]
  local second
  second="$(ls "$PROMPTS"/pbrain-*.md | wc -l | tr -d ' ')"
  [ "$first" -eq "$second" ]
  [ "$(grep -c '>>> pbrain (managed' "$AGENTS")" -eq 1 ]
  [ "$(grep -c '<<< pbrain (managed' "$AGENTS")" -eq 1 ]
}

@test "prunes stale managed prompts but never touches the user's own prompts" {
  _configure_vault >/dev/null
  mkdir -p "$PROMPTS"
  printf -- '---\ndescription: mine\n---\nhi\n' > "$PROMPTS/myprompt.md"
  printf -- '---\nx\n---\n<!-- pbrain-codex-managed | x -->\nold\n' > "$PROMPTS/pbrain-gonecmd.md"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ -f "$PROMPTS/myprompt.md" ]            # user file preserved
  [ ! -f "$PROMPTS/pbrain-gonecmd.md" ]    # stale managed file pruned
  [[ "$output" == *"PROMPTS_PRUNED="*"pbrain-gonecmd"* ]]
}

@test "does not overwrite a user's own pbrain-<cmd> prompt lacking the marker" {
  _configure_vault >/dev/null
  mkdir -p "$PROMPTS"
  # A name that collides with a real generated command, but it's the user's.
  printf -- '---\ndescription: my own\n---\nMy custom content.\n' > "$PROMPTS/pbrain-journal.md"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  grep -q 'My custom content.' "$PROMPTS/pbrain-journal.md"    # preserved verbatim
  ! grep -q 'pbrain-codex-managed' "$PROMPTS/pbrain-journal.md" # marker not injected
  [[ "$output" == *"PROMPTS_SKIPPED_UNMANAGED="*"pbrain-journal"* ]]
}

@test "skips a command whose .sh is missing and warns" {
  _configure_vault >/dev/null
  STRAY_MD="$REPO_ROOT/commands/zzz-codextest-missing.md"
  printf -- '---\ndescription: stray\n---\nbody\n' > "$STRAY_MD"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ ! -f "$PROMPTS/pbrain-zzz-codextest-missing.md" ]
  [[ "$output" == *"has no matching"* ]]
  [[ "$output" == *"zzz-codextest-missing.sh"* ]]
  rm -f "$STRAY_MD"
  unset STRAY_MD
}

@test "configured vault is quoted in the launch command (handles spaces)" {
  local v
  v="$(_configure_vault)"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault=$v"* ]]
  [[ "$output" == *"--add-dir \"$v\" --add-dir \"\$HOME/.config/pbrain\""* ]]
}

@test "unconfigured vault yields NOT_CONFIGURED and a placeholder launch" {
  # No config file written, and HOME is empty so the default iCloud path is absent.
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault=NOT_CONFIGURED"* ]]
  [[ "$output" == *"<your-vault-path>"* ]]
  grep -q 'set up via /init-obsidian' "$AGENTS"
}

@test "never writes anything into the repo or the vault" {
  local v
  v="$(_configure_vault)"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  # The installer only touches $CODEX_HOME; the vault stays empty.
  [ -z "$(ls -A "$v")" ]
}

@test "exits 1 and reports error when CMD_DIR is missing" {
  # Copy the installer to a temp dir that has no commands/ sibling, so CMD_DIR resolves to a missing dir.
  local bare_dir="$TMP/bare"
  mkdir -p "$bare_dir"
  cp "$INSTALLER" "$bare_dir/pbrain-codex-install.sh"
  run bash "$bare_dir/pbrain-codex-install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"command sources not found"* ]]
}

@test "vault resolved via PBRAIN_VAULT env var yields vault_source=env" {
  local v="$TMP/env-vault"
  mkdir -p "$v"
  export PBRAIN_VAULT="$v"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault=$v"* ]]
  [[ "$output" == *"vault_source=env"* ]]
}

@test "AGENTS.md block is created (action=created) when the file is absent" {
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGENTS_BLOCK=created"* ]]
  [ -f "$AGENTS" ]
  grep -q '>>> pbrain (managed' "$AGENTS"
}

@test "AGENTS.md block is appended when the file exists without a pbrain block" {
  _configure_vault >/dev/null
  mkdir -p "$CODEX_HOME"
  printf '# Pre-existing Codex notes\n' > "$AGENTS"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGENTS_BLOCK=appended"* ]]
  grep -q 'Pre-existing Codex notes' "$AGENTS"
  grep -q '>>> pbrain (managed' "$AGENTS"
}

@test "softens 'the Bash tool' to 'your shell' in generated prompts" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  # No prompt should contain the Claude-specific phrase 'the Bash tool' verbatim
  for f in "$PROMPTS"/pbrain-*.md; do
    ! grep -q 'the Bash tool' "$f"
  done
  # At least one prompt should use the softened phrase (plan-my-day is a good one)
  grep -rq 'your shell' "$PROMPTS"/pbrain-*.md
}

@test "codex_detected reported in output (yes or no)" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex_detected="* ]]
}

@test "no unescaped bare dollar variables in generated prompts (only \$ARGUMENTS allowed)" {
  _configure_vault >/dev/null
  bash "$INSTALLER" >/dev/null
  # Write the checker to a temp file to avoid bash/Python backslash escaping conflicts
  local checker="$TMP/check_dollars.py"
  cat > "$checker" <<'PYEOF'
import os, re, sys
prompts_dir = sys.argv[1]
bad = []
# (?<!\$) = not preceded by dollar; \$ = literal dollar; then identifier
pat = re.compile(r'(?<!\$)\$([A-Za-z_][A-Za-z0-9_]*)')
for f in sorted(os.listdir(prompts_dir)):
    if not f.endswith('.md'):
        continue
    text = open(os.path.join(prompts_dir, f)).read()
    for m in pat.finditer(text):
        if m.group(1) != 'ARGUMENTS':
            bad.append('%s: $%s' % (f, m.group(1)))
if bad:
    print('FAIL: ' + '; '.join(bad[:5]))
    sys.exit(1)
PYEOF
  run python3 "$checker" "$PROMPTS"
  [ "$status" -eq 0 ]
}

@test "vault_source is reported in output when vault is configured" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault_source="* ]]
}
