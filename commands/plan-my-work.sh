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

source "$_SCRIPT_DIR/../lib/vault.sh"

pbrain_emit_prefs "plan-my-work" || true

PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
STORE="$(pbrain_profile_store "$PLAN_DIR")"

TODAY="$(date +%Y-%m-%d)"
NOW_TIME="$(date +%H:%M)"
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
# `task` subcommand — revise an EXISTING day's WORK TRACKER without rebuilding.
#   task add | task remove | task list   (moved here from /plan-my-day)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "task" ]]; then
  TASK_ACTION="${2:-list}"
  case "$TASK_ACTION" in
    add|remove|list|execute) ;;
    *) echo "usage: plan-my-work.sh task add|remove|list|execute" >&2; exit 2;;
  esac
  if [[ ! -f "$OUT_FILE" ]]; then
    echo "PLAN_MY_WORK_TASK_NO_PLAN"
    echo "action: $TASK_ACTION"
    echo "file: $OUT_FILE"
    echo ""
    echo "INSTRUCTIONS: There's no day plan for $TODAY yet, so there's no work tracker"
    echo "to edit. Tell the user to run /plan-my-day (lay out the day), then /plan-my-work"
    echo "(fill the blocks) first — the task verb only revises an existing day. Stop here."
    exit 0
  fi

  # --- task execute (PB-40) — drive the CURRENT block's tasks to Done --------
  # The deterministic half lives here: which block contains `now`, and that
  # block's unfinished Work-tracker rows (done filtered out → resume-safe). The
  # lifecycle/cascade + every Plane/git/PR/merge step is driven by execute.txt.
  if [[ "$TASK_ACTION" == execute ]]; then
    # ONE $()-captured python heredoc (bash-3.2 trap — no apostrophes inside).
    # Prints two lines: the current block label, then the not-done rows as JSON.
    EXEC_PARSE="$(python3 - "$OUT_FILE" "$NOW_TIME" <<'PY'
import sys, re, json
path, now = sys.argv[1], sys.argv[2]
try:
    txt = open(path).read()
except Exception:
    txt = ""
def mins(t):
    h, m = t.split(":")
    return int(h) * 60 + int(m)
try:
    now_min = mins(now)
except Exception:
    now_min = 0
header = "## Work tracker"
i = txt.find(header)
section = ""
if i != -1:
    section = txt[i + len(header):]
    nxt = section.find("\n## ")
    if nxt != -1:
        section = section[:nxt]
cols = ["block", "task", "project", "plane", "priority", "est",
        "status", "done_at", "pct", "est_rating", "notes"]
rows = []
for ln in section.splitlines():
    s = ln.strip()
    if not s.startswith("|") or "---" in s:
        continue
    cells = [c.strip() for c in s.strip("|").split("|")]
    if not cells or cells[0].lower() == "block":
        continue
    row = {}
    for idx, name in enumerate(cols):
        row[name] = cells[idx] if idx < len(cells) else ""
    rows.append(row)
rng = re.compile(r"\((\d{1,2}:\d{2})\s*[–\-]\s*(\d{1,2}:\d{2})\)")
order = []
blocks = {}
for r in rows:
    lab = r["block"]
    if lab not in blocks:
        blocks[lab] = {"label": lab, "start": None, "end": None, "rows": []}
        order.append(lab)
    blocks[lab]["rows"].append(r)
    m = rng.search(lab)
    if m and blocks[lab]["start"] is None:
        blocks[lab]["start"] = mins(m.group(1))
        blocks[lab]["end"] = mins(m.group(2))
ranged = [blocks[l] for l in order if blocks[l]["start"] is not None]
current = None
for b in sorted(ranged, key=lambda b: b["start"]):
    if b["start"] <= now_min < b["end"]:
        current = b
        break
if current is None:
    up = [b for b in ranged if b["start"] > now_min]
    if up:
        current = sorted(up, key=lambda b: b["start"])[0]
if current is None and not ranged and order:
    current = blocks[order[0]]
