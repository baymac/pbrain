#!/usr/bin/env bash
set -euo pipefail

# weekly-review.sh
# Gathers the last 7 days of journal, gratitude, plan, end-of-day,
# fitness, and diet entries; emits a context block for Claude to
# synthesize and walk a structured weekly review with the user.
#
# Step 4 builds a PER-COMMAND improvement list from the week's evidence and
# walks it one item at a time (approve/reject). Approved improvements update
# the VERSIONED PROFILES: each owning command's `profile new` mints a draft,
# the approved edits land in it, `profile commit` freezes the new version.
# Libraries (work/goals/food/fitness) are living documents — approved library
# edits apply in place, no version mint.
#
# Default destination:  $VAULT_DIR/life/weekly-tracking/YYYY-Www.md (ISO week)
# Overrides:
#   PBRAIN_VAULT             — vault root
#   PBRAIN_WEEKLY_DIR        — where the weekly review writes
#   PBRAIN_JOURNAL_DIR       — daily journals
#   PBRAIN_GRATITUDE_DIR     — gratitude entries
#   PBRAIN_PLAN_DIR          — daily plans (the plan profile store lives inside)
#   PBRAIN_FITNESS_DIR       — fitness sessions (+ fitness profile store)
#   PBRAIN_DIET_DIR          — diet logs (+ diet profile store)
#   PBRAIN_PLAN_PROFILE_FILE — explicit plans-profile file (bypasses the store)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /weekly-review (emits nothing if none set).
pbrain_emit_prefs "weekly-review" || true

WEEKLY_DIR="${PBRAIN_WEEKLY_DIR:-$VAULT_DIR/life/weekly-tracking}"
DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
GRATITUDE_DIR="${PBRAIN_GRATITUDE_DIR:-$VAULT_DIR/life/gratitude-journal}"
PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
DIET_DIR="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}"

# The versioned profile stores Step 4 reads (and proposes new versions of).
PLAN_STORE="$(pbrain_profile_store "$PLAN_DIR")"
FIT_STORE="$(pbrain_profile_store "$FITNESS_DIR")"
DIET_STORE="$(pbrain_profile_store "$DIET_DIR")"

# Migration: weekly reviews used to live in life/weekly-reviews. If we're at the
# default location, the new dir doesn't exist yet, and the legacy dir does,
# rename it so past reviews (and the Monday nudge that reads them) carry over.
_LEGACY_WEEKLY="$VAULT_DIR/life/weekly-reviews"
if [[ -z "${PBRAIN_WEEKLY_DIR:-}" && ! -d "$WEEKLY_DIR" && -d "$_LEGACY_WEEKLY" ]]; then
  mv "$_LEGACY_WEEKLY" "$WEEKLY_DIR" 2>/dev/null \
    && echo "Renamed life/weekly-reviews → life/weekly-tracking (past reviews moved)." || true
fi
unset _LEGACY_WEEKLY

mkdir -p "$WEEKLY_DIR"

# Optional --date YYYY-MM-DD flag — anchors the review on the ISO week
# containing that date instead of the current week. Useful for retroactive
# reviews (e.g. run on Tuesday to review the previous Mon–Sun week).
ANCHOR_DATE=""
FORCE_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --date) ANCHOR_DATE="$2"; FORCE_RUN=1; shift 2 ;;
    --force) FORCE_RUN=1; shift ;;
    *) shift ;;
  esac
done
TODAY="$(date +%Y-%m-%d)"
[[ -n "$ANCHOR_DATE" ]] && TODAY="$ANCHOR_DATE"

