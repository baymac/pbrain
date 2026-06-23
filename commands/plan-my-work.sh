#!/usr/bin/env bash
set -euo pipefail

# plan-my-work.sh — fill the day's work blocks with real tasks pulled from Plane.
#
# Runs AFTER /plan-my-day (which lays out the life anchors + empty work blocks).
# /plan-my-day stopped assigning tasks; /plan-my-work is the work layer:
#   1. delegate grooming of this week's goal projects to /project-manager (it owns
#      every Plane write — this layer never triages inline),
#   2. show a progress report keyed off this week's PROJECT-level goals (+ monthly),
#   3. let the user pick today's projects → renormalize their allocation,
#   4. pull ready tasks from Plane and pack them into the blocks,
#   5. write a rich "## Work tracker" into the SAME daily file.
#
# The session INSTRUCTIONS + the task-verb prompts are externalized to
# commands/templates/plan-my-work/*.txt (this .sh is a thin dispatcher).
#
# It writes into $PLAN_DIR/$TODAY.md — editing in place when /plan-my-day wrote
# it, or creating a minimal standalone file (now → bed work blocks, no whole-day
# timeline) when run alone. /end-of-day reconciles the tracker back to Plane.
#
# Subcommands:
#   (none)                 plan today's work (the main flow)
#   task add|remove|list   revise an existing day's work tracker + re-flow blocks
#   blocks <flags>         [internal] standalone block count from now → bed
#   alloc <flags>          [internal] renormalize chosen allocations → blocks
#
# Overrides: same as /plan-my-day — PBRAIN_PLAN_DIR, PBRAIN_PLAN_PROFILE_FILE,
#   PBRAIN_FITNESS_DIR (wake/bed anchors), plus the Plane backend env.

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK

# --- internal math subcommands (no vault needed; pure + unit-testable) ------
# Kept ABOVE the vault.sh source so the bats math tests don't need a vault.
if [[ "${1:-}" == "blocks" ]]; then
  shift
  python3 - "$@" <<'PY'
import sys
def getf(flags, name, default=None):
    if name in flags:
        return flags[flags.index(name)+1]
    return default
args = sys.argv[1:]
flags = args
now = getf(flags, "--now", "")
bed = getf(flags, "--bed", "")
sess = int(getf(flags, "--session-min", "90"))
brk = int(getf(flags, "--break-min", "30"))
def mins(t):
    h, m = t.split(":"); return int(h)*60+int(m)
avail = mins(bed) - mins(now)
if avail <= 0:
    print(0); sys.exit(0)
per = sess + brk
# last block needs no trailing break → add one break back before flooring
n = (avail + brk) // per
print(max(0, int(n)))
PY
  exit 0
fi

if [[ "${1:-}" == "alloc" ]]; then
  shift
  # --chosen '<json array of {id,project_name,priority,allocation_percent}>' --blocks N
  CHOSEN=""; NBLOCKS="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --chosen) CHOSEN="${2:-}"; shift 2;;
      --blocks) NBLOCKS="${2:-0}"; shift 2;;
      *) shift;;
    esac
  done
  python3 - "$CHOSEN" "$NBLOCKS" <<'PY'
import json, sys
chosen = json.loads(sys.argv[1] or "[]")
N = int(sys.argv[2] or 0)
total = sum(float(g.get("allocation_percent", 0) or 0) for g in chosen)
n = len(chosen)
for g in chosen:
    if total > 0:
        g["daily_alloc"] = round(100.0 * float(g.get("allocation_percent", 0) or 0) / total, 1)
    else:
        g["daily_alloc"] = round(100.0 / n, 1) if n else 0.0
# distribute N blocks by daily_alloc, then fix rounding so the sum is exactly N
base = [int(round(N * g["daily_alloc"] / 100.0)) for g in chosen]
diff = N - sum(base)
by_pri = sorted(range(n), key=lambda i: chosen[i].get("priority", 99))  # 1 = highest
i = 0
while diff > 0 and n:                      # leftover → highest-priority project
    base[by_pri[i % n]] += 1; diff -= 1; i += 1
while diff < 0:                            # excess → trim lowest-priority first
    trimmed = False
    for j in reversed(by_pri):
        if base[j] > 0:
            base[j] -= 1; diff += 1; trimmed = True; break
    if not trimmed:
        break
