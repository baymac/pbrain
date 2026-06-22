#!/usr/bin/env bash
# pbrain PM grooming helpers — sourced by commands/project-manager.sh (PB-46).
#
# Implements PB-44 Move 2: take the MECHANICAL half of `/project-manager review`
# (the deterministic triage/dedupe/thin-flag scan that needs no model judgement)
# and make it runnable HEADLESS on a schedule, off the interactive Opus session.
# By the time `/plan-my-work` runs, the board is already triaged and the thin
# issues are queued for review — cutting quota burn and hand-holding.
#
# The deterministic logic lives in lib/plane.py (`groom` subcommand → groom_run):
#   - well-formed BACKLOG issues (description + priority + estimate where a scale
#     exists, not a sub-task) → backlog→todo triage (applied only with --apply).
#   - thin issues → queued into `needs_review`, NEVER auto-edited (the interactive
#     review / spec walks own them — model judgement required).
# This file is the ORCHESTRATION layer: run the scan, render a dated markdown
# report under the config dir, and own the daily LaunchAgent (install/uninstall/
# status), mirroring lib/vault-backup.sh.
#
# Scheduling rides the shared LaunchAgent helper (lib/launchd.sh): a daily
# StartCalendarInterval agent runs `project-manager.sh groom run`.
#
# Like the other lib/ helpers this is best-effort and bash-3.2-safe, and the
# ride-along helpers never exit non-zero (call sites add `|| true`).

PMG_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain"
PMG_LABEL="com.pbrain.pm-groom"

pmg_report_dir()  { printf '%s\n' "${PBRAIN_PMG_DIR:-$PMG_CONFIG_DIR/pm-groom}"; }
pmg_report_file() { printf '%s\n' "$(pmg_report_dir)/${1:?date}.md"; }
pmg_log_file()    { printf '%s\n' "$PMG_CONFIG_DIR/pm-groom.log"; }
pmg_plist()       { printf '%s\n' "$HOME/Library/LaunchAgents/$PMG_LABEL.plist"; }

# This file's own lib/ dir, captured AT SOURCE TIME (when BASH_SOURCE is
# reliable). Resolving it lazily inside a function is unsafe: by call time
# BASH_SOURCE may be empty/relative, pointing pmg_plane_py at the wrong path.
_PMG_LIB_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Resolve plane.py (lives alongside this file in lib/). PBRAIN_PLANE_PY overrides
# for tests; an existing caller-set $PLANE is honoured first.
pmg_plane_py() {
  if [[ -n "${PBRAIN_PLANE_PY:-}" ]]; then printf '%s\n' "$PBRAIN_PLANE_PY"; return; fi
  if [[ -n "${PLANE:-}" && -f "${PLANE:-}" ]]; then printf '%s\n' "$PLANE"; return; fi
  printf '%s\n' "$_PMG_LIB_DIR/plane.py"
}

# pmg_today — today's date (YYYY-MM-DD). Overridable via PBRAIN_PMG_DATE (tests).
pmg_today() { printf '%s\n' "${PBRAIN_PMG_DATE:-$(date +%F)}"; }

# pmg_run [--projects "<csv>"] [--apply] — run the scan, write the dated report,
# echo the report path. Returns the python exit status. The JSON report from
# plane.py is rendered to markdown by an inline Python heredoc (stdlib only).
pmg_run() {
  local projects="" apply=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --projects) projects="${2:-}"; shift 2 ;;
      --apply)    apply="--apply"; shift ;;
      *) shift ;;
    esac
  done
  local py date out
  py="$(pmg_plane_py)"
  date="$(pmg_today)"
  out="$(pmg_report_file "$date")"
  mkdir -p "$(pmg_report_dir)" 2>/dev/null || true

  # Build argv as an ARRAY so the project list stays a single argument and the
  # --projects flag stays separate from it (a quoted ${var:+...} word-splits
  # inconsistently across shells and was passing "--projects <csv>" as one arg).
  local scan_args=(groom)
  [[ -n "$projects" ]] && scan_args+=(--projects "$projects")
  [[ -n "$apply" ]] && scan_args+=("$apply")

  local json rc logf; logf="$(pmg_log_file)"
  mkdir -p "$(dirname "$logf")" 2>/dev/null || true
  json="$(python3 "$py" "${scan_args[@]}" 2>>"$logf")"
  rc=$?
  if [[ $rc -ne 0 || -z "$json" ]]; then
    return $rc
  fi

  PMG_JSON="$json" PMG_DATE="$date" PMG_OUT="$out" python3 - <<'PYEOF'