# Derive ISO week bounds (Mon–Sun) from the anchor date.
read -r ISO_WEEK FIRST_DATE LAST_DATE MONTH_YEAR NEXT_ISO_WEEK NEXT_MONTH_YEAR < <(python3 - "$TODAY" <<'PY'
import sys, datetime, calendar
anchor = datetime.date.fromisoformat(sys.argv[1])
y, w, _ = anchor.isocalendar()
iso_week = f"{y}-W{w:02d}"
mon = anchor - datetime.timedelta(days=anchor.weekday())  # Monday
sun = mon + datetime.timedelta(days=6)                    # Sunday
month_year = mon.strftime("%Y-%m")
next_anchor = anchor + datetime.timedelta(weeks=1)
ny, nw, _ = next_anchor.isocalendar()
next_iso = f"{ny}-W{nw:02d}"
nxt_mon = datetime.date(mon.year, mon.month, 1) + datetime.timedelta(days=calendar.monthrange(mon.year, mon.month)[1])
next_month = nxt_mon.strftime("%Y-%m")
print(iso_week, mon.isoformat(), sun.isoformat(), month_year, next_iso, next_month)
PY
)

# Generate the 7 dates for the ISO week (Mon through Sun), oldest first.
DATES="$(python3 - "$FIRST_DATE" <<'PY'
import sys, datetime
mon = datetime.date.fromisoformat(sys.argv[1])
for i in range(7):
    print((mon + datetime.timedelta(days=i)).isoformat())
PY
)"

OUT_FILE="$WEEKLY_DIR/$ISO_WEEK.md"

if [[ -f "$OUT_FILE" && "$FORCE_RUN" -eq 0 ]]; then
  echo "This week's review already exists: $OUT_FILE"
  echo ""
  cat "$OUT_FILE"
  exit 0
fi

cat_section() {
  local label="$1"
  local f="$2"
  echo ""
  echo "### $label"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo "(no entry)"
  fi
}

# Cat the latest committed version of a profile base with a labelled header.
cat_profile() {
  local label="$1" store="$2" base="$3" f
  f="$(pbrain_profile_latest "$store" "$base")"
  echo ""
  echo "### $label [versioned: ${f:-no committed version yet}]"
  [[ -n "$f" ]] && cat "$f" || echo "(none)"
}

echo "WEEKLY_REVIEW_SESSION"
echo "iso_week: $ISO_WEEK"
echo "output_file: $OUT_FILE"
echo "date_range: $FIRST_DATE → $LAST_DATE"
echo "commands_dir: $_SCRIPT_DIR"
echo "dates_covered:"
for d in $DATES; do echo "  - $d"; done
echo ""
echo "--- WEEK CONTEXT (oldest first) ---"

for d in $DATES; do
  echo ""
  echo "============================================================"
  echo "## $d"
  echo "============================================================"
  cat_section "Gratitude"  "$GRATITUDE_DIR/$d.md"
  cat_section "Journal"    "$DAILY_DIR/$d.md"
  cat_section "Plan & close" "$PLAN_DIR/$d.md"
  cat_section "Fitness"    "$FITNESS_DIR/$d.md"
  cat_section "Diet"       "$DIET_DIR/$d.md"
done

echo ""
echo "--- END WEEK CONTEXT ---"

# Habit rollup (this week / month vs each habit's criteria). Empty if habit
# tracking isn't set up. HABITS_CMD lets Step 4 add/archive habits on a yes.
# Sync the week's tracking md into the DB first so the rollup is accurate.
pbrain_habits_sync_range 8 || true
HABITS_ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
HABITS_CMD="$(pbrain_habits_cmd 2>/dev/null || true)"
if [[ "$HABITS_ROLLUP" =~ [^[:space:]] ]]; then
  echo ""
  echo "--- HABITS (this week / month vs each habit's criteria) ---"
  echo "$HABITS_ROLLUP"
  echo "habits_cmd: $HABITS_CMD"
  echo "--- END HABITS ---"
fi

# Core profiles, for the Step 4 improvements pass. All versioned (committed =
# final; changes mint the next version through the owning command's `profile`
# subcommand). The explicit plans-profile override is respected.
echo ""
echo "--- CORE PROFILES (for Step 4 improvements) ---"
if [[ -n "${PBRAIN_PLAN_PROFILE_FILE:-}" && -f "${PBRAIN_PLAN_PROFILE_FILE:-}" ]]; then
  echo ""
  echo "### Plans profile [override: $PBRAIN_PLAN_PROFILE_FILE]"
  cat "$PBRAIN_PLAN_PROFILE_FILE"
