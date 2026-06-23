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
# The report dir (~/.config/pbrain/pm-groom/<date>.md) is a disposable daily
# cache — NOT the vault, NOT the source of truth (the actual grooming write,
# backlog→todo, lands in Plane via --apply). Each run prunes to the newest
# PBRAIN_PMG_KEEP reports (default 14) so it self-bounds instead of growing one
# .md per day forever.
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

# PB-94: the grooming-data artifact in the VAULT (iCloud-synced, reviewable on the
# phone in the morning) — distinct from the disposable config-cache report above.
# Holds the day's triage info AND the auto-exec queue + auto-work outcomes that the
# execute loop appends. $VAULT_DIR is resolved by lib/vault.sh (sourced before this
# file); PBRAIN_GROOM_DATA_DIR overrides for tests.
pmg_data_dir()  { printf '%s\n' "${PBRAIN_GROOM_DATA_DIR:-${VAULT_DIR:-$HOME/pbrain-vault}/agent-work/daily-grooming}"; }
pmg_data_file() { printf '%s\n' "$(pmg_data_dir)/${1:?date}.md"; }

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

  # PB-94: the ORDERED hand-off queue groom feeds to /plan-my-work (blockers ahead
  # of the issues they block). Best-effort — an empty array if it can't be built.
  local queue_args=(ready --ordered)
  [[ -n "$projects" ]] && queue_args+=(--projects "$projects")
  local queue_json; queue_json="$(python3 "$py" "${queue_args[@]}" 2>>"$logf" || echo '[]')"
  [[ -n "$queue_json" ]] || queue_json='[]'
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
    lines.append("| Project | todo (ready) | needs review | skipped |")
    lines.append("|---|---|---|---|")
    for p in projs:
        c = p.get("counts", {})
        lines.append("| %s | %d | %d | %d |" % (
            p.get("project", p.get("project_id", "?")),
            c.get("todo", 0), c.get("needs_review", 0), c.get("skipped", 0)))
    lines.append("")
todo = data.get("todo", [])
lines.append("## Todo — pipeline-ready (%d)" % len(todo))
lines.append("")
if todo:
    for t in todo:
        lines.append("- **%s** %s" % (t.get("id"), t.get("title", "")))
else:
    lines.append("_None — no well-formed todo issues. (Backlog is the user's staging "
                 "area — groom never promotes it.)_")
lines.append("")
nr = data.get("needs_review", [])
lines.append("## Needs review (thin todo — enrich before running)")
lines.append("")
if nr:
    for r in nr:
        lines.append("- **%s** %s — %s" % (
            r.get("id"), r.get("title", ""), ", ".join(r.get("flags", []))))
else:
    lines.append("_None — every todo issue is well-formed._")
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

  # PB-94: also write the vault-synced grooming-data artifact (triage info + the
  # auto-exec queue). The execute loop appends per-issue auto-work outcomes under
  # "## Auto-work" when it drives the queue. Best-effort: a vault-write failure
  # must not fail the (headless) groom run, so it's wrapped and never fatal.
  local data_out; data_out="$(pmg_data_file "$date")"
  mkdir -p "$(pmg_data_dir)" 2>/dev/null || true
  PMG_JSON="$json" PMG_QUEUE="$queue_json" PMG_DATE="$date" PMG_DATA_OUT="$data_out" python3 - <<'PYEOF' 2>>"$logf" || true
import json, os
data = json.loads(os.environ["PMG_JSON"])
try:
    queue = json.loads(os.environ.get("PMG_QUEUE") or "[]")
except Exception:
    queue = []
date = os.environ["PMG_DATE"]
out = os.environ["PMG_DATA_OUT"]
# Preserve an existing "## Auto-work" section (the execute loop / pmw writes into it
# as it drives + parks issues), so a re-run of the scan doesn't clobber the day's
# recorded outcomes.
existing_autowork = ""
if os.path.exists(out):
    try:
        prev = open(out).read()
        idx = prev.find("\n## Auto-work")
        if idx != -1:
            existing_autowork = prev[idx:].rstrip() + "\n"
    except Exception:
        existing_autowork = ""