label = current["label"] if current else "none"
tasks = []
if current:
    for r in current["rows"]:
        if (r.get("status") or "").strip().lower() == "done":
            continue
        tasks.append(r)
print(label)
print(json.dumps(tasks, ensure_ascii=False))
PY
)"
    CURRENT_BLOCK="$(printf '%s\n' "$EXEC_PARSE" | head -1)"
    CURRENT_TASKS_JSON="$(printf '%s\n' "$EXEC_PARSE" | tail -n +2)"
    [[ -n "$CURRENT_BLOCK" ]] || CURRENT_BLOCK="none"
    [[ -n "$CURRENT_TASKS_JSON" ]] || CURRENT_TASKS_JSON="[]"
    WORKING_LOCATIONS_JSON="$(pbrain_projects_workdirs_json 2>/dev/null || echo '{}')"
    PM_CMD="${PM_CMD:-/project-manager}"

    echo "PLAN_MY_WORK_EXECUTE"
    echo "action: execute"
    echo "file: $OUT_FILE"
    echo "today: $TODAY"
    echo "now_time: $NOW_TIME"
    echo "current_block: $CURRENT_BLOCK"
    echo "weekly_pids: ${WEEKLY_PIDS:-(none)}"
    echo "project_manager_cmd: ${PM_CMD:-(unavailable)}"
    echo "habits_cmd: ${HABITS_CMD:-(unavailable)}"
    echo "plane_web_base: $PLANE_WEB_BASE"
    echo ""
    echo "=== CURRENT BLOCK ==="
    echo "$CURRENT_BLOCK"
    echo ""
    echo "=== CURRENT BLOCK TASKS (not-done rows — resume from the first) ==="
    echo "$CURRENT_TASKS_JSON"
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
    export OUT_FILE TODAY NOW_TIME CURRENT_BLOCK CURRENT_TASKS_JSON WORKING_LOCATIONS_JSON WEEKLY_PIDS REGISTRY_JSON PM_CMD HABITS_CMD PLANE_WEB_BASE
    envsubst '$OUT_FILE $TODAY $NOW_TIME $CURRENT_BLOCK $WEEKLY_PIDS $PM_CMD $HABITS_CMD $PLANE_WEB_BASE' < "$_SCRIPT_DIR/templates/plan-my-work/execute.txt"
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

echo "PLAN_MY_WORK_SESSION"
echo "today: $TODAY"
echo "now_time: $NOW_TIME"
echo "iso_week: $ISO_WEEK"
echo "month_year: $MONTH_YEAR"
echo "file: $OUT_FILE"
echo "plan_exists: $PLAN_EXISTS"
echo "plane_configured: $(pbrain_plane_configured && echo yes || echo no)"
echo "weekly_pids: ${WEEKLY_PIDS:-(none)}"
echo "project_manager_cmd: ${PM_CMD:-(unavailable)}"
echo "blocks_helper: bash \"$_SCRIPT_DIR/plan-my-work.sh\" blocks --now HH:MM --bed HH:MM --session-min N --break-min N"
echo "alloc_helper: bash \"$_SCRIPT_DIR/plan-my-work.sh\" alloc --chosen '<json>' --blocks N"
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
if [[ "$PLAN_EXISTS" == yes ]]; then
  echo "=== TODAY'S PLAN ($OUT_FILE) — work blocks to fill ==="
  cat "$OUT_FILE"
  echo ""
fi

# Instructions live in commands/templates/plan-my-work/session.txt — the .sh is a
# thin dispatcher (mirrors /plan-my-day). Grooming/triage hands off to
# /project-manager (separation of concern); this layer owns goals → blocks.
PM_CMD="${PM_CMD:-/project-manager}"
export PM_CMD WEEKLY_PIDS OUT_FILE PLANE_WEB_BASE
envsubst '$PM_CMD $WEEKLY_PIDS $OUT_FILE $PLANE_WEB_BASE' < "$_SCRIPT_DIR/templates/plan-my-work/session.txt"

pbrain_emit_habits_extract "plan-my-work" || true
pbrain_emit_self_improve "plan-my-work" "$PROFILE_FILE" "plans profile" || true