else
  cat_profile "Plans profile" "$PLAN_STORE" plans-profile
fi
cat_profile "Work library"    "$PLAN_STORE" work-library
cat_profile "Goals library"   "$PLAN_STORE" goals-library
cat_profile "Diet profile"    "$DIET_STORE" diet-profile
cat_profile "Food library"    "$DIET_STORE" food-library
cat_profile "Fitness profile" "$FIT_STORE"  fitness-profile
cat_profile "Fitness library" "$FIT_STORE"  fitness-library
echo ""
echo "### Activity profiles [versioned: $FIT_STORE/activities]"
python3 - "$FIT_STORE/activities" <<'PYEOF' 2>/dev/null || echo "(none)"
import glob, os, re, sys
act_store = sys.argv[1]
# Highest COMMITTED version per slug — an open draft (higher version,
# committed: false) must NOT shadow the committed version below it.
best = {}
for f in glob.glob(os.path.join(act_store, "*.v*.md")):
    m = re.match(r"(.+)\.v(\d+)\.md$", os.path.basename(f))
    if not m:
        continue
    slug, ver = m.group(1), int(m.group(2))
    try:
        with open(f) as fh:
            text = fh.read()
    except Exception:
        continue
    if re.search(r"^committed:\s*false\s*$", text[:400], re.MULTILINE):
        continue
    if slug not in best or ver > best[slug][0]:
        best[slug] = (ver, f, text)
if not best:
    print("(none)")
for slug, (_v, f, text) in sorted(best.items()):
    print(f"# {f}")
    print(text)
    print()
PYEOF
echo ""
echo "### Habits profile [$(pbrain_habits_profile_file)]"
if [[ -f "$(pbrain_habits_profile_file)" ]]; then cat "$(pbrain_habits_profile_file)"; else echo "(no habits profile)"; fi
echo ""
echo "--- END CORE PROFILES ---"

# Weekly and monthly goal files — resolved by period.
WEEKLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$PLAN_STORE" weekly-goals "$ISO_WEEK" || true)"
MONTHLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$PLAN_STORE" monthly-goals "$MONTH_YEAR" || true)"
WEEKLY_GOALS_CONTENT=""
MONTHLY_GOALS_CONTENT=""
[[ -n "$WEEKLY_GOALS_FILE" ]] && WEEKLY_GOALS_CONTENT="$(cat "$WEEKLY_GOALS_FILE" 2>/dev/null || true)"
[[ -n "$MONTHLY_GOALS_FILE" ]] && MONTHLY_GOALS_CONTENT="$(cat "$MONTHLY_GOALS_FILE" 2>/dev/null || true)"

# Read this week's WORK TRACKER rows (new schema; legacy "## Task log" too) from
# day-plan files to show project/goal progress.
TASK_LOG_DATA="$(python3 - "$PLAN_DIR" "$FIRST_DATE" "$LAST_DATE" <<'PYEOF' 2>/dev/null || echo "(no work tracker)"
import glob, os, re, sys
plan_dir, first_date, last_date = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
for f in sorted(glob.glob(os.path.join(plan_dir, "*.md"))):
    date_str = os.path.basename(f)[:-3]
    if not (first_date <= date_str <= last_date):
        continue
    try:
        with open(f) as fh:
            text = fh.read()
    except Exception:
        continue
    for header in ("Work tracker", "Task log"):
        m = re.search(r"## %s\n+(.*?)(?=\n## |\Z)" % header, text, re.DOTALL)
        if not m:
            continue
        section = m.group(1).strip()
        if section and ("| Block |" in section or "| Task |" in section):
            rows.append("=== %s (%s) ===" % (date_str, header))
            rows.append(section)
        break
if rows:
    print("\n".join(rows))
else:
    print("(no work tracker this week)")
PYEOF
)"