for i, g in enumerate(chosen):
    g["blocks"] = base[i]
print(json.dumps(chosen, ensure_ascii=False))
PY
  exit 0
fi

# --- natural-language "do work" routing (PB-96) -----------------------------
# Without this, ONLY the literal `task execute …` form reaches the EXECUTE
# lifecycle; everything else falls through to PLAN_MY_WORK_SESSION, whose step 2
# delegates grooming/triage to /project-manager. So a plain-words work request
# like "fix the X bug", "work on PB-96", or just "pb96" used to TRIAGE the board
# instead of running the plan→implement→PR→close cycle the user actually asked
# for. Here we normalize such a request into the canonical `task execute <ref>`
# form so it flows through the EXACT existing EXECUTE path (no duplicated logic):
#   - a leading action verb (fix/do/work/implement/execute/build/ship/finish/
#     start/tackle, optionally "work on") → execute, with any PB-ref/seq that
#     follows it carried through as the target ($3);
#   - a bare leading PB-ref token (pb96 / PB-96 / 96) → execute that ref;
#   - `task …` (canonical) and the no-arg / planning form are left untouched, so
#     `/plan-my-work` with no args still plans the day's work (SESSION).
# Re-dispatch is deterministic and lives in the .sh (agent-agnostic), so Codex
# and Claude behave identically.
if [[ "${1:-}" != "task" && $# -gt 0 ]]; then
  _PMW_REROUTE="$(python3 - "$@" <<'PY'
import re, sys
args = [a for a in sys.argv[1:] if a.strip()]
if not args:
    sys.exit(0)
VERBS = {"fix", "do", "work", "implement", "execute", "build", "ship",
         "finish", "start", "tackle", "complete", "resolve", "address"}
# A PB-ref token: full id (pb-96 / pb96 / PB-96), or a bare sequence number.
REF = re.compile(r"^(?:pb-?)?(\d+)$", re.IGNORECASE)
def find_ref(tokens):
    for t in tokens:
        m = REF.match(t.strip().strip(":#"))
        if m:
            # normalize to the hyphenless lowercase form the EXECUTE parser
            # already understands (matches() strips a leading "pb-").
            return "pb" + m.group(1)
    return ""
first = args[0].strip().lower()
# "work on PB-96" — treat "on" as a connective after the verb.
verb_form = first in VERBS
ref = find_ref(args)
if verb_form:
    # An NL work request. Carry through a ref if one is present; otherwise emit
    # execute with no target so it drives the ledger / cascades (never triages).
    print("execute")
    print(ref)
elif ref and len(args) == 1:
    # A single bare PB-ref token → execute that ref.
    print("execute")
    print(ref)
# else: print nothing → leave args untouched (planning SESSION form).
PY
)"
  if [[ -n "$_PMW_REROUTE" ]]; then
    _PMW_REF="$(printf '%s\n' "$_PMW_REROUTE" | sed -n '2p')"
    if [[ -n "$_PMW_REF" ]]; then
      set -- task execute "$_PMW_REF"
    else
      set -- task execute
    fi
  fi
  unset _PMW_REROUTE _PMW_REF
fi

source "$_SCRIPT_DIR/../lib/vault.sh"

pbrain_emit_prefs "plan-my-work" || true

PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
STORE="$(pbrain_profile_store "$PLAN_DIR")"

TODAY="$(date +%Y-%m-%d)"
# PBRAIN_NOW lets tests pin "now" (HH:MM) deterministically; falls back to wall clock.
NOW_TIME="${PBRAIN_NOW:-$(date +%H:%M)}"
ISO_WEEK="$(python3 -c "import datetime; t=datetime.date.today(); y,w,_=t.isocalendar(); print(f'{y}-W{w:02d}')")"
MONTH_YEAR="$(date +%Y-%m)"
OUT_FILE="$PLAN_DIR/$TODAY.md"
mkdir -p "$PLAN_DIR"

# Does today already have a /plan-my-day layout (an "## Today at a glance")?
PLAN_EXISTS=no
[[ -f "$OUT_FILE" ]] && grep -q "## Today at a glance" "$OUT_FILE" 2>/dev/null && PLAN_EXISTS=yes

# --- profile resolution (shared with /plan-my-day) --------------------------
PROFILE_FILE="${PBRAIN_PLAN_PROFILE_FILE:-}"
if [[ -n "$PROFILE_FILE" && ! -f "$PROFILE_FILE" ]]; then PROFILE_FILE=""; fi
[[ -n "$PROFILE_FILE" ]] || PROFILE_FILE="$(pbrain_profile_latest "$STORE" plans-profile)"

if [[ -z "$PROFILE_FILE" ]]; then
  echo "PLAN_MY_WORK_NO_PROFILE"
  echo "store: $STORE"
  echo ""
  echo "INSTRUCTIONS: There's no committed plans profile yet, so there's no working"
  echo "style (session length, work hours, bed time) to lay blocks against. Tell the"
  echo "user to run /plan-my-day first — it builds the plans profile and the day's"
  echo "shape; /plan-my-work then fills the work blocks. Stop here."
  exit 0
fi
PROFILE_JSON="$(pbrain_profile_json "$PROFILE_FILE")"
# Lean the profile to what the WORK layer needs (working_style + day shape) —
# current_focus / anti_patterns / planning_guidelines are /plan-my-day's concern.
WORK_PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print(json.dumps({k:d.get(k) for k in ('working_style','typical_day','daily_anchors','rest_days') if d.get(k) is not None}, ensure_ascii=False))" 2>/dev/null || printf '%s' "$PROFILE_JSON")"
# Browser base for clickable tracker links (the loopback base_url isn't browsable);
# override with PBRAIN_PLANE_WEB_BASE if your vhost/workspace slug differs.
PLANE_WEB_BASE="${PBRAIN_PLANE_WEB_BASE:-http://plane.localhost:1800/pb}"

# --- goals (new project-level schema), registry, progress -------------------
WEEKLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$STORE" weekly-goals "$ISO_WEEK" || true)"
MONTHLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$STORE" monthly-goals "$MONTH_YEAR" || true)"
WEEKLY_GOALS_CONTENT="(not set up — /weekly-review creates this week's project goals)"
MONTHLY_GOALS_CONTENT="(not set up — /monthly-review creates this month's project goals)"
[[ -n "$WEEKLY_GOALS_FILE" ]] && WEEKLY_GOALS_CONTENT="$(cat "$WEEKLY_GOALS_FILE" 2>/dev/null || true)"
[[ -n "$MONTHLY_GOALS_FILE" ]] && MONTHLY_GOALS_CONTENT="$(cat "$MONTHLY_GOALS_FILE" 2>/dev/null || true)"

# Plane project ids referenced by this week's goals (for the progress report).
WEEKLY_PIDS=""
if [[ -n "$WEEKLY_GOALS_FILE" ]]; then
  WEEKLY_PIDS="$(pbrain_profile_json "$WEEKLY_GOALS_FILE" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
pids=[g.get("plane_project") for g in d.get("goals",[]) if g.get("plane_project")]
print(",".join(pids))' 2>/dev/null || true)"
fi

REGISTRY_JSON="$(pbrain_projects_registry_json 2>/dev/null || echo '[]')"
PROGRESS_JSON="$(pbrain_projects_progress_json "$WEEKLY_PIDS" "" 2>/dev/null || echo '{}')"
HABITS_CMD="$(pbrain_habits_cmd 2>/dev/null || true)"
PM_CMD="$(pbrain_projects_manager_cmd 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# Standalone Work tracker schema (PB-85). The tracker is a CEO-overview ledger
# that lives BELOW daily planning and is INDEPENDENT of the day's "## Today at a
# glance" work blocks — no Block column, just tasks/notes/time/links. Kept in one
# place so the autonomous-scaffold path and the templates stay in lockstep.
WORK_TRACKER_HEADER='| Task | Project | Plane id | Priority | Est | Status | Started | Done at | Time taken | % complete | Links | Notes |'
WORK_TRACKER_SEP='| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'

# pbrain_pmw_scaffold_file — PB-85 autonomy: pmw creates a minimal daily-planning
# file when none exists, instead of nudging the user to run /plan-my-day first. It
# writes only what pmw owns (frontmatter + an empty "## Work tracker" + an empty
# "## How it went"); /plan-my-day later lays "## Today at a glance" ABOVE the
# tracker without disturbing it. Idempotent: only writes when the file is absent.
pbrain_pmw_scaffold_file() {
  local f="$1"
  [[ -f "$f" ]] && return 0
  mkdir -p "$(dirname "$f")"
  local dow; dow="$(date -j -f "%Y-%m-%d" "$TODAY" "+%A" 2>/dev/null || date "+%A")"
  {
    printf -- '---\n'
    printf 'type: daily-plan\n'
    printf 'date: %s\n' "$TODAY"
    printf 'iso_week: %s\n' "$ISO_WEEK"
    printf 'standalone: true\n'
    printf 'source: plan-my-work\n'
    printf -- '---\n\n'
    printf '# %s — %s\n\n' "$TODAY" "$dow"
    printf '## Work tracker\n\n'
    printf '%s\n' "$WORK_TRACKER_HEADER"
    printf '%s\n\n' "$WORK_TRACKER_SEP"
    printf '## How it went\n\n'
  } > "$f"
}

# ---------------------------------------------------------------------------
# `task` subcommand — revise an EXISTING day's WORK TRACKER without rebuilding.
#   task add | task remove | task list   (moved here from /plan-my-day)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "task" ]]; then
  TASK_ACTION="${2:-list}"
  case "$TASK_ACTION" in
    add|remove|list|execute) ;;
    *) echo "usage: plan-my-work.sh task add|remove|list|execute" >&2; exit 2;;
  esac
  # PB-85 autonomy: never nudge the user to run /plan-my-day first. If today has no
  # daily-planning file yet, pmw scaffolds a minimal one (tracker + how-it-went) and
  # proceeds. `task list` on a fresh file simply shows an empty ledger.
  pbrain_pmw_scaffold_file "$OUT_FILE"

  # --- task execute (PB-40, PB-85) — drive the work-tracker ledger to Done ----
  # The deterministic half lives here. PB-85 decoupled the tracker from the day's
  # "## Today at a glance" work blocks: the tracker is now a standalone ORDERED
  # ledger, so "what to run next" is simply the first not-done row, top to bottom
  # (resume-safe), independent of clock time or any block grouping.
  #
  # PARALLEL EXECUTION (PB-85): each execute session drives its OWN assigned task
  # in its OWN worktree. We do NOT enforce "one task in-progress at a time" and we
  # do NOT block on other in-progress rows — multiple tasks may be in flight in
  # parallel across sessions/worktrees. A single optional argument ($3) names the
  # target row (a PB-id like "85", "PB-85", or a tie/title fragment); when given,
  # that row leads and the rest follow it. With no arg, the first not-done row leads.
  #
  # The parser keys off the table HEADER names (not column position) so BOTH the
  # new schema and legacy Block-column files read correctly (no migration).
  # The lifecycle/cascade + every Plane/git/PR/merge step is driven by execute.txt.
  if [[ "$TASK_ACTION" == execute ]]; then
    TARGET_REF="${3:-}"
    # ONE $()-captured python heredoc (bash-3.2 trap — no apostrophes inside).
    # PB-92: an explicit target is AUTHORITATIVE. With no target, emit the full
    # not-done ledger (first row leads, cascade applies). With a target:
    #   - matched   → emit ONLY that row (solo) so execute drives that one task
    #                 and does NOT cascade to other in-progress rows/worktrees;
    #   - unmatched → emit an EMPTY list (the agent resolves the ref against
    #                 Plane and pulls it in, never substitutes a pending row).
    # The mode is reported on its own stdout line (TARGET_MODE=...) parsed below.
    NEXT_TASKS_JSON="$(python3 - "$OUT_FILE" "$TARGET_REF" <<'PY'
