#!/usr/bin/env bats
# Tests for commands/codex-install.sh — the Codex CLI interop generator.
#
# It installs each pbrain command as a Codex *agent skill*
# ($CODEX_HOME/skills/pbrain-<cmd>/SKILL.md), writes a managed AGENTS.md block,
# and a `codex-pbrain` launcher shell function. Skills are read from disk
# verbatim (Codex does NOT expand $NAME in a skill body), so unlike the old
# custom-prompt path there is no '$'-escaping to verify.
#
# Run with:  bats tests/
# Install bats:  brew install bats-core   (macOS)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INSTALLER="$REPO_ROOT/commands/codex-install.sh"
  TMP="$(mktemp -d)"
  export HOME="$TMP/home"
  mkdir -p "$HOME"
  export CODEX_HOME="$TMP/codex"
  export XDG_CONFIG_HOME="$TMP/config"
  # Deterministic baked path: bake the repo under test, not the machine's dev dir.
  export PBRAIN_DEV_DIR="$REPO_ROOT"
  unset PBRAIN_VAULT
  SKILLS="$CODEX_HOME/skills"
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

@test "generates one skill per command, excluding setup commands" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PBRAIN_CODEX_INSTALLED"* ]]
  # A representative sample exists as $CODEX_HOME/skills/pbrain-<cmd>/SKILL.md.
  [ -f "$SKILLS/pbrain-journal/SKILL.md" ]
  [ -f "$SKILLS/pbrain-brainstorm/SKILL.md" ]
  [ -f "$SKILLS/pbrain-habits/SKILL.md" ]
  # Setup commands are NOT exposed to Codex.
  [ ! -d "$SKILLS/pbrain-init-obsidian" ]
  [ ! -d "$SKILLS/pbrain-codex-install" ]
}

@test "SKILL.md frontmatter carries name and description" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  grep -q '^name: pbrain-journal$' "$SKILLS/pbrain-journal/SKILL.md"
  # Description is a double-quoted YAML scalar sourced from the command .md.
  grep -q '^description: ".*journal.*"$' "$SKILLS/pbrain-journal/SKILL.md"
}

@test "bakes a literal .sh path and drops the Claude path token" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  grep -q "bash \"$REPO_ROOT/commands/journal.sh\"" "$SKILLS/pbrain-journal/SKILL.md"
  ! grep -q 'CLAUDE_PLUGIN_ROOT' "$SKILLS/pbrain-journal/SKILL.md"
  ! grep -q 'PBRAIN_DEV_DIR' "$SKILLS/pbrain-journal/SKILL.md"
}

@test "skill bodies are verbatim: no \$-escaping, \$ARGUMENTS and \$VAULT_DIR stay literal" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  # The arg placeholder survives as plain $ARGUMENTS (the body's own prose tells
  # the agent to substitute the user's input) — and is never doubled to $$.
  grep -q '"\$ARGUMENTS"' "$SKILLS/pbrain-brainstorm/SKILL.md"
  ! grep -q '\$\$' "$SKILLS/pbrain-brainstorm/SKILL.md"
  # Prose shell vars stay single-dollar (skills are not placeholder-expanded).
  grep -q '\$VAULT_DIR' "$SKILLS/pbrain-brainstorm/SKILL.md"
}

@test "leaves native pbrain and non-pbrain slash refs verbatim (no /prompts: rewrite)" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  ! grep -q '/prompts:pbrain-' "$SKILLS/pbrain-brainstorm/SKILL.md"
  grep -q '/journal' "$SKILLS/pbrain-brainstorm/SKILL.md"
  grep -q '/gratitude-journal' "$SKILLS/pbrain-brainstorm/SKILL.md"
  # gstack skills are not pbrain commands — left verbatim.
  grep -q '/office-hours' "$SKILLS/pbrain-brainstorm/SKILL.md"
  grep -q '/plan-ceo-review' "$SKILLS/pbrain-brainstorm/SKILL.md"
}

@test "every generated skill carries the managed marker" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  for f in "$SKILLS"/pbrain-*/SKILL.md; do
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

@test "AGENTS.md explains skill invocation, warns no-slash, and drops the dead /prompts: form" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  # Skill-based invocation is documented (by name / $pbrain-<cmd>).
  grep -q 'skill' "$AGENTS"
  grep -q '\$pbrain-journal' "$AGENTS"
  # Must warn that a literal /journal does not work.
  grep -q '/slash' "$AGENTS"
  # And must NOT advertise the deprecated custom-prompt form.
  ! grep -q '/prompts:pbrain-' "$AGENTS"
}

@test "re-running is idempotent: single managed block, stable skill count" {
  _configure_vault >/dev/null
  bash "$INSTALLER" >/dev/null
  local first
  first="$(ls -d "$SKILLS"/pbrain-*/ | wc -l | tr -d ' ')"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGENTS_BLOCK=updated"* ]]
  local second
  second="$(ls -d "$SKILLS"/pbrain-*/ | wc -l | tr -d ' ')"
  [ "$first" -eq "$second" ]
  [ "$(grep -c '>>> pbrain (managed' "$AGENTS")" -eq 1 ]
  [ "$(grep -c '<<< pbrain (managed' "$AGENTS")" -eq 1 ]
}