# ── Clippings (collect if any exist — processed in Step 6) ─────────────────
CLIPPINGS_DIR="${PBRAIN_CLIPPINGS_DIR:-$VAULT_DIR/Clippings}"
CLIPPINGS_PRESET="${PBRAIN_CLIPPINGS_TARGETS:-}"
CLIPPINGS_AVAILABLE=""
CLIPPINGS_PAYLOAD_WR=""
ALL_CANDIDATES_WR=""
DESTINATIONS_TREE_WR=""
if [[ -d "$CLIPPINGS_DIR" ]]; then
  _wr_clip_count="$(find "$CLIPPINGS_DIR" -maxdepth 1 -type f -name "*.md" | wc -l | tr -d ' ')"
  if [[ "$_wr_clip_count" -gt 0 ]]; then
    CLIPPINGS_AVAILABLE="yes"

    _wr_py1="$(mktemp)"
    _wr_py2=""
    trap 'rm -f "${_wr_py1:-}" "${_wr_py2:-}"' EXIT
    cat > "$_wr_py1" <<'PYEOF'
import os, glob, re, sys
clippings_dir = sys.argv[1]
files = sorted(glob.glob(os.path.join(clippings_dir, "*.md")))
chunks = []
for f in files:
    name = os.path.basename(f)
    try:
        with open(f, encoding="utf-8") as fh:
            content = fh.read()
    except Exception as e:
        chunks.append("=== " + name + " ===\n(error reading: " + str(e) + ")\n")
        continue
    fm = ""
    body = content
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", content, re.DOTALL)
    if m:
        fm = m.group(1).strip()
        body = m.group(2).strip()
    body_clean = re.sub(r"!\[.*?\]\(.*?\)", "", body)
    body_clean = re.sub(r"\n{3,}", "\n\n", body_clean).strip()
    preview = body_clean[:800]
    if len(body_clean) > 800:
        preview += "\n...(truncated)"
    chunk = "=== " + name + " ===\n"
    if fm:
        chunk += "frontmatter:\n" + fm + "\n\n"
    chunk += "body_preview:\n" + preview + "\n"
    chunks.append(chunk)
print("\n".join(chunks))
PYEOF
    CLIPPINGS_PAYLOAD_WR="$(python3 "$_wr_py1" "$CLIPPINGS_DIR")"
    rm -f "$_wr_py1"

    _wr_py2="$(mktemp)"
    cat > "$_wr_py2" <<'PYEOF'
import os, sys
vault = sys.argv[1]
clippings_basename = sys.argv[2]
EXCLUDE = {"agent-work", clippings_basename}
def is_hidden(name):
    return name.startswith(".") or name.startswith("_")
def list_dirs(path):
    try:
        return sorted(n for n in os.listdir(path)
                      if os.path.isdir(os.path.join(path, n)) and not is_hidden(n))
    except Exception:
        return []
def list_md_files(path):
    try:
        return sorted(n for n in os.listdir(path)
                      if n.endswith(".md") and not is_hidden(n))
    except Exception:
        return []
top_dirs = [d for d in list_dirs(vault) if d not in EXCLUDE]
lines = []
for d in top_dirs:
    full = os.path.join(vault, d)
    files = list_md_files(full)
    subdirs = list_dirs(full)
    lines.append("- " + d + "/")
    if files:
        sample = files[:6]
        more = "" if len(files) <= 6 else " ...(" + str(len(files) - 6) + " more)"
        lines.append("    files: " + ", ".join(sample) + more)
    for sd in subdirs:
        sd_full = os.path.join(full, sd)
        sd_files = list_md_files(sd_full)
        sd_subdirs = list_dirs(sd_full)
        descriptor = "    " + d + "/" + sd + "/"
        if sd_files:
            sample = sd_files[:5]
            more = "" if len(sd_files) <= 5 else " ...(" + str(len(sd_files) - 5) + " more)"
            descriptor += "  files: " + ", ".join(sample) + more
        if sd_subdirs:
            descriptor += "  subdirs: " + ", ".join(sd_subdirs)
        lines.append(descriptor)
print("ALL_CANDIDATES: " + ",".join(top_dirs))
print("")
print("\n".join(lines))
PYEOF
    _wr_dest_raw="$(python3 "$_wr_py2" "$VAULT_DIR" "$(basename "$CLIPPINGS_DIR")")"
    rm -f "$_wr_py2"
    ALL_CANDIDATES_WR="$(printf '%s\n' "$_wr_dest_raw" | head -1)"
    DESTINATIONS_TREE_WR="$(printf '%s\n' "$_wr_dest_raw" | tail -n +3)"
  fi
