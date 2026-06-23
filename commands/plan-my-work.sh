#!/usr/bin/env bash
set -euo pipefail

# plan-my-work.sh — the EXECUTION layer (PB-94). ONE loop: take a single Plane
# issue id and drive it through the 5-stage auto-execution pipeline
# (plan → implement → test → ship → land), parking at the first stage whose
# `auto:<stage>` label is absent.
#
# PB-94 stripped this command down. It NO LONGER plans the day: there is no
# `## Work tracker`, no daily-planning file, no project picking, no plans-profile,
# no `task add|remove|list`. State lives in PLANE ONLY — the loop reads issue state
# via `/project-manager spec <id> --read` and resume reads a park breadcrumb from
# the issue's comments. This command writes NOTHING to the vault.
#
# Task SELECTION is groom's job (it asks /project-manager for the ordered ready
# stream and feeds ids here one at a time). This command only EXECUTES one id.
#
# The loop INSTRUCTIONS are externalized to
# commands/templates/plan-my-work/execute.txt (this .sh is a thin dispatcher).
#
# Usage:
#   /plan-my-work <issue-id>          run the loop on one issue (pb96 / PB-96 / 96)
#   /plan-my-work task execute <id>   back-compat alias for the same path
#   /plan-my-work <verb> <words…>     NL form (PB-96): "fix the X bug" / "work on pb96"
#   /plan-my-work                     no id → emits PLAN_MY_WORK_NEEDS_ID (asks for one;
#                                     it never picks tasks — selection is groom's job)
#
# Overrides: PBRAIN_PLANE_WEB_BASE (clickable link base), plus the Plane backend env.

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK

# --- natural-language "do work" routing (PB-96) -----------------------------
# Normalize a plain-words work request into the canonical `task execute <target>`
# form so it flows through the EXACT execute path (no duplicated logic). The
# <target> is one of two KINDS the execute template handles:
#   - an ID (pb96 / PB-96 / 96, alone or after a verb) → resolved against Plane;
#   - a DESCRIPTION (free text after an action verb, e.g. "fix the routing bug")
#     → the find-or-file cycle: find a matching issue, else file a NEW one via
#     `${PM_CMD} file "<desc>"`, then execute the resulting id.
# Triggers: a leading action verb, or a bare PB-ref token. `task …` (canonical)
# and the no-arg form are left untouched. Re-dispatch is deterministic and lives
# in the .sh (agent-agnostic) so Codex and Claude behave identically.
PMW_TARGET_KIND=""
if [[ "${1:-}" != "task" && $# -gt 0 ]]; then
  _PMW_REROUTE="$(python3 - "$@" <<'PY'
import re, sys
args = [a for a in sys.argv[1:] if a.strip()]
if not args:
    sys.exit(0)
VERBS = {"fix", "do", "work", "implement", "execute", "build", "ship",
         "finish", "start", "tackle", "complete", "resolve", "address"}
# Connectives dropped after the leading verb so "work on X"/"fix the X" →  "X".
STOP_AFTER_VERB = {"on", "the", "a", "an", "this", "that", "some", "my", "with"}
# Generic filler nouns: a verb + only these ("do some work") names NO specific
# task → no target (the loop asks for an id), NOT a description to file.
FILLER_TARGET = {"work", "stuff", "something", "things", "tasks", "task", "anything"}
# A PB-ref token: full id (pb-96 / pb96 / PB-96), or a bare sequence number.
REF = re.compile(r"^(?:pb-?)?(\d+)$", re.IGNORECASE)
def as_ref(tok):
    m = REF.match(tok.strip().strip(":#"))
    return ("pb" + m.group(1)) if m else ""
def find_ref(tokens):
    for t in tokens:
        r = as_ref(t)
        if r:
            return r
    return ""
first = args[0].strip().lower()
verb_form = first in VERBS
ref = find_ref(args)
if ref and (verb_form or len(args) == 1):
    print("execute"); print("id"); print(ref)
elif verb_form:
    rest = args[1:]
    while rest and rest[0].strip().lower() in STOP_AFTER_VERB:
        rest = rest[1:]
    desc = " ".join(rest).strip()
    rest_words = [w.lower() for w in rest]
    if desc and not all(w in FILLER_TARGET for w in rest_words):
        print("execute"); print("desc"); print(desc)
    else:
        # bare verb / verb + only filler → no target (the loop asks for an id).
        print("execute"); print("none"); print("")
# else: print nothing → leave args untouched.
PY
)"
  if [[ -n "$_PMW_REROUTE" ]]; then
    PMW_TARGET_KIND="$(printf '%s\n' "$_PMW_REROUTE" | sed -n '2p')"
    _PMW_TARGET="$(printf '%s\n' "$_PMW_REROUTE" | sed -n '3p')"
    if [[ -n "$_PMW_TARGET" ]]; then
      set -- task execute "$_PMW_TARGET"
    else
      set -- task execute
    fi
  fi
  unset _PMW_REROUTE _PMW_TARGET
fi
export PMW_TARGET_KIND

source "$_SCRIPT_DIR/../lib/vault.sh"

pbrain_emit_prefs "plan-my-work" || true

TODAY="$(date +%Y-%m-%d)"
# PBRAIN_NOW lets tests pin "now" (HH:MM) deterministically; falls back to wall clock.
NOW_TIME="${PBRAIN_NOW:-$(date +%H:%M)}"
PLANE_WEB_BASE="${PBRAIN_PLANE_WEB_BASE:-http://plane.localhost:1800/pb}"
HABITS_CMD="$(pbrain_habits_cmd 2>/dev/null || true)"
PM_CMD="$(pbrain_projects_manager_cmd 2>/dev/null || true)"
PM_CMD="${PM_CMD:-/project-manager}"

# Plane is the sole state store now — the loop cannot run without it.
if ! pbrain_plane_configured; then
  echo "PLAN_MY_WORK_NO_PLANE"
  echo "Plane is not configured, and the execution loop reads/writes all state in"
  echo "Plane. Set it up with /project-manager, then re-run /plan-my-work <id>."
  exit 0
fi

# --- the single subcommand: run the loop on ONE issue id --------------------
# Accept both `/plan-my-work <id>` (rewritten to `task execute <id>` above when it
# was a bare ref/verb) and the explicit `task execute <id>` back-compat form.
TARGET_REF=""
if [[ "${1:-}" == "task" ]]; then
  [[ "${2:-}" == "execute" ]] || {
    echo "usage: /plan-my-work <issue-id>   (or: task execute <issue-id>)" >&2
    echo "note: 'task add|remove|list' were removed in PB-94 — pmw runs one issue id." >&2
    exit 2
  }
  shift 2 2>/dev/null || true   # drop "task" + "execute"; leave the target in $@
  TARGET_REF="$*"
elif [[ $# -gt 0 ]]; then
  TARGET_REF="$*"
fi

# No id → ask for one. pmw never selects tasks (that's groom's job).
if [[ -z "${TARGET_REF// }" ]]; then
  echo "PLAN_MY_WORK_NEEDS_ID"
  echo "today: $TODAY"
  echo "project_manager_cmd: $PM_CMD"
  echo ""
  echo "/plan-my-work runs ONE issue at a time and needs the issue id to run."
  echo "Ask the user which issue to execute (a Plane id like PB-96), or which work"
  echo "to do (a description — it will be searched/filed via ${PM_CMD}). It does NOT"
  echo "pick tasks itself: task selection + ordering is groom's job"
  echo "(/project-manager groom feeds ids here one at a time)."
  exit 0
fi

# TARGET_KIND (PB-96) — what the target IS, so execute.txt resolves it correctly:
#   id-shaped ref → id (subtree/spec read); any other non-empty target → desc
#   (find-or-file cycle). The NL normalizer may have already set PMW_TARGET_KIND.
TARGET_KIND="${PMW_TARGET_KIND:-}"
if [[ -z "$TARGET_KIND" ]]; then
  if [[ "$TARGET_REF" =~ ^(pb-?)?[0-9]+$ ]]; then
    TARGET_KIND="id"
  else
    TARGET_KIND="desc"
  fi
fi

WORKING_LOCATIONS_JSON="$(pbrain_projects_workdirs_json 2>/dev/null || echo '{}')"
REGISTRY_JSON="$(pbrain_projects_registry_json 2>/dev/null || echo '[]')"

echo "PLAN_MY_WORK_EXECUTE"
echo "action: execute"
echo "today: $TODAY"
echo "now_time: $NOW_TIME"
echo "target_ref: ${TARGET_REF}"
echo "target_kind: ${TARGET_KIND}"
echo "project_manager_cmd: ${PM_CMD}"
echo "habits_cmd: ${HABITS_CMD:-(unavailable)}"
echo "plane_web_base: $PLANE_WEB_BASE"
# PB-93: deterministic self-host staleness guard. Prints a SELFHOST_STALE line only
# when this pbrain checkout (the live command wrapper) is not on a clean, up-to-date
# main; silent on the happy path. The PRE-FLIGHT prose in execute.txt acts on it.
pbrain_selfhost_staleness_line || true
echo ""
echo "=== WORKING LOCATIONS (plane.json projects[].work) ==="
echo "$WORKING_LOCATIONS_JSON"
echo ""
echo "=== PROJECT REGISTRY ==="
echo "$REGISTRY_JSON"
echo ""
export TODAY NOW_TIME TARGET_REF TARGET_KIND WORKING_LOCATIONS_JSON REGISTRY_JSON PM_CMD HABITS_CMD PLANE_WEB_BASE
envsubst '$TODAY $NOW_TIME $TARGET_REF $TARGET_KIND $PM_CMD $HABITS_CMD $PLANE_WEB_BASE' < "$_SCRIPT_DIR/templates/plan-my-work/execute.txt"
exit 0