import sys, re, json
path = sys.argv[1]
target = (sys.argv[2] if len(sys.argv) > 2 else "").strip().lower()
try:
    txt = open(path).read()
except Exception:
    txt = ""
header = "## Work tracker"
i = txt.find(header)
section = ""
if i != -1:
    section = txt[i + len(header):]
    nxt = section.find("\n## ")
    if nxt != -1:
        section = section[:nxt]
# Parse the markdown table by HEADER names so old (Block-column) and new schemas
# both read. Normalize header cells to lowercase keys; map a few legacy aliases.
ALIAS = {"plane": "plane", "plane id": "plane", "% complete": "pct", "%": "pct",
         "done at": "done_at", "est rating": "est_rating", "time taken": "time_taken"}
def norm(h):
    h = h.strip().lower()
    return ALIAS.get(h, h.replace(" ", "_"))
lines = [ln for ln in section.splitlines() if ln.strip().startswith("|")]
headers = None
rows = []
for ln in lines:
    cells = [c.strip() for c in ln.strip().strip("|").split("|")]
    if all(set(c) <= set("-: ") for c in cells):  # the |---|---| separator
        continue
    low = [c.lower() for c in cells]
    if headers is None and ("task" in low and ("plane" in low or "plane id" in low or "status" in low)):
        headers = [norm(c) for c in cells]
        continue
    if headers is None:
        continue
    row = {}
    for idx, name in enumerate(headers):
        row[name] = cells[idx] if idx < len(cells) else ""
    rows.append(row)