fi

echo ""
echo "--- WEEKLY GOALS ($ISO_WEEK) ---"
if [[ -n "$WEEKLY_GOALS_CONTENT" ]]; then
  echo "weekly_goals_file: $WEEKLY_GOALS_FILE"
  echo "$WEEKLY_GOALS_CONTENT"
else
  echo "(none — not set up for this week)"
fi
echo "--- END WEEKLY GOALS ---"

echo ""
echo "--- MONTHLY GOALS ($MONTH_YEAR) ---"
if [[ -n "$MONTHLY_GOALS_CONTENT" ]]; then
  echo "monthly_goals_file: $MONTHLY_GOALS_FILE"
  echo "$MONTHLY_GOALS_CONTENT"
else
  echo "(none — not set up for this month)"
fi
echo "--- END MONTHLY GOALS ---"

echo ""
echo "--- PROJECT REGISTRY (registry_json) ---"
echo "plane_configured: $(pbrain_plane_configured 2>/dev/null && echo yes || echo no)"
pbrain_projects_registry_json 2>/dev/null || echo "[]"
echo "--- END PROJECT REGISTRY ---"

echo ""
echo "--- PROJECT PROGRESS (progress_json, this week's goal projects since $FIRST_DATE) ---"
WR_WEEKLY_PIDS=""
if [[ -n "$WEEKLY_GOALS_FILE" ]]; then
  WR_WEEKLY_PIDS="$(pbrain_profile_json "$WEEKLY_GOALS_FILE" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print(",".join(g.get("plane_project") for g in d.get("goals",[]) if g.get("plane_project")))' 2>/dev/null || true)"
fi
echo "weekly_pids: ${WR_WEEKLY_PIDS:-(none)}"
pbrain_projects_progress_json "$WR_WEEKLY_PIDS" "$FIRST_DATE" 2>/dev/null || echo "{}"
echo "--- END PROJECT PROGRESS ---"

echo ""
echo "--- THIS WEEK'S WORK TRACKER ROWS ---"
echo "$TASK_LOG_DATA"
echo "--- END WORK TRACKER ROWS ---"

if [[ -n "$CLIPPINGS_AVAILABLE" ]]; then
  echo ""
  echo "--- CLIPPINGS TO ORGANIZE ---"
  echo "clippings_dir: $CLIPPINGS_DIR"
  echo "preset_targets: ${CLIPPINGS_PRESET:-(none — ask the user)}"
  echo "$ALL_CANDIDATES_WR"
  echo ""
  echo "=== CLIPPINGS ==="
  echo "$CLIPPINGS_PAYLOAD_WR"
  echo ""
  echo "=== DESTINATION DIRS (top-level, with subdir tree) ==="
  echo "$DESTINATIONS_TREE_WR"
  echo "--- END CLIPPINGS ---"
fi

echo ""
cat <<PROMPT
weekly_goals_file: ${WEEKLY_GOALS_FILE:-(not set up)}
monthly_goals_file: ${MONTHLY_GOALS_FILE:-(not set up)}
iso_week: $ISO_WEEK
next_iso_week: $NEXT_ISO_WEEK
month_year: $MONTH_YEAR
clippings_available: ${CLIPPINGS_AVAILABLE:-no}
clippings_dir: $CLIPPINGS_DIR

INSTRUCTIONS: Walk a weekly review. You have a lot of context above — use it. Specifics or silence.

Step 1 — Read every day above. Look for: recurring themes (what kept coming up), real wins (what actually shipped or moved), friction (where the week stalled or repeated), shifts (how thinking changed), unfinished threads (open questions that didn't get resolved). If a HABITS rollup is present, weave its standouts into your synthesis — limit habits over cap, high-priority build habits that lagged, streaks worth naming. Don't dump the table; surface what matters.

Step 2 — Present a TIGHT synthesis FIRST, then ask questions. Order:
  a) Say: "Here's what I'm seeing from your week:" then 3-5 bullets. Specific. Quote the user where you can. No generic positivity.
  b) Then ask, ONE at a time:
     1) "What did this week want to teach you?"
     2) "What's one thing you want to drop next week?"
     3) "What's one thing you want to double down on?"

