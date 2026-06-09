#!/usr/bin/env bash
# pbrain shared native-helper build + LaunchAgent helpers — sourced by lib/vault.sh
# (before reminders.sh, which calls pbrain_swift_build).
#
# Two unrelated-but-co-located concerns that every Swift-backed pbrain command
# needs, extracted here so there is exactly ONE swiftc builder and ONE launchd
# installer instead of a copy per command:
#
#   pbrain_swift_build        compile a <name>.swift → <name>.app bundle on demand,
#                             SOURCE-HASH cached (rebuild only when the source
#                             content changes, NOT on every mtime touch) with a
#                             STABLE CFBundleIdentifier. The hash cache matters for
#                             TCC: an ad-hoc-signed rebuild can invalidate an
#                             Automation/Reminders grant, so we must not rebuild
#                             unless the source actually changed.
#   pbrain_launchagent_install / _uninstall
#                             write a LaunchAgent plist (XML-escaped) and
#                             bootstrap/bootout it in the user's GUI (Aqua) domain.
#
# Like the other lib/ helpers, everything here NEVER exits non-zero — these are
# sourced into commands running under `set -euo pipefail`, and a fault here must
# not take the command down.

# Hash a file's contents (sha256 preferred; falls back to md5 / cksum). Echoes
# the bare hash, or nothing on failure (callers treat empty as "always rebuild").
_pbrain_file_hash() {
  local f="${1:-}"
  [[ -f "$f" ]] || return 0
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q "$f" 2>/dev/null
  elif command -v cksum >/dev/null 2>&1; then
    cksum "$f" 2>/dev/null | awk '{print $1"-"$2}'
  fi
  return 0
}

# XML-escape &, <, > so a path/label with metacharacters can't produce malformed
# plist XML (which launchctl silently rejects while we'd report success).
_pbrain_xml_escape() {
  printf '%s' "${1:-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# pbrain_swift_build <app_path> <src_file> <bundle_id> [--sign] [--plist-extra "<xml>"]
#
# Compile <src_file> into <app_path>/Contents/MacOS/<exe>, where <exe> is the
# source basename minus .swift (so foo.swift → an executable named `foo`, matching
# CFBundleExecutable). Idempotent + best-effort:
#   * no swiftc, missing source, or a compile failure → leaves the app absent and
#     returns 0 (callers degrade); never prints.
#   * SOURCE-HASH cache: rebuilds only when the binary is missing OR the source
#     content changed since the last successful build (recorded in Contents/.srchash).
#     This is the key difference from a naive mtime check — a `touch`, a checkout,
#     or an unchanged upgrade does NOT rebuild, so a stable ad-hoc signature (and
#     thus any TCC grant keyed on it) survives.
#   * --sign ad-hoc codesigns the finished bundle (needed when TCC keys consent on
#     the signature, e.g. the Reminders/Automation helpers).
#   * --plist-extra injects caller-specific Info.plist keys (LSUIElement, usage
#     strings, …) into the bundle's dict.
# The Info.plist is (re)written on each build so bundle-id / plist-extra changes
# take effect; the up-to-date fast path returns before touching anything.
pbrain_swift_build() {
  command -v swiftc >/dev/null 2>&1 || return 0
  local app="${1:-}" src="${2:-}" bundle_id="${3:-}"
  shift 3 2>/dev/null || return 0
  local sign=0 plist_extra=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sign) sign=1; shift ;;
      --plist-extra) plist_extra="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$app" && -n "$src" && -n "$bundle_id" ]] || return 0
  [[ -f "$src" ]] || return 0
  local exe; exe="$(basename "$src")"; exe="${exe%.swift}"
  local bin="$app/Contents/MacOS/$exe"
  local hashfile="$app/Contents/.srchash"
  local cur prev=""
  cur="$(_pbrain_file_hash "$src")"
  [[ -f "$hashfile" ]] && prev="$(cat "$hashfile" 2>/dev/null || true)"
  # Up to date: binary present and the source content is unchanged.
  [[ -x "$bin" && -n "$cur" && "$cur" == "$prev" ]] && return 0
  mkdir -p "$app/Contents/MacOS" 2>/dev/null || return 0
  # Unquoted heredoc — interpolates bundle id / exe / caller plist keys. The
  # interpolated values are pbrain-controlled (no untrusted $), so this is safe.
  cat > "$app/Contents/Info.plist" 2>/dev/null <<PLIST || return 0
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$exe</string>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
$plist_extra
</dict>
</plist>
PLIST
  # Compile to a temp path in the same dir, then atomic-rename so a concurrent
  # reader never executes a half-written binary.
  local tmp="$bin.tmp.$$"
  if swiftc -suppress-warnings "$src" -o "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$bin" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
    if [[ "$sign" == "1" ]]; then
      command -v codesign >/dev/null 2>&1 && codesign --force --sign - "$app" >/dev/null 2>&1 || true
    fi
    [[ -n "$cur" ]] && printf '%s' "$cur" > "$hashfile" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# pbrain_launchagent_install <label> <plist_path> <log_file> <extra_xml> -- <prog> [args...]