L = []
L.append("---")
L.append("type: daily-grooming")
L.append("date: %s" % date)
L.append("source: project-manager groom")
L.append("---")
L.append("")
L.append("# Grooming — %s" % date)
L.append("")
L.append("_Todo-only triage + the ordered run queue. Backlog is your staging area — "
         "groom never touches it. Review on waking, then run `/plan-my-work <id>` to "
         "drive or resume any queued issue._")
L.append("")
# The ordered run queue: todo issues in the order pmw should run them (blockers ahead
# of the issues they block). groom feeds these ids to /plan-my-work one at a time.
L.append("## Queue — ordered (%d)" % len(queue))
L.append("")
if queue:
    L.append("| # | Issue | Priority | Title |")
    L.append("|---|---|---|---|")
    for i, r in enumerate(queue, 1):
        L.append("| %d | %s | %s | %s |" % (
            i, r.get("id"), r.get("priority", ""), r.get("title", "")))
else:
    L.append("_None — no todo issues ready to run. (Move a backlog issue to todo to "
             "queue it.)_")
L.append("")
# Thin todo issues to enrich before running.
nr = data.get("needs_review", [])
L.append("## Needs review (thin todo — enrich before running)")
L.append("")
if nr:
    for r in nr:
        L.append("- **%s** %s — %s" % (
            r.get("id"), r.get("title", ""), ", ".join(r.get("flags", []))))
else:
    L.append("_None — every todo issue is well-formed._")
L.append("")
if existing_autowork:
    L.append(existing_autowork.rstrip())
    L.append("")
else:
    # Seed an empty Auto-work section pmw appends to as it drives each queued id.
    L.append("## Auto-work")
    L.append("")
    L.append("_Empty until `/plan-my-work` drives the queue — each id records how far "
             "it got (which stages auto-advanced) and the manual stage it parked at._")
    L.append("")
with open(out, "w") as f:
    f.write("\n".join(L).rstrip() + "\n")
PYEOF

  pmg_prune "$(pmg_report_dir)" "${PBRAIN_PMG_KEEP:-14}"
  echo "$out"
  return 0
}

