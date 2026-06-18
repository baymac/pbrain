#!/usr/bin/env bash
set -euo pipefail

# habits.sh — habit tracking.
#
# First run interviews the user to build a habits PROFILE — one question at a
# time. Each habit carries its OWN fulfillment criteria:
#   schedule_type : daily | weekly | monthly
#   direction     : at_least (build) | at_most (limit)
#   target_count  : integer N (or null)
#   priority      : low | medium | high
# (e.g. "brush at night" = daily/at_least/1; "nail cut" = weekly/at_least/2;
#  "long run" = monthly/at_least/5; "alcohol" = weekly/at_most/2.)
#
# The profile is a vault markdown note carrying its data in a fenced ```json
# block — same discipline as the plans profile, browsable in Obsidian. Each
# habit has a STABLE id (slug) minted once and never changed: renames touch only
# the display name, so event history (in SQLite, keyed by habit_id) stays
# attached. Removing a habit soft-archives it (history preserved).
#
# Every subsequent run shows a dashboard: per-habit progress vs each criteria
# (✅ met / ⏳ not yet / ⚠️ over), top 20 by priority. Events are logged into
# the shared SQLite DB (lib/db.sh) — both from /habits directly and, via the
# ride-along extraction emitter, from ordinary journaling commands.
#
# Subcommands:
#   habits.sh                        first run → setup; else → dashboard
#   habits.sh log --name "X" --date YYYY-MM-DD [--count N] [--source cmd] [--note "..."]
#   habits.sh add --name "X" --type daily|weekly|monthly --direction at_least|at_most
#                 [--target N] [--priority low|medium|high] [--notes "..."]
#   habits.sh edit --id <id> [--name ...] [--type ...] [--direction ...]
#                  [--target N] [--priority ...] [--notes ...]
#   habits.sh archive --id <id>      soft-delete (keeps history)
#   habits.sh history --name "X"     event history for one habit (newest first)
#   habits.sh rollup [--date YYYY-MM-DD]   text rollup (top 20 vs criteria)
#   habits.sh status [--date YYYY-MM-DD]   structured status JSON (machine)
#   habits.sh list                   list configured habits
#   habits.sh track [--date YYYY-MM-DD]  init today's tracking md from profile
#   habits.sh mark --name "X" [--date YYYY-MM-DD] [--count N] [--amount N] [--note "..."]
#                  [--good N] [--bad N] [--slips N]              (slip_ladder / meal_ratio)
#                  [--actual-time HH:MM] [--actual-hours N.N]    (deviation: sleep-well)
#                  [--items JSON] [--session JSON]               (weighted_completion / session_volume)
#                  [--focus JSON]                                (focus_ratio: deep-work)
#                  [--status done|skipped|missed] [--skip]       (3-state record;
#                  --skip = --status skipped; default done. skipped/missed write a
#                  count=0 row — recorded but not a completion)
#                  (scored habits: pass raw inputs, the score is computed from the
#                  habit's profile rule — see `score`)
#   habits.sh score --name "X" (--good N --bad N | --slips N | --actual-time HH:MM --actual-hours N)
#                  compute (no write) a scored habit's score from its profile rule
#   habits.sh scores [--date YYYY-MM-DD]
#                  read back engine-computed scores for all scored habits on a date;
#                  emits human lines + "HABIT_SCORES [...]" JSON trailer
#   habits.sh profile show|new|commit    manage the VERSIONED habits profile
#                  (lib/profiles.sh store; add/edit/archive stay living-document
#                  ops on the latest version — `new` is for structural redesigns)
#   habits.sh sync [--days N] [--date YYYY-MM-DD]  mirror md → DB (default 7 days)
#   habits.sh consolidate [--date YYYY-MM-DD]  sync md → DB then prune unchecked rows
#   habits.sh refresh [--date YYYY-MM-DD] [--days N]  recompute Progress column from DB
#   habits.sh reminder --id <id> (--link --time HH:MM [--days mon,wed,fri] | --decline | --unlink [--cancel])
#                  link a build habit to a per-day Apple Reminder (--days = fixed weekdays)
#   habits.sh reminders-pending          daily build habits with no reminder decision yet
#   habits.sh reminders-ensure      [--date]  create today's one-shot reminders for linked habits (idempotent)
#   habits.sh reminders-sync        [--date] [--sweep]  reconcile linked habits ↔ their one-shots, both directions
#   habits.sh reminders-reschedule  --habit <name> --time HH:MM [--date YYYY-MM-DD]  update a pending one-shot's due time
#   habits.sh reminders-cancel      --habit <name|id> [--date YYYY-MM-DD]  delete a pending one-shot + mark its row cancelled
#   habits.sh fitness-reconcile     --activity "<name|slug>" [--date YYYY-MM-DD]  align fitness-habit reminders to today's chosen activity (skip the rest)
#   habits.sh autostatus            [--date YYYY-MM-DD]  end-of-day: mark scheduled-but-undone build habits 'missed' (skipped/done left)
#
# A build (at_least) habit can be LINKED to Apple Reminders (/remind). The link
# is an INTENT stored on the habit in the profile JSON as
#   "reminder": {"state": "linked", "time": "07:00"}                     (daily)
#   "reminder": {"state": "linked", "time": "07:00", "days": ["mon","wed","fri"]}
#                                                              (fixed weekdays)
# or {"state": "declined"} when the user said no (absent = undecided → offered).
# pbrain owns the habit data; the reminder is just a notification + a familiar
# checkbox. A linked habit gets ONE one-shot reminder per scheduled day (not an
# Apple-recurring one) — created by reminders-ensure (day-gated by `days`), kept
# in TWO-WAY sync by reminders-sync (tick it in Reminders → habit marked; mark
# the habit → reminder completed). Per-day reminder ids live in the DB
# (habit_reminders), not the profile. `days` gates reminder CREATION only — it
# does NOT change how the habit is scored. Eligibility: build habits only; a
# daily habit links with no days, a weekly/monthly habit only WITH --days (no
# fixed day of its own otherwise); limit habits never. Linking is opt-in per
# habit, offered at first-run setup and on add (or when the user asks).
# Reminders only — Calendar has no done-state.
#
# Default profile:  versioned store at $VAULT_DIR/life/habit-tracking/.profile/
#                   habits-profile.vN.md (migration 0005 moves the legacy
#                   life/Habits Profile.md here automatically)
# Event log:        shared SQLite DB (~/.config/pbrain/pbrain.db)
#
# DEFAULT SCORED HABITS: once a committed diet profile exists, "Eat clean"
# (meal_ratio scoring) is seeded automatically; once a committed fitness
# profile exists, "Sleep well" (deviation scoring vs the profile's normal
# sleep window) is seeded. Idempotent; archived defaults are never resurrected.
#
# Overrides:
#   PBRAIN_VAULT                  — vault root
#   PBRAIN_HABITS_PROFILE_FILE    — explicit profile file (bypasses the store)
#   PBRAIN_HABIT_TRACK_DIR        — tracking dir (the store lives inside it)
#   PBRAIN_DB_FILE                — SQLite DB path

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

pbrain_emit_prefs "habits" || true
pbrain_db_init || true

PROFILE_FILE="$(pbrain_habits_profile_file)"
TODAY="$(date +%Y-%m-%d)"
SUB="${1:-}"