@test "prunes stale managed skills but never touches the user's own skills" {
  _configure_vault >/dev/null
  mkdir -p "$SKILLS/myskill" "$SKILLS/pbrain-gonecmd"
  printf -- '---\nname: myskill\ndescription: mine\n---\nhi\n' > "$SKILLS/myskill/SKILL.md"
  printf -- '---\nname: pbrain-gonecmd\ndescription: x\n---\n<!-- pbrain-codex-managed | x -->\nold\n' > "$SKILLS/pbrain-gonecmd/SKILL.md"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ -d "$SKILLS/myskill" ]                  # user dir preserved
  [ ! -d "$SKILLS/pbrain-gonecmd" ]         # stale managed skill pruned
  [[ "$output" == *"SKILLS_PRUNED="*"pbrain-gonecmd"* ]]
}

@test "does not overwrite a user's own pbrain-<cmd> skill lacking the marker" {
  _configure_vault >/dev/null
  mkdir -p "$SKILLS/pbrain-journal"
  printf -- '---\nname: pbrain-journal\ndescription: my own\n---\nMy custom content.\n' > "$SKILLS/pbrain-journal/SKILL.md"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  grep -q 'My custom content.' "$SKILLS/pbrain-journal/SKILL.md"    # preserved verbatim
  ! grep -q 'pbrain-codex-managed' "$SKILLS/pbrain-journal/SKILL.md" # marker not injected
  [[ "$output" == *"SKILLS_SKIPPED_UNMANAGED="*"pbrain-journal"* ]]
}

@test "cleans up legacy managed custom-prompts from earlier installs" {
  _configure_vault >/dev/null
  mkdir -p "$PROMPTS"
  printf -- '---\nx\n---\n<!-- pbrain-codex-managed | x -->\nold\n' > "$PROMPTS/pbrain-journal.md"
  # A user's own prompt (no marker) must be left alone.
  printf -- '---\nx\n---\nmy own prompt\n' > "$PROMPTS/pbrain-mine.md"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ ! -f "$PROMPTS/pbrain-journal.md" ]            # legacy managed prompt removed
  [ -f "$PROMPTS/pbrain-mine.md" ]                 # user prompt preserved
  [[ "$output" == *"LEGACY_PROMPTS_REMOVED="*"pbrain-journal"* ]]
}

@test "skips a command whose .sh is missing and warns" {
  _configure_vault >/dev/null
  STRAY_MD="$REPO_ROOT/commands/zzz-codextest-missing.md"
  printf -- '---\ndescription: stray\n---\nbody\n' > "$STRAY_MD"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ ! -d "$SKILLS/pbrain-zzz-codextest-missing" ]
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
  # The installer only touches $CODEX_HOME (+ RC files under $HOME); vault stays empty.
  [ -z "$(ls -A "$v")" ]
}

@test "exits 1 and reports error when CMD_DIR is missing" {
  # Copy the installer to a temp dir that has no commands/ sibling, so CMD_DIR resolves to a missing dir.
  local bare_dir="$TMP/bare"
  mkdir -p "$bare_dir"
  cp "$INSTALLER" "$bare_dir/codex-install.sh"
  run bash "$bare_dir/codex-install.sh"
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

@test "softens 'the Bash tool' to 'your shell' in generated skills" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  # No skill should contain the Claude-specific phrase 'the Bash tool' verbatim
  for f in "$SKILLS"/pbrain-*/SKILL.md; do
    ! grep -q 'the Bash tool' "$f"
  done
  # At least one skill should use the softened phrase
  grep -rq 'your shell' "$SKILLS"/pbrain-*/SKILL.md
}

@test "codex_detected reported in output (yes or no)" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex_detected="* ]]
}

@test "vault_source is reported in output when vault is configured" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"vault_source="* ]]
}

@test "writes codex-pbrain shell function to .zshrc when no RC exists" {
  _configure_vault >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.zshrc" ]
  grep -q 'codex-pbrain()' "$HOME/.zshrc"
  grep -q 'codex --sandbox workspace-write' "$HOME/.zshrc"
  grep -q '>>> pbrain-managed: codex-pbrain >>>' "$HOME/.zshrc"
  [[ "$output" == *"SHELL_FUNC_ADDED="* ]]
}

@test "updates existing codex-pbrain block in .zshrc idempotently" {
  _configure_vault >/dev/null
  bash "$INSTALLER" >/dev/null
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ "$(grep -c '>>> pbrain-managed: codex-pbrain >>>' "$HOME/.zshrc")" -eq 1 ]
  [[ "$output" == *"SHELL_FUNC_UPDATED="* ]]
}

@test "writes codex-pbrain function to all existing RC files" {
  _configure_vault >/dev/null
  touch "$HOME/.bashrc" "$HOME/.zshrc"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  grep -q 'codex-pbrain()' "$HOME/.zshrc"
  grep -q 'codex-pbrain()' "$HOME/.bashrc"
}