# Not-done rows, in ledger order.
notdone = [r for r in rows if (r.get("status") or "").strip().lower() != "done"]
def matches(r, t):
    if not t:
        return False
    blob = " ".join(str(v) for v in r.values()).lower()
    t2 = t[3:] if t.startswith("pb-") else t
    # match "85" against "pb-85" boundaries, or any tie/title fragment
    if re.search(r"\bpb-%s\b" % re.escape(t2), blob) or re.search(r"\b%s\b" % re.escape(t2), blob):
        return True
    return t in blob
mode = "none"
if target:
    lead = [r for r in notdone if matches(r, target)]
    if lead:
        # PB-92: solo — drive ONLY the matched row, no cascade tail.
        notdone = lead
        mode = "solo"
    else:
        # PB-92: the ref matched no ledger row. Emit nothing so the agent
        # resolves it against Plane and pulls it in, rather than silently
        # falling back to the first pending row.
        notdone = []
        mode = "unmatched"
# Line 1 = mode, line 2 = the JSON array (split by the caller).
print(mode)
print(json.dumps(notdone, ensure_ascii=False))
PY
)"
    # Split the heredoc output: first line is the mode, the rest is the JSON.
    TARGET_MODE="$(printf '%s\n' "$NEXT_TASKS_JSON" | sed -n '1p')"
    NEXT_TASKS_JSON="$(printf '%s\n' "$NEXT_TASKS_JSON" | sed -n '2,$p')"
    [[ -n "$TARGET_MODE" ]] || TARGET_MODE="none"
    [[ -n "$NEXT_TASKS_JSON" ]] || NEXT_TASKS_JSON="[]"
    WORKING_LOCATIONS_JSON="$(pbrain_projects_workdirs_json 2>/dev/null || echo '{}')"
    PM_CMD="${PM_CMD:-/project-manager}"

    echo "PLAN_MY_WORK_EXECUTE"
    echo "action: execute"
    echo "file: $OUT_FILE"
    echo "today: $TODAY"
    echo "now_time: $NOW_TIME"
    echo "target_ref: ${TARGET_REF:-(none)}"
    echo "target_mode: ${TARGET_MODE}"
    echo "weekly_pids: ${WEEKLY_PIDS:-(none)}"
    echo "project_manager_cmd: ${PM_CMD:-(unavailable)}"
    echo "habits_cmd: ${HABITS_CMD:-(unavailable)}"
    echo "plane_web_base: $PLANE_WEB_BASE"
    # PB-93: deterministic self-host staleness guard. Prints a SELFHOST_STALE
    # line only when this pbrain checkout (the live command wrapper) is not on a
    # clean, up-to-date main; silent on the happy path. The PRE-FLIGHT prose in
    # execute.txt tells the agent how to act on it.
    pbrain_selfhost_staleness_line || true
    echo ""
    echo "=== NEXT TASKS (not-done ledger rows, in order — lead row first) ==="
    echo "$NEXT_TASKS_JSON"
    echo ""
    echo "=== WORKING LOCATIONS (plane.json projects[].work) ==="
    echo "$WORKING_LOCATIONS_JSON"
    echo ""
    echo "=== TODAY'S PLAN ($OUT_FILE) ==="
    cat "$OUT_FILE"
    echo ""
    echo "=== PLANS PROFILE (working_style + day shape) ==="
    echo "$WORK_PROFILE_JSON"
    echo ""
    echo "=== PROJECT REGISTRY ==="
    echo "$REGISTRY_JSON"
    echo ""
    export OUT_FILE TODAY NOW_TIME TARGET_REF TARGET_MODE NEXT_TASKS_JSON WORKING_LOCATIONS_JSON WEEKLY_PIDS REGISTRY_JSON PM_CMD HABITS_CMD PLANE_WEB_BASE
    envsubst '$OUT_FILE $TODAY $NOW_TIME $TARGET_REF $TARGET_MODE $WEEKLY_PIDS $PM_CMD $HABITS_CMD $PLANE_WEB_BASE' < "$_SCRIPT_DIR/templates/plan-my-work/execute.txt"
    exit 0
  fi

  echo "PLAN_MY_WORK_TASK"
  echo "action: $TASK_ACTION"
  echo "file: $OUT_FILE"
  echo "today: $TODAY"
  echo "now_time: $NOW_TIME"
  echo "weekly_pids: ${WEEKLY_PIDS:-(none)}"
  echo "project_manager_cmd: ${PM_CMD:-(unavailable)}"
  echo "habits_cmd: ${HABITS_CMD:-(unavailable)}"
  echo ""
  echo "=== TODAY'S PLAN ($OUT_FILE) ==="
  cat "$OUT_FILE"
  echo ""
  echo "=== PLANS PROFILE (working_style + day shape) ==="
  echo "$WORK_PROFILE_JSON"
  echo ""
  echo "=== PROJECT REGISTRY ==="
  echo "$REGISTRY_JSON"
  echo ""

  # Instructions live in commands/templates/plan-my-work/task-*.txt — the .sh is a
  # thin dispatcher (mirrors /plan-my-day). Plane writes hand off to /project-manager.
  PM_CMD="${PM_CMD:-/project-manager}"
  export OUT_FILE PM_CMD HABITS_CMD TODAY
  case "$TASK_ACTION" in
    list)   cat "$_SCRIPT_DIR/templates/plan-my-work/task-list.txt" ;;
    add)    envsubst '$OUT_FILE $PM_CMD $HABITS_CMD $TODAY' < "$_SCRIPT_DIR/templates/plan-my-work/task-add.txt" ;;
    remove) envsubst '$OUT_FILE' < "$_SCRIPT_DIR/templates/plan-my-work/task-remove.txt" ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Plane preflight — the auto-pull session needs a configured Plane backend.
