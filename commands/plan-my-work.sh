#!/usr/bin/env bash
set -euo pipefail

# plan-my-work.sh — fill the day's work blocks with real tasks pulled from Plane.
#
# Runs AFTER /plan-my-day (which lays out the life anchors + empty work blocks).
# /plan-my-day stopped assigning tasks; /plan-my-work is the work layer:
#   1. run /project-manager review (so pulled tasks are well-formed),
#   2. show a progress report keyed off this week's PROJECT-level goals,
#   3. let the user pick today's projects → renormalize their allocation,
#   4. pull ready tasks from Plane and pack them into the blocks,
#   5. write a rich "## Work tracker" into the SAME daily file.
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
    add|remove|list) ;;
    *) echo "usage: plan-my-work.sh task add|remove|list" >&2; exit 2;;
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
  echo "=== PLANS PROFILE (working_style) ==="
  echo "$PROFILE_JSON"
  echo ""
  echo "=== PROJECT REGISTRY ==="
  echo "$REGISTRY_JSON"
  echo ""

  if [[ "$TASK_ACTION" == "list" ]]; then
    cat <<'TASKLIST'
---
INSTRUCTIONS — task list. Show the rows of today's "## Work tracker" as a short
numbered list: number, task, project, Plane id (tie), priority, est, status.
Do NOT rewrite the file and do NOT touch "Today at a glance". If there are no
task rows yet, say so in one line. Stop here.
TASKLIST
    exit 0
  fi

  cat <<TASKEDIT
---
INSTRUCTIONS — task $TASK_ACTION. You are revising TODAY'S EXISTING work tracker
($OUT_FILE), not rebuilding the day. The plan carries TWO things that stay in sync:
  • "## Today at a glance" — the gap-free schedule; work blocks flow around the
    FIXED life anchors (calendar, meals, fitness, walk, bed, habit 🔔). Never
    disturb those anchors or ✓ done rows.
  • "## Work tracker" — one row per task pulled from Plane:
    | Block | Task | Project | Plane id | Priority | Est | Status | Done at | % complete | Est rating | Notes |
    where "Plane id" carries the full tie (<project_id>:<issue_id>).

WORKING STYLE (from the plans profile JSON above): use working_style.session_length_min
for block size, working_style.break_min for the gap between blocks, and NEVER
schedule a work block past working_style.last_block_end.
TASKEDIT

  if [[ "$TASK_ACTION" == "add" ]]; then
    cat <<'TASKADD'

For `task add`:
1. IDENTIFY the task. If the user named a Plane issue, use its tie
   (<project_id>:<issue_id>); priority/est come from Plane. If it's a brand-new
   task, offer to create it in Plane first via the project manager
   (`/project-manager` — capture it under the right project), then pull it. If
   the user just wants a quick local row, set Plane id = "—".
2. APPEND a row to "## Work tracker": Block (TBD until placed) | Task | Project |
   Plane id | Priority | Est | planned | (Done at blank) | (% blank) | (Est
   rating blank) | (Notes). Leave existing rows untouched.
3. RE-FLOW "Today at a glance": slot ONE new work block (session_length_min, with
   a break_min break separating it from an adjacent block) into the next free gap
   that fits, honoring the fixed anchors and the last_block_end ceiling. If
   nothing fits before last_block_end, don't silently overflow — offer to (a) do
   it tomorrow, (b) shrink/drop a block, or (c) extend past last_block_end today.
   Set the new tracker row's Block to the placed time range.
4. If the placed block corresponds to a habit with a linked one-shot reminder,
   realign it (best-effort, silent on failure) with habits_cmd above:
     bash "<habits_cmd>" reminders-reschedule --habit "<name>" --time "HH:MM" --date TODAY
TASKADD
  else
    cat <<'TASKREMOVE'

For `task remove`:
1. IDENTIFY the row the user means in "## Work tracker" (by name or list number —
   quote it back).
2. CONFIRM-ON-CLOSED-ROW: if its Status is already filled (anything other than
   "planned"), confirm before removing — /end-of-day's Plane reconcile would
   otherwise lose a closed task. A plain "planned" row removes without the prompt.
