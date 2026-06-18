#!/usr/bin/env bats
# Tests for lib/launchd.sh — the shared native-helper build + LaunchAgent helpers
# extracted in T1 (so reminders/overlay/tracker share one swiftc builder + one
# launchd installer). These pin the two behaviours that matter:
#   - pbrain_swift_build: SOURCE-HASH caching (rebuild only on content change, so
#     an ad-hoc-signed TCC grant survives) + Info.plist scaffolding.
#   - pbrain_launchagent_install/uninstall: well-formed, XML-escaped plist + the
#     bootout/bootstrap dance (launchctl is stubbed; we don't load real agents).
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/bin"
  # Stub swiftc: emit a runnable file at the -o path and bump a build counter, so
  # we can assert exactly how many times a real compile would have happened.
  cat > "$TMP/bin/swiftc" <<EOF
#!/usr/bin/env bash
out=""
prev=""
for a in "\$@"; do
  [[ "\$prev" == "-o" ]] && out="\$a"
  prev="\$a"
done
echo "build" >> "$TMP/build-count"
if [[ -n "\$out" ]]; then printf '#!/bin/sh\n' > "\$out"; chmod +x "\$out"; fi
exit 0
EOF
  chmod +x "$TMP/bin/swiftc"
  # Stub launchctl + codesign so nothing touches the real system.
  for c in launchctl codesign; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$c"; chmod +x "$TMP/bin/$c"
  done
  export PATH="$TMP/bin:$PATH"
  source "$REPO_ROOT/lib/launchd.sh"
  : > "$TMP/build-count"
}

teardown() {
  rm -rf "$TMP"
}

build_count() { grep -c build "$TMP/build-count" 2>/dev/null || echo 0; }

# --- pbrain_swift_build -----------------------------------------------------

@test "pbrain_swift_build compiles the bundle, Info.plist, and hash on first run" {
  printf 'let x = 1\n' > "$TMP/foo.swift"
  run pbrain_swift_build "$TMP/foo.app" "$TMP/foo.swift" "com.pbrain.foo"
  [ "$status" -eq 0 ]
  [ -x "$TMP/foo.app/Contents/MacOS/foo" ]
  [ -f "$TMP/foo.app/Contents/Info.plist" ]
  [ -f "$TMP/foo.app/Contents/.srchash" ]
  run grep -q "com.pbrain.foo" "$TMP/foo.app/Contents/Info.plist"
  [ "$status" -eq 0 ]
}

@test "pbrain_swift_build does NOT recompile when the source is unchanged (hash cache)" {
  printf 'let x = 1\n' > "$TMP/foo.swift"
  pbrain_swift_build "$TMP/foo.app" "$TMP/foo.swift" "com.pbrain.foo"
  [ "$(build_count)" -eq 1 ]
  # touch the mtime forward but keep content identical → must NOT rebuild
  touch "$TMP/foo.swift"
  pbrain_swift_build "$TMP/foo.app" "$TMP/foo.swift" "com.pbrain.foo"
  [ "$(build_count)" -eq 1 ]
}

@test "pbrain_swift_build recompiles when the source content changes" {
  printf 'let x = 1\n' > "$TMP/foo.swift"
  pbrain_swift_build "$TMP/foo.app" "$TMP/foo.swift" "com.pbrain.foo"
  [ "$(build_count)" -eq 1 ]
  printf 'let x = 2\n' > "$TMP/foo.swift"
  pbrain_swift_build "$TMP/foo.app" "$TMP/foo.swift" "com.pbrain.foo"
  [ "$(build_count)" -eq 2 ]
}

@test "pbrain_swift_build injects --plist-extra keys" {
  printf 'let x = 1\n' > "$TMP/foo.swift"
  pbrain_swift_build "$TMP/foo.app" "$TMP/foo.swift" "com.pbrain.foo" \
    --plist-extra '  <key>LSUIElement</key><true/>'
  run grep -q "LSUIElement" "$TMP/foo.app/Contents/Info.plist"
  [ "$status" -eq 0 ]
}