Step 3 — Write to $OUT_FILE using exactly this format (frontmatter included):

---
type: weekly
date: $FIRST_DATE
week: $ISO_WEEK
tags: []
---

# Weekly review — $ISO_WEEK

Dates: $FIRST_DATE → $LAST_DATE

## What I'm seeing
{your bullets from Step 2a, verbatim}

## What this week wanted to teach me
{verbatim answer to Q1}

## Drop next week
{verbatim answer to Q2}

## Double down on
{verbatim answer to Q3}

## Work review
{filled in by Step 3w below — a per-project read of the week's work: planned vs
done (from THIS WEEK'S WORK TRACKER ROWS), Plane pct + delta (from PROJECT
PROGRESS), alloc% vs where the time actually went (estimate-rating), and any
pile-up flags. If no project goals/tracker exist this week, write "No project
work tracked."}

## Weekly goals — $ISO_WEEK
{filled in by Step 4b below — the closing week's PROJECT goals with their status
(from the work tracker + project progress: which projects advanced, which
stalled). If no weekly goals were set up, write "Weekly goals not configured."}

## Improvements
{filled in by Step 4 — every improvement you proposed, per command, with the
user's decision (approved → which profile version it landed in; rejected;
deferred). If you proposed nothing, write "None this week."}

## Habit review
{filled in by Step 4d — a one-paragraph read of how habits went this week (from
the HABITS rollup: what's sticking, what's lagging or over) plus any add/remove
proposals and what the user decided. If habit tracking isn't set up, write
"No habits tracked." If set up but nothing to change, give the read and write
"No habit changes."}

Step 3w — Work review. Fill the "## Work review" section from THIS WEEK'S WORK
TRACKER ROWS + PROJECT PROGRESS + the weekly PROJECT goals. Per project in play
this week (one bullet each):
  - planned vs done: count work-tracker rows tied to the project's plane_project
    (status done / partial / open) across the week.
  - Plane pct + delta: from progress_json[pid].pct (the "delta" is your read of
    movement — if you have a prior reference, note the change; else just the pct).
  - alloc% vs actual: the goal's allocation_percent vs the share of the week's
    done work that actually went to it — call out big mismatches (an
    estimate/allocation calibration signal).
  - pile-up flag: rows that stayed partial / not-started all week → "piling up".
Lead with what moved and what stalled; keep it tight. If neither project goals
nor a work tracker exist this week, write "No project work tracked." and move on.

Step 4 — Improvements. Build a PER-COMMAND improvement list from the week's
evidence, using the CORE PROFILES above as the baseline. One list per command:

  - plan-my-day  → plans-profile / work-library / goals-library
  - diet-journal → diet-profile (food-library for library rows)
  - fitness-journal → fitness-profile / fitness-library / activity profiles
  - habits → the habit set (handled in Step 4d below)

