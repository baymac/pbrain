#!/usr/bin/env bash
set -euo pipefail
#
# whats-new.sh — the per-release "what's new" doc (PB-129).
#
# Two jobs:
#   1. render <version>   — turn a CHANGELOG section (markdown on stdin) into a
#                           self-contained styled HTML page, printed to stdout.
#                           Driven by scripts/release.sh whats-new.
#   2. surface            — at the plugin-update moment, emit a one-line pointer
#                           to the newest docs/whats-new/<v>.html and (on macOS,
#                           when a real upgrade just landed) offer to open it.
#                           Sourced/called from the upgrade-nudge path so it
#                           rides the same once-per-cache-window cadence as
#                           lib/update-check.sh — a nudge, never a gate.
#
# The HTML reuses the dark palette from docs/nightly-groom-flow.html so the
# generated pages look native to the repo's docs.
#
# Env:
#   PBRAIN_WHATS_NEW_DIR   override the docs/whats-new directory (tests)
#   PBRAIN_WHATS_NEW_OPEN  set to 0 to suppress the macOS auto-open offer

_WN_SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WHATS_NEW_DIR="${PBRAIN_WHATS_NEW_DIR:-$_WN_SCRIPT_DIR/../docs/whats-new}"

# render <version>  (markdown on stdin → HTML on stdout)
# A deliberately small markdown subset — enough for Keep-a-Changelog bodies:
# ### headings, - bullets (one level), **bold**, `code`, and [text](url) links.
_whats_new_render() {
  local version="$1"
  # Markdown arrives on this function's stdin; the Python source must come from
  # a path (not a heredoc on stdin, which would shadow the piped markdown).
  PBRAIN_WN_VERSION="$version" python3 "$_WN_SCRIPT_DIR/whats-new-render.py"
}

# newest generated doc path (highest SemVer), or empty if none exist.
_whats_new_latest() {
  find "$WHATS_NEW_DIR" -maxdepth 1 -name '*.html' 2>/dev/null \
    | sed 's#.*/##; s#\.html$##' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -V | tail -n1
}

# surface [<new-version>]
# Prints a one-line "what's new" pointer for the newest doc. When a concrete
# new version is passed (a real upgrade just landed) and we're on macOS with a
# TTY, also offer to open it. Never exits non-zero — it's a nudge.
_whats_new_surface() {
  local landed="${1:-}" v doc
  v="$(_whats_new_latest)" || true
  [[ -n "$v" ]] || return 0
  doc="$WHATS_NEW_DIR/$v.html"
  [[ -f "$doc" ]] || return 0
  printf '✨ What'\''s new in pbrain %s — %s\n' "$v" "$doc"
  if [[ -n "$landed" && "${PBRAIN_WHATS_NEW_OPEN:-1}" != "0" ]] \
       && [[ "$(uname)" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
    open "$doc" >/dev/null 2>&1 || true
  fi
  return 0
}

# check
# The auto-open trigger (PB-129). Tracks the last local plugin version we saw in
# a state file; when the local version advances (a `/plugin update` landed) and
# a matching docs/whats-new/<v>.html exists, surfaces it ONCE — the open offer
# fires only on that transition, then the state file is updated so it stays
# quiet until the next upgrade. First-ever run just records the baseline (no
# surface), so a fresh install doesn't pop the doc. Never fatal.
#
# Env: PBRAIN_WHATS_NEW_STATE  override the state file (tests)
#      PBRAIN_PLUGIN_JSON       override the plugin.json read (tests)
_whats_new_check() {
  local plugin_json state seen cur doc higher
  plugin_json="${PBRAIN_PLUGIN_JSON:-$_WN_SCRIPT_DIR/../.claude-plugin/plugin.json}"
  [[ -f "$plugin_json" ]] || return 0
  cur="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$plugin_json" 2>/dev/null || true)"
  printf '%s' "$cur" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || return 0

  state="${PBRAIN_WHATS_NEW_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/pbrain/whats-new.seen}"
  mkdir -p "$(dirname "$state")" 2>/dev/null || return 0
  seen=""; [[ -f "$state" ]] && seen="$(cat "$state" 2>/dev/null || true)"

  # First run: record baseline silently, don't surface.
  if [[ -z "$seen" ]]; then printf '%s\n' "$cur" > "$state"; return 0; fi
  # No change: nothing to show.
  [[ "$seen" == "$cur" ]] && return 0
  # Only surface on an UPWARD move (a downgrade/dev-rewind just re-baselines).
  higher="$(printf '%s\n%s\n' "$seen" "$cur" | sort -V | tail -n1)"
  printf '%s\n' "$cur" > "$state"
  [[ "$higher" == "$cur" ]] || return 0

  doc="$WHATS_NEW_DIR/$cur.html"
  [[ -f "$doc" ]] || return 0
  _whats_new_surface "$cur"
}

# CLI entry (so scripts/release.sh and tests can call it directly).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    render)  _whats_new_render "${1:?usage: whats-new.sh render <version>}" ;;
    latest)  _whats_new_latest ;;
    check)   _whats_new_check ;;
    surface) _whats_new_surface "${1:-}" ;;
    *) printf 'usage: whats-new.sh render <version> | latest | check | surface [<version>]\n' >&2; exit 2 ;;
  esac
fi
