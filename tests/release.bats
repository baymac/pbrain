#!/usr/bin/env bats
# Tests for scripts/release.sh + lib/whats-new.sh — the release pipeline (PB-128/PB-129).
#
# release.sh is the sole writer of the two version files (VERSION + plugin.json),
# cuts the CHANGELOG [Unreleased] section, generates the per-version what's-new
# HTML, and (tag/publish) drives git/gh. Everything is dry-run until --apply and
# idempotent on re-run. whats-new.sh renders the HTML and surfaces it once per
# upgrade. These tests run against a sandbox copy so the real repo stays clean.
#
# Run with:  bats tests/
# Install bats:  brew install bats-core   (macOS)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  SBX="$TMP/repo"
  # Minimal sandbox repo carrying only what release.sh touches.
  mkdir -p "$SBX/scripts" "$SBX/lib" "$SBX/.claude-plugin" "$SBX/docs"
  cp "$REPO_ROOT/scripts/release.sh" "$SBX/scripts/"
  cp "$REPO_ROOT/lib/whats-new.sh" "$SBX/lib/"
  cp "$REPO_ROOT/lib/whats-new-render.py" "$SBX/lib/"
  printf '0.24.0.0\n' > "$SBX/VERSION"
  printf '{\n  "name": "pbrain",\n  "version": "0.24.0"\n}\n' > "$SBX/.claude-plugin/plugin.json"
  cat > "$SBX/CHANGELOG.md" <<'EOF'
# Changelog

All notable changes to pbrain are documented here.

## [Unreleased]

### Added

- **A shiny new thing.** It does `stuff` and links to [docs](https://example.com).
- A second bullet.

## [0.24.0] — 2026-06-25

### Added

- The prior release.
EOF
  REL="$SBX/scripts/release.sh"
  export PBRAIN_RELEASE_DATE="2026-07-01"
}

teardown() { rm -rf "$TMP"; }

_ver_file()   { cat "$SBX/VERSION"; }
_ver_plugin() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$SBX/.claude-plugin/plugin.json"; }

@test "current reads the SemVer from plugin.json" {
  run bash "$REL" current
  [ "$status" -eq 0 ]
  [ "$output" = "0.24.0" ]
}

@test "next computes major/minor/patch without writing" {
  run bash "$REL" next minor; [ "$output" = "0.25.0" ]
  run bash "$REL" next major; [ "$output" = "1.0.0" ]
  run bash "$REL" next patch; [ "$output" = "0.24.1" ]
  # unchanged on disk
  [ "$(_ver_plugin)" = "0.24.0" ]
}

@test "bump is dry-run by default (writes nothing)" {
  run bash "$REL" bump minor
  [ "$status" -eq 0 ]
  [ "$(_ver_file)" = "0.24.0.0" ]
  [ "$(_ver_plugin)" = "0.24.0" ]
}

@test "bump --apply writes BOTH version files in lockstep" {
  run bash "$REL" bump minor --apply
  [ "$status" -eq 0 ]
  [ "$(_ver_file)" = "0.25.0.0" ]
  [ "$(_ver_plugin)" = "0.25.0" ]
}

@test "changelog --apply rolls [Unreleased] into a dated version + fresh empty [Unreleased]" {
  run bash "$REL" changelog --version 0.25.0 --apply
  [ "$status" -eq 0 ]
  grep -q '^## \[0.25.0\] — 2026-07-01' "$SBX/CHANGELOG.md"
  # [Unreleased] still present (now empty above the new section)
  grep -q '^## \[Unreleased\]' "$SBX/CHANGELOG.md"
  # new section sits above the old 0.24.0 one
  run grep -n '^## \[' "$SBX/CHANGELOG.md"
  [[ "${lines[0]}" == *"[Unreleased]"* ]]
  [[ "${lines[1]}" == *"[0.25.0]"* ]]
  [[ "${lines[2]}" == *"[0.24.0]"* ]]
}