3. DROP the row from "## Work tracker".
4. RE-FLOW "Today at a glance": free the removed block — pull later work blocks
   earlier to close the gap, OR leave the span as a rest/buffer row; SAY which.
   Keep the table gap-free; never disturb the fixed anchors or ✓ done rows.
TASKREMOVE
  fi

  cat <<TASKWRITE

After editing, REWRITE BOTH the "## Today at a glance" work-block rows AND the
"## Work tracker" TOGETHER and save the full plan back to $OUT_FILE (they must
never drift apart). Then show the updated blocks + tracker and confirm in one
line what changed. Do not re-run the full work session. Stop here.
TASKWRITE
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
echo "=== PLANS PROFILE (working_style + bed/typical_day) ==="
echo "$PROFILE_JSON"
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

cat <<INSTRUCTIONS
---
INSTRUCTIONS — fill today's work blocks with real tasks from Plane. The plans
profile carries working_style (session_length_min, break_min, work_hours_per_day,
last_block_end) and the typical_day bed time; read them from the JSON above.

1. PREFLIGHT.
   - plan_exists = yes → /plan-my-day already laid out "## Today at a glance"
     with empty work-block rows. Read those rows; you'll label them, not move the
     life anchors (calendar, meals, fitness, walk, bed, habit 🔔 stay put).
   - plan_exists = no → STANDALONE. Don't build a whole-day timeline. Ask the
     user how many focused hours they have, read working_style + bed time, and
     compute the block count from now → bed with:
       bash "$_SCRIPT_DIR/plan-my-work.sh" blocks --now $NOW_TIME --bed <bed HH:MM> --session-min <N> --break-min <N>
     You'll create a minimal file with just a "## Work tracker" (and a short
     "## Today at a glance" listing only the work blocks).

2. ENRICH + TRIAGE (the PM step — do this before picking today's tasks).
   Run the review scan over this week's goal projects (always include backlog since
   new issues default there):
     bash "${PM_CMD:-/project-manager}" review --projects "${WEEKLY_PIDS:-<weekly-goal pids>}"
   (If weekly_pids is empty, ask which projects to pull from and use those.)

   For EVERY issue flagged as thin, apply ALL of the following without asking —
   infer sensible values yourself as a PM would:

   a) DESCRIPTION — write a clear, actionable description covering: what the task
      is, why it matters, what "done" looks like, and any known blockers or
      dependencies. Use description_html. No placeholders.

   b) PRIORITY — assign urgent/high/medium/low based on: deadline proximity,
      dependency chain (blockers get higher priority), week goal allocation%, and
      impact. Urgent = must ship this week or blocks others. High = this week.
      Medium = this month. Low = backlog, no deadline.

   c) ESTIMATE — set the Est field in the tracker (free text: 30m / 1h / 2h / 3h
      / 4h / 6h). Plane's estimate_point is not patchable without a configured UUID
      scheme (and there is none in this workspace); use the tracker column only.
      Base estimates on scope of work in the description: quick fix = 30m–1h,
      feature = 2–4h, large feature = 6h+.

   d) START DATE — set to today for any issue going into today's blocks. Leave
      blank for backlog issues not being worked today.
        bash "${PM_CMD:-/project-manager}" enrich --edits '[{"tie":"<tie>","field":"start_date","value":"$TODAY"}]'

   e) ASSIGNEE — assign to the sole developer (kylojavier68,
      id=e364da77-b440-4f36-a167-f3b96c535bb9) for every issue that has no assignee.
        bash "${PM_CMD:-/project-manager}" enrich --edits '[{"tie":"<tie>","field":"assignees","value":["e364da77-b440-4f36-a167-f3b96c535bb9"]}]'

   f) RELATIONS — wire blocking/blocked_by between issues whose descriptions
      imply a dependency (e.g. "blocked by", "requires X first", "unblocks Y").
      Use field "relation:<type>" (valid types: blocking, blocked_by, relates_to,
      duplicate, start_after, start_before, finish_after, finish_before):
        bash "${PM_CMD:-/project-manager}" enrich --edits '[{"tie":"<tie>","field":"relation:blocking","value":"<target_tie>"}]'

   g) SUB-TASKS — if a task's description implies multiple sequential steps, break
      it into sub-issues now so it's actionable in blocks:
        bash "${PM_CMD:-/project-manager}" enrich --edits '[{"tie":"<tie>","field":"subissue","value":"<subtask title>"}]'
      Create sub-tasks for any issue estimated > 2h or with a clear multi-step
      delivery (e.g. build → test → publish). Aim for sub-tasks of 30m–1h each.

   h) TRIAGE — after enriching, move issues that are ready to work from backlog →
      todo state so they appear in the ready pull:
        bash "${PM_CMD:-/project-manager}" move "<tie>" --to todo

   Apply all enrichments in a single batch enrich call per group where possible.
   Do NOT ask the user to confirm each field — use your PM judgment and apply.
   Only pause if you genuinely cannot infer a value (e.g. a task title that's
   completely ambiguous). Report what you set at the end of this step as a
   compact table: issue | priority | est | assignee | start | relations | subtasks.