# Default scored habits — seeded once their source profiles exist: a committed
# diet profile enables "Eat clean" (meal_ratio: score = share of clean meals);
# a committed fitness profile enables "Sleep well" (deviation vs the normal
# sleep window baked from that profile). Goes through the same atomic
# ProfileLock write path as `add`. Idempotent; an id that exists (active OR
# archived) is never re-added, so archiving a default makes it stay gone.
_habits_seed_defaults() {
  [[ -f "$PROFILE_FILE" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local diet_store fit_store plan_store dietp fitp fitlibp goalsp act_store
  diet_store="$(pbrain_profile_store "${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}")"
  fit_store="$(pbrain_profile_store "${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}")"
  plan_store="$(pbrain_profile_store "${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}")"
  dietp="$(pbrain_profile_latest "$diet_store" diet-profile)"
  fitp="$(pbrain_profile_latest "$fit_store" fitness-profile)"
  fitlibp="$(pbrain_profile_latest "$fit_store" fitness-library)"
  goalsp="$(pbrain_profile_latest "$plan_store" plans-profile)"
  act_store="$fit_store/activities"
  # "Deep work" (focus_ratio) needs the laptop tracker's DB (work-block activity)
  # AND a committed plans profile (the source of the work-block windows).
  local tracker_db tracker_present
  tracker_db="${PBRAIN_TRACKER_DB_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/tracker.db}"
  [[ -f "$tracker_db" ]] && tracker_present=1 || tracker_present=0
  [[ -n "$dietp$fitp$goalsp$fitlibp" ]] || return 0
  python3 - "$_SCRIPT_DIR/../lib" "$PROFILE_FILE" "$dietp" "$fitp" "$TODAY" "$goalsp" "$fitlibp" "$act_store" "$tracker_present" <<'PYEOF' 2>/dev/null || true
import json, re, sys
libdir, path, dietp, fitp, today, goalsp, fitlibp, act_store, tracker_present = sys.argv[1:10]
sys.path.insert(0, libdir)
from profile_lock import ProfileLock

def read_json_block(p):
    if not p:
        return None
    try:
        with open(p) as fh:
            text = fh.read()
    except Exception:
        return None
    m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
    try:
        return json.loads(m.group(1) if m else text)
    except Exception:
        return None

added = []
linked = []   # existing habits whose `activity` field we backfilled in place
with ProfileLock(path) as lock:
    text = lock.read()
    m = re.search(r"(```json\s*\n)(.*?)(```)", text, re.DOTALL)
    if not m:
        sys.exit(0)
    try:
        data = json.loads(m.group(2))
    except Exception:
        sys.exit(0)
    habits = data.setdefault("habits", [])
    ids = {str(h.get("id", "")).strip() for h in habits}  # incl. archived — never resurrect

    if dietp and "eat-clean" not in ids:
        habits.append({
            "id": "eat-clean", "name": "Eat clean", "direction": "at_least",
            "schedule": {"type": "daily"}, "schedule_type": "daily",
            "target_count": None, "priority": "high",
            "unit": "", "measure_target": 80, "archived": False,
            "notes": ("Default scored habit (from the diet profile). Daily score = "
                      "share of clean meals: count clean vs unclean MEALS in the "
                      "diet log for the day (every eating occasion counts) and "
                      "mark with --good/--bad; target 80+."),
            "scoring": {"type": "meal_ratio"},
        })
        added.append("Eat clean (scored from your diet log)")

    if fitp and "sleep-well" not in ids:
        fp = read_json_block(fitp) or {}
        sleep = fp.get("sleep") or {}
        bed = str(sleep.get("bed_time") or "23:00")
        hours = sleep.get("hours")
        try:
            hours = float(hours)
        except (TypeError, ValueError):
            hours = 8.0
        habits.append({
            "id": "sleep-well", "name": "Sleep well", "direction": "at_least",
            "schedule": {"type": "daily"}, "schedule_type": "daily",
            "target_count": None, "priority": "high",
            "unit": "", "measure_target": 80, "archived": False,
            "notes": ("Default scored habit (from the fitness profile). Daily "
                      "score = deviation from the normal sleep window: mark with "
                      "--actual-time HH:MM (bed time) and --actual-hours N.N; "
                      "target 80+."),
            "scoring": {"type": "deviation", "normal_time": bed,
                        "normal_hours": hours, "unit_minutes": 30,
                        "unit_hours": 0.5, "ladder": [100, 90, 75, 50, 25, 0]},
        })
        added.append("Sleep well (scored vs your normal sleep window)")

    if goalsp and "work-the-plan" not in ids:
        habits.append({
            "id": "work-the-plan", "name": "Work the plan", "direction": "at_least",
            "schedule": {"type": "daily"}, "schedule_type": "daily",
            "target_count": None, "priority": "high",
            "unit": "", "measure_target": 70, "archived": False,
            "notes": ("Default scored habit (from the plans profile). Daily score = "
                      "weighted task completion (difficulty=load, priority=importance, "
                      "status=credit). Mark at end-of-day with "
                      "--items JSON array of {priority,difficulty,status}; target 70+."),
            "scoring": {"type": "weighted_completion",
                        "difficulty_weights": {"easy": 1, "normal": 2, "hard": 3, "nightmare": 5},
                        "status_credit": {"done": 1.0, "partial": 0.5, "dropped": 0.0, "carried": 0.0},
                        "priority_pivot": 3, "priority_step": 0.25},
        })
        added.append("Work the plan (scored from your daily task log)")

    if fitlibp and "train" not in ids:
        import glob as _glob
        import os as _os
        try:
            from habit_schedule import norm_days as _norm_days
        except Exception:
            _norm_days = None
        # Per-activity profiles carry their fixed days in FRONTMATTER as weekday
        # NAMES (`days: [Mon, Thu]`), not in a JSON block — mirror the
        # fitness-journal pre-select parser. Take the highest COMMITTED version
        # per slug, then union the activities' fixed days into the schedule.
        by_slug = {}  # slug -> (version, [day-name tokens])
        for af in _glob.glob(_os.path.join(act_store, "*.v*.md")):
            mver = re.match(r"^(.*)\.v(\d+)\.md$", _os.path.basename(af))
            if not mver:
                continue
            slug, ver = mver.group(1), int(mver.group(2))
            try:
                with open(af) as fh:
                    atxt = fh.read()
            except Exception:
                continue
            fm = re.match(r"^---\n(.*?)\n---", atxt, re.DOTALL)
            if not fm:
                continue
            front = fm.group(1)
            if re.search(r"^committed:\s*false\s*$", front, re.MULTILINE):
                continue
            dm = re.search(r"^days:\s*\[(.*?)\]\s*$", front, re.MULTILINE)
            if not dm:
                continue
            days = [d.strip().strip("\"'") for d in dm.group(1).split(",") if d.strip()]
            if slug not in by_slug or ver > by_slug[slug][0]:
                by_slug[slug] = (ver, days)
        train_days = []
        for _ver, days in by_slug.values():
            train_days.extend(days)
        if _norm_days:
            norm = _norm_days(train_days)
        else:
            norm = sorted({d.strip().lower()[:3] for d in train_days if d.strip()})
        if norm:
            schedule = {"type": "weekdays", "days": norm}
            schedule_type = "weekly"
        else:
            schedule = {"type": "daily"}
            schedule_type = "daily"
        habits.append({
            "id": "train", "name": "Train", "direction": "at_least",
            "schedule": schedule, "schedule_type": schedule_type,
            "target_count": None, "priority": "high",
            "unit": "", "measure_target": 80, "archived": False,
            "notes": ("Default scored habit (from the fitness library). Daily score = "
                      "session volume ratio (actual vs planned volume). Mark after "
                      "logging a session with --session JSON; target 80+."),
            "scoring": {"type": "session_volume",
                        "status_credit": {"completed": 1.0, "partial": 0.5, "skipped": 0.0},
                        "volume_cap": 1.0},
        })
        added.append("Train (scored from your fitness sessions)")

    # Per-activity fitness habits — one habit per fitness-library activity, each
    # tagged with its `activity` slug so /plan-my-day's fitness-reconcile can map
    # the day's chosen activity → its habit reliably (not by a fragile name guess).
    # REUSE, don't duplicate: if a non-archived habit already matches an activity
    # (by `activity` field or case-insensitive name containment, e.g. habit
    # "Apple Fitness" ↔ activity "Apple Fitness+ Kickboxing"), backfill its
    # `activity` field IN PLACE instead of creating a new one. NOTE: the scored
    # `Train` habit above stays as the cross-activity VOLUME score; these
    # per-activity habits own occurrence + reminders + the done/skipped/missed
    # record — the two are complementary, not duplicates.
    if fitlibp:
        try:
            from habit_schedule import norm_days as _na_norm_days
        except Exception:
            _na_norm_days = None

        def _na_norm(s):
            return re.sub(r"[^a-z0-9]+", " ", (s or "").strip().lower()).strip()

        _lib_acts = (read_json_block(fitlibp) or {}).get("activities")
        for a in (_lib_acts if isinstance(_lib_acts, list) else []):
          try:
            if not isinstance(a, dict):
                continue
            aslug = str(a.get("id") or "").strip() or re.sub(r"[^a-z0-9]+", "-", str(a.get("name", "")).lower()).strip("-")
            if not aslug:
                continue
            aname = str(a.get("name", "")).strip()
            _ad = a.get("days")
            adays = [str(d).strip() for d in (_ad if isinstance(_ad, list) else []) if str(d).strip()]
            occ = a.get("occurrence")
            if not isinstance(occ, dict):
                occ = {}   # legacy/string occurrence ("4x/week") → no structured times
            an = _na_norm(aname)
            match = None
            for h in habits:
                if h.get("archived"):
                    continue
                if str(h.get("activity", "")).strip().lower() == aslug.lower():
                    match = h
                    break
                hn = _na_norm(h.get("name"))
                if hn and ((an and (hn in an or an in hn)) or hn == _na_norm(aslug)):
                    match = h
                    break
            if match is not None:
                if str(match.get("activity", "")).strip().lower() != aslug.lower():
                    match["activity"] = aslug
                    linked.append("%s ↔ %s" % (match.get("name", aslug), aslug))
                continue
            if aslug in ids:
                continue   # id collision we couldn't name-match — never resurrect
            if adays:
                norm = _na_norm_days(adays) if _na_norm_days else sorted({d.lower()[:3] for d in adays})
                nh = {"id": aslug, "name": aname or aslug.replace("-", " ").title(),
                      "direction": "at_least", "schedule": {"type": "weekdays", "days": norm},
                      "schedule_type": "weekly", "target_count": None, "priority": "medium",
                      "unit": "", "measure_target": None, "archived": False, "activity": aslug,
                      "notes": "Per-activity fitness habit (from the fitness library)."}
            else:
                # no fixed days → an occurrence-based count habit (never daily-missed
                # on a fixed schedule); the engine spaces its frequency itself.
                per = str(occ.get("per", "week")).strip().lower()
                try:
                    tc = int(occ.get("times")) if occ.get("times") not in (None, "") else None
                except (TypeError, ValueError):
                    tc = None
                nh = {"id": aslug, "name": aname or aslug.replace("-", " ").title(),
                      "direction": "at_least",
                      "schedule_type": ("monthly" if per.startswith("month") else "weekly"),
                      "target_count": tc, "priority": "medium",
                      "unit": "", "measure_target": None, "archived": False, "activity": aslug,
                      "notes": "Per-activity fitness habit (from the fitness library)."}
            habits.append(nh)
            ids.add(aslug)
            added.append("%s (per-activity fitness habit)" % (aname or aslug))
          except Exception:
            continue   # a malformed activity entry never aborts the rest of seeding

    if tracker_present == "1" and goalsp and "deep-work" not in ids:
        # Schedule over the plan's WORKDAYS (all weekdays minus rest_days from the
        # plans profile's typical_day) so weekends/rest days aren't counted as
        # missed — there are no work blocks to score then. Falls back to Mon–Fri.
        try:
            from habit_schedule import norm_days as _norm_days
        except Exception:
            _norm_days = None
        ALL = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        gp = read_json_block(goalsp) or {}
        td = gp.get("typical_day") or {}
        rest = td.get("rest_days") or []
        rest_norm = _norm_days(rest) if _norm_days else sorted(
            {str(d).strip().lower()[:3] for d in rest if str(d).strip()})
        work_days = [d for d in ALL if d not in set(rest_norm)]
        if not work_days or len(work_days) == 7:
            # no rest days recorded (or all 7 are rest) -> default to Mon–Fri
            work_days = ["mon", "tue", "wed", "thu", "fri"] if not rest_norm else work_days
        if len(work_days) == 7:
            schedule = {"type": "daily"}
            schedule_type = "daily"
        else:
            schedule = {"type": "weekdays", "days": work_days}
            schedule_type = "weekly"
        habits.append({
            "id": "deep-work", "name": "Deep work", "direction": "at_least",
            "schedule": schedule, "schedule_type": schedule_type,
            "target_count": None, "priority": "high",
            "unit": "", "measure_target": 75, "archived": False,
            "notes": ("Default scored habit (from laptop tracking + the plans "
                      "profile). Auto-scored at /end-of-day: maps the day's laptop "
                      "activity onto the plan's work blocks; score = work / (work + "
                      "distraction) of active time (AFK is neutral, not penalized). "
                      "Marked with --focus JSON of per-category minutes; target 75+."),
            "scoring": {"type": "focus_ratio",
                        "work_categories": ["work"],
                        "distraction_categories": ["social", "entertainment"]},
        })
        added.append("Deep work (scored from laptop activity in your work blocks)")

    if added or linked:
        new_json = json.dumps(data, indent=2)
        text = text[:m.start()] + m.group(1) + new_json + "\n" + m.group(3) + text[m.end():]
        lock.write(text)

for a in added:
    print(f"Added default habit: {a}")
for l in linked:
    print(f"Linked fitness habit ↔ activity: {l}")
PYEOF
  return 0
}

# ---------------------------------------------------------------------------
# profile — manage the VERSIONED habits profile (lib/profiles.sh store at
# <habit-track-dir>/.profile). Day-to-day add/edit/archive remain LIVING-
# document ops on the latest version; `new` mints a draft for structural
# redesigns only, `commit` freezes it.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "profile" ]]; then
  P_ACTION="${2:-show}"
  P_STORE="$(pbrain_habits_store)"
  case "$P_ACTION" in
    show)
      echo "HABITS_PROFILE_SHOW"
      P_F="$(pbrain_profile_latest "$P_STORE" habits-profile)"
      P_D="$(pbrain_profile_draft "$P_STORE" habits-profile)"
      echo "committed: ${P_F:-none}"
      echo "draft: ${P_D:-none}"
      echo "active (resolved): $PROFILE_FILE"
      echo ""
      [[ -f "$PROFILE_FILE" ]] && cat "$PROFILE_FILE"
      echo ""
      echo "---"
      echo "INSTRUCTIONS: Present the habits above as a short human-readable summary"
      echo "(name, schedule, direction, target/measure, priority — one line each)."
      echo "Do not dump raw JSON. Structural redesigns go through:"
      echo "  /habits profile new   (then edit the draft, then /habits profile commit)"
      exit 0
      ;;
    new)
      P_D="$(pbrain_profile_draft "$P_STORE" habits-profile)"
      if [[ -n "$P_D" ]]; then
        echo "HABITS_PROFILE_DRAFT_OPEN"
        echo "draft: $P_D"
        echo "A draft is already open. Iterate on it with the user and, when they confirm,"
        echo "finalize with: bash \"$_SCRIPT_DIR/habits.sh\" profile commit"
        exit 0
      fi
      P_NEW="$(pbrain_profile_new "$P_STORE" habits-profile)" || exit 1
      echo "HABITS_PROFILE_NEW"
      echo "draft: $P_NEW"
      echo ""
      echo "INSTRUCTIONS: A new DRAFT version of the habits profile was minted (copied"
      echo "from the previous version). Walk the user through the structural changes"
      echo "they want (keep the fenced JSON valid and every habit id STABLE — renames"
      echo "touch only the name field; history is keyed to ids), then finalize with:"
      echo "  bash \"$_SCRIPT_DIR/habits.sh\" profile commit"
      echo "Once committed the version is FINAL — further redesigns mint the next one."
      exit 0
      ;;
    commit)
      P_OUT="$(pbrain_profile_commit "$P_STORE" habits-profile)" || exit 1
      echo "HABITS_PROFILE_COMMITTED"
      echo "file: $P_OUT"
      echo "This version is now final. Day-to-day add/edit/archive keep working on it."
      exit 0
      ;;
    *)
      echo "usage: habits.sh profile show|new|commit" >&2
      exit 2
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# log — append/update a habit event. Used by Claude (via the extraction emitter)
# and callable directly. Resolves --name (or --id) to the habit's STABLE id via
# the profile; REJECTS names that aren't a tracked habit (keeps the event log
# clean — every row maps to a defined habit). Idempotent per (habit_id, day).
# ---------------------------------------------------------------------------
if [[ "$SUB" == "log" ]]; then
  shift || true
  H_NAME=""; H_DATE="$TODAY"; H_COUNT="1"; H_SOURCE="habits"; H_NOTE=""; H_AMOUNT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--id) H_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --date)   H_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      --count)  H_COUNT="${2:-1}"; shift 2 2>/dev/null || shift ;;
      --amount) H_AMOUNT="${2:-}"; shift 2 2>/dev/null || shift ;;
      --source) H_SOURCE="${2:-habits}"; shift 2 2>/dev/null || shift ;;
      --note)   H_NOTE="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${H_NAME//[[:space:]]/}" ]]; then
    echo "habits: log requires --name" >&2
    exit 1
  fi
  python3 - "$PBRAIN_DB_FILE" "$PROFILE_FILE" "$H_NAME" "$H_DATE" "$H_COUNT" "$H_SOURCE" "$H_NOTE" "$(date '+%Y-%m-%d %H:%M')" "$H_AMOUNT" <<'PYEOF'
import sqlite3, sys, re, datetime, json
db, profile, name, date, count, source, note, created, amount = sys.argv[1:10]
name = name.strip()

# Resolve name (or id) -> stable habit_id via the profile. Only ACTIVE,
# tracked habits can be logged; unknown names are rejected so the event log
# never accumulates orphan rows that nothing displays.
data = {}
try:
    with open(profile) as fh:
        text = fh.read()
    m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
except Exception:
    data = {}

def slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "").strip().lower()).strip("-")
    return s or "habit"

habit_id = None
disp = name
nm_l = name.lower()
for h in (data.get("habits") or []):
    if h.get("archived"):
        continue
    if str(h.get("name", "")).strip().lower() == nm_l or str(h.get("id", "")).strip().lower() == nm_l:
        habit_id = str(h.get("id", "")).strip() or slug(name)
        disp = str(h.get("name", "")).strip() or name
        break

if not habit_id:
    print(f"not a tracked habit: {name} — add it with /habits (not logged)")
    sys.exit(0)

if not re.match(r"^\d{4}-\d{2}-\d{2}$", date or ""):
    date = datetime.date.today().isoformat()
try:
    count = max(1, int(float(count)))
except (TypeError, ValueError):
    count = 1
try:
    amount = float(amount) if str(amount).strip() else None
except (TypeError, ValueError):
    amount = None
note = (note or "").strip() or None
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    con.execute(
        "INSERT INTO habit_events (habit_id, habit, occurred_on, count, amount, source, note, created_at) "
        "VALUES (?,?,?,?,?,?,?,?) "
        "ON CONFLICT(habit_id, occurred_on) DO UPDATE SET "
        "  count=MAX(habit_events.count, excluded.count), "
        "  amount=COALESCE(excluded.amount, habit_events.amount), "
        "  habit=excluded.habit, "
        "  source=excluded.source, "
        "  note=COALESCE(excluded.note, habit_events.note)",
        (habit_id, disp, date, count, amount, source, note, created),
    )
    con.commit()
    con.close()
    tail = f" — amount {amount}" if amount is not None else ""
    print(f"logged: {disp} on {date} (x{count}){tail}")
except Exception as e:
    print(f"habits: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
  exit 0
fi

# ---------------------------------------------------------------------------
# add — define a new habit: mint a stable id, append to the profile JSON.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "add" ]]; then
  shift || true
  A_NAME=""; A_TYPE=""; A_DIR="at_least"; A_TARGET=""; A_PRIO="medium"; A_NOTES=""
  A_UNIT=""; A_MEASURE=""; A_COMPONENTS=""
  # Schedule (axis 1): kind + its params. Frequency forms resolve to spaced days.
  A_SCHED=""; A_DAYS=""; A_TPW=""; A_START_DAY=""; A_EVERY=""; A_START_DATE=""
  A_DOM=""; A_TPM=""; A_START_DOM=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)            A_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --type)            A_TYPE="${2:-}"; shift 2 2>/dev/null || shift ;;          # legacy → mapped to --schedule
      --direction)       A_DIR="${2:-at_least}"; shift 2 2>/dev/null || shift ;;
      --target)          A_TARGET="${2:-}"; shift 2 2>/dev/null || shift ;;        # legacy
      --priority)        A_PRIO="${2:-medium}"; shift 2 2>/dev/null || shift ;;
      --unit)            A_UNIT="${2:-}"; shift 2 2>/dev/null || shift ;;
      --measure-target)  A_MEASURE="${2:-}"; shift 2 2>/dev/null || shift ;;
      --components)      A_COMPONENTS="${2:-}"; shift 2 2>/dev/null || shift ;;    # checklist scoring: "Item A; Item B=2; Item C"
      --notes)           A_NOTES="${2:-}"; shift 2 2>/dev/null || shift ;;
      --schedule)        A_SCHED="${2:-}"; shift 2 2>/dev/null || shift ;;         # daily|weekdays|interval|monthly
      --days)            A_DAYS="${2:-}"; shift 2 2>/dev/null || shift ;;          # weekdays: mon,wed,fri
      --times-per-week)  A_TPW="${2:-}"; shift 2 2>/dev/null || shift ;;           # weekdays: N (spaced from --start-day)
      --start-day)       A_START_DAY="${2:-}"; shift 2 2>/dev/null || shift ;;
      --every-days)      A_EVERY="${2:-}"; shift 2 2>/dev/null || shift ;;         # interval: every N days
      --start-date)      A_START_DATE="${2:-}"; shift 2 2>/dev/null || shift ;;
      --days-of-month)   A_DOM="${2:-}"; shift 2 2>/dev/null || shift ;;           # monthly: 1,16
      --times-per-month) A_TPM="${2:-}"; shift 2 2>/dev/null || shift ;;           # monthly: N (spaced from --start-dom)
      --start-dom)       A_START_DOM="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${A_NAME//[[:space:]]/}" ]]; then
    echo "habits: add requires --name" >&2
    exit 1
  fi
  case "$A_DIR" in at_least|at_most) ;; *) echo "habits: --direction must be at_least|at_most" >&2; exit 1 ;; esac
  case "$A_PRIO" in low|medium|high) ;; *) A_PRIO="medium" ;; esac
  # Legacy --type maps into a schedule kind when no explicit --schedule was given
  # (a weekly/monthly --target N becomes an N-per-period spacing). schedule_type
  # and target_count are still set from --type/--target below (the scoring axis),
  # so this is purely additive — it does not change existing scoring behavior.
  if [[ -z "${A_SCHED//[[:space:]]/}" && -n "${A_TYPE//[[:space:]]/}" ]]; then
    case "$A_TYPE" in
      daily)   A_SCHED="daily" ;;
      weekly)  A_SCHED="weekdays"; [[ -n "${A_TPW//[[:space:]]/}$A_DAYS" ]] || A_TPW="${A_TARGET:-1}" ;;
      monthly) A_SCHED="monthly";  [[ -n "${A_TPM//[[:space:]]/}$A_DOM" ]]  || A_TPM="${A_TARGET:-1}" ;;
      *) echo "habits: --type must be daily|weekly|monthly" >&2; exit 1 ;;
    esac
  fi

  # Ensure the profile exists with a json block before appending. A fresh
  # bootstrap lands in the versioned store as v1, committed (the store path is
  # what pbrain_habits_profile_file resolves to when nothing exists yet).
  if [[ ! -f "$PROFILE_FILE" ]]; then
    mkdir -p "$(dirname "$PROFILE_FILE")"
    cat > "$PROFILE_FILE" <<EOF