@test "changelog is idempotent — second run is a no-op" {
  bash "$REL" changelog --version 0.25.0 --apply
  before="$(md5 -q "$SBX/CHANGELOG.md" 2>/dev/null || md5sum "$SBX/CHANGELOG.md")"
  run bash "$REL" changelog --version 0.25.0 --apply
  [ "$status" -eq 0 ]
  after="$(md5 -q "$SBX/CHANGELOG.md" 2>/dev/null || md5sum "$SBX/CHANGELOG.md")"
  [ "$before" = "$after" ]
}

@test "whats-new --apply generates HTML from the changelog section" {
  run bash "$REL" whats-new --version 0.24.0 --apply
  [ "$status" -eq 0 ]
  [ -f "$SBX/docs/whats-new/0.24.0.html" ]
  # no authored .md → fallback hero, and the 0.24.0 changelog body shows through
  grep -q '<h1>What' "$SBX/docs/whats-new/0.24.0.html"
  grep -q 'The prior release' "$SBX/docs/whats-new/0.24.0.html"
  grep -q 'v0.24.0' "$SBX/docs/whats-new/0.24.0.html"
}

@test "cut runs bump + changelog + whats-new in one --apply, idempotent" {
  run bash "$REL" cut minor --apply
  [ "$status" -eq 0 ]
  [ "$(_ver_plugin)" = "0.25.0" ]
  grep -q '^## \[0.25.0\]' "$SBX/CHANGELOG.md"
  [ -f "$SBX/docs/whats-new/0.25.0.html" ]
  # re-running cut at the SAME level now bumps to 0.26.0 (level is relative),
  # but the changelog cut for an already-present version stays a no-op:
  run bash "$REL" changelog --version 0.25.0 --apply
  [ "$status" -eq 0 ]
}

@test "cut dry-run writes nothing" {
  run bash "$REL" cut minor
  [ "$status" -eq 0 ]
  [ "$(_ver_plugin)" = "0.24.0" ]
  [ ! -d "$SBX/docs/whats-new" ] || [ -z "$(ls -A "$SBX/docs/whats-new" 2>/dev/null)" ]
}

@test "whats-new render turns the markdown subset into HTML" {
  out="$(printf '### Added\n\n- **Bold.** a `code` and [link](https://x.io)\n- two\n' \
    | bash "$SBX/lib/whats-new.sh" render 1.2.3)"
  [[ "$out" == *"<h2>Added</h2>"* ]]
  [[ "$out" == *"<strong>Bold.</strong>"* ]]
  [[ "$out" == *"<code>code</code>"* ]]
  [[ "$out" == *'<a href="https://x.io">link</a>'* ]]
  [[ "$out" == *"<li>two</li>"* ]]
  [[ "$out" == *"v1.2.3"* ]]
}

@test "whats-new prefers an authored highlights file over the changelog" {
  mkdir -p "$SBX/docs/whats-new"
  cat > "$SBX/docs/whats-new/0.24.0.md" <<'EOF'
# Hero headline here
> A punchy tagline.

## A feature
Now you can do **the thing** with `code`.

```bash
/some-command --flag
```
EOF
  run bash "$REL" whats-new --version 0.24.0 --apply
  [ "$status" -eq 0 ]
  html="$SBX/docs/whats-new/0.24.0.html"
  grep -q '<h1>Hero headline here</h1>' "$html"
  grep -q 'A punchy tagline' "$html"
  grep -q '<h2>A feature</h2>' "$html"
  # the fenced block becomes a "Try it" command card
  grep -q 'class="card-h">Try it' "$html"
  grep -q '/some-command --flag' "$html"
  # the changelog bullet text must NOT appear — the .md won
  ! grep -q 'A shiny new thing' "$html"
}

@test "render: bold spans inline code that contains an asterisk" {
  out="$(printf 'now **assigns the `auto:*` labels** ok\n' \
    | bash "$SBX/lib/whats-new.sh" render 1.0.0)"
  [[ "$out" == *"<strong>assigns the <code>auto:*</code> labels</strong>"* ]]
  [[ "$out" != *"**"* ]]
}

