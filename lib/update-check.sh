#!/usr/bin/env bash
# pbrain update check — sourced by lib/vault.sh.
#
# Compares the locally-installed plugin version (read from
# .claude-plugin/plugin.json) against the remote on GitHub. When the local
# install is behind, it prints exactly one line to stdout:
#
#   UPGRADE_AVAILABLE <local> <remote>
#
# That line is meant to be picked up by the calling Claude session, which
# then suggests `/plugin update pbrain` to the user. The check is cached
# (1h when up-to-date, 12h when an upgrade is pending) so it never hits
# the network on a hot command.
#
# Env knobs:
#   PBRAIN_UPDATE_CHECK=0          disable the check entirely
#   PBRAIN_REMOTE_PLUGIN_URL=...   override the remote plugin.json URL

_pbrain_update_check() {
  [[ "${PBRAIN_UPDATE_CHECK:-1}" == "0" ]] && return 0

  local lib_dir state_dir cache plugin_json local_ver remote_url
  local cached remote_json remote_ver higher now mtime ttl
  lib_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  state_dir="${XDG_STATE_HOME:-$HOME/.config}/pbrain"
  cache="$state_dir/update-cache"
  plugin_json="${CLAUDE_PLUGIN_ROOT:-$lib_dir/..}/.claude-plugin/plugin.json"
  remote_url="${PBRAIN_REMOTE_PLUGIN_URL:-https://raw.githubusercontent.com/baymac/pbrain/main/.claude-plugin/plugin.json}"

  [[ -f "$plugin_json" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  local_ver="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$plugin_json" 2>/dev/null || true)"
  [[ -n "$local_ver" ]] || return 0

  if [[ -f "$cache" ]]; then
    cached="$(cat "$cache" 2>/dev/null || true)"
    now="$(date +%s)"
    mtime="$(python3 -c 'import os,sys; print(int(os.path.getmtime(sys.argv[1])))' "$cache" 2>/dev/null || echo 0)"
    case "$cached" in
      "UP_TO_DATE $local_ver")
        ttl=3600
        (( now - mtime < ttl )) && return 0
        ;;
      "UPGRADE_AVAILABLE $local_ver "*)
        ttl=43200
        if (( now - mtime < ttl )); then
          echo "$cached"
          return 0
        fi
        ;;
    esac
  fi

  command -v curl >/dev/null 2>&1 || return 0
  mkdir -p "$state_dir"
  remote_json="$(curl -sf --max-time 5 "$remote_url" 2>/dev/null || true)"
  [[ -n "$remote_json" ]] || return 0
  remote_ver="$(printf '%s' "$remote_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)"
  echo "$remote_ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' || return 0

  if [[ "$local_ver" == "$remote_ver" ]]; then
    echo "UP_TO_DATE $local_ver" > "$cache"
    return 0
  fi

  # Only flag when remote sorts strictly higher than local — protects
  # against transient CDN regressions and dev installs running ahead of main.
  higher="$(printf '%s\n%s\n' "$local_ver" "$remote_ver" | sort -V | tail -n1)"
  if [[ "$higher" != "$remote_ver" ]]; then
    echo "UP_TO_DATE $local_ver" > "$cache"
    return 0
  fi

  echo "UPGRADE_AVAILABLE $local_ver $remote_ver" > "$cache"
  echo "UPGRADE_AVAILABLE $local_ver $remote_ver"
}

_pbrain_update_check || true
unset -f _pbrain_update_check
