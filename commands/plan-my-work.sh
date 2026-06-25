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

# --- explicit MODE selectors (PB-147) ---------------------------------------
# The 4 execution modes are normally INFERRED (id→1, desc→2, no-arg→4), but a user
# can name a hands-off mode explicitly. These selector words are consumed here so the
# rest of the dispatcher / NL normalizer never sees them:
#   auto | --auto | autodrive | drive   → MODE 3 (auto-drive the whole queue)
#   top | next | --top | --next         → MODE 4 (claim the single top of queue)
# The execution LOOP is identical across all modes; only selection + gating differ.
PMW_MODE=""
case "${1:-}" in
  auto|--auto|autodrive|drive)   PMW_MODE="3"; shift ;;
  top|next|--top|--next)         PMW_MODE="4"; shift ;;
esac
export PMW_MODE

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
if [[ -z "$PMW_MODE" && "${1:-}" != "task" && $# -gt 0 ]]; then
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
HABITS_CMD="$(pbrain_habits_cmd 2>/dev/null || true)"
PM_CMD="$(pbrain_projects_manager_cmd 2>/dev/null || true)"
PM_CMD="${PM_CMD:-/project-manager}"

# Browser-facing Plane base for clickable links — derive from the backend's
# `web-base` (single source of truth: swaps the 127.0.0.1 loopback for the vanity
# host, honours PBRAIN_PLANE_WEB_BASE). Fall back to the local-default vhost only if
# the backend yields nothing, so links are never blank.
PLANE_WEB_BASE="${PBRAIN_PLANE_WEB_BASE:-}"
if [[ -z "$PLANE_WEB_BASE" ]]; then
  PLANE_WEB_BASE="$(eval "$PM_CMD web-base" 2>/dev/null | grep -E '^https?://' | tail -1 || true)"
fi
PLANE_WEB_BASE="${PLANE_WEB_BASE:-http://plane.localhost:1800/pb}"

# Plane is the sole state store now — the loop cannot run without it.
if ! pbrain_plane_configured; then
  echo "PLAN_MY_WORK_NO_PLANE"
  echo "Plane is not configured, and the execution loop reads/writes all state in"
  echo "Plane. Set it up with /project-manager, then re-run /plan-my-work <id>."
  exit 0
fi

# --- MODE 3: auto-drive the whole queue (PB-147/PB-150) ---------------------
# Hands-off. The .sh does NOT loop (the execution loop is agent-driven — it writes
# code/PRs and can't run in pure shell). Instead it hands the agent a session token
# + context and the MODE 3 instructions in execute.txt run the loop:
#   claim-next → run the 5-stage loop → at the land gate without auto:land PARK +
#   log the bottleneck + move on → repeat until claim-next returns null.
# The queue claim-next consumes is CROSS-PROJECT (groom's merged ranked queue) and
# already skips `parked` issues (PB-152/PB-154).
if [[ "$PMW_MODE" == "3" ]]; then
  PMW_SESSION="$$$(date +%s 2>/dev/null || echo 0)"
  WORKING_LOCATIONS_JSON="$(pbrain_projects_workdirs_json 2>/dev/null || echo '{}')"
  REGISTRY_JSON="$(pbrain_projects_registry_json 2>/dev/null || echo '[]')"
  echo "PLAN_MY_WORK_AUTODRIVE"
  echo "mode: 3"
  echo "action: autodrive"
  echo "today: $TODAY"
  echo "now_time: $NOW_TIME"
  echo "session: $PMW_SESSION"
  echo "project_manager_cmd: ${PM_CMD}"
  echo "habits_cmd: ${HABITS_CMD:-(unavailable)}"
  echo "plane_web_base: $PLANE_WEB_BASE"
  pbrain_selfhost_staleness_line || true
  echo ""
  echo "=== WORKING LOCATIONS (plane.json projects[].work) ==="
  echo "$WORKING_LOCATIONS_JSON"
  echo ""
  echo "=== PROJECT REGISTRY ==="
  echo "$REGISTRY_JSON"
  echo ""
  TARGET_REF=""; TARGET_KIND="autodrive"
  export TODAY NOW_TIME TARGET_REF TARGET_KIND WORKING_LOCATIONS_JSON REGISTRY_JSON PM_CMD HABITS_CMD PLANE_WEB_BASE PMW_MODE PMW_SESSION
  envsubst '$TODAY $NOW_TIME $TARGET_REF $TARGET_KIND $PM_CMD $HABITS_CMD $PLANE_WEB_BASE $PMW_MODE $PMW_SESSION' < "$_SCRIPT_DIR/templates/plan-my-work/execute.txt"
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

# No id → walk the QUEUE (PB-141). Groom ranks todo issues into Plane's Queued
# state; with no explicit id, pmw drives the TOP of that queue. This is how you
# "walk the queue": run /plan-my-work with no arg repeatedly and it takes the next
# Queued issue each time (completing one advances it out, so the top moves down).
# pmw still doesn't INVENT or reorder work — it only consumes groom's ranked queue.
if [[ -z "${TARGET_REF// }" ]]; then
  # ATOMIC CLAIM (PB-141): claim-next moves the top Queued issue into Planning +
  # stamps a per-session sentinel, then verifies THIS session won — so two parallel
  # /plan-my-work drivers walking the queue pick DIFFERENT issues sequentially
  # instead of colliding on the same top. The session token is pid+epoch (unique).
  PMW_SESSION="$$$(date +%s 2>/dev/null || echo 0)"
  CLAIM_JSON="$(eval "$PM_CMD claim-next --session $PMW_SESSION" 2>/dev/null | grep -E '^(\{|null)' | tail -1 || true)"
  QUEUE_TOP="$(QJSON="$CLAIM_JSON" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    top = json.loads(os.environ.get("QJSON") or "null")
except Exception:
    top = None
if top:
    print("%s\t%s\t%s" % (top.get("id", ""), top.get("tie", ""), top.get("title", "")))
PY
)"
  if [[ -n "$QUEUE_TOP" ]]; then
    q_id="$(printf '%s' "$QUEUE_TOP" | cut -f1)"
    q_tie="$(printf '%s' "$QUEUE_TOP" | cut -f2)"
    q_title="$(printf '%s' "$QUEUE_TOP" | cut -f3)"
    # Drive the tie (unambiguous); execute.txt treats it as an id target. The issue
    # is ALREADY in Planning (claimed) — execute.txt re-reads state and continues.
    TARGET_REF="$q_tie"
    PMW_TARGET_KIND="id"
    PMW_MODE="4"   # no-arg / top / next = MODE 4 (claim the single top of queue)
    echo "PLAN_MY_WORK_QUEUE_PULL"
    echo "mode: 4"
    echo "claimed the top of the Queued state (groom's ranked queue) for this session:"
    echo "  PB-${q_id#PB-}  ${q_title}"
    echo "(no id given — walking the queue. The issue is now claimed (→ Planning) so a"
    echo " parallel /plan-my-work session takes the NEXT one. Run again for the next.)"
    echo ""
  else
    # Empty queue (or Plane unreachable) → ask, as before. pmw never invents work.
    echo "PLAN_MY_WORK_NEEDS_ID"
    echo "today: $TODAY"
    echo "project_manager_cmd: $PM_CMD"
    echo ""
    echo "The Queued state is empty — there's nothing groomed to walk. Either run"
    echo "/project-manager groom to (re)build the queue, or tell me which issue to"
    echo "execute (a Plane id like PB-96) or what work to do (a description — it will"
    echo "be searched/filed via ${PM_CMD}). pmw does NOT pick or reorder tasks itself"
    echo "(selection + ranking is groom's job; pmw just walks the Queued state)."
    exit 0
  fi
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

# MODE (PB-147) — when not already set by an explicit selector or the queue walk,
# infer from the target kind: an id-shaped target is MODE 1 (by id); a free-text
# description is MODE 2 (fix-an-issue / find-or-file). The execution loop is the
# SAME for all modes; execute.txt only varies the SELECTION + GATING prose.
if [[ -z "$PMW_MODE" ]]; then
  if [[ "$TARGET_KIND" == "id" ]]; then PMW_MODE="1"; else PMW_MODE="2"; fi
fi

echo "PLAN_MY_WORK_EXECUTE"
echo "mode: ${PMW_MODE}"
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
export TODAY NOW_TIME TARGET_REF TARGET_KIND WORKING_LOCATIONS_JSON REGISTRY_JSON PM_CMD HABITS_CMD PLANE_WEB_BASE PMW_MODE
envsubst '$TODAY $NOW_TIME $TARGET_REF $TARGET_KIND $PM_CMD $HABITS_CMD $PLANE_WEB_BASE $PMW_MODE' < "$_SCRIPT_DIR/templates/plan-my-work/execute.txt"
exit 0