Each improvement is ONE line, tied to something that actually happened this
week (e.g. "you skipped legs twice — drop gym to 3 fixed days", "protein
landed under target 5/7 days — bump the lunch protein anchor", "the Lettuce
goal wasn't touched in any plan — re-scope or re-prioritise it"). Propose
NOTHING without a clear signal — do not invent changes.

Then walk the list ONE BY ONE: present an improvement, ask approve / reject,
record the decision. No batch approvals.

After the walk, apply the approved improvements:
  - For each PROFILE with at least one approved improvement, mint a NEW
    VERSION via the owning command (paths use commands_dir above):
      bash "<commands_dir>/plan-my-day.sh"    profile new [plans-profile]
      bash "<commands_dir>/diet-journal.sh"   profile new
      bash "<commands_dir>/fitness-journal.sh" profile new [fitness-profile|fitness-library|activity <name>]
      bash "<commands_dir>/habits.sh"          profile new
    Edit the minted DRAFT file applying ONLY the approved changes (keep the
    fenced JSON valid and the frontmatter version/committed lines intact),
    then freeze it:
      bash "<commands_dir>/<cmd>.sh" profile commit [base]
  - LIBRARIES (work-library, goals-library, food-library, fitness-library)
    are living documents — apply approved library edits IN PLACE on the
    latest version; no version mint.
Record in "## Improvements" what landed where (including the new version
file path for each committed profile).

Step 4b — Weekly Goals lifecycle. Walk this for every weekly review.
  i) GOAL PROGRESS: Read THIS WEEK'S TASK LOGS above. For each goal in the
     WEEKLY GOALS section, determine its status: completed (Done at filled,
     Status=done), partial (some done), or not started. Show a brief summary
     before committing.
  ii) COMMIT the closing week: if weekly_goals_file is a real path (not "(not
     set up)"), commit it:
       bash "\$commands_dir/plan-my-day.sh" profile commit weekly-goals
  iii) MINT next week's draft: mint a fresh weekly-goals draft for next_iso_week:
       bash "\$commands_dir/plan-my-day.sh" profile new weekly-goals
       This creates the file. Weekly goals are now a CEO overview — which Plane
       PROJECTS are in play next week, at what priority, and at what % of your
       importance/time (allocation_percent summing to 100). NOT task-level. The
       real tasks live in Plane (see /plan-my-work). Edit the draft to set:
       - "period": "$NEXT_ISO_WEEK" in the JSON block
       - Derive the goals:
         * If monthly_goals_file is set and its period is the current month
           ($MONTH_YEAR): derive from monthly goals (copy goal text + plane_project
           + priority; confirm each).
         * Else: derive from the plans-profile's current_focus list (use their
           priority).
       Walk goals ONE BY ONE — each round ask: "Include '{goal}' next week? If
       yes, what % of next week's importance? (difficulty is optional — easy/
       normal/hard/nightmare)". When the PROJECT REGISTRY above shows
       plane_configured: yes, ALSO ask which **Plane project** it maps to (pick
       from the registry; if missing, run /project-manager projects --sync first)
       and record "plane_project" (uuid) + "project_name". When
       plane_configured: no, SKIP the project-mapping question entirely — leave
       "plane_project": "" and keep the goal as a focus-area + allocation_percent
       only (auto task-pull + progress just aren't available without Plane).
       Allow adding new goals. After all are assigned, **balance
       allocation_percent to sum to 100** across active goals (show the split,
       adjust until it's exactly 100).
       The final JSON shape is:
       {"created": "TODAY", "period": "NEXT_ISO_WEEK",
        "derived_from": "monthly-goals MONTH_YEAR or plans-profile vN",
        "goals": [{"id": "<slug>", "goal": "...", "plane_project": "<uuid or ''>",
                   "project_name": "...", "priority": 1, "allocation_percent": 40,
                   "success_looks_like": "...", "status": "active",
                   "difficulty": "normal"}]}
       (allocation_percent over active goals must total 100; difficulty is kept
       but secondary.)
  iv) Commit the new next-week draft:
       bash "\$commands_dir/plan-my-day.sh" profile commit weekly-goals
  v) Record in "## Weekly goals — $ISO_WEEK" the closing week's goal progress.
  Skip this whole step silently if weekly_goals_file is "(not set up)" AND the
  user doesn't want to start using weekly goals.

Step 4c — Monthly goal progress (only if monthly_goals_file is set):
  Show a brief one-paragraph read: how many monthly goals were touched this
  week (from task logs), which are on track, which lagged. Don't force action.
  If the month is ending (last 3 days): suggest /monthly-review once.

Step 4d — Habit review (only if a HABITS rollup is present above). Give a short
read of how the week's habits went, then — if the week clearly warrants it —
propose adding a habit the user has been doing but isn't tracking, or archiving
one that's gone stale / no longer serves them. Evidence-based only; propose
nothing if there's no signal. These are user-owned: do NOT change the habit set
by default. Only run a command if the user explicitly says yes this session:
  - add:     bash "$HABITS_CMD" add --name "<X>" --type daily|weekly|monthly --direction at_least|at_most [--target N] [--priority low|medium|high]
  - archive: bash "$HABITS_CMD" archive --id <id>   (keeps history)