import json, os
data = json.loads(os.environ["PMG_JSON"])
date = os.environ["PMG_DATE"]
out = os.environ["PMG_OUT"]
applied = data.get("applied")
mode = "applied" if applied else "dry-run"
lines = []
lines.append("# PM groom report — %s (%s)" % (date, mode))
lines.append("")
projs = data.get("projects", [])
if projs:
    lines.append("## Per-project")
    lines.append("")
    lines.append("| Project | triaged | needs review | skipped |")
    lines.append("|---|---|---|---|")
    for p in projs:
        c = p.get("counts", {})
        lines.append("| %s | %d | %d | %d |" % (
            p.get("project", p.get("project_id", "?")),
            c.get("triaged", 0), c.get("needs_review", 0), c.get("skipped", 0)))
    lines.append("")
triaged = data.get("triaged", [])
lines.append("## Triaged backlog → todo (%s)" % ("written" if applied else "proposed"))
lines.append("")
if triaged:
    for t in triaged:
        mark = ""
        if applied:
            mark = " ✅" if t.get("ok") else " ⚠️ %s" % t.get("error", "failed")
        lines.append("- **%s** %s — %s → %s%s" % (
            t.get("id"), t.get("title", ""), t.get("from"), t.get("to"), mark))
else:
    lines.append("_None — no well-formed backlog issues to promote._")
lines.append("")
nr = data.get("needs_review", [])
lines.append("## Needs review (thin — left for the interactive walk)")
lines.append("")
if nr:
    for r in nr:
        lines.append("- **%s** %s [%s] — %s" % (
            r.get("id"), r.get("title", ""), r.get("group", ""),
            ", ".join(r.get("flags", []))))
else:
    lines.append("_None — every top-level issue is well-formed._")
lines.append("")
errs = data.get("errors", [])
if errs:
    lines.append("## Errors")
    lines.append("")
    for e in errs:
        lines.append("- %s: %s" % (e.get("project", e.get("project_id")), e.get("error")))
    lines.append("")
with open(out, "w") as f:
    f.write("\n".join(lines).rstrip() + "\n")
PYEOF
  echo "$out"
  return 0
}

# pmg_report_fresh <date> — true (0) when a report for <date> exists and is
# non-empty. Used by /plan-my-work to decide skip-live-review vs fall back.
pmg_report_fresh() {
  local f; f="$(pmg_report_file "${1:?date}")"
  [[ -s "$f" ]]
}

# pmg_status — one-line schedule + last-report status to stdout.
pmg_status() {
  local plist; plist="$(pmg_plist)"
  local sched="no"
  [[ -f "$plist" ]] && sched="yes ($plist)"
  echo "PMG_STATUS"
  echo "scheduled: $sched"
  echo "label: $PMG_LABEL"
  echo "report_dir: $(pmg_report_dir)"
  local today; today="$(pmg_today)"
  if pmg_report_fresh "$today"; then
    echo "today_report: $(pmg_report_file "$today")"
  else
    echo "today_report: (none)"
  fi
}

# pmg_schedule_install [HH:MM] [csv-projects] — daily LaunchAgent that runs the
# groom scan. Default 06:40 (a few hours before a typical first work block).
pmg_schedule_install() {
  local hhmm="${1:-06:40}" projects="${2:-}"
  local sh
  sh="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../commands" && pwd -P)/project-manager.sh"
  local hh="${hhmm%%:*}" mm="${hhmm##*:}"
  hh=$((10#${hh:-6})); mm=$((10#${mm:-40}))
  local extra
  extra="  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$hh</integer>
    <key>Minute</key><integer>$mm</integer>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>"
  # The scheduled run APPLIES the conservative triage (--apply) for the named
  # projects; thin issues are still only queued, never edited.
  local args=(/bin/bash "$sh" groom run --apply)
  [[ -n "$projects" ]] && args+=(--projects "$projects")
  pbrain_launchagent_install "$PMG_LABEL" "$(pmg_plist)" "$(pmg_log_file)" "$extra" -- "${args[@]}"
}

pmg_schedule_uninstall() {
  pbrain_launchagent_uninstall "$PMG_LABEL" "$(pmg_plist)"
}