3. PROGRESS REPORT (before picking projects). Using progress_json + this week's
   goals (each with allocation_percent + plane_project):
   - Per goal: name · alloc% · Plane pct · tasks done this week (from the week's
     tracker rows) · flag.
   - % of the week's importance met = Σ(alloc% · pct) / Σ(alloc%).
   - FLAGS: "pile-up" (last week's partial/not-started tracker rows still open)
     and "re-evaluate" (high alloc%, low pct, no recent activity).
   - One-line monthly read from the monthly goals.

4. PICK PROJECTS → DAILY ALLOCATION. The user names today's subset. Renormalize
   and distribute the day's blocks deterministically (leftover → highest-priority
   chosen project) with:
     bash "$_SCRIPT_DIR/plan-my-work.sh" alloc --chosen '[{"id":..,"project_name":..,"plane_project":..,"priority":..,"allocation_percent":..}]' --blocks <N>
   It returns each chosen goal with daily_alloc + blocks. N = the empty work
   blocks in "Today at a glance" (plan_exists=yes) or the standalone count from
   step 1.

5. PULL TASKS + ASSIGN. Pull ready tasks for the chosen projects — ALWAYS pass
   the explicit project list so all projects are queried (not just the default):
     bash "${PM_CMD:-/project-manager}" ready --projects "<chosen pids comma-separated>"
   If ready returns empty for a project, check with --include-backlog and triage
   (move to todo + set priority) before assigning. Map tasks → blocks:
   PREFER one project per block; combine projects in a block only when a project
   has few/easy tasks. Biggest-rock first (priority → est). Honor last_block_end.

6. WRITE "## Work tracker" into $OUT_FILE and (re)label the "## Today at a glance"
   work-block rows so each names its task/project. Tracker schema:
     | Block | Task | Project | Plane | Priority | Est | Status | Done at | % complete | Est rating | Notes |
   - "Block" = the time range (e.g. "Block 1 (10:00–11:30)").
   - "Plane" = clickable markdown link(s) using the format
       [PB-19](http://plane.localhost:1800/pb/browse/PB-19/)
     Multiple issues in one block: comma-separated links. Use "—" for no Plane issue.
     The tie (<project_id>:<issue_id>) is what /end-of-day uses for reconciliation;
     embed it as a data comment if needed, but the visible cell must be the link.
     Plane issue URL pattern: http://plane.localhost:1800/pb/browse/<IDENTIFIER>-<seq>/
     Project identifiers (uppercase): PB, YT, KA, ML, MUC, BIO.
   - Status starts "planned"; Done at / % complete / Est rating stay blank for
     /end-of-day. "Est rating" later judges whether the estimate held.
   If plan_exists=no, write a minimal file: frontmatter + a short "## Today at a
   glance" (work blocks only) + the "## Work tracker" + an empty "## How it went".
   Both tables are rewritten together; never let them drift.

7. Confirm in one tight read: the chosen projects, the block→task assignment, and
   "run /end-of-day to close + reconcile to Plane." Stop here.
INSTRUCTIONS

pbrain_emit_habits_extract "plan-my-work" || true
pbrain_emit_self_improve "plan-my-work" "$PROFILE_FILE" "plans profile" || true