@test "render: hero + tagline + feature section + try-it card" {
  out="$(printf '# Big\n> tag\n\n## Feat\nbody\n\n```bash\n/cmd\n```\n' \
    | bash "$SBX/lib/whats-new.sh" render 2.0.0)"
  [[ "$out" == *"<h1>Big</h1>"* ]]
  [[ "$out" == *'class="lede">tag'* ]]
  [[ "$out" == *"<h2>Feat</h2>"* ]]
  [[ "$out" == *'class="card-h">Try it'* ]]
  [[ "$out" == *"/cmd"* ]]
}

@test "render: a markdown table becomes a styled <table>" {
  out="$(printf '## S\n\n| Command | Does |\n|---|---|\n| `/x` | thing |\n| `/y` | other |\n' \
    | bash "$SBX/lib/whats-new.sh" render 1.0.0)"
  [[ "$out" == *"<table>"* ]]
  [[ "$out" == *"<th>Command</th>"* ]]
  [[ "$out" == *"<td><code>/x</code></td>"* ]]
  [[ "$out" == *"<td>thing</td>"* ]]
  [[ "$out" == *"<td>other</td>"* ]]
}

@test "render: a flow block becomes connected chips" {
  out="$(printf '## S\n\n```flow\nplan -> implement -> land\n```\n' \
    | bash "$SBX/lib/whats-new.sh" render 1.0.0)"
  [[ "$out" == *'class="flow"'* ]]
  [[ "$out" == *'class="chip">plan</span>'* ]]
  [[ "$out" == *'class="chip">implement</span>'* ]]
  [[ "$out" == *'class="chip">land</span>'* ]]
  [[ "$out" == *'class="arrow"'* ]]
}

@test "render: flow accepts unicode arrows too" {
  out="$(printf '## S\n\n```flow\na → b\n```\n' \
    | bash "$SBX/lib/whats-new.sh" render 1.0.0)"
  [[ "$out" == *'class="chip">a</span>'* ]]
  [[ "$out" == *'class="chip">b</span>'* ]]
}

@test "whats-new latest picks the highest SemVer doc" {
  mkdir -p "$SBX/docs/whats-new"
  : > "$SBX/docs/whats-new/0.9.0.html"
  : > "$SBX/docs/whats-new/0.24.0.html"
  : > "$SBX/docs/whats-new/0.24.1.html"
  run env PBRAIN_WHATS_NEW_DIR="$SBX/docs/whats-new" bash "$SBX/lib/whats-new.sh" latest
  [ "$output" = "0.24.1" ]
}

@test "whats-new check: first run baselines silently, then surfaces once on upgrade" {
  mkdir -p "$SBX/docs/whats-new"
  cp "$REPO_ROOT/docs/whats-new/0.24.0.html" "$SBX/docs/whats-new/0.24.0.html" 2>/dev/null \
    || bash "$REL" whats-new --version 0.24.0 --apply
  state="$TMP/seen"
  pj="$SBX/.claude-plugin/plugin.json"
  export PBRAIN_WHATS_NEW_DIR="$SBX/docs/whats-new"
  export PBRAIN_WHATS_NEW_STATE="$state"
  export PBRAIN_WHATS_NEW_OPEN=0

  # first run on 0.24.0 → baseline, silent
  run env PBRAIN_PLUGIN_JSON="$pj" bash "$SBX/lib/whats-new.sh" check
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(cat "$state")" = "0.24.0" ]

  # pretend we were last on 0.23.0, now on 0.24.0 → surface once
  printf '0.23.0\n' > "$state"
  run env PBRAIN_PLUGIN_JSON="$pj" bash "$SBX/lib/whats-new.sh" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"What's new in pbrain 0.24.0"* ]]
  [ "$(cat "$state")" = "0.24.0" ]

  # repeat → silent (already surfaced)
  run env PBRAIN_PLUGIN_JSON="$pj" bash "$SBX/lib/whats-new.sh" check
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "version files never drift after a bump (lockstep invariant)" {
  bash "$REL" bump patch --apply
  vf="$(_ver_file)"; vp="$(_ver_plugin)"
  # VERSION is x.y.z.0 ; plugin.json is x.y.z ; first three parts must match
  [ "${vf%.0}" = "$vp" ]
}
