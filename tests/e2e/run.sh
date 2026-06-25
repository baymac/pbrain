#!/usr/bin/env bash
# run.sh — single filterable entry point for the pbrain e2e framework.
#
# Discovers scenarios under scenarios/<command>/<feature>/*.json, cross-products
# each with the personas it should run against, and drives every (scenario x
# persona) through the command's registered engine (registry.json). Each run emits
# one *.result.json into a shared results dir; report.py then aggregates them into
# ONE standalone HTML. No flags = run everything; flags narrow the set so you only
# regenerate what you ask for.
#
# Usage:
#   run.sh                                   # all commands, all features, default personas
#   run.sh --command fitness-journal         # one command
#   run.sh --command fitness-journal --feature sleep
#   run.sh --command fitness-journal --feature sleep --persona fast
#   run.sh --command fitness-journal --feature sleep --persona-mode live
#   run.sh --list                            # show what WOULD run, don't run it
#
# Selection is data-driven: a scenario JSON carries command/feature/tags/
# persona_mode; --persona-mode overrides the scenario's own mode (e.g. force live).

set -uo pipefail

E2E_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$E2E_DIR/../.." && pwd)"
REGISTRY="$E2E_DIR/registry.json"
REPORT_DIR="$REPO_ROOT/.e2e_report"
RESULTS="$REPORT_DIR/.results"

F_COMMAND=""; F_FEATURE=""; F_PERSONA=""; F_MODE=""; LIST_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --command)      F_COMMAND="$2"; shift 2 ;;
    --feature)      F_FEATURE="$2"; shift 2 ;;
    --persona)      F_PERSONA="$2"; shift 2 ;;
    --persona-mode) F_MODE="$2";    shift 2 ;;
    --list)         LIST_ONLY=1;    shift ;;
    -h|--help)      sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "run.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "run.sh: python3 required" >&2; exit 3; }
[[ -f "$REGISTRY" ]] || { echo "run.sh: no registry at $REGISTRY" >&2; exit 3; }

mkdir -p "$RESULTS"
# Fresh results for THIS invocation (the report aggregates whatever is present).
rm -f "$RESULTS"/*.result.json "$RESULTS"/*.transcript.txt 2>/dev/null || true

# reg <command> <key> → value from registry.json
reg() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]))["commands"];print(d.get(sys.argv[2],{}).get(sys.argv[3],""))' "$REGISTRY" "$1" "$2"; }
# reg_personas <command> → space-separated default personas
reg_personas() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]))["commands"];print(" ".join(d.get(sys.argv[2],{}).get("default_personas",[])))' "$REGISTRY" "$1"; }
# sc <file> <key> → scalar value from a scenario JSON (a list value is space-joined)
sc() { python3 -c 'import json,sys
v=json.load(open(sys.argv[1])).get(sys.argv[2],"")
print(" ".join(map(str,v)) if isinstance(v,list) else v)' "$1" "$2"; }

# Which commands to consider.
ALL_COMMANDS="$(python3 -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1]))["commands"].keys()))' "$REGISTRY")"
COMMANDS="$ALL_COMMANDS"; [[ -n "$F_COMMAND" ]] && COMMANDS="$F_COMMAND"

planned=0; ran=0; failed=0; skipped=0
declare -a PLAN

for cmd in $COMMANDS; do
  cmd_dir="$E2E_DIR/scenarios/$cmd"
  [[ -d "$cmd_dir" ]] || { echo "run.sh: no scenarios for command '$cmd'" >&2; continue; }
  # feature subdirs (or a flat set)
  while IFS= read -r scen; do
    [[ -n "$scen" ]] || continue
    feat="$(sc "$scen" feature)"; [[ -n "$feat" ]] || feat="$(basename "$(dirname "$scen")")"
    [[ -n "$F_FEATURE" && "$feat" != "$F_FEATURE" ]] && continue
    # personas: scenario may name its own; else the command defaults.
    personas="$(sc "$scen" personas)"; [[ -n "$personas" ]] || personas="$(reg_personas "$cmd")"
    [[ -n "$personas" ]] || personas="fast"
    for persona in $personas; do
      [[ -n "$F_PERSONA" && "$persona" != "$F_PERSONA" ]] && continue
      mode="$(sc "$scen" persona_mode)"; [[ -n "$F_MODE" ]] && mode="$F_MODE"
      [[ -n "$mode" ]] || mode="$(reg "$cmd" default_mode)"; [[ -n "$mode" ]] || mode="scripted"
      PLAN+=("$cmd|$feat|$persona|$mode|$scen")
      planned=$((planned+1))
    done
  done < <(find "$cmd_dir" -name '*.json' | sort)
done

if [[ "$LIST_ONLY" -eq 1 ]]; then
  printf '%-16s %-8s %-9s %-9s %s\n' COMMAND FEATURE PERSONA MODE SCENARIO
  for row in "${PLAN[@]:-}"; do
    [[ -n "$row" ]] || continue
    IFS='|' read -r c f p m s <<<"$row"
    printf '%-16s %-8s %-9s %-9s %s\n' "$c" "$f" "$p" "$m" "$(basename "$s")"
  done
  echo "($planned run(s) would execute)"
  exit 0
fi

[[ "$planned" -gt 0 ]] || { echo "run.sh: no scenarios matched the filter" >&2; exit 1; }

for row in "${PLAN[@]}"; do
  IFS='|' read -r cmd feat persona mode scen <<<"$row"
  persona_file="$E2E_DIR/personas/$persona/persona.md"
  [[ -f "$persona_file" ]] || persona_file="$E2E_DIR/personas/$persona.md"  # legacy
  # Pick the engine: live mode uses the command's live_engine if defined.
  if [[ "$mode" == "live" ]]; then
    engine="$(reg "$cmd" live_engine)"; run_fn="$(reg "$cmd" live_run_fn)"
    if [[ -z "$engine" ]]; then
      echo "run.sh: command '$cmd' has no live engine; skipping $(basename "$scen") [$persona]" >&2
      skipped=$((skipped+1)); continue
    fi
  else
    engine="$(reg "$cmd" engine)"; run_fn="$(reg "$cmd" run_fn)"
  fi
  echo "▶ $cmd/$feat  $(basename "$scen" .json)  × $persona  [$mode]"
  # Each run in a subshell so a driver's set/exit can't poison the loop.
  (
    source "$E2E_DIR/$engine"
    "$run_fn" "$REPO_ROOT" "$scen" "$persona_file" "$RESULTS"
  )
  rc=$?
  ran=$((ran+1))
  [[ "$rc" -eq 0 ]] || failed=$((failed+1))
done

# Aggregate into one standalone HTML.
report=""
if [[ -n "$(ls -A "$RESULTS" 2>/dev/null)" ]]; then
  report="$(python3 "$E2E_DIR/report.py" "$RESULTS" "$REPORT_DIR" 2>/dev/null)" || true
fi

echo
echo "e2e: ran $ran, failed $failed, skipped $skipped (of $planned planned)"
[[ -n "$report" ]] && echo "e2e report: $report"
[[ "$failed" -eq 0 ]]