# pmg_prune <dir> <keep> — delete all but the newest <keep> dated reports in
# <dir>. keep<=0 (or non-numeric) disables pruning. Mirrors pbrain_vbk_prune:
# the report dir is a disposable daily cache, so it bounds itself instead of
# growing one .md per day forever. Best-effort, always returns 0.
pmg_prune() {
  local dir="${1:-}" keep="${2:-14}"
  [[ -d "$dir" ]] || return 0
  case "$keep" in ''|*[!0-9]*) return 0 ;; esac
  [[ "$keep" -gt 0 ]] || return 0
  local f
  ls -1 "$dir"/*.md 2>/dev/null | sort -r | tail -n +"$((keep + 1))" | while IFS= read -r f; do
    [[ -n "$f" ]] && rm -f "$f" 2>/dev/null && echo "pruned $(basename "$f")" >&2 || true
  done
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

# pmg_doctor [--apply] — diagnose whether the daily groom LaunchAgent will fire
# reliably on AC power, and (optionally, opt-in) apply the one fix that matters.
#
# Why this exists (PB-79): the groom agent uses StartCalendarInterval at 06:40.
# launchd DOES run a missed StartCalendarInterval job on the next wake — but only
# while the Mac can wake/run work during AC sleep, which is gated by Power Nap.
# With Power Nap off and the lid closed overnight on AC, the 06:40 fire can be
# skipped until the user opens the laptop. So the one knob that makes overnight
# firing reliable is `pmset -c powernap 1`. Everything else here is informational.
#
# Read-only by default: it prints a verdict + the exact command to fix it. With
# --apply it runs `sudo pmset -c powernap 1` (which prompts for a password). It
# NEVER writes any setting unless --apply is passed.
#
# Verdict policy:
#   FAIL  — agent not installed/loaded (groom won't fire at all → `groom enable`)
#   WARN  — installed, but Power Nap is off on AC (catch-up-on-wake still works,
#           but overnight firing isn't guaranteed → enable Power Nap)
#   OK    — installed + Power Nap on (AC)
#   UNKNOWN — pmset unavailable / not macOS (can't assess power policy)
# Bash-3.2-safe; never exits non-zero (call site adds `|| true`).
pmg_doctor() {
  local do_apply=no
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) do_apply=yes; shift;;
      *) shift;;
    esac
  done

  echo "PMG_DOCTOR"
  echo "label: $PMG_LABEL"

  # --- 1. Is the agent installed + loaded? -------------------------------
  local plist sched=no loaded=no
  plist="$(pmg_plist)"
  [[ -f "$plist" ]] && sched=yes
  if pbrain_launchagent_loaded "$PMG_LABEL" 2>/dev/null; then loaded=yes; fi
  echo "scheduled: $sched"
  echo "loaded: $loaded"

  # --- 2. Power source + AC Power Nap policy (read-only) -----------------
  local power_source="unknown" powernap_ac="unknown" sleep_ac="unknown"
  if command -v pmset >/dev/null 2>&1; then
    # Current power source: "AC" or "Battery". `pmset -g batt` line 1 reads e.g.
    # "Now drawing from 'AC Power'" or "Now drawing from 'Battery Power'".
    case "$(pmset -g batt 2>/dev/null | head -1)" in
      *"AC Power"*)  power_source="AC";;
      *Battery*)     power_source="Battery";;
    esac
    # Parse the AC block of `pmset -g custom` for powernap + sleep.
    # Format: two sections headed "AC Power:" and "Battery Power:", each with
    # indented "key value" lines. We read only the AC section.
    local custom; custom="$(pmset -g custom 2>/dev/null || true)"
    if [[ -n "$custom" ]]; then
      local parsed
      parsed="$(printf '%s\n' "$custom" | awk '
        /^AC Power:/      { sect="ac"; next }
        /^Battery Power:/ { sect="batt"; next }
        sect=="ac" && $1=="powernap" { pn=$2 }
        sect=="ac" && $1=="sleep"    { sl=$2 }
        END { printf "%s|%s", (pn==""?"unknown":pn), (sl==""?"unknown":sl) }
      ')"
      powernap_ac="${parsed%%|*}"
      sleep_ac="${parsed##*|}"
    fi
  fi
  echo "power_source: $power_source"
  echo "powernap_ac: $powernap_ac"
  echo "sleep_ac: $sleep_ac"

  # --- 3. Verdict --------------------------------------------------------
  local verdict fix=""
  if [[ "$sched" != yes || "$loaded" != yes ]]; then
    verdict="FAIL"
    fix="groom isn't scheduled — run: /project-manager groom enable"
  elif [[ "$powernap_ac" == "unknown" ]]; then
    verdict="UNKNOWN"
    fix="couldn't read AC power policy (pmset unavailable) — can't confirm overnight firing"
  elif [[ "$powernap_ac" == "1" ]]; then
    verdict="OK"
  else
    verdict="WARN"
    fix="Power Nap is off on AC, so the 06:40 groom may not fire during overnight sleep until you open the lid. Enable it: sudo pmset -c powernap 1  (or System Settings > Battery > Options > Power Nap). Re-run with --apply to do it now."
  fi
  echo "verdict: $verdict"
  [[ -n "$fix" ]] && echo "fix: $fix"

  # --- 4. Opt-in apply (the only setting we ever write) ------------------
  # The privilege wrapper is overridable (PBRAIN_PMG_SUDO) so tests can stub it;
  # in real use it's `sudo`, which prompts for a password.
  local sudo_cmd="${PBRAIN_PMG_SUDO:-sudo}"
  if [[ "$do_apply" == yes ]]; then
    if [[ "$verdict" == "WARN" ]] && command -v pmset >/dev/null 2>&1; then
      echo "applying: $sudo_cmd pmset -c powernap 1"
      if $sudo_cmd pmset -c powernap 1 2>/dev/null; then
        echo "applied: powernap=1 (AC) — re-run 'groom doctor' to confirm"
      else
        echo "apply_failed: could not set powernap (sudo declined or pmset error)"
      fi
    else
      echo "apply_skipped: nothing to apply (verdict=$verdict)"
    fi
  fi
  return 0
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
    <key>PBRAIN_PMG_HEADLESS</key><string>1</string>
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