#
# Write a LaunchAgent plist and (re)bootstrap it into the user's GUI domain.
#   <label>      reverse-DNS launchd label (e.g. com.pbrain.tracker)
#   <plist_path> ~/Library/LaunchAgents/<label>.plist
#   <log_file>   stdout+stderr target ("" to omit the StandardOut/ErrorPath keys)
#   <extra_xml>  raw Info-dict keys the caller composes + XML-escapes itself
#                (StartInterval / RunAtLoad / KeepAlive / LimitLoadToSessionType /
#                EnvironmentVariables …)
#   <prog> args  ProgramArguments, each XML-escaped here
# Always returns 0 (best-effort). The reload is bootout-then-bootstrap, falling
# back to unload/load on older launchctl.
pbrain_launchagent_install() {
  local label="${1:-}" plist="${2:-}" log="${3:-}" extra="${4:-}"
  shift 4 2>/dev/null || return 0
  [[ "${1:-}" == "--" ]] && shift
  [[ -n "$label" && -n "$plist" ]] || return 0
  mkdir -p "$(dirname "$plist")" 2>/dev/null || true
  [[ -n "$log" ]] && mkdir -p "$(dirname "$log")" 2>/dev/null || true
  local args_xml="" a
  for a in "$@"; do
    args_xml+="    <string>$(_pbrain_xml_escape "$a")</string>"$'\n'
  done
  local log_xml=""
  if [[ -n "$log" ]]; then
    local lx; lx="$(_pbrain_xml_escape "$log")"
    log_xml="  <key>StandardOutPath</key><string>$lx</string>
  <key>StandardErrorPath</key><string>$lx</string>"
  fi
  cat > "$plist" 2>/dev/null <<PLISTEOF || return 0
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(_pbrain_xml_escape "$label")</string>
  <key>ProgramArguments</key>
  <array>
${args_xml}  </array>
${extra}
${log_xml}
</dict>
</plist>
PLISTEOF
  local uid; uid="$(id -u)"
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || {
    launchctl unload "$plist" 2>/dev/null || true
    launchctl load "$plist" 2>/dev/null || true
  }
  return 0
}

# pbrain_launchagent_uninstall <label> <plist_path> — bootout + remove the plist.
# Always returns 0. Echoes nothing (the caller reports).
pbrain_launchagent_uninstall() {
  local label="${1:-}" plist="${2:-}"
  [[ -n "$label" ]] || return 0
  local uid; uid="$(id -u)"
  launchctl bootout "gui/$uid/$label" 2>/dev/null \
    || launchctl unload "$plist" 2>/dev/null || true
  [[ -n "$plist" && -f "$plist" ]] && rm -f "$plist" 2>/dev/null || true
  return 0
}

# pbrain_launchagent_loaded <label> — return 0 if the agent is currently loaded in
# the user's GUI domain, 1 otherwise. Best-effort (returns 1 if launchctl absent).
pbrain_launchagent_loaded() {
  local label="${1:-}"
  [[ -n "$label" ]] || return 1
  command -v launchctl >/dev/null 2>&1 || return 1
  local uid; uid="$(id -u)"
  launchctl print "gui/$uid/$label" >/dev/null 2>&1
}