# (The `task add|remove|list` verb above only edits the day's "## Work tracker"
# and works without Plane — the registry just degrades to [].)
# ---------------------------------------------------------------------------
if ! pbrain_plane_configured; then
  echo "PLAN_MY_WORK_NO_PLANE"
  echo "today: $TODAY"
  echo ""
  echo "INSTRUCTIONS: Pulling tasks into the day's work blocks needs Plane — pbrain's"
  echo "project brain — and it isn't set up yet. Tell the user: task-based planning"
  echo "and project progress require a Plane instance. Set one up with /init-plane"
  echo "(local self-host) or /project-manager setup (Plane Cloud / a remote host),"
  echo "then re-run /plan-my-work. The rest of pbrain (journal, gratitude, fitness,"
  echo "diet, habits, and /plan-my-day's day-shape) works fine without it. Stop here."
  exit 0
fi

# ---------------------------------------------------------------------------
# Main flow — plan today's work.
# ---------------------------------------------------------------------------
# This-week work-tracker rows scraped from the last 7 day-plans (carry-forward +
# week-so-far context). Reads "## Work tracker" (and the legacy "## Task log").
WEEK_TRACKER="$(python3 - "$PLAN_DIR" "$TODAY" <<'PY' 2>/dev/null || true
import os, sys, glob, datetime, re
plan_dir, today = sys.argv[1], sys.argv[2]
try:
    t0 = datetime.date.fromisoformat(today)