Write the read + proposals + what the user decided into "## Habit review".

Step 5 — Print the file path. One closing line, no fanfare.

Step 6 — Clippings (only if clippings_available is "yes" above):
  After writing the review file, process the clippings in
  "--- CLIPPINGS TO ORGANIZE ---" as the final act of the weekly session.

  Step 6.0 — Destination selection (once, before any moves):
    - Look at preset_targets and ALL_CANDIDATES in the clippings context.
    - If preset_targets is "all", use every dir in ALL_CANDIDATES.
    - If preset_targets is a non-empty list, use those (skip any not in
      ALL_CANDIDATES, warn once).
    - Otherwise ask: "Which top-level dirs should I file these clippings into?
        Available: <ALL_CANDIDATES>
        Reply with a comma-separated subset, or 'all'."
    Wait for their answer. Lock result as ALLOWED_TOP_DIRS.

  For each clipping (in order from === CLIPPINGS ===):

  Step 6.1 — Read filename, frontmatter, and body preview. Form an opinion on
    topic and best destination.

  Step 6.2 — Pick destination: top-level dir MUST be one of ALLOWED_TOP_DIRS;
    subpath is open-ended (reuse existing subdirs when they fit, propose new ones
    only when the content is clearly a distinct sub-topic). NEVER target
    agent-work/ or Clippings/.

  Step 6.3 — Decide filename: keep if already clean (3-6 words). Otherwise
    propose: 3-6 words, Title Case, content-derived, .md. If renaming, also plan
    to rewrite the frontmatter title: field.

  Step 6.4 — Confidence check:
    - >= ~70% sure: announce in one line ("→ moving OLD to DEST/NEW") and ask "ok?"
    - Close call: present 2-3 options, let user pick.
    Always get a confirmation token before mv.

  Step 6.5 — Execute move (path-safe):
    BEFORE running mkdir/mv, validate dest_dir is inside VAULT_DIR:
      python3 -c "
import os, sys
dest = os.path.realpath('{dest_dir}')
vault = os.path.realpath('$VAULT_DIR')
if not dest.startswith(vault + os.sep) and dest != vault:
    print('BLOCKED: dest_dir outside vault: ' + dest, file=sys.stderr); sys.exit(1)
"
    If the check fails, skip this clipping and say "skipped (unsafe path)".
    Otherwise:
      mkdir -p "{dest_dir}"
      mv "$CLIPPINGS_DIR/{old_name}" "{dest_dir}/{new_name}"
    If renamed, rewrite the frontmatter title: field using exactly this fixed
    snippet (do NOT write your own variation):
      python3 - "{dest_dir}/{new_name}" "{new_title}" <<'REWRITE_EOF'
import re, sys
path, new_title = sys.argv[1], sys.argv[2]
text = open(path).read()
text = re.sub(r"(^---\n.*?^title:\s*).*?$", lambda m: m.group(1) + new_title,
              text, count=1, flags=re.MULTILINE | re.DOTALL)
open(path, "w").write(text)
REWRITE_EOF
    Announce: "✓ moved → {relative_path_from_vault}"

  When all clippings are processed, print: N moved, grouped by top-level dir.

Hard rules:
- Quote the user back to themselves in the synthesis. Their language, not yours.
- If a day has zero entries, note it once in your synthesis ("you were dark Thu-Fri") and move on. Do not moralize about missed days.
- Do NOT generate a generic "great week!" summary. Specifics or silence.
- Do NOT prescribe productivity systems or self-improvement frameworks. The user is reviewing their own life, not buying a course.
PROMPT

# Self-improvement: capture standing preferences / quality fixes the user
# raised this session (silent unless there was genuine feedback). No plan args:
# Step 4 above owns profile updates with its richer approve-per-item flow.
pbrain_emit_self_improve "weekly-review" || true