@test "pbrain_swift_build is a no-op when swiftc is absent" {
  # Empty PATH so `command -v swiftc` finds nothing (the real /usr/bin/swiftc must
  # not leak in). The function returns at its first guard line — before it needs
  # any external tool — so the empty PATH is safe.
  mkdir -p "$TMP/nobin"
  printf 'let x = 1\n' > "$TMP/foo.swift"
  PATH="$TMP/nobin" run pbrain_swift_build "$TMP/foo.app" "$TMP/foo.swift" "com.pbrain.foo"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/foo.app/Contents/MacOS/foo" ]
}

# --- pbrain_launchagent_install / _uninstall --------------------------------

@test "pbrain_launchagent_install writes a well-formed plist with escaped args" {
  local plist="$TMP/com.pbrain.test.plist"
  pbrain_launchagent_install "com.pbrain.test" "$plist" "$TMP/log.txt" \
    "  <key>RunAtLoad</key><true/>" \
    -- /bin/bash "$TMP/path with spaces & <special>" tick
  [ -f "$plist" ]
  run cat "$plist"
  [[ "$output" == *"<string>com.pbrain.test</string>"* ]]
  [[ "$output" == *"<key>RunAtLoad</key>"* ]]
  [[ "$output" == *"<key>StandardOutPath</key>"* ]]
  # XML metacharacters in a program argument must be escaped, not raw.
  [[ "$output" == *"&amp;"* ]]
  [[ "$output" == *"&lt;special&gt;"* ]]
}

@test "pbrain_launchagent_install always returns 0 (best-effort)" {
  run pbrain_launchagent_install "com.pbrain.test" "$TMP/x.plist" "" "" -- /bin/echo hi
  [ "$status" -eq 0 ]
}

@test "pbrain_launchagent_uninstall removes the plist and returns 0" {
  local plist="$TMP/com.pbrain.test.plist"
  printf '<plist/>\n' > "$plist"
  run pbrain_launchagent_uninstall "com.pbrain.test" "$plist"
  [ "$status" -eq 0 ]
  [ ! -f "$plist" ]
}

# --- pbrain_stable_cmd_path -------------------------------------------------
# Guards against baking an ephemeral conductor-workspace / dev-clone path into a
# persistent LaunchAgent (which dies when that dir is cleaned up). Each test pins
# HOME to a temp tree so resolution is deterministic.

@test "pbrain_stable_cmd_path prefers the ~/.claude/commands symlink over the given path" {
  export HOME="$TMP/home"; mkdir -p "$HOME/.claude/commands"
  printf '#!/bin/sh\n' > "$TMP/real-pm.sh"
  ln -s "$TMP/real-pm.sh" "$HOME/.claude/commands/project-manager.sh"
  run pbrain_stable_cmd_path "/ephemeral/ws/commands/project-manager.sh"
  [ "$output" = "$HOME/.claude/commands/project-manager.sh" ]
}

@test "pbrain_stable_cmd_path uses the marketplace install when ~/.claude/commands is absent" {
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude/plugins/marketplaces/pbrain/commands"
  printf '#!/bin/sh\n' > "$HOME/.claude/plugins/marketplaces/pbrain/commands/project-manager.sh"
  run pbrain_stable_cmd_path "/ephemeral/ws/commands/project-manager.sh"
  [ "$output" = "$HOME/.claude/plugins/marketplaces/pbrain/commands/project-manager.sh" ]
}

@test "pbrain_stable_cmd_path falls back to the given path when not installed anywhere" {
  export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
  run pbrain_stable_cmd_path "/ephemeral/ws/commands/project-manager.sh"
  [ "$output" = "/ephemeral/ws/commands/project-manager.sh" ]
}

@test "pbrain_stable_cmd_path ignores a DANGLING ~/.claude/commands symlink (falls through)" {
  export HOME="$TMP/home"; mkdir -p "$HOME/.claude/commands"
  ln -s "$TMP/does-not-exist.sh" "$HOME/.claude/commands/project-manager.sh"
  run pbrain_stable_cmd_path "/ephemeral/ws/commands/project-manager.sh"
  [ "$output" = "/ephemeral/ws/commands/project-manager.sh" ]
}