except Exception:
    t0 = datetime.date.today()
def in_window(name):
    m = re.match(r"(\d{4}-\d{2}-\d{2})\.md$", name)
    if not m: return False
    try:
        d = datetime.date.fromisoformat(m.group(1))
    except Exception:
        return False
    return 0 <= (t0 - d).days <= 7
out = []
for f in sorted(glob.glob(os.path.join(plan_dir, "*.md"))):
    base = os.path.basename(f)
    if not in_window(base):
        continue
    try:
        txt = open(f).read()
    except Exception:
        continue
    for header in ("## Work tracker", "## Task log"):
        i = txt.find(header)
        if i == -1:
            continue
        section = txt[i+len(header):]
        nxt = section.find("\n## ")
        if nxt != -1:
            section = section[:nxt]
        rows = [ln for ln in section.splitlines()
                if ln.strip().startswith("|") and "---" not in ln]
        if rows:
            out.append("### %s (%s)" % (base[:-3], header))
            out.extend(rows)
        break
print("\n".join(out) if out else "(no work-tracker rows in the last 7 days)")
PY
)"

# PB-85 autonomy: pmw never refuses for lack of a /plan-my-day layout, and never
# nudges the user to run another command first. If today has no daily-planning file
# yet, scaffold a minimal one (frontmatter + empty "## Work tracker" + "## How it
# went") so the session can write a standalone Work tracker. glance_present tells
# the model whether /plan-my-day also laid a "## Today at a glance" above it (which
# pmw must leave untouched) or not.
GLANCE_PRESENT="$PLAN_EXISTS"   # PLAN_EXISTS = "## Today at a glance" grep (line ~129)
pbrain_pmw_scaffold_file "$OUT_FILE"