---
type: habits-profile
date: $TODAY
tags: []
version: 1
committed: true
---

# Habits profile

The habits /habits tracks. Edit names/notes freely; structure lives in the JSON
block below. Each habit has a stable \`id\` — don't change it (history is keyed
to it). \`schedule\` = when it occurs (daily | weekdays | interval | monthly);
\`direction\` = at_least (build) or at_most (limit) — a SCORING axis, separate
from the schedule.

\`\`\`json
{
  "created": "$TODAY",
  "habits": []
}
\`\`\`
EOF
  fi

  # DRY: mint the slug via the shared pbrain_habit_slug, feeding it the ids
  # already taken so collisions get a -2/-3 suffix.
  EXISTING_IDS="$(pbrain_habits_json | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("\n".join(str(h.get("id","")).strip() for h in (d.get("habits") or []) if h.get("id")))
' 2>/dev/null || true)"
  NEW_ID="$(pbrain_habit_slug "$A_NAME" "$EXISTING_IDS")"

  PBH_KIND="$A_SCHED" PBH_DAYS="$A_DAYS" PBH_TPW="$A_TPW" PBH_START_DAY="$A_START_DAY" \
  PBH_EVERY="$A_EVERY" PBH_START_DATE="$A_START_DATE" PBH_DOM="$A_DOM" PBH_TPM="$A_TPM" \
  PBH_START_DOM="$A_START_DOM" PBH_TODAY="$TODAY" PBH_TARGET="$A_TARGET" PBH_COMPONENTS="$A_COMPONENTS" \
  python3 - "$_SCRIPT_DIR/../lib" "$PROFILE_FILE" "$NEW_ID" "$A_NAME" "$A_DIR" "$A_PRIO" "$A_NOTES" "$A_UNIT" "$A_MEASURE" <<'PYEOF'
import json, os, re, sys
libdir, path, hid, name, direction, priority, notes, unit, measure = sys.argv[1:10]
sys.path.insert(0, libdir)
from habit_schedule import build_schedule, legacy_fields, schedule_label
from profile_lock import ProfileLock
result_line = ""

def _slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", str(s).strip().lower()).strip("-")
    return s or "item"

def _parse_components(spec):
    """'Item A; Item B=2; Item C' -> [{id,name,weight}]. Weight after '=' (default 1)."""
    comps, seen = [], set()
    for part in str(spec).split(";"):
        part = part.strip()
        if not part:
            continue
        w = 1.0
        if "=" in part:
            nm, _, wraw = part.rpartition("=")
            nm = nm.strip()
            try:
                w = float(wraw.strip())
            except ValueError:
                nm, w = part, 1.0
        else:
            nm = part
        if not nm:
            continue
        cid = _slug(nm)
        base, n = cid, 2
        while cid in seen:
            cid = f"{base}-{n}"; n += 1
        seen.add(cid)
        if w <= 0:
            w = 1.0
        comps.append({"id": cid, "name": nm, "weight": int(w) if float(w).is_integer() else w})
    return comps
with ProfileLock(path) as lock:
    text = lock.read()
    m = re.search(r"(```json\s*\n)(.*?)(```)", text, re.DOTALL)
    data = json.loads(m.group(2)) if m else {"habits": []}
    habits = data.setdefault("habits", [])
    sched = build_schedule({
        "kind": os.environ.get("PBH_KIND"), "days": os.environ.get("PBH_DAYS"),
        "times_per_week": os.environ.get("PBH_TPW"), "start_day": os.environ.get("PBH_START_DAY"),
        "every_days": os.environ.get("PBH_EVERY"), "start_date": os.environ.get("PBH_START_DATE"),
        "days_of_month": os.environ.get("PBH_DOM"), "times_per_month": os.environ.get("PBH_TPM"),
        "start_dom": os.environ.get("PBH_START_DOM"), "today": os.environ.get("PBH_TODAY"),
    })
    # schedule_type / target_count are the legacy SCORING fields the current evaluator
    # still reads: derive from the schedule, but an explicit --target always wins (it
    # is the cap for a limit habit, or the per-period count for a build habit).
    st, tv = legacy_fields(sched)
    target_env = (os.environ.get("PBH_TARGET") or "").strip()
    if target_env:
        try:
            tv = int(target_env)
        except ValueError:
            pass
    try:
        mv = float(measure) if str(measure).strip() else None
        if mv is not None and mv.is_integer():
            mv = int(mv)
    except (TypeError, ValueError):
        mv = None
    # Checklist scoring (--components): a fixed daily set of weighted items. A
    # scored habit must be "measured" (carry a measure_target) for its computed
    # 0-100 score to persist into the DB — default the daily target to 100 (take
    # the whole stack) when one wasn't given.
    components = _parse_components(os.environ.get("PBH_COMPONENTS", ""))
    scoring = None
    if components:
        scoring = {"type": "checklist", "components": components}
        if mv is None:
            mv = 100
    entry = {
        "id": hid, "name": name.strip(), "direction": direction,
        "schedule": sched, "schedule_type": st, "target_count": tv,
        "priority": priority, "unit": unit.strip(), "measure_target": mv,
        "archived": False, "notes": notes.strip(),
    }
    if scoring is not None:
        entry["scoring"] = scoring
    habits.append(entry)
    new_json = json.dumps(data, indent=2)
    if m:
        text = text[:m.start()] + m.group(1) + new_json + "\n" + m.group(3) + text[m.end():]
    else:
        text = text.rstrip() + f"\n\n```json\n{new_json}\n```\n"
    lock.write(text)
    measure_note = f", {mv} {unit.strip()}".rstrip() if mv is not None else ""
    score_note = (", checklist: " + " + ".join(f"{c['name']} ×{c['weight']}" for c in components)) if components else ""
    result_line = f"added: {name.strip()} [{hid}] ({schedule_label(sched)}, {direction}, {priority}{measure_note}{score_note})"
print(result_line)
PYEOF
  exit 0
fi

# ---------------------------------------------------------------------------
# edit — change a habit's fields by id. Renaming keeps the id (history intact).
# ---------------------------------------------------------------------------
if [[ "$SUB" == "edit" ]]; then
  shift || true
  E_ID=""; E_NAME="__keep__"; E_TYPE="__keep__"; E_DIR="__keep__"; E_TARGET="__keep__"; E_PRIO="__keep__"; E_NOTES="__keep__"
  E_UNIT="__keep__"; E_MEASURE="__keep__"; E_COMPONENTS="__keep__"
  # Schedule edit flags — passing ANY of these rebuilds the habit's schedule.
  E_SCHED=""; E_DAYS=""; E_TPW=""; E_START_DAY=""; E_EVERY=""; E_START_DATE=""
  E_DOM=""; E_TPM=""; E_START_DOM=""; E_SCHED_TOUCHED=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)              E_ID="${2:-}"; shift 2 2>/dev/null || shift ;;
      --name)            E_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --type)            E_TYPE="${2:-}"; E_SCHED_TOUCHED=1; shift 2 2>/dev/null || shift ;;
      --direction)       E_DIR="${2:-}"; shift 2 2>/dev/null || shift ;;
      --target)          E_TARGET="${2:-}"; shift 2 2>/dev/null || shift ;;   # scoring (cap/count); does NOT rebuild schedule on its own
      --priority)        E_PRIO="${2:-}"; shift 2 2>/dev/null || shift ;;
      --unit)            E_UNIT="${2:-}"; shift 2 2>/dev/null || shift ;;
      --measure-target)  E_MEASURE="${2:-}"; shift 2 2>/dev/null || shift ;;
      --components)      E_COMPONENTS="${2:-}"; shift 2 2>/dev/null || shift ;;   # checklist scoring; "" clears it
      --notes)           E_NOTES="${2:-}"; shift 2 2>/dev/null || shift ;;
      --schedule)        E_SCHED="${2:-}"; E_SCHED_TOUCHED=1; shift 2 2>/dev/null || shift ;;
      --days)            E_DAYS="${2:-}"; E_SCHED_TOUCHED=1; shift 2 2>/dev/null || shift ;;
      --times-per-week)  E_TPW="${2:-}"; E_SCHED_TOUCHED=1; shift 2 2>/dev/null || shift ;;
      --start-day)       E_START_DAY="${2:-}"; E_SCHED_TOUCHED=1; shift 2 2>/dev/null || shift ;;
      --every-days)      E_EVERY="${2:-}"; E_SCHED_TOUCHED=1; shift 2 2>/dev/null || shift ;;
      --start-date)      E_START_DATE="${2:-}"; E_SCHED_TOUCHED=1; shift 2 2>/dev/null || shift ;;
      --days-of-month)   E_DOM="${2:-}"; E_SCHED_TOUCHED=1; shift 2 2>/dev/null || shift ;;
      --times-per-month) E_TPM="${2:-}"; E_SCHED_TOUCHED=1; shift 2 2>/dev/null || shift ;;
      --start-dom)       E_START_DOM="${2:-}"; E_SCHED_TOUCHED=1; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${E_ID//[[:space:]]/}" || ! -f "$PROFILE_FILE" ]]; then
    echo "habits: edit requires --id and an existing profile" >&2
    exit 1
  fi
  # Legacy --type maps to a schedule kind (mirrors add).
  if [[ -z "${E_SCHED//[[:space:]]/}" && "$E_TYPE" != "__keep__" && -n "${E_TYPE//[[:space:]]/}" ]]; then
    case "$E_TYPE" in
      daily)   E_SCHED="daily" ;;
      weekly)  E_SCHED="weekdays"; [[ -n "${E_TPW//[[:space:]]/}$E_DAYS" ]] || { [[ "$E_TARGET" != "__keep__" ]] && E_TPW="$E_TARGET" || E_TPW="1"; } ;;
      monthly) E_SCHED="monthly";  [[ -n "${E_TPM//[[:space:]]/}$E_DOM" ]]  || { [[ "$E_TARGET" != "__keep__" ]] && E_TPM="$E_TARGET" || E_TPM="1"; } ;;
    esac
  fi
  PBH_TOUCHED="$E_SCHED_TOUCHED" PBH_KIND="$E_SCHED" PBH_DAYS="$E_DAYS" PBH_TPW="$E_TPW" \
  PBH_START_DAY="$E_START_DAY" PBH_EVERY="$E_EVERY" PBH_START_DATE="$E_START_DATE" \
  PBH_DOM="$E_DOM" PBH_TPM="$E_TPM" PBH_START_DOM="$E_START_DOM" PBH_TODAY="$TODAY" \
  python3 - "$_SCRIPT_DIR/../lib" "$PROFILE_FILE" "$E_ID" "$E_NAME" "$E_DIR" "$E_TARGET" "$E_PRIO" "$E_NOTES" "$E_UNIT" "$E_MEASURE" "$E_COMPONENTS" <<'PYEOF'
import json, os, re, sys
libdir, path, hid, name, direction, target, priority, notes, unit, measure, components = sys.argv[1:12]
sys.path.insert(0, libdir)
from habit_schedule import build_schedule, legacy_fields
from profile_lock import ProfileLock
KEEP = "__keep__"
result_line = ""

def _slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", str(s).strip().lower()).strip("-")
    return s or "item"

def _parse_components(spec):
    comps, seen = [], set()
    for part in str(spec).split(";"):
        part = part.strip()
        if not part:
            continue
        w = 1.0
        if "=" in part:
            nm, _, wraw = part.rpartition("=")
            nm = nm.strip()
            try:
                w = float(wraw.strip())
            except ValueError:
                nm, w = part, 1.0
        else:
            nm = part
        if not nm:
            continue
        cid = _slug(nm)
        base, n = cid, 2
        while cid in seen:
            cid = f"{base}-{n}"; n += 1
        seen.add(cid)
        if w <= 0:
            w = 1.0
        comps.append({"id": cid, "name": nm, "weight": int(w) if float(w).is_integer() else w})
    return comps
with ProfileLock(path) as lock:
    text = lock.read()
    m = re.search(r"(```json\s*\n)(.*?)(```)", text, re.DOTALL)
    if not m:
        print("habits: no json block in profile", file=sys.stderr); sys.exit(1)
    data = json.loads(m.group(2))
    found = None
    for h in (data.get("habits") or []):
        if str(h.get("id", "")).strip() == hid:
            found = h
            break
    if found is None:
        print(f"habits: no habit with id {hid}", file=sys.stderr); sys.exit(1)
    if name != KEEP and name.strip():
        found["name"] = name.strip()
    if direction != KEEP and direction in ("at_least", "at_most"):
        found["direction"] = direction
    if priority != KEEP and priority in ("low", "medium", "high"):
        found["priority"] = priority
    if unit != KEEP:
        found["unit"] = unit.strip()
    if measure != KEEP:
        if str(measure).strip():
            try:
                mv = float(measure)
                found["measure_target"] = int(mv) if mv.is_integer() else mv
            except (TypeError, ValueError):
                found["measure_target"] = None
        else:
            found["measure_target"] = None
    if notes != KEEP:
        found["notes"] = notes.strip()
    # Checklist scoring: --components "A; B=2; C" sets the spec; --components ""
    # clears it (drops the habit back to a plain tracked habit).
    if components != KEEP:
        comps = _parse_components(components)
        if comps:
            found["scoring"] = {"type": "checklist", "components": comps}
            if found.get("measure_target") is None:
                found["measure_target"] = 100  # scored habit must be measured to persist
        else:
            found.pop("scoring", None)
    # Rebuild the schedule only when a schedule-affecting flag was passed.
    if os.environ.get("PBH_TOUCHED") == "1":
        sched = build_schedule({
            "kind": os.environ.get("PBH_KIND"), "days": os.environ.get("PBH_DAYS"),
            "times_per_week": os.environ.get("PBH_TPW"), "start_day": os.environ.get("PBH_START_DAY"),
            "every_days": os.environ.get("PBH_EVERY"), "start_date": os.environ.get("PBH_START_DATE"),
            "days_of_month": os.environ.get("PBH_DOM"), "times_per_month": os.environ.get("PBH_TPM"),
            "start_dom": os.environ.get("PBH_START_DOM"), "today": os.environ.get("PBH_TODAY"),
        })
        found["schedule"] = sched
        st, tv = legacy_fields(sched)
        found["schedule_type"] = st
        found["target_count"] = tv
    # An explicit --target always wins (scoring axis: a limit cap / a build count),
    # applied after any schedule rebuild so it is never clobbered by the derivation.
    if target != KEEP:
        try:
            found["target_count"] = int(target) if str(target).strip() else None
        except (TypeError, ValueError):
            found["target_count"] = None
    new_json = json.dumps(data, indent=2)
    text = text[:m.start()] + m.group(1) + new_json + "\n" + m.group(3) + text[m.end():]
    lock.write(text)
    result_line = f"edited: {found.get('name')} [{hid}]"
print(result_line)
PYEOF
  exit 0
fi

# ---------------------------------------------------------------------------
# archive — soft-delete a habit by id. Events are preserved (history queryable).
# ---------------------------------------------------------------------------
if [[ "$SUB" == "archive" ]]; then
  shift || true
  AR_ID=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) AR_ID="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${AR_ID//[[:space:]]/}" || ! -f "$PROFILE_FILE" ]]; then
    echo "habits: archive requires --id and an existing profile" >&2
    exit 1
  fi
  python3 - "$_SCRIPT_DIR/../lib" "$PROFILE_FILE" "$AR_ID" <<'PYEOF'
import json, re, sys
libdir, path, hid = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, libdir)
from profile_lock import ProfileLock
result_lines = []
with ProfileLock(path) as lock:
    text = lock.read()
    m = re.search(r"(```json\s*\n)(.*?)(```)", text, re.DOTALL)
    if not m:
        print("habits: no json block in profile", file=sys.stderr); sys.exit(1)
    data = json.loads(m.group(2))
    found = None
    for h in (data.get("habits") or []):
        if str(h.get("id", "")).strip() == hid:
            h["archived"] = True
            found = h
            break
    if found is None:
        print(f"habits: no habit with id {hid}", file=sys.stderr); sys.exit(1)
    new_json = json.dumps(data, indent=2)
    text = text[:m.start()] + m.group(1) + new_json + "\n" + m.group(3) + text[m.end():]
    lock.write(text)
    result_lines.append(f"archived: {found.get('name')} [{hid}] (history kept)")
    rem = found.get("reminder") if isinstance(found.get("reminder"), dict) else {}
    if rem.get("state") == "linked":
        # Was linked → its per-day one-shots (ids live in the DB) may still be
        # pending; signal /habits to offer cancelling them via reminder --unlink.
        result_lines.append("LINKED_REMINDER")
print("\n".join(result_lines))
PYEOF
  exit 0
fi

# ---------------------------------------------------------------------------
# history — event history for one habit (newest first). Resolves --name/--id.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "history" ]]; then
  shift || true
  HI_NAME=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--id) HI_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${HI_NAME//[[:space:]]/}" ]]; then
    echo "habits: history requires --name" >&2
    exit 1
  fi
  python3 - "$PBRAIN_DB_FILE" "$PROFILE_FILE" "$HI_NAME" <<'PYEOF'
import sqlite3, sys, re, json, os
db, profile, name = sys.argv[1], sys.argv[2], sys.argv[3].strip()

def slug(s):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "").strip().lower()).strip("-")
    return s or "habit"

# resolve to a habit_id via the profile, falling back to the slug of the input
habit_id, disp = None, name
try:
    with open(profile) as fh:
        m = re.search(r"```json\s*\n(.*?)```", fh.read(), re.DOTALL)
        data = json.loads(m.group(1)) if m else {}
except Exception:
    data = {}
nm_l = name.lower()
for h in (data.get("habits") or []):
    if str(h.get("name", "")).strip().lower() == nm_l or str(h.get("id", "")).strip().lower() == nm_l:
        habit_id = str(h.get("id", "")).strip() or slug(name)
        disp = str(h.get("name", "")).strip() or name
        break
if not habit_id:
    habit_id = slug(name)

print(f"HISTORY: {disp} [{habit_id}]")
rows = []
if os.path.exists(db):
    try:
        con = sqlite3.connect(db, timeout=5)
        con.execute("PRAGMA busy_timeout=5000")
        rows = con.execute(
            "SELECT occurred_on, count, source, note FROM habit_events "
            "WHERE habit_id=? ORDER BY occurred_on DESC", (habit_id,)
        ).fetchall()
        con.close()
    except Exception:
        rows = []
if not rows:
    print("(no history yet)")
else:
    for d, c, src, note in rows:
        extra = f" x{c}" if (c or 1) != 1 else ""
        tail = f" — {note}" if note else ""
        print(f"- {d}{extra} ({src or '?'}){tail}")
    print(f"({len(rows)} day(s) logged)")
PYEOF
  exit 0
fi

# ---------------------------------------------------------------------------
# rollup — text rollup (top 20 vs criteria). Reused by plan-my-day/eod/weekly.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "rollup" ]]; then
  shift || true
  R_DATE="$TODAY"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) R_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  ROLL="$(pbrain_habits_rollup "$R_DATE" || true)"
  if [[ -n "${ROLL//[[:space:]]/}" ]]; then
    echo "$ROLL"
  else
    echo "(no habit data — set up tracking with /habits)"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# status — structured per-habit status JSON (machine-readable).
# ---------------------------------------------------------------------------
if [[ "$SUB" == "status" ]]; then
  shift || true
  S_DATE="$TODAY"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) S_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  pbrain_habits_status "$S_DATE"
  exit 0
fi

# ---------------------------------------------------------------------------
# scores — read back engine-computed scores for all scored habits on a date.
# Scored habits carry a `scoring` block in the profile JSON; their 0–100 score
# is stored in habit_events.amount at mark time. Emits human-readable lines
# plus a HABIT_SCORES [...] JSON trailer for machine consumption.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "scores" ]]; then
  shift || true
  SCRD_DATE="$TODAY"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) SCRD_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  pbrain_habits_scores "$SCRD_DATE"
  exit 0
fi

# ---------------------------------------------------------------------------
# track — create/refresh the dated tracking markdown (the human-facing log).
# Generated from the profile: a row per active habit with empty Done cells.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "track" || "$SUB" == "track-init" ]]; then
  shift || true
  T_DATE="$TODAY"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) T_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "habits: no profile yet — run /habits to set up your habits first" >&2
    exit 1
  fi
  # Seed default scored habits first so they appear in this date's tracker.
  _habits_seed_defaults || true
  FILE="$(pbrain_habit_track_init "$T_DATE")"
  # Best-effort: ensure linked habits have their per-day one-shot reminder for
  # this date (idempotent; degrades silently without Reminders access).
  bash "$_SCRIPT_DIR/habits.sh" reminders-ensure --date "$T_DATE" >/dev/null 2>&1 || true
  echo "HABITS_TRACK_FILE"
  echo "file: $FILE"
  echo "date: $T_DATE"
  echo "(today's habit checklist — mark 'x' in the Done column as you do each one;"
  echo " /end-of-day consolidates it to the DB and prunes what you didn't do)"
  exit 0
fi

# ---------------------------------------------------------------------------
# mark — mark a habit done in the dated tracking md (the primary write path).
# Resolves --name to a tracked habit; rejects unknown names.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "mark" ]]; then
  shift || true
  M_NAME=""; M_DATE="$TODAY"; M_COUNT="1"; M_NOTE=""; M_AMOUNT=""
  M_GOOD=""; M_BAD=""; M_SLIPS=""; M_ATIME=""; M_AHOURS=""
  M_ITEMS=""; M_SESSION=""; M_FOCUS=""; M_DONE=""; M_STATUS="done"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--id) M_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --date)   M_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      --count)  M_COUNT="${2:-1}"; shift 2 2>/dev/null || shift ;;
      --amount) M_AMOUNT="${2:-}"; shift 2 2>/dev/null || shift ;;
      --good)   M_GOOD="${2:-}"; shift 2 2>/dev/null || shift ;;
      --bad)    M_BAD="${2:-}"; shift 2 2>/dev/null || shift ;;
      --slips)  M_SLIPS="${2:-}"; shift 2 2>/dev/null || shift ;;
      --actual-time)  M_ATIME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --actual-hours) M_AHOURS="${2:-}"; shift 2 2>/dev/null || shift ;;
      --items)   M_ITEMS="${2:-}"; shift 2 2>/dev/null || shift ;;
      --session) M_SESSION="${2:-}"; shift 2 2>/dev/null || shift ;;
      --focus)   M_FOCUS="${2:-}"; shift 2 2>/dev/null || shift ;;
      --done)    M_DONE="${2:-}"; shift 2 2>/dev/null || shift ;;
      --status) M_STATUS="${2:-done}"; shift 2 2>/dev/null || shift ;;
      --skip)   M_STATUS="skipped"; shift ;;   # sugar for --status skipped
      --note)   M_NOTE="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${M_NAME//[[:space:]]/}" ]]; then
    echo "habits: mark requires --name" >&2
    exit 1
  fi
  if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "not a tracked habit: $M_NAME — add it with /habits (not marked)"
    exit 0
  fi
  pbrain_habit_mark "$M_DATE" "$M_NAME" "$M_COUNT" "$M_NOTE" "$M_AMOUNT" \
    "$M_GOOD" "$M_BAD" "$M_SLIPS" "$M_ATIME" "$M_AHOURS" "$M_ITEMS" "$M_SESSION" "$M_FOCUS" "$M_DONE" "$M_STATUS"
  exit 0
fi

# ---------------------------------------------------------------------------
# score — deterministically compute a scored habit's score from its profile
# rule + raw classification counts, WITHOUT writing anything. Prints the number.
#   habits.sh score --name "Eat clean" --good 3 --bad 0
#   habits.sh score --name "Eat clean" --slips 2
# ---------------------------------------------------------------------------
if [[ "$SUB" == "score" ]]; then
  shift || true
  SC_NAME=""; SC_GOOD=""; SC_BAD=""; SC_SLIPS=""; SC_ATIME=""; SC_AHOURS=""
  SC_ITEMS=""; SC_SESSION=""; SC_FOCUS=""; SC_DONE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--id) SC_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --good)  SC_GOOD="${2:-}"; shift 2 2>/dev/null || shift ;;
      --bad)   SC_BAD="${2:-}"; shift 2 2>/dev/null || shift ;;
      --slips) SC_SLIPS="${2:-}"; shift 2 2>/dev/null || shift ;;
      --actual-time)  SC_ATIME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --actual-hours) SC_AHOURS="${2:-}"; shift 2 2>/dev/null || shift ;;
      --items)   SC_ITEMS="${2:-}"; shift 2 2>/dev/null || shift ;;
      --session) SC_SESSION="${2:-}"; shift 2 2>/dev/null || shift ;;
      --focus)   SC_FOCUS="${2:-}"; shift 2 2>/dev/null || shift ;;
      --done)    SC_DONE="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${SC_NAME//[[:space:]]/}" ]]; then
    echo "habits: score requires --name" >&2
    exit 1
  fi
  if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "no habits profile" >&2
    exit 1
  fi
  pbrain_habit_score "$SC_NAME" "$SC_GOOD" "$SC_BAD" "$SC_SLIPS" "$SC_ATIME" "$SC_AHOURS" "$SC_ITEMS" "$SC_SESSION" "$SC_FOCUS" "$SC_DONE"
  exit 0
fi

# ---------------------------------------------------------------------------
# sync — mirror the last N days of tracking md into the DB (default 7). Run by
# read commands so the analysis store reflects the markdown before querying.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "sync" ]]; then
  shift || true
  S_DAYS="7"
  S_DATE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --days) S_DAYS="${2:-7}"; shift 2 2>/dev/null || shift ;;
      --date) S_DATE="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  pbrain_habits_sync_range "$S_DAYS" "$S_DATE"
  echo "synced last $S_DAYS day(s) of habit tracking into the DB"
  exit 0
fi

# ---------------------------------------------------------------------------
# consolidate — sync one date's md into the DB, then prune that file to only the
# habits actually done. Run by /end-of-day.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "consolidate" ]]; then
  shift || true
  C_DATE="$TODAY"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) C_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "(no habits profile — nothing to consolidate)"
    exit 0
  fi
  pbrain_habit_consolidate "$C_DATE"
  exit 0
fi

# ---------------------------------------------------------------------------
# refresh — recompute the Progress column in the tracking md from the DB without
# touching any Done marks. One date, or --days N back (oldest→newest). Used to
# backfill historical trackers after a formula/data change.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "refresh" ]]; then
  shift || true
  RF_DATE="$TODAY"; RF_DAYS=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) RF_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      --days) RF_DAYS="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ ! -f "$PROFILE_FILE" ]]; then
    echo "(no habits profile — nothing to refresh)"
    exit 0
  fi
  if [[ -n "${RF_DAYS//[[:space:]]/}" ]]; then
    pbrain_habit_refresh_range "$RF_DAYS" "$RF_DATE"
    echo "refreshed Progress across the last $RF_DAYS day(s) of trackers (through $RF_DATE)"
  else
    pbrain_habit_refresh "$RF_DATE"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# suggest-seen — record that a new-habit candidate was suggested, so the
# cross-command nudge doesn't re-suggest it for a while. Called by the agent.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "suggest-seen" ]]; then
  shift || true
  SS_NAME=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--id) SS_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${SS_NAME//[[:space:]]/}" ]]; then
    echo "habits: suggest-seen requires --name" >&2
    exit 1
  fi
  pbrain_habit_suggest_record "$(pbrain_habit_slug "$SS_NAME")" "$TODAY"
  echo "noted: won't re-suggest '$SS_NAME' for a while"
  exit 0
fi

# ---------------------------------------------------------------------------
# reminder — manage a habit's link to Apple Reminders (/remind). ANY habit can
# opt in (build or limit) — linking creates a per-day ONE-SHOT reminder at `time`
# on the days the habit's SCHEDULE is due, and keeps it in two-way sync (see
# reminders-ensure / reminders-sync). The Apple reminder is purely a notification
# + a familiar checkbox — pbrain owns the habit data and the score. The link is
# an INTENT on the habit: {"state":"linked","time":"07:00"}; which DAYS it fires
# comes from the habit's `schedule` (NOT from the reminder), and the per-day
# reminder ids live in the DB (habit_reminders). Exactly one action:
#   --link --time HH:MM     enable per-day one-shot reminders on the habit's schedule
#   --decline               record "no reminder" so it's never re-offered
#   --unlink [--cancel]     drop the link; --cancel also cancels today's + future
#                           pending one-shots in Reminders
# Reminder ops go through the shared /remind EventKit helper (pbrain_reminders_run,
# in scope via lib/reminders.sh) — the first one triggers the one-time macOS
# Reminders access prompt, separate from Calendar.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "reminder" ]]; then
  shift || true
  RM_ID=""; RM_ACTION=""; RM_TIME=""; RM_CANCEL=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)      RM_ID="${2:-}"; shift 2 2>/dev/null || shift ;;
      --link|--create|--enable) RM_ACTION="link"; shift ;;
      --decline) RM_ACTION="decline"; shift ;;
      --unlink)  RM_ACTION="unlink"; shift ;;
      --time)    RM_TIME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --cancel)  RM_CANCEL=1; shift ;;
      *) shift ;;
    esac
  done
  if [[ -z "${RM_ID//[[:space:]]/}" || ! -f "$PROFILE_FILE" ]]; then
    echo "habits: reminder requires --id and an existing profile" >&2; exit 1
  fi
  [[ -n "$RM_ACTION" ]] || { echo "habits: reminder needs one of --link --time HH:MM | --decline | --unlink" >&2; exit 1; }

  # Habit facts for the id: NAME<TAB>schedule-label (empty line = no such id).
  HINFO="$(python3 - "$_SCRIPT_DIR/../lib" "$PROFILE_FILE" "$RM_ID" <<'PYEOF' 2>/dev/null || true
import json, re, sys
libdir, path, hid = sys.argv[1:4]
sys.path.insert(0, libdir)
try:
    from habit_schedule import derive_schedule, schedule_label
except Exception:
    schedule_label = lambda s: "daily"; derive_schedule = lambda h: {"type": "daily"}
try:
    m = re.search(r"```json\s*\n(.*?)```", open(path).read(), re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
except Exception:
    sys.exit(0)
for h in (data.get("habits") or []):
    if str(h.get("id", "")).strip() != hid:
        continue
    print("%s\t%s" % (str(h.get("name", "")).strip(), schedule_label(derive_schedule(h))))
    break
PYEOF
)"
  if [[ -z "${HINFO//[[:space:]]/}" ]]; then
    echo "habits: no habit with id $RM_ID" >&2; exit 1
  fi
  RM_NAME="$(printf '%s' "$HINFO" | cut -f1)"
  RM_SCHED_LABEL="$(printf '%s' "$HINFO" | cut -f2)"

  _rm_valid_time() { [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; }
  _rm_write() {  # <linked|declined|clear> [<time>]
    python3 - "$PROFILE_FILE" "$RM_ID" "$1" "${2:-}" <<'PYEOF'
import json, re, sys, fcntl, os
path, hid, state, rtime = sys.argv[1:5]
lock_path = path + ".lock"
with open(lock_path, 'w') as lf:
    fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
    text = open(path).read()
    m = re.search(r"(```json\s*\n)(.*?)(```)", text, re.DOTALL)
    if not m:
        print("habits: no json block in profile", file=sys.stderr); sys.exit(1)
    data = json.loads(m.group(2))
    found = None
    for h in (data.get("habits") or []):
        if str(h.get("id", "")).strip() == hid:
            found = h; break
    if found is None:
        print(f"habits: no habit with id {hid}", file=sys.stderr); sys.exit(1)
    if state == "clear":
        found.pop("reminder", None)
    elif state == "declined":
        found["reminder"] = {"state": "declined"}
    else:
        found["reminder"] = {"state": "linked", "time": rtime}
    new_json = json.dumps(data, indent=2)
    text = text[:m.start()] + m.group(1) + new_json + "\n" + m.group(3) + text[m.end():]
    open(path, "w").write(text)
PYEOF
  }

  case "$RM_ACTION" in
    decline)
      _rm_write declined || { echo "habits: failed to update profile" >&2; exit 1; }
      echo "reminder: '$RM_NAME' set to no reminder (won't re-offer)" ;;
    unlink)
      # --cancel deletes today's + future PENDING one-shots from Reminders and
      # marks their rows cancelled; past/done rows are history and left alone.
      if [[ "$RM_CANCEL" -eq 1 ]]; then
        RIDS="$(python3 - "$PBRAIN_DB_FILE" "$RM_ID" "$TODAY" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys
db, hid, today = sys.argv[1:4]
try:
    con = sqlite3.connect(db, timeout=5)
    for (rid,) in con.execute("SELECT reminder_id FROM habit_reminders WHERE habit_id=? AND occurred_on>=? AND status='pending'", (hid, today)).fetchall():
        print(rid)
    con.close()
except Exception:
    pass
PYEOF
)"
        while IFS= read -r rid; do
          [[ -n "${rid//[[:space:]]/}" ]] || continue
          pbrain_reminders_run delete --id "$rid" >/dev/null 2>&1 || true
        done <<< "$RIDS"
        python3 - "$PBRAIN_DB_FILE" "$RM_ID" "$TODAY" "$(date '+%Y-%m-%d %H:%M')" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys
db, hid, today, now = sys.argv[1:5]
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("UPDATE habit_reminders SET status='cancelled', resolved_at=? WHERE habit_id=? AND occurred_on>=? AND status='pending'", (now, hid, today))
    con.commit(); con.close()
except Exception:
    pass
PYEOF
      fi
      _rm_write clear || { echo "habits: failed to update profile" >&2; exit 1; }
      if [[ "$RM_CANCEL" -eq 1 ]]; then echo "reminder: unlinked '$RM_NAME' (today's + future reminders cancelled)"; else echo "reminder: unlinked '$RM_NAME'"; fi ;;
    link)
      # Any habit can opt in — its SCHEDULE decides which days fire.
      _rm_valid_time "$RM_TIME" || { echo "habits: --link needs --time HH:MM (24h)" >&2; exit 1; }
      _rm_write linked "$RM_TIME" || { echo "habits: failed to update profile" >&2; exit 1; }
      # Best-effort: create today's one-shot now (if due today) so the user sees
      # it immediately. (reminders-ensure is idempotent and degrades silently.)
      ENS="$(bash "$_SCRIPT_DIR/habits.sh" reminders-ensure --date "$TODAY" 2>/dev/null || true)"
      echo "reminder: linked '$RM_NAME' — $RM_TIME on its schedule (${RM_SCHED_LABEL:-daily}), kept in two-way sync with the habit"
      case "$ENS" in
        *ACCESS_DENIED*) echo "  (Reminders access isn't granted yet — run \`/remind access\` once; reminders appear after you approve.)" ;;
        *UNAVAILABLE*)   echo "  (the Reminders helper needs swiftc — \`xcode-select --install\`; the link is saved and reminders start once it's available.)" ;;
      esac ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# reminders-pending — habits with NO reminder decision yet (state absent/none).
# Reminders are an opt-in ANY habit can take, so this lists every undecided
# non-archived habit (the agent offers case by case — it does not auto-nag).
# One "id<TAB>name" line each; empty when none / not set up.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "reminders-pending" ]]; then
  [[ -f "$PROFILE_FILE" ]] || exit 0
  pbrain_habits_status "$TODAY" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for h in d.get("habits") or []:
    if (h.get("reminder") or {}).get("state") == "none":
        print("%s\t%s" % (h.get("id", ""), h.get("name", "")))
' 2>/dev/null || true
  exit 0
fi

# ---------------------------------------------------------------------------
# reminders-ensure [--date] — make sure each LINKED habit scheduled on <date>
# has its per-day one-shot Apple Reminder. Idempotent: the (habit_id, date) PK in
# habit_reminders guards against duplicates, so re-running creates nothing new.
# Creates a timed one-shot (no Apple recurrence) at the habit's linked time, with
# an at-due alarm, and records the reminder id in the DB. Degrades silently when
# Reminders access/helper is missing (echoes ACCESS_DENIED|UNAVAILABLE and stops,
# leaving the link in place to retry next run). Echoes "ENSURED <n>" otherwise.
# Schedule-gated via the habit_schedule engine: a linked habit fires only on the
# days its schedule is_due — daily (every day), weekdays (mon/wed/fri), interval
# (every N days from a start), or monthly (the Nth) — so off-days create nothing.
# Run by track / plan-my-day.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "reminders-ensure" ]]; then
  shift || true
  RE_DATE="$TODAY"; RE_ONLY=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) RE_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      # --habit <id|name>: ensure JUST this habit, BYPASSING the is_due gate —
      # used by fitness-reconcile to create a one-shot for an off-schedule chosen
      # activity (e.g. doing Apple Fitness on a Gym-scheduled Monday).
      --habit) RE_ONLY="${2:-}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  [[ -f "$PROFILE_FILE" ]] || exit 0
  # Atomic mkdir lock prevents parallel ensure calls from each creating their own
  # Apple Reminders before any can INSERT into the DB (TOCTOU race on the have-set).
  # A concurrent caller sees the dir exists and exits immediately — idempotent since
  # the first caller will create all reminders for this date.
  _ENSURE_LOCK="${PBRAIN_DB_FILE%.db}.ensure.lock.d"
  if ! mkdir "$_ENSURE_LOCK" 2>/dev/null; then
    echo "ENSURED 0"; exit 0
  fi
  trap "rm -rf '$_ENSURE_LOCK' 2>/dev/null || true" EXIT INT TERM
  TODO="$(python3 - "$_SCRIPT_DIR/../lib" "$PROFILE_FILE" "$PBRAIN_DB_FILE" "$RE_DATE" "$RE_ONLY" <<'PYEOF' 2>/dev/null || true
import json, re, sys, sqlite3
libdir, profile, db, date = sys.argv[1:5]
only = (sys.argv[5] if len(sys.argv) > 5 else "").strip().lower()
sys.path.insert(0, libdir)
try:
    from habit_schedule import derive_schedule, is_due
except Exception:
    sys.exit(0)
try:
    m = re.search(r"```json\s*\n(.*?)```", open(profile).read(), re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
except Exception:
    sys.exit(0)
have = set()
try:
    con = sqlite3.connect(db, timeout=5)
    for (hid,) in con.execute("SELECT habit_id FROM habit_reminders WHERE occurred_on=?", (date,)).fetchall():
        have.add(hid)
    con.close()
except Exception:
    pass
for h in (data.get("habits") or []):
    if h.get("archived"):
        continue
    hid = str(h.get("id", "")).strip()
    hname = str(h.get("name", "")).strip()
    # --habit narrows to one habit (matched by id OR name) and bypasses is_due.
    is_only = bool(only) and (hid.lower() == only or hname.lower() == only)
    if only and not is_only:
        continue
    rem = h.get("reminder") if isinstance(h.get("reminder"), dict) else {}
    if str(rem.get("state", "")).strip().lower() != "linked" or not str(rem.get("time", "")).strip():
        continue
    if hid in have:
        continue
    if not is_only and not is_due(derive_schedule(h), date):
        continue   # not scheduled on this date → no one-shot (skipped for --habit)
    print("%s\t%s\t%s" % (hid, hname, str(rem.get("time")).strip()))
PYEOF
)"
  if [[ -z "${TODO//[[:space:]]/}" ]]; then echo "ENSURED 0"; exit 0; fi
  CREATED=0
  while IFS=$'\t' read -r hid name htime; do
    [[ -n "${hid//[[:space:]]/}" && -n "${htime//[[:space:]]/}" ]] || continue
    RES="$(pbrain_reminders_run add --title "$name" --due "$RE_DATE $htime" --alarms "0" 2>/dev/null || true)"
    case "$RES" in
      ADDED\ *)
        rid="${RES#ADDED }"; rid="${rid%% *}"
        # Record the tracking row, then CONFIRM it points at this rid. If the
        # write failed (transient DB lock) or a row for (habit,date) already
        # exists with a different rid, this reminder is untracked → an orphan the
        # end-of-day sweep could never resolve. Delete it rather than leave it.
        INS="$(python3 - "$PBRAIN_DB_FILE" "$hid" "$RE_DATE" "$rid" "$(date '+%Y-%m-%d %H:%M')" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys
db, hid, date, rid, now = sys.argv[1:6]
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("INSERT OR IGNORE INTO habit_reminders (habit_id, occurred_on, reminder_id, status, created_at) VALUES (?,?,?,?,?)",
                (hid, date, rid, 'pending', now))
    con.commit()
    row = con.execute("SELECT reminder_id FROM habit_reminders WHERE habit_id=? AND occurred_on=?", (hid, date)).fetchone()
    con.close()
    if row and row[0] == rid:
        print("OK")
except Exception:
    pass
PYEOF
)"
        if [[ "${INS:-}" == OK ]]; then
          CREATED=$((CREATED + 1))
        else
          pbrain_reminders_run delete --id "$rid" >/dev/null 2>&1 || true
        fi ;;
      ACCESS_DENIED) echo "ACCESS_DENIED"; exit 0 ;;
      UNAVAILABLE)   echo "UNAVAILABLE"; exit 0 ;;
      *) : ;;  # transient error — leave it, retry next run
    esac
  done <<< "$TODO"
  echo "ENSURED $CREATED"
  exit 0
fi

# ---------------------------------------------------------------------------
# reminders-sync [--date] [--sweep] — reconcile a day's linked habits with their
# per-day one-shot reminders, BOTH directions:
#   PULL  reminder → habit: a pending one-shot the user checked off in the Apple
#         Reminders app (status DONE) marks the habit done that day (md + DB) and
#         closes the row; a MISSING (deleted) one-shot just closes the row.
#   PUSH  habit → reminder: a habit already done that day whose one-shot is still
#         pending gets its reminder completed, then the row closed.
#   SWEEP (only with --sweep): any one-shot STILL pending after PULL+PUSH means
#         the habit wasn't done and the reminder wasn't ticked — the day is
#         closing, so delete the stale Apple Reminder and close the row so it
#         doesn't linger as an overdue notification. Gated behind --sweep so the
#         morning plan-my-day sync never deletes the day's not-yet-done reminders;
#         end-of-day passes --sweep.
#   ORPHAN sweep (also --sweep only): the three steps above are DB-row-driven, so
#         a habit reminder that exists in the Reminders app but has NO tracking
#         row (a create-without-recorded-row orphan — e.g. a transient DB lock
#         during plan-my-day's ensure) is invisible to them and lingers overdue.
#         So after the row sweep, list the app's pbrain reminders for <date> and
#         delete any whose title matches a known habit name AND has no tracking
#         row. The title+date match keeps /remind reminders and other days safe.
# PULL runs first so PUSH never double-handles a row. Degrades silently without
# Reminders access (PENDING/UNAVAILABLE/ACCESS leave rows untouched). Echoes
# "SYNCED pulled=<n> pushed=<n> swept=<n>". Run by plan-my-day (morning, no sweep)
# + end-of-day (with --sweep).
# ---------------------------------------------------------------------------
if [[ "$SUB" == "reminders-sync" ]]; then
  shift || true
  RS_DATE="$TODAY"; RS_SWEEP=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date)  RS_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      --sweep) RS_SWEEP=1; shift ;;
      *) shift ;;
    esac
  done
  [[ -f "$PROFILE_FILE" ]] || exit 0

  _hr_name_for_id() {  # <habit_id> → display name (or empty)
    python3 - "$PROFILE_FILE" "$1" <<'PYEOF' 2>/dev/null || true
import json, re, sys
path, hid = sys.argv[1], sys.argv[2]
try:
    m = re.search(r"```json\s*\n(.*?)```", open(path).read(), re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
except Exception:
    data = {}
for h in (data.get("habits") or []):
    if str(h.get("id", "")).strip() == hid:
        print(str(h.get("name", "")).strip()); break
PYEOF
  }
  _hr_set_status() {  # <habit_id> <date> <status>
    python3 - "$PBRAIN_DB_FILE" "$1" "$2" "$3" "$(date '+%Y-%m-%d %H:%M')" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys
db, hid, date, status, now = sys.argv[1:6]
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("UPDATE habit_reminders SET status=?, resolved_at=? WHERE habit_id=? AND occurred_on=?",
                (status, now, hid, date))
    con.commit(); con.close()
except Exception:
    pass
PYEOF
  }

  # PULL: reminder → habit
  PULLED=0
  PEND="$(python3 - "$PBRAIN_DB_FILE" "$RS_DATE" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys
db, date = sys.argv[1:3]
try:
    con = sqlite3.connect(db, timeout=5)
    for hid, rid in con.execute("SELECT habit_id, reminder_id FROM habit_reminders WHERE occurred_on=? AND status='pending'", (date,)).fetchall():
        print("%s\t%s" % (hid, rid))
    con.close()
except Exception:
    pass
PYEOF
)"
  while IFS=$'\t' read -r hid rid; do
    [[ -n "${rid//[[:space:]]/}" ]] || continue
    ST="$(pbrain_reminders_run status --id "$rid" 2>/dev/null || true)"
    case "$ST" in
      DONE*)
        nm="$(_hr_name_for_id "$hid")"
        [[ -n "${nm//[[:space:]]/}" ]] && bash "$_SCRIPT_DIR/habits.sh" mark --name "$nm" --date "$RS_DATE" >/dev/null 2>&1 || true
        _hr_set_status "$hid" "$RS_DATE" done
        PULLED=$((PULLED + 1)) ;;
      MISSING) _hr_set_status "$hid" "$RS_DATE" cancelled ;;
      *) : ;;  # PENDING / UNAVAILABLE / ACCESS_DENIED — leave the row
    esac
  done <<< "$PEND"

  # PUSH: habit → reminder. Pass the status JSON via argv, NOT a pipe: a pipe into
  # `python3 - <<HEREDOC` collides on stdin (the heredoc wins), so json.load(stdin)
  # would always read empty — pushed would silently stay 0.
  PUSHED=0
  PUSH_STATUS="$(pbrain_habits_status "$RS_DATE" 2>/dev/null || true)"
  PUSH="$(python3 - "$PBRAIN_DB_FILE" "$RS_DATE" "$PUSH_STATUS" "$PROFILE_FILE" "$TODAY" "$(date '+%H:%M')" <<'PYEOF' 2>/dev/null || true
import json, re, sys, sqlite3
db, date, status_json, profile, today, now_hm = sys.argv[1:7]
try:
    d = json.loads(status_json) if status_json.strip() else {}
except Exception:
    sys.exit(0)
done_ids = set()
for h in d.get("habits") or []:
    if (h.get("today_count") or 0) > 0 or (h.get("today_amount") or 0) > 0:
        done_ids.add(h.get("id"))
# Per-habit reminder clock time, so a one-shot whose nudge has NOT fired yet is
# left pending instead of being auto-completed the moment the habit is marked.
# Marking is often anticipatory (planned/partial); completing a future reminder
# would silently delete a nudge the user still needs. Only guards the CURRENT
# day — past-day pendings are always safe to complete.
rtimes = {}
try:
    m = re.search(r"```json\s*\n(.*?)```", open(profile).read(), re.DOTALL)
    pdata = json.loads(m.group(1)) if m else {}
    for h in (pdata.get("habits") or []):
        rem = h.get("reminder") if isinstance(h.get("reminder"), dict) else {}
        t = str(rem.get("time", "")).strip()
        if t:
            rtimes[str(h.get("id", "")).strip()] = t
except Exception:
    pass
def _mins(s):
    try:
        p = str(s).split(":"); return int(p[0]) * 60 + int(p[1])
    except Exception:
        return None
now_m = _mins(now_hm) if date == today else None
try:
    con = sqlite3.connect(db, timeout=5)
    for hid, rid in con.execute("SELECT habit_id, reminder_id FROM habit_reminders WHERE occurred_on=? AND status='pending'", (date,)).fetchall():
        if hid not in done_ids:
            continue
        if now_m is not None:
            rt = _mins(rtimes.get(hid))
            if rt is not None and rt > now_m:
                continue   # nudge has not fired yet — keep it pending
        print("%s\t%s" % (hid, rid))
    con.close()
except Exception:
    pass
PYEOF
)"
  while IFS=$'\t' read -r hid rid; do
    [[ -n "${rid//[[:space:]]/}" ]] || continue
    pbrain_reminders_run complete --id "$rid" >/dev/null 2>&1 || true
    _hr_set_status "$hid" "$RS_DATE" done
    PUSHED=$((PUSHED + 1))
  done <<< "$PUSH"

  # SWEEP: delete stale one-shots for habits not done (end-of-day only).
  SWEPT=0
  if [[ "$RS_SWEEP" -eq 1 ]]; then
    SWP="$(python3 - "$PBRAIN_DB_FILE" "$RS_DATE" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys
db, date = sys.argv[1:3]
try:
    con = sqlite3.connect(db, timeout=5)
    for hid, rid in con.execute("SELECT habit_id, reminder_id FROM habit_reminders WHERE occurred_on=? AND status='pending'", (date,)).fetchall():
        print("%s\t%s" % (hid, rid))
    con.close()
except Exception:
    pass
PYEOF
)"
    while IFS=$'\t' read -r hid rid; do
      [[ -n "${rid//[[:space:]]/}" ]] || continue
      pbrain_reminders_run delete --id "$rid" >/dev/null 2>&1 || true
      _hr_set_status "$hid" "$RS_DATE" cancelled
      SWEPT=$((SWEPT + 1))
    done <<< "$SWP"

    # ORPHAN sweep: app reminders pbrain created for a habit but never recorded a
    # row for. Match on (due date == RS_DATE) AND (title == a known habit name) so
    # /remind reminders and other days are never touched; skip anything already
    # tracked (handled above). Best-effort — silent if the helper is unavailable.
    APP_LIST="$(pbrain_reminders_run list 2>/dev/null || true)"
    if [[ -n "${APP_LIST//[[:space:]]/}" ]]; then
      ORPHANS="$(python3 - "$PROFILE_FILE" "$PBRAIN_DB_FILE" "$RS_DATE" "$APP_LIST" <<'PYEOF' 2>/dev/null || true
import json, re, sys, sqlite3
profile, db, date, app_list = sys.argv[1:5]
try:
    m = re.search(r"```json\s*\n(.*?)```", open(profile).read(), re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
except Exception:
    data = {}
names = {str(h.get("name", "")).strip().lower() for h in (data.get("habits") or []) if str(h.get("name", "")).strip()}
tracked = set()
try:
    con = sqlite3.connect(db, timeout=5)
    for (rid,) in con.execute("SELECT reminder_id FROM habit_reminders WHERE occurred_on=?", (date,)).fetchall():
        if rid:
            tracked.add(rid.strip())
    con.close()
except Exception:
    pass
for line in app_list.splitlines():
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 2:
        continue
    rid, due, title = parts[0].strip(), parts[1].strip(), parts[-1].strip()
    if not rid or rid in tracked:
        continue
    if not due.startswith(date):
        continue   # other day / no due date — never touch
    if title.lower() not in names:
        continue   # not a habit reminder (e.g. a /remind item) — never touch
    print(rid)
PYEOF
)"
      while IFS= read -r orid; do
        [[ -n "${orid//[[:space:]]/}" ]] || continue
        pbrain_reminders_run delete --id "$orid" >/dev/null 2>&1 || true
        SWEPT=$((SWEPT + 1))
      done <<< "$ORPHANS"
    fi
  fi

  echo "SYNCED pulled=$PULLED pushed=$PUSHED swept=$SWEPT"
  exit 0
fi

# ---------------------------------------------------------------------------
# reminders-reschedule --habit <name> --time HH:MM [--date YYYY-MM-DD]
# Update the due time (and at-due alarm) of a linked habit's pending one-shot
# Apple Reminder for <date> (default today). Looks up the reminder_id from
# habit_reminders, then calls pbrain_reminders_run edit --id <rid> --due.
# Echoes: RESCHEDULED <name> → HH:MM | NOT_LINKED | NOT_FOUND | UNAVAILABLE
# Used by /plan-my-day to align a habit's reminder with its planned time block.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "reminders-reschedule" ]]; then
  shift || true
  RR_DATE="$TODAY"; RR_NAME=""; RR_TIME=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --habit|--name) RR_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --time)         RR_TIME="${2:-}";  shift 2 2>/dev/null || shift ;;
      --date)         RR_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  [[ -n "${RR_NAME//[[:space:]]/}" ]] || { echo "ERROR:--habit required"; exit 0; }
  [[ -n "${RR_TIME//[[:space:]]/}" ]] || { echo "ERROR:--time required"; exit 0; }
  [[ "$RR_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "ERROR:bad date '$RR_DATE'"; exit 0; }
  [[ -f "$PROFILE_FILE" ]] || { echo "NOT_LINKED"; exit 0; }

  # Look up habit_id by name → reminder_id for that date (pending only)
  RID="$(python3 - "$PROFILE_FILE" "$PBRAIN_DB_FILE" "$RR_NAME" "$RR_DATE" <<'PYEOF' 2>/dev/null || true
import json, re, sys, sqlite3
profile, db, name, date = sys.argv[1:5]
try:
    m = re.search(r"```json\s*\n(.*?)```", open(profile).read(), re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
except Exception:
    sys.exit(0)
hid = None
for h in (data.get("habits") or []):
    if str(h.get("name", "")).strip().lower() == name.strip().lower():
        rem = h.get("reminder") if isinstance(h.get("reminder"), dict) else {}
        if str(rem.get("state", "")).strip().lower() != "linked":
            print("NOT_LINKED"); sys.exit(0)
        hid = str(h.get("id", "")).strip()
        break
if not hid:
    print("NOT_LINKED"); sys.exit(0)
try:
    con = sqlite3.connect(db, timeout=5)
    row = con.execute(
        "SELECT reminder_id FROM habit_reminders WHERE habit_id=? AND occurred_on=? AND status='pending'",
        (hid, date)).fetchone()
    con.close()
    print(row[0] if row else "NOT_FOUND")
except Exception:
    print("NOT_FOUND")
PYEOF
)"
  case "${RID:-}" in
    NOT_LINKED) echo "NOT_LINKED"; exit 0 ;;
    NOT_FOUND)  echo "NOT_FOUND";  exit 0 ;;
  esac
  [[ -n "${RID//[[:space:]]/}" ]] || { echo "NOT_FOUND"; exit 0; }

  RES="$(pbrain_reminders_run edit --id "$RID" --due "$RR_DATE $RR_TIME" 2>/dev/null || true)"
  case "${RES:-}" in
    EDITED*|OK*) echo "RESCHEDULED ${RR_NAME} → ${RR_TIME}" ;;
    NOT_FOUND*)  echo "NOT_FOUND" ;;
    *)           echo "${RES:-UNAVAILABLE}" ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# reminders-cancel --habit <name|id> [--date YYYY-MM-DD]
# Cancel a habit's PENDING one-shot Apple Reminder for <date> (default today):
# delete the Apple Reminder and mark the habit_reminders row cancelled. The
# primitive /plan-my-day uses to suppress an off-activity reminder (e.g. the
# scheduled Gym 12:30 when the user actually did Apple Fitness). Resolves the
# habit by name OR id; works regardless of the habit's link state.
# Echoes: CANCELLED <name> | NOT_LINKED | NOT_FOUND | UNAVAILABLE
# ---------------------------------------------------------------------------
if [[ "$SUB" == "reminders-cancel" ]]; then
  shift || true
  RC_DATE="$TODAY"; RC_NAME=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --habit|--name|--id) RC_NAME="${2:-}"; shift 2 2>/dev/null || shift ;;
      --date)              RC_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  [[ -n "${RC_NAME//[[:space:]]/}" ]] || { echo "ERROR:--habit required"; exit 0; }
  [[ "$RC_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "ERROR:bad date '$RC_DATE'"; exit 0; }
  [[ -f "$PROFILE_FILE" ]] || { echo "NOT_FOUND"; exit 0; }

  # Resolve the habit (name OR id) → its pending one-shot reminder_id for <date>.
  # NOT_FOUND if the habit doesn't exist or has no pending one-shot to cancel.
  RC_OUT="$(python3 - "$PROFILE_FILE" "$PBRAIN_DB_FILE" "$RC_NAME" "$RC_DATE" <<'PYEOF' 2>/dev/null || true
import json, re, sys, sqlite3
profile, db, ref, date = sys.argv[1:5]
try:
    m = re.search(r"```json\s*\n(.*?)```", open(profile).read(), re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
except Exception:
    print("NOT_FOUND"); sys.exit(0)
ref_l = ref.strip().lower()
hid = name = None
for h in (data.get("habits") or []):
    if str(h.get("id", "")).strip().lower() == ref_l or str(h.get("name", "")).strip().lower() == ref_l:
        hid = str(h.get("id", "")).strip()
        name = str(h.get("name", "")).strip()
        break
if not hid:
    print("NOT_FOUND"); sys.exit(0)
try:
    con = sqlite3.connect(db, timeout=5)
    row = con.execute(
        "SELECT reminder_id FROM habit_reminders WHERE habit_id=? AND occurred_on=? AND status='pending'",
        (hid, date)).fetchone()
    con.close()
except Exception:
    row = None
if not row:
    print("NOT_FOUND\t%s\t%s" % (hid, name)); sys.exit(0)
print("OK\t%s\t%s\t%s" % (hid, name, row[0]))
PYEOF
)"
  RC_KIND="${RC_OUT%%$'\t'*}"
  if [[ "$RC_KIND" != "OK" ]]; then echo "NOT_FOUND"; exit 0; fi
  IFS=$'\t' read -r _k RC_HID RC_DNAME RC_RID <<< "$RC_OUT"
  [[ -n "${RC_RID//[[:space:]]/}" ]] || { echo "NOT_FOUND"; exit 0; }

  RES="$(pbrain_reminders_run delete --id "$RC_RID" 2>/dev/null || true)"
  case "${RES:-}" in
    UNAVAILABLE|ACCESS_DENIED) echo "UNAVAILABLE"; exit 0 ;;
    *) : ;;  # DELETED / MISSING (already gone) / transient — close the row regardless
  esac
  # Mark the habit_reminders row cancelled so reminders-ensure won't re-create it.
  python3 - "$PBRAIN_DB_FILE" "$RC_HID" "$RC_DATE" "$(date '+%Y-%m-%d %H:%M')" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys
db, hid, date, now = sys.argv[1:5]
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("UPDATE habit_reminders SET status='cancelled', resolved_at=? WHERE habit_id=? AND occurred_on=?",
                (now, hid, date))
    con.commit(); con.close()
except Exception:
    pass
PYEOF
  echo "CANCELLED ${RC_DNAME:-$RC_NAME}"
  exit 0
fi

# ---------------------------------------------------------------------------
# fitness-reconcile --activity "<name|slug>" [--date YYYY-MM-DD]
# The deterministic "dumb" path /plan-my-day uses once it knows the day's chosen
# fitness activity (from today's /fitness-journal `focus:` field). It maps the
# chosen activity → the matching habit and:
#   - CHOSEN activity's habit (if linked): ensure its one-shot for <date>
#     (BYPASSING is_due — the activity can happen off its usual schedule), then
#     align the reminder to the activity's typical_time.
#   - every OTHER fitness habit with an EXPLICIT schedule due today that is NOT
#     the chosen one: reminders-cancel + mark --status skipped (no reminder +
#     auto-skip — the "explicitly cancelled" case).
#   - chosen activity with NO matching habit → nothing (no reminder), per the
#     user's rule. Unresolvable activity → nothing.
# Activity↔habit link = the optional `activity` field, else case-insensitive name
# containment between the habit name and a fitness-library activity name (so habit
# "Apple Fitness" ↔ activity "Apple Fitness+ Kickboxing"). Only habits with a
# FIXED schedule are ever auto-skipped (so floating habits like Meditation/Yoga,
# which co-occur with a workout, are never suppressed). Best-effort + silent.
# Echoes: RECONCILED chosen=<slug|—> ensured=<0|1> skipped=<n> | NO_MATCH <text>
# ---------------------------------------------------------------------------
if [[ "$SUB" == "fitness-reconcile" ]]; then
  shift || true
  FR_DATE="$TODAY"; FR_ACT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --activity) FR_ACT="${2:-}"; shift 2 2>/dev/null || shift ;;
      --date)     FR_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  [[ -f "$PROFILE_FILE" ]] || { echo "NO_MATCH ${FR_ACT}"; exit 0; }
  [[ -n "${FR_ACT//[[:space:]]/}" ]] || { echo "NO_MATCH"; exit 0; }
  [[ "$FR_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "ERROR:bad date '$FR_DATE'"; exit 0; }

  # Resolve the committed fitness-library (the activity registry).
  FR_FITSTORE="$(pbrain_profile_store "${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}" 2>/dev/null || true)"
  FR_FITLIB="$(pbrain_profile_latest "$FR_FITSTORE" fitness-library 2>/dev/null || true)"

  FR_PLAN="$(python3 - "$_SCRIPT_DIR/../lib" "$PROFILE_FILE" "$PBRAIN_DB_FILE" "${FR_FITLIB:-}" "$FR_ACT" "$FR_DATE" <<'PYEOF' 2>/dev/null || true
import json, re, sys
libdir, profile, db, fitlibp, activity, date = sys.argv[1:7]
sys.path.insert(0, libdir)
try:
    from habit_schedule import derive_schedule, is_due
except Exception:
    def derive_schedule(h): return {"type": "daily"}
    def is_due(s, d): return True

def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", (s or "").strip().lower()).strip()

def read_block(p):
    if not p:
        return {}
    try:
        m = re.search(r"```json\s*\n(.*?)```", open(p).read(), re.DOTALL)
        return json.loads(m.group(1)) if m else {}
    except Exception:
        return {}

data = read_block(profile)
habits = [h for h in (data.get("habits") or []) if not h.get("archived")]

acts = []
for a in (read_block(fitlibp).get("activities") or []):
    slug = str(a.get("id") or "").strip() or re.sub(r"[^a-z0-9]+", "-", str(a.get("name", "")).lower()).strip("-")
    acts.append({"slug": slug, "name": str(a.get("name", "")).strip(),
                 "time": str(a.get("typical_time") or "").strip()})

# Resolve the chosen activity from --activity (a slug, or the raw focus text).
act_in = activity.strip()
act_l = norm(act_in)
chosen = None
for a in acts:
    if a["slug"] and a["slug"].lower() == act_in.lower():
        chosen = a
        break
if chosen is None:
    best = None
    for a in acts:
        an = norm(a["name"])
        if an and (an in act_l or act_l in an):
            if best is None or len(an) > len(norm(best["name"])):
                best = a
    chosen = best

def hmatch(h, a):
    if a["slug"] and str(h.get("activity", "")).strip().lower() == a["slug"].lower():
        return True
    hn, an = norm(h.get("name")), norm(a["name"])
    if hn and an and (hn in an or an in hn):
        return True
    if hn and hn == norm(a["slug"]):
        return True
    return False

def is_fitness_habit(h):
    if str(h.get("activity", "")).strip():
        return True
    return any(hmatch(h, a) for a in acts)

chosen_habit = None
if chosen:
    for h in habits:
        if hmatch(h, chosen):
            chosen_habit = h
            break

out = []
if chosen and chosen_habit:
    out.append("CHOSEN\t%s\t%s\t%s" % (str(chosen_habit.get("id", "")).strip(),
                                       str(chosen_habit.get("name", "")).strip(), chosen.get("time", "")))
elif chosen:
    out.append("CHOSEN_NOHABIT\t%s" % chosen["slug"])
else:
    out.append("NO_MATCH\t%s" % act_in)

chosen_id = str(chosen_habit.get("id", "")).strip() if chosen_habit else ""
for h in habits:
    hid = str(h.get("id", "")).strip()
    if hid == chosen_id or not is_fitness_habit(h):
        continue
    sched = h.get("schedule")
    if not (isinstance(sched, dict) and sched.get("type")):
        continue   # only an EXPLICIT fixed schedule makes it "scheduled today"
    if not is_due(derive_schedule(h), date):
        continue
    out.append("SKIP\t%s\t%s" % (hid, str(h.get("name", "")).strip()))
print("\n".join(out))
PYEOF
)"

  FR_CHOSEN="—"; FR_ENSURED=0; FR_SKIPPED=0
  while IFS=$'\t' read -r kind a b c; do
    case "$kind" in
      CHOSEN)
        FR_CHOSEN="$b"
        # ensure the chosen activity's one-shot (off-schedule bypass), then align.
        bash "$_SCRIPT_DIR/habits.sh" reminders-ensure --habit "$a" --date "$FR_DATE" >/dev/null 2>&1 || true
        FR_ENSURED=1
        if [[ -n "${c//[[:space:]]/}" ]]; then
          bash "$_SCRIPT_DIR/habits.sh" reminders-reschedule --habit "$b" --time "$c" --date "$FR_DATE" >/dev/null 2>&1 || true
        fi
        ;;
      SKIP)
        bash "$_SCRIPT_DIR/habits.sh" reminders-cancel --habit "$a" --date "$FR_DATE" >/dev/null 2>&1 || true
        bash "$_SCRIPT_DIR/habits.sh" mark --name "$b" --date "$FR_DATE" --status skipped >/dev/null 2>&1 || true
        FR_SKIPPED=$((FR_SKIPPED + 1))
        ;;
      NO_MATCH) echo "NO_MATCH ${b:-$a}"; exit 0 ;;
      CHOSEN_NOHABIT) FR_CHOSEN="$a" ;;
      *) : ;;
    esac
  done <<< "$FR_PLAN"
  echo "RECONCILED chosen=${FR_CHOSEN} ensured=${FR_ENSURED} skipped=${FR_SKIPPED}"
  exit 0
fi

# ---------------------------------------------------------------------------
# autostatus [--date YYYY-MM-DD] — end-of-day pass so scheduled habits stop
# silently vanishing. For every non-archived habit, using the day's md tracker
# as the source of truth:
#   - is_due today AND already done OR missed   → leave
#   - is_due today AND already skipped          → leave (counted, for surfacing)
#   - is_due today AND a BUILD (at_least) habit with no mark → mark --status missed
#   - not is_due today                          → leave (off day)
# Limit (at_most) habits are never auto-missed — NOT doing them is success.
#
# FLEXIBLE COUNT habits ("N times per week/month" — schedule_type weekly/monthly
# with target_count, or an explicit schedule carrying times_per_week/month) have
# NO specific required day: only the weekly/monthly COUNT matters. They are
# judged over the WHOLE period, never auto-missed on an individual day. autostatus
# only records a miss for them on the LAST day of the period (Sunday / month-end)
# and only when the period's completed count is still below target. On any other
# day they are left untouched (an unmarked day is just "not yet", pruned by
# consolidate) — so doing one on Tuesday no longer makes Monday a false miss.
#
# Run by /end-of-day BEFORE reminders-sync --sweep + consolidate.
# Echoes: AUTOSTATUS missed=<n> skipped=<n>
# ---------------------------------------------------------------------------
if [[ "$SUB" == "autostatus" ]]; then
  shift || true
  AS_DATE="$TODAY"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --date) AS_DATE="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
      *) shift ;;
    esac
  done
  [[ -f "$PROFILE_FILE" ]] || { echo "AUTOSTATUS missed=0 skipped=0"; exit 0; }
  [[ "$AS_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "ERROR:bad date '$AS_DATE'"; exit 0; }
  AS_FILE="$(pbrain_habit_track_file "$AS_DATE")"
  AS_PLAN="$(python3 - "$_SCRIPT_DIR/../lib" "$PROFILE_FILE" "$AS_FILE" "$AS_DATE" <<'PYEOF' 2>/dev/null || true
import json, re, sys, os, datetime, calendar
libdir, profile, trackfile, date = sys.argv[1:5]
sys.path.insert(0, libdir)
try:
    from habit_schedule import derive_schedule, is_due, norm_days
except Exception:
    def derive_schedule(h): return {"type": "daily"}
    def is_due(s, d): return True
    def norm_days(x): return [str(t).strip().lower() for t in (x or [])]

DONE_TRUE = {"x", "yes", "y", "done", "true", "1", "✅", "✓"}
SKIP_TOK  = {"skip", "skipped", "⊘"}
MISS_TOK  = {"miss", "missed", "✗"}
def day_status(v):
    t = (v or "").strip().lower()
    if t in DONE_TRUE: return "done"
    if t in SKIP_TOK:  return "skipped"
    if t in MISS_TOK:  return "missed"
    return ""

# A dated md tracker is the source of truth for that day. Parse name → state.
_file_cache = {}
def file_statuses(fp):
    if fp in _file_cache:
        return _file_cache[fp]
    out = {}
    try:
        lines = open(fp).read().splitlines()
    except Exception:
        lines = []
    hi = None
    for i, l in enumerate(lines):
        if re.match(r"\s*\|\s*Habit\s*\|", l):
            hi = i
            break
    if hi is not None:
        j = hi + 2
        while j < len(lines) and lines[j].strip().startswith("|"):
            cells = [c.strip() for c in lines[j].strip().strip("|").split("|")]
            while len(cells) < 6:
                cells.append("")
            out[cells[0].strip().lower()] = day_status(cells[3])
            j += 1
    _file_cache[fp] = out
    return out

status_by_name = file_statuses(trackfile)
TRACK_DIR = os.path.dirname(trackfile)

def flexible_target(h):
    # A frequency-based ("N times per week/month") habit has no fixed required
    # day — only a weekly/monthly COUNT target. Returns (target, period) for such
    # habits, else None (daily / interval / explicit fixed-day schedules).
    s = h.get("schedule")
    if isinstance(s, dict) and s.get("type"):
        for k, per in (("times_per_week", "week"), ("times_per_month", "month")):
            if s.get(k):
                try:
                    return (max(1, int(s[k])), per)
                except (TypeError, ValueError):
                    return (1, per)
        return None
    rem = h.get("reminder") if isinstance(h.get("reminder"), dict) else {}
    if norm_days(rem.get("days")):
        return None
    st = str(h.get("schedule_type", "") or "").strip().lower()
    if st in ("weekly", "monthly"):
        try:
            t = max(1, int(h.get("target_count")))
        except (TypeError, ValueError):
            t = 1
        return (t, "week" if st == "weekly" else "month")
    return None

def is_period_end(period, date_iso):
    try:
        d = datetime.date.fromisoformat(date_iso)
    except (TypeError, ValueError):
        return False
    if period == "week":
        return d.weekday() == 6          # Sunday closes the ISO week
    if period == "month":
        return d.day == calendar.monthrange(d.year, d.month)[1]
    return False

def done_in_period(period, date_iso, name):
    # Count done marks for this habit across the whole period up to date_iso,
    # reading each dated tracker file (sibling of trackfile).
    try:
        d = datetime.date.fromisoformat(date_iso)
    except (TypeError, ValueError):
        return 0
    if period == "week":
        start = d - datetime.timedelta(days=d.weekday())
        days = [start + datetime.timedelta(days=i) for i in range(7)]
    elif period == "month":
        last = calendar.monthrange(d.year, d.month)[1]
        days = [datetime.date(d.year, d.month, k) for k in range(1, last + 1)]
    else:
        days = [d]
    cnt = 0
    key = name.strip().lower()
    for dd in days:
        if dd > d:
            break
        fp = os.path.join(TRACK_DIR, dd.isoformat() + ".md")
        if file_statuses(fp).get(key) == "done":
            cnt += 1
    return cnt

try:
    m = re.search(r"```json\s*\n(.*?)```", open(profile).read(), re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
except Exception:
    data = {}

skipped = 0
miss = []
for h in (data.get("habits") or []):
    if h.get("archived"):
        continue
    direction = str(h.get("direction", "")).strip().lower()
    if direction not in ("at_least", "at_most"):
        direction = "at_most" if str(h.get("kind", "")).strip().lower() == "limit" else "at_least"
    nm = str(h.get("name", "")).strip()
    if not nm:
        continue
    flex = flexible_target(h)
    # A flexible-count habit has no fixed due-day, so treat it as "in play" every
    # day for skipped-counting; its miss is decided over the whole period below.
    due = True if flex is not None else is_due(derive_schedule(h), date)
    cur = status_by_name.get(nm.lower(), "")
    if cur == "skipped":
        if due:
            skipped += 1
        continue
    if cur in ("done", "missed"):
        continue
    if direction != "at_least":
        continue   # not doing a limit habit is success, not a miss
    if flex is not None:
        target, period = flex
        # Only a real miss once the period closes and the count fell short —
        # never per-day. Mid-period unmarked days stay "not yet" (pruned).
        if is_period_end(period, date) and done_in_period(period, date, nm) < target:
            miss.append(nm)
        continue
    if not due:
        continue
    miss.append(nm)
print("SKIPPED\t%d" % skipped)
for nm in miss:
    print("MISS\t%s" % nm)
PYEOF
)"
  AS_MISS=0; AS_SKIP=0
  while IFS=$'\t' read -r kind val; do
    case "$kind" in
      SKIPPED) AS_SKIP="${val:-0}" ;;
      MISS)
        [[ -n "${val//[[:space:]]/}" ]] || continue
        bash "$_SCRIPT_DIR/habits.sh" mark --name "$val" --date "$AS_DATE" --status missed >/dev/null 2>&1 || true
        AS_MISS=$((AS_MISS + 1)) ;;
      *) : ;;
    esac
  done <<< "$AS_PLAN"
  echo "AUTOSTATUS missed=$AS_MISS skipped=$AS_SKIP"
  exit 0
fi

# ---------------------------------------------------------------------------
# PHASE 0 — first-run setup (no profile yet).
# ---------------------------------------------------------------------------
if [[ ! -f "$PROFILE_FILE" ]]; then
  cat <<SETUP
HABITS_SETUP_PROFILE
profile_file: $PROFILE_FILE
seed_dirs: ${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking} | ${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning} | ${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking} | ${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}
add_cmd: bash "$_SCRIPT_DIR/habits.sh" add --name "<X>" --direction at_least|at_most --schedule daily|weekdays|interval|monthly [schedule args] [--unit "L"] [--measure-target N] [--priority low|medium|high] [--notes "..."]
  schedule args by kind:
    daily     : (none)
    weekdays  : --days mon,wed,fri   OR   --times-per-week N [--start-day mon]   (N spaced from the start day)
    interval  : --every-days N [--start-date YYYY-MM-DD]                          (defaults to today)
    monthly   : --days-of-month 1,16 OR   --times-per-month N [--start-dom D]
  (legacy still works: --type daily|weekly|monthly [--target N] maps to a schedule)
reminder_cmd: bash "$_SCRIPT_DIR/habits.sh" reminder --id <id> (--link --time HH:MM | --decline)

INSTRUCTIONS — first-time habits setup. Don't log anything yet. You're helping
the user define the habits they want to track. Ask ONE question at a time; wait
for each answer before the next. Do NOT batch questions, and do NOT ask about
caps/limits as an opening "pattern" question. There is no 5–8 limit — a person
can track many habits.

STEP 1 — Ask exactly this first, and nothing else:
  "Want me to suggest habits from your recent pbrain entries, or would you
   rather tell me the habits you want to track?"

STEP 2a — IF "suggest from entries":
  - Read the last ~30 days of files under the seed_dirs above (journals, daily
    plans, fitness, diet). Grep/scan for recurring activities the user actually
    did or mentioned repeatedly (e.g. "walked", "meditated", "gym", "read",
    "skipped X"). Ground every candidate in real entries — do NOT invent habits.
  - Present the candidate list ONCE for a quick yes/no per item. Then go through
    the ACCEPTED ones one at a time for their criteria (Step 3).

STEP 2b — IF "I'll specify":
  - Ask for the habits one at a time. After each habit name, immediately gather
    that habit's criteria (Step 3) before moving to the next habit.

STEP 3 — For EACH habit, gather its OWN criteria, one short question at a time.
  A habit has two SEPARATE axes — ask about both:
  - SCHEDULE (when it happens — axis 1). Map the user's answer to a --schedule:
      • every day → daily
      • specific weekdays (e.g. gym Mon/Wed/Fri) → weekdays --days mon,wed,fri
      • N times a week, no fixed days (e.g. gym 4×) → weekdays --times-per-week N
        [--start-day <their usual start>] (pbrain spaces them out across the week)
      • every N days (e.g. every 15 days) → interval --every-days N [--start-date]
      • on a calendar date / N times a month → monthly --days-of-month D[,D]
        OR --times-per-month N [--start-dom D]
    Every habit gets a concrete schedule — there is no vague "sometimes". If the
    user truly can't name days/frequency, default to daily and note it.
  - direction (the SCORING axis — axis 2): are you trying to DO it (at_least,
    e.g. eat clean) or KEEP IT UNDER a limit (at_most, e.g. no smoking, alcohol)?
    This is independent of the schedule.
  - cap/count (--target): for a LIMIT habit, the cap (e.g. ≤2). Ask only if it
    isn't obviously 1.
  - measure (optional): does this habit have a NATURAL AMOUNT you'd rather track
    than a yes/no? (e.g. "4L water", "30 min meditation", "20 km/week running").
    If so, capture a unit (--unit "L") and the per-period target (--measure-target
    4); fulfillment then checks the summed amount vs target ("2.5/4 L") instead of
    done/not-done. Most habits are plain yes/no — only ask/set this when the user
    frames it as a quantity. A measured habit's --target is then irrelevant.
  - priority: low / medium / high — how much it matters right now.
  - notes: optional short note (e.g. "10 min morning", "weekends only").
  Then create it immediately by running the add_cmd above with those values.
  The command mints a stable id and writes valid JSON — never hand-edit the file.

STEP 3.5 — REMINDER (offer ONLY for a build habit you're trying to DO — i.e.
  direction at_least; never for limit/at_most habits). Right after creating such
  a habit, ask once:
    "Want an Apple reminder for <name> you can check off? If so, what time —
     every day, or on specific days?"
  - If yes + a time (HH:MM): link it (pbrain creates a per-day reminder and keeps
    it in two-way sync — checking it off in the Reminders app marks the habit,
    and vice-versa). A plain DAILY habit needs no days:
      bash "$_SCRIPT_DIR/habits.sh" reminder --id <id> --link --time HH:MM
    A habit on FIXED WEEKDAYS (e.g. gym Mon/Wed/Fri) — including a weekly/monthly
    habit — pins those days with --days:
      bash "$_SCRIPT_DIR/habits.sh" reminder --id <id> --link --time HH:MM --days mon,wed,fri
  - If no: record the decision so it's never re-offered:
      bash "$_SCRIPT_DIR/habits.sh" reminder --id <id> --decline
  The first link triggers the one-time macOS Reminders access prompt (separate
  from Calendar). If it reports access isn't granted, tell the user to run
  /remind access once and approve it, then retry. A weekly/monthly habit with NO
  fixed days (e.g. "gym 4×/week, any days") can't get a reminder — leave it
  unlinked. Never offer one for a limit habit.

STEP 4 — When done, run \`bash "$_SCRIPT_DIR/habits.sh"\` once more to show the
dashboard, and confirm: "Habits profile saved. I'll log these from your journals
and planning sessions; re-run /habits any time to see where you stand, add or
remove habits, or check a habit's history."
SETUP
  exit 0
fi

# Seed default scored habits (eat-clean / sleep-well) before the dashboard
# reads the profile, so a freshly-enabled diet/fitness profile shows up here.
_habits_seed_defaults || true

# Validate the profile JSON.
PROFILE_JSON="$(pbrain_habits_json || true)"
if [[ -z "${PROFILE_JSON//[[:space:]]/}" ]]; then
  cat <<ERR
HABITS_CONFIG_ERROR
profile_file: $PROFILE_FILE

The habits profile at $PROFILE_FILE has no readable JSON block (or it's
malformed). Fix the fenced \`\`\`json block manually, or delete the file and
re-run /habits to redo the setup.
ERR
  exit 1
fi

# ---------------------------------------------------------------------------
# list — just the configured habits.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "list" ]]; then
  echo "HABITS_LIST"
  printf '%s' "$PROFILE_JSON" | python3 -c '
import json, sys, re
data = json.load(sys.stdin)
for h in data.get("habits") or []:
    name = str(h.get("name", "?"))
    hid = str(h.get("id", "")) or re.sub(r"[^a-z0-9]+","-",name.strip().lower()).strip("-")
    st = h.get("schedule_type") or ("monthly" if str(h.get("cap_period","")).startswith("month") else ("weekly" if str(h.get("cap_period","")).startswith("week") else "daily"))
    direction = h.get("direction") or ("at_most" if h.get("kind")=="limit" else "at_least")
    prio = h.get("priority", "medium")
    target = h.get("target_count", h.get("cap_count"))
    arch = " [archived]" if h.get("archived") else ""
    mt = h.get("measure_target")
    measure = ""
    if mt is not None:
        unit = str(h.get("unit", "")).strip()
        measure = ", measure %s%s" % (mt, (" " + unit) if unit else "")
    print("- %s [%s] (%s, %s, target %s, %s%s)%s" % (name, hid, st, direction, target, prio, measure, arch))
' 2>/dev/null || echo "(could not parse habits)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Default — dashboard (structured status → tight read + offer to update).
# Sync recent tracking md into the DB first so today's marks are reflected.
# The Done column (x) is the source of truth — refresh today's Progress column
# from the DB after sync so manual marks land in the file too.
# ---------------------------------------------------------------------------
pbrain_habits_sync_range 35 || true
pbrain_habit_refresh "$TODAY" >/dev/null 2>&1 || true
TRACK_FILE="$(pbrain_habit_track_file "$TODAY")"
STATUS_JSON="$(pbrain_habits_status "$TODAY" || true)"
ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
[[ -n "${ROLLUP//[[:space:]]/}" ]] || ROLLUP="(no events logged yet)"

cat <<DASH
HABITS_DASHBOARD
date: $TODAY
profile_file: $PROFILE_FILE
track_file: $TRACK_FILE

=== STATUS (structured; top 20 by priority shown in rollup) ===
$STATUS_JSON

=== ROLLUP (per habit vs its criteria) ===
$ROLLUP

---
INSTRUCTIONS — present the user's habit standing and offer to update.

Habit data lives in a dated markdown log you (and I) edit — today's is at
track_file above. The DB you see in the rollup is synced from those files.

Step 1 — Give a tight read of the ROLLUP (don't dump it). Lead with what needs
attention: limit habits over cap (⚠️), high-priority habits not yet fulfilled
this period (⏳), nice streaks worth naming. The list is the top 20 by priority;
if a "+N more" line shows, mention there are more lower-priority habits. 3–6 lines.

Step 2 — Ask: "Want to open today's tracker, mark something, add or change a habit?"
Use these commands — never hand-edit the profile JSON or the tracking table directly:
  - TRACK today: bash "$_SCRIPT_DIR/habits.sh" track --date $TODAY   (create/refresh today's checklist md)
  - MARK done:   bash "$_SCRIPT_DIR/habits.sh" mark --name "<exact name>" --date $TODAY [--count N] [--amount X] [--note "..."]
                 (for a measured habit — one with a unit — pass --amount, e.g. --amount 2.5)
  - ADD habit:   bash "$_SCRIPT_DIR/habits.sh" add --name "<X>" --direction at_least|at_most --schedule daily|weekdays|interval|monthly [--days mon,wed,fri | --times-per-week N [--start-day mon] | --every-days N [--start-date YYYY-MM-DD] | --days-of-month 1,16 | --times-per-month N [--start-dom D]] [--unit "L"] [--measure-target N] [--priority low|medium|high] [--notes "..."]
  - EDIT habit:  bash "$_SCRIPT_DIR/habits.sh" edit --id <id> [--name ...] [--direction ...] [--schedule ... + its schedule args] [--target N] [--unit ...] [--measure-target N] [--priority ...] [--notes ...]   (passing any schedule flag rebuilds the schedule)
  - ARCHIVE:     bash "$_SCRIPT_DIR/habits.sh" archive --id <id>   (removes it from the dashboard, keeps history)
  - HISTORY:     bash "$_SCRIPT_DIR/habits.sh" history --name "<X>"
  - REMINDER:    bash "$_SCRIPT_DIR/habits.sh" reminder --id <id> (--link --time HH:MM [--days mon,wed,fri] | --decline | --unlink [--cancel])
  For add/edit/archive, show the user what you'll run and get an explicit yes first.
  The user can also just open today's track_file in Obsidian and tick cells by hand.

Step 2.5 — REMINDERS (opt-in, per habit — do NOT proactively nag). A linked
build habit gets a per-day Apple reminder it can be checked off from, kept in
two-way sync; it shows "🔔 HH:MM" (or "🔔 Mon/Wed/Fri HH:MM") in the rollup,
unlinked ones show nothing. Only act here when the USER asks to set up / change a
habit's reminder (or asks which habits could have one). To list daily candidates
on request:
  bash "$_SCRIPT_DIR/habits.sh" reminders-pending   ("id<TAB>name" — daily build, undecided)
For a habit the user wants linked: ask the time (and whether it's every day or
specific weekdays), then run — daily:
  bash "$_SCRIPT_DIR/habits.sh" reminder --id <hid> --link --time HH:MM
fixed weekdays (e.g. gym Mon/Wed/Fri — works for a weekly/monthly habit too):
  bash "$_SCRIPT_DIR/habits.sh" reminder --id <hid> --link --time HH:MM --days mon,wed,fri
(pbrain creates the reminder + keeps it in sync — no need to find an existing
one). To turn it off:  reminder --id <hid> --decline. A weekly/monthly habit with
no fixed days can't be linked. If a reminder op reports Reminders access isn't
granted, tell the user to run /remind access once, then move on. When ARCHIVE
prints a "LINKED_REMINDER" line, the habit was linked — offer to cancel its
reminders too: reminder --id <id> --unlink --cancel.

Step 3 — Keep it brief. This is a dashboard, not a coaching session.

Step 4 — If the HABIT EXTRACTION block below appears, act on it: when the user
has evidenced any tracked habit in this session (now or in a later turn), MARK
it per that block instead of waiting to be asked — that's how the dashboard
keeps progress live. Marking is idempotent, so it's safe.
DASH

# Habit extraction ride-along: lets the dashboard auto-mark habits the user
# evidences this session (e.g. "I had one unclean meal") so progress updates in
# the same run, not only when explicitly asked. Silent if nothing's evidenced.
pbrain_emit_habits_extract "habits" || true

pbrain_emit_self_improve "habits" "$PROFILE_FILE" "habits profile" || true