echo "PLAN_MY_WORK_SESSION"
echo "today: $TODAY"
echo "now_time: $NOW_TIME"
echo "iso_week: $ISO_WEEK"
echo "month_year: $MONTH_YEAR"
echo "file: $OUT_FILE"
echo "glance_present: $GLANCE_PRESENT"
echo "plane_configured: $(pbrain_plane_configured && echo yes || echo no)"
echo "weekly_pids: ${WEEKLY_PIDS:-(none)}"
echo "project_manager_cmd: ${PM_CMD:-(unavailable)}"
echo ""
echo "=== PLANS PROFILE (working_style + day shape) ==="
echo "$WORK_PROFILE_JSON"
echo ""
echo "=== THIS WEEK'S PROJECT GOALS ($ISO_WEEK) ==="
echo "weekly_goals_file: ${WEEKLY_GOALS_FILE:-(not set up)}"
echo "$WEEKLY_GOALS_CONTENT"
echo ""
echo "=== THIS MONTH'S PROJECT GOALS ($MONTH_YEAR) ==="
echo "monthly_goals_file: ${MONTHLY_GOALS_FILE:-(not set up)}"
echo "$MONTHLY_GOALS_CONTENT"
echo ""
echo "=== PROJECT REGISTRY (registry_json) ==="
echo "$REGISTRY_JSON"
echo ""
echo "=== PROGRESS (progress_json, this week's goal projects) ==="
echo "$PROGRESS_JSON"
echo ""
echo "=== THIS WEEK'S WORK TRACKER ROWS (carry-forward context) ==="
echo "$WEEK_TRACKER"
echo ""
# The file always exists now (scaffolded if needed). Show it so the model can
# refresh the standalone "## Work tracker" and respect any "## Today at a glance"
# /plan-my-day laid above it (glance_present tells which case this is).
echo "=== TODAY'S FILE ($OUT_FILE) — refresh the standalone ## Work tracker ==="
cat "$OUT_FILE"
echo ""

# Instructions live in commands/templates/plan-my-work/session.txt — the .sh is a
# thin dispatcher (mirrors /plan-my-day). Grooming/triage hands off to
# /project-manager (separation of concern); this layer owns goals → the tracker.
PM_CMD="${PM_CMD:-/project-manager}"
export PM_CMD WEEKLY_PIDS OUT_FILE PLANE_WEB_BASE
envsubst '$PM_CMD $WEEKLY_PIDS $OUT_FILE $PLANE_WEB_BASE' < "$_SCRIPT_DIR/templates/plan-my-work/session.txt"

pbrain_emit_habits_extract "plan-my-work" || true
