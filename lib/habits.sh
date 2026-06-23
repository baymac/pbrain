#!/usr/bin/env bash
# pbrain habits helper — sourced by lib/vault.sh (after profile.sh and db.sh).
#
# Two-layer design, mirroring how goals/diet/fitness already split definition
# from data:
#   - The habits PROFILE (which habits to track, their kind / priority / cap)
#     is a vault markdown note carrying its structured data in a fenced ```json
#     block — same discipline as the plans profile, so pbrain_profile_json reads
#     it and it stays browsable/editable in Obsidian.
#   - The habit EVENT LOG lives in the shared SQLite DB (lib/db.sh), so weekly /
#     monthly counts and cap checks are a cheap query.
#
# This file bridges the two and provides the ride-along extraction emitter that
# the journaling commands call so habits get logged from ordinary sessions.
#
# Defines:
#   pbrain_habits_profile_file        echo resolved Habits Profile.md path
#   pbrain_habits_json                echo the profile JSON (or empty if none)
#   pbrain_habits_cmd                 echo abs path to commands/habits.sh
#   pbrain_habits_rollup [today]      text rollup: week/month counts vs caps per habit
#   pbrain_emit_habits_extract <cmd>  ride-along: tell Claude to log evidenced habits (silent if no profile)
#
# Resolution (in order):
#   1. PBRAIN_HABITS_PROFILE_FILE  explicit file override (no versioning)
#   2. versioned store — highest COMMITTED habits-profile.v<N>.md under
#      <habit-track-dir>/.profile (lib/profiles.sh; migration 0005 moves the
#      legacy file here automatically)
#   3. legacy $VAULT_DIR/life/Habits Profile.md if it still exists
#   4. otherwise the store v1 path (not existing yet → triggers first-run setup;
#      the bootstrap writes it with version: 1, committed: true)
#
# Scored-habit evaluator (score_from_spec) — the model only CLASSIFIES raw
# inputs; the scoring rule on the habit computes a 0.0–1.0 UNIT score
# deterministically. ALL scored habits share the 0–1 scale; only the model
# (ratio vs ladder) differs. Ladders are written on the 0–1 scale too.
# One line per scoring type:
#   slip_ladder          counts → ladder index (rungs 0–1, e.g. [1,0.6,0.3,0]).
#   meal_ratio    (eat-clean)  clean/(clean+unclean) meals (0–1); mark --good/--bad.
#   deviation     (sleep-well) slips from circular bed-time diff vs normal_time
#                              (per unit_minutes) + hours shortfall vs normal_hours
#                              (per unit_hours), ladder-indexed; mark
#                              --actual-time HH:MM --actual-hours N.N.
#   weighted_completion (work-the-plan) earned/possible (0–1); per-task weight =
#                              difficulty_weights[difficulty] (easy1/normal2/hard3/
#                              nightmare5) × priority boost (1 + max(0,
#                              priority_pivot−priority)·priority_step, pivot 3 step
#                              0.25); credit = status_credit[status] (done1/partial0.5/
#                              dropped,carried0); every planned task is in the
#                              denominator (overplanning costs you); pass rows as
#                              --items '[{"priority":1,"difficulty":"hard","status":"done"},…]'.
#   session_volume (train)     skipped→0; strength/duration with planned>0 & actual
#                              present → clamp(actual/planned,0,volume_cap) (cap
#                              1.0); else binary status_credit[status]
#                              (completed1/partial0.5); pass --session
#                              '{"mode":"strength|duration|binary","status":…,"planned":N,"actual":N}'.
#   focus_ratio   (deep-work)  work/(work+distraction) of *active* minutes (0–1);
#                              work_categories/distraction_categories default
#                              ["work"]/["social","entertainment"]; neutral+afk
#                              excluded; w+d=0 → unmarked; pass
#                              --focus '{"work":120,"social":30,…}'.
#   checklist                  fixed daily set of named weighted `components`;
#                              sum(done weights)/sum(all weights) (0–1); pass parts
#                              done by name or id as --done '[…]'.
#
# Auto-seeded default habits (idempotent; archived defaults never resurrected).
# All five are weekly aggregates: scored daily as a 0–1 unit value (the Count
# cell), banked over the week as a running sum out of 7, measure_target = the
# weekly pass bar (5 → Criteria "weekly ≥5"); all eod_only.
#
# Each default seeds ONLY when its owning command is ENABLED. "Enabled" = that
# command's committed profile exists (or, for Deep work, the laptop tracker DB);
# a command the user never set up — or disabled by never committing its profile
# — seeds none of its habits (PB-39). The hard-coded command→habit map:
#   /diet-journal     (committed diet profile)     → "Eat clean"   (meal_ratio).
#   /fitness-journal  (committed fitness profile)   → "Sleep well"  (deviation; normal window from it).
#   /fitness-journal  (committed fitness-library)   → "Train"       (session_volume; any logged session)
#                                                     + one per-activity habit per library activity.
#   /plan-my-day      (committed plans-profile)     → "Work the plan" (weighted_completion).
#   /laptop-tracking  (tracker.db) + /plan-my-day (committed plans-profile)
#                                                   → "Deep work"   (focus_ratio; tracker over the
#                                                     day's work-block windows).
#
# Habit↔reminder linking — a per-day ONE-SHOT reminder on the days the habit's
# SCHEDULE is due (NOT Apple-recurring). The link is an INTENT on the habit:
# "reminder":{"state":"linked","time":"HH:MM"} (or "declined"; absent = undecided)
# — NO `days` on the reminder, the schedule owns days. Per-day reminder ids live
# in the DB table habit_reminders(habit_id,occurred_on,reminder_id,status)
# (idempotency PK); two-way sync via reminders-ensure / reminders-sync [--sweep].
#
# Never exits non-zero. Assumes lib/vault.sh has set VAULT_DIR and sourced
# profile.sh + profiles.sh + db.sh first.

pbrain_habits_store() {
  printf '%s\n' "${PBRAIN_HABIT_TRACK_DIR:-${VAULT_DIR:-$HOME}/life/habit-tracking}/.profile"
}

pbrain_habits_profile_file() {
  if [[ -n "${PBRAIN_HABITS_PROFILE_FILE:-}" ]]; then
    printf '%s\n' "$PBRAIN_HABITS_PROFILE_FILE"
    return 0
  fi
  local store f
  store="$(pbrain_habits_store)"
  if declare -f pbrain_profile_latest >/dev/null 2>&1; then
    f="$(pbrain_profile_latest "$store" "habits-profile")"
    if [[ -n "$f" ]]; then
      printf '%s\n' "$f"
      return 0
    fi
  fi
  if [[ -f "${VAULT_DIR:-$HOME}/life/Habits Profile.md" ]]; then
    printf '%s\n' "${VAULT_DIR:-$HOME}/life/Habits Profile.md"
    return 0
  fi
  printf '%s\n' "$store/habits-profile.v1.md"
}

pbrain_habits_json() {
  local f
  f="$(pbrain_habits_profile_file)"
  [[ -f "$f" ]] || return 0
  # pbrain_profile_json is defined in lib/profile.sh (sourced before this file).
  if declare -f pbrain_profile_json >/dev/null 2>&1; then
    pbrain_profile_json "$f"
  fi
  return 0
}

# Absolute path to the /habits command script (sibling of this lib dir).
pbrain_habits_cmd() {
  local lib_dir repo_dir
  lib_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  repo_dir="$(cd -P -- "$lib_dir/.." && pwd -P)"
  printf '%s\n' "$repo_dir/commands/habits.sh"
}

# Canonical habit slug. Lowercase, non-alphanumerics → '-', trimmed. This is the
# STABLE habit_id minted once per habit and never changed afterwards (renames
# only touch the display name). The algorithm MUST match the backfill slug in
# lib/db.sh's migration so migrated events line up with profile habit ids — both
# are pinned by tests (tests/habits.bats + tests/db.bats).
#
# Pass a newline-separated list of already-taken ids as $2 to get a
# collision-safe suffix (-2, -3, …). Prints the slug; never exits non-zero.
pbrain_habit_slug() {
  command -v python3 >/dev/null 2>&1 || { printf '%s\n' "habit"; return 0; }
  python3 - "${1:-}" "${2:-}" <<'PYEOF' 2>/dev/null || printf '%s\n' "habit"
import re, sys
name = sys.argv[1] if len(sys.argv) > 1 else ""
existing = set(filter(None, (sys.argv[2] if len(sys.argv) > 2 else "").splitlines()))
base = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-") or "habit"
slug, n = base, 2
while slug in existing:
    slug, n = f"{base}-{n}", n + 1
print(slug)
PYEOF
}

# ── Habit criteria model ───────────────────────────────────────────────────
#
# Each habit carries its own fulfillment criteria, expressed as three fields in
# the profile JSON:
#
#   schedule_type : daily | weekly | monthly   (the period it's evaluated over)
#   direction     : at_least | at_most         (build a habit vs cap a habit)
#   target_count  : integer N (or null)        (how many times within the period)
#
#   ┌──────────┬───────────┬─────────────────────────────────────────────────┐
#   │ daily    │ at_least  │ do it every day — today ✅/⏳ + streak + N/7 week │
#   │ weekly   │ at_least  │ ≥ N times this week     (e.g. nail cut 2/week)    │
#   │ monthly  │ at_least  │ ≥ N times this month    (e.g. long run 5/month)   │
#   │ weekly   │ at_most   │ ≤ N this week — OVER ⚠️  (e.g. alcohol 2/week)    │
#   └──────────┴───────────┴─────────────────────────────────────────────────┘
#
# Legacy profiles (kind/cap_period/cap_count) are read transparently:
#   kind build→at_least, limit→at_most; cap_period week→weekly, month→monthly;
#   cap_count→target_count. Missing id → derived from the name slug, so legacy
#   events (also keyed by name-slug after the db migration) still line up.

# pbrain_habits_status [today] — emit a JSON object of per-habit computed status,
# sorted by priority (high→low) then name, archived habits excluded:
#   {"today": "...", "count": N, "habits": [ {id,name,schedule_type,direction,
#     target_count,priority,today_count,week_count,month_count,period_used,
#     period_target,last_done,streak,fulfilled,over,at_cap}, ... ]}
# This is the ONE evaluator: the dashboard consumes the JSON directly; the text
# rollup below is a thin renderer over it. Uses a single windowed query and
# aggregates in python (no per-habit N+1).
pbrain_habits_status() {
  command -v python3 >/dev/null 2>&1 || { printf '%s\n' "{}"; return 0; }
  local today profile db
  today="${1:-$(date +%Y-%m-%d)}"
  profile="$(pbrain_habits_profile_file)"
  db="$PBRAIN_DB_FILE"
  [[ -f "$profile" ]] || { printf '%s\n' "{}"; return 0; }
  local libdir; libdir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  python3 - "$profile" "$db" "$today" "$libdir" <<'PYEOF' 2>/dev/null || printf '%s\n' "{}"
import json, re, sys, sqlite3, datetime, os, calendar
profile, db, today_s, libdir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
sys.path.insert(0, libdir)
try:
    from habit_schedule import derive_schedule, is_due, schedule_label
except Exception:
    # Degrade gracefully if the engine isn't importable: treat everything daily.
    def derive_schedule(h): return {"type": "daily"}
    def is_due(s, d): return True
    def schedule_label(s): return "daily"
try:
    from habit_category import normalize as cat_norm, label as cat_label, order as cat_order
except Exception:
    # Degrade gracefully: a bare slug, title-cased label, uncategorized-last order.
    def cat_norm(v): return re.sub(r"[^a-z0-9]+", "-", str(v or "").strip().lower()).strip("-")
    def cat_label(v): return (" ".join(w.capitalize() for w in cat_norm(v).split("-"))) or "Uncategorized"
    def cat_order(v): return 1000 if not cat_norm(v) else 100

try:
    with open(profile) as fh:
        text = fh.read()
except Exception:
    print("{}"); sys.exit(0)
m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
raw = m.group(1).strip() if m else text.strip()
try:
    data = json.loads(raw)
except Exception:
    print("{}"); sys.exit(0)

def slug(name):
    s = re.sub(r"[^a-z0-9]+", "-", (name or "").strip().lower()).strip("-")
    return s or "habit"

def norm(h):
    name = str(h.get("name", "")).strip()
    st = str(h.get("schedule_type", "")).strip().lower()
    if st not in ("daily", "weekly", "monthly"):
        cp = str(h.get("cap_period", "")).strip().lower()        # legacy
        st = "monthly" if cp.startswith("month") else ("weekly" if cp.startswith("week") else "daily")
    direction = str(h.get("direction", "")).strip().lower()
    if direction not in ("at_least", "at_most"):
        kind = str(h.get("kind", "")).strip().lower()            # legacy
        direction = "at_most" if kind == "limit" else "at_least"
    tc = h.get("target_count", h.get("cap_count"))               # legacy fallback
    try:
        tc = int(tc) if tc not in (None, "") else None
    except (TypeError, ValueError):
        tc = None
    prio = str(h.get("priority", "medium")).strip().lower()
    if prio not in ("low", "medium", "high"):
        prio = "medium"
    hid = str(h.get("id", "")).strip() or slug(name)
    # Optional measure: a unit (str) + measure_target (number). When present the
    # habit is evaluated by AMOUNT over its period (e.g. 2.5/4 L) instead of by
    # occurrence count; target_count is then irrelevant.
    unit = str(h.get("unit", "")).strip()
    mt = h.get("measure_target")
    try:
        mt = float(mt) if mt not in (None, "") else None
    except (TypeError, ValueError):
        mt = None
    measured = mt is not None
    # Optional Apple-Reminder link — an INTENT, not a stored reminder id. Three
    # states: "linked" (pbrain creates a per-day one-shot at `time` and keeps it
    # in two-way sync — the per-day reminder ids live in the DB's habit_reminders
    # table, NOT here), "declined" (user said no — don't re-offer), or "none"
    # (absent → undecided). Only daily build (at_least) habits are ever offered a
    # reminder; the rest read as "none" and are simply never surfaced as pending.
    rem = h.get("reminder")
    rstate = "none"; rtime = ""
    if isinstance(rem, dict):
        rs = str(rem.get("state", "")).strip().lower()
        if rs in ("linked", "declined", "none"):
            rstate = rs
        rtime = str(rem.get("time", "")).strip()
        if rstate == "linked" and not rtime:
            rstate = "none"   # linked with no time → treat as undecided
    reminder = {"state": rstate, "time": rtime}
    # Schedule (axis 1) — derived non-destructively from the explicit `schedule`
    # block or legacy fields. Drives is_due (which days count). Scoring is only
    # schedule-AWARE when the habit carries an EXPLICIT `schedule` (a fixed plan
    # of days); a legacy habit with no schedule block stays count-based ("N times
    # this period, any days"), since a synthesized schedule is just for reminders.
    sched = derive_schedule(h)
    has_schedule = bool(isinstance(h.get("schedule"), dict) and h.get("schedule", {}).get("type"))
    sc = h.get("scoring")
    # Category ("part") — a single normalized slug; "" = uncategorized. Carries
    # its display label + a sort index so the rollup can group without importing.
    cat = cat_norm(h.get("category"))
    return {"id": hid, "name": name, "schedule_type": st, "direction": direction,
            "target_count": tc, "priority": prio, "unit": unit,
            "measure_target": mt, "measured": measured,
            "scoring": sc if isinstance(sc, dict) else None,
            "schedule": sched, "schedule_label": schedule_label(sched),
            "has_schedule": has_schedule,
            "category": cat, "category_label": cat_label(cat), "category_order": cat_order(cat),
            "reminder": reminder, "reminder_eligible": True,
            "archived": bool(h.get("archived")), "notes": str(h.get("notes", "")).strip()}

habits = [norm(h) for h in (data.get("habits") or []) if str(h.get("name", "")).strip()]
active = [h for h in habits if not h["archived"]]

today = datetime.date.fromisoformat(today_s)
week_start = today - datetime.timedelta(days=today.weekday())     # Monday
week_end = week_start + datetime.timedelta(days=6)
month_start = today.replace(day=1)
month_end = today.replace(day=calendar.monthrange(today.year, today.month)[1])
lookback = today - datetime.timedelta(days=400)                   # bounds the streak scan

# Single windowed query for every active habit; aggregate per-habit in python.
# Each date maps to [count, amount, status]: count = occurrences, amount =
# measured sum, status = done | skipped | missed (one row per habit-day, so the
# last status wins). A skipped day is an OFF day (never breaks/denominates a
# streak); a missed day is a real miss (count=0 breaks a build streak).
events = {}  # id -> {date_iso: [count, amount, status]}
ids = [h["id"] for h in active]
if ids and os.path.exists(db):
    try:
        con = sqlite3.connect(db, timeout=5)
        con.execute("PRAGMA busy_timeout=5000")
        cols = [r[1] for r in con.execute("PRAGMA table_info(habit_events)").fetchall()]
        scol = "status" if "status" in cols else "'done'"   # tolerate a pre-migration DB
        q = ("SELECT habit_id, occurred_on, count, amount, %s FROM habit_events "
             "WHERE habit_id IN (%s) AND occurred_on>=? AND occurred_on<=?"
             % (scol, ",".join("?" * len(ids))))
        for hid, d, c, a, st in con.execute(q, ids + [lookback.isoformat(), today.isoformat()]):
            slot = events.setdefault(hid, {}).setdefault(d, [0, 0.0, "done"])
            slot[0] += (c or 0)
            slot[1] += (a or 0.0)
            slot[2] = (st or "done")
        con.close()
    except Exception:
        events = {}

def _status_at(dates, di):
    s = dates.get(di)
    return (s[2] if s and len(s) > 2 else "done")

def in_range(dates, start, end, idx=0):
    s, e = start.isoformat(), end.isoformat()
    return sum(v[idx] for d, v in dates.items() if s <= d <= e)

ONE = datetime.timedelta(days=1)

def due_dates_in(sched, start, end):
    """ISO dates in [start, end] on which the habit's schedule is due."""
    out, d = [], start
    while d <= end:
        if is_due(sched, d.isoformat()):
            out.append(d.isoformat())
        d += ONE
    return out

def due_streak(sched, dates, today):
    """Consecutive DUE days (most recent backward) that were done. A non-due day
    is skipped (never breaks the streak); a deliberately SKIPPED due day is also
    treated as an off day (never breaks it); today being due-but-not-yet-done
    does not break it either. So a Mon/Wed/Fri habit isn't 'missed' on a Tuesday,
    and an explicit skip is not a missed day."""
    n, d, limit = 0, today, today - datetime.timedelta(days=400)
    while d >= limit:
        di = d.isoformat()
        if is_due(sched, di):
            if _status_at(dates, di) == "skipped":
                pass   # explicit skip → off day, never breaks the streak
            elif di in dates and dates[di][0] > 0:
                n += 1
            elif di == today.isoformat():
                pass   # today due but not done yet — don't break
            else:
                break   # missed (count 0, not skipped) → breaks the streak
        d -= ONE
    return n

def next_due(sched, today):
    """The next date (today or later) the schedule is due, or None within a year."""
    d, limit = today, today + datetime.timedelta(days=370)
    while d <= limit:
        if is_due(sched, d.isoformat()):
            return d.isoformat()
        d += ONE
    return None

prio_rank = {"high": 0, "medium": 1, "low": 2}
out = []
for h in active:
    dates = events.get(h["id"], {})
    slot = dates.get(today.isoformat(), [0, 0.0])
    today_count = slot[0]
    today_amount = slot[1]
    week_count = in_range(dates, week_start, week_end, 0)
    month_count = in_range(dates, month_start, today, 0)
    week_amount = in_range(dates, week_start, week_end, 1)
    month_amount = in_range(dates, month_start, today, 1)
    done_dates = [d for d, v in dates.items() if (v[0] or 0) > 0 and _status_at(dates, d) == "done"]
    last = max(done_dates) if done_dates else None
    st, tc, direction = h["schedule_type"], h["target_count"], h["direction"]
    sched = h["schedule"]
    sk = sched.get("type", "daily")
    due_today = bool(is_due(sched, today.isoformat()))
    nd = today.isoformat() if due_today else next_due(sched, today)
    fulfilled = over = at_cap = False
    streak_val = 0
    if h["measured"]:
        # amount-based vs target. A plain measured habit (water, distance) SUMS
        # the amount over the period. A SCORED habit stores a 0–1 unit score per
        # day; over a week/month we show the running SUM of those daily scores
        # (like Eat clean: "4/7 wk"), banked toward the period max. round to 2 dp
        # to keep the unit scale. Daily stays today's score.
        scored = isinstance(h.get("scoring"), dict)
        if scored and st == "weekly":
            amt = round(week_amount, 2)
        elif scored and st == "monthly":
            amt = round(month_amount, 2)
        else:
            amt = {"daily": today_amount, "weekly": week_amount, "monthly": month_amount}.get(st, today_amount)
        used, target = amt, h["measure_target"]
        if direction == "at_most":
            if target is not None:
                over, at_cap, fulfilled = used > target, used == target, used <= target
        else:
            fulfilled = (used >= target) if target is not None else (used > 0)
            if sk == "daily":
                streak_val = due_streak(sched, dates, today)
    elif direction == "at_most":
        # cap / limit — count ALL lapses in the period (not schedule-filtered)
        used = {"daily": today_count, "weekly": week_count, "monthly": month_count}.get(st, today_count)
        target = tc
        if target is not None:
            over, at_cap, fulfilled = used > target, used == target, used <= target
    elif h["has_schedule"] and sk in ("weekdays", "interval", "monthly"):
        # build habit with an EXPLICIT fixed schedule → SCHEDULE-AWARE: progress
        # over DUE occurrences in the period (week for weekdays, month for
        # interval/monthly). A non-due day is never counted against the habit;
        # the streak walks due days only (so an off-day never breaks it).
        p_start, p_end = (month_start, month_end) if sk in ("monthly", "interval") else (week_start, week_end)
        # A deliberately SKIPPED due day is an off day — drop it from the
        # denominator so "3/4 this week" reads "3/3" once one is skipped.
        due_in_period = [di for di in due_dates_in(sched, p_start, p_end)
                         if _status_at(dates, di) != "skipped"]
        scheduled = len(due_in_period)
        done_due = sum(1 for di in due_in_period if (dates.get(di, [0])[0] or 0) > 0)
        used, target = done_due, (scheduled if scheduled else 1)
        fulfilled = (done_due >= scheduled) if scheduled else (done_due > 0)
        streak_val = due_streak(sched, dates, today)
    elif st == "daily":
        # daily build (explicit or legacy) → today-based, with a due-day streak
        used, target = today_count, (tc if tc else 1)
        fulfilled = (used >= target)
        streak_val = due_streak(sched, dates, today)
    elif st == "weekly":
        # legacy floating "N times a week, any days" → count-based (old behavior)
        used, target = week_count, tc
        fulfilled = (used >= target) if target is not None else (used > 0)
    else:
        # legacy floating "N times a month, any days" → count-based (old behavior)
        used, target = month_count, tc
        fulfilled = (used >= target) if target is not None else (used > 0)
    row = dict(h)
    row.update({"today_count": today_count, "week_count": week_count,
                "month_count": month_count, "today_amount": today_amount,
                "week_amount": week_amount, "month_amount": month_amount,
                "period_used": used, "period_target": target,
                "due_today": due_today, "next_due": nd,
                "last_done": last, "streak": streak_val,
                "fulfilled": fulfilled, "over": over, "at_cap": at_cap})
    out.append(row)

out.sort(key=lambda x: (prio_rank.get(x["priority"], 1), x["name"].lower()))
print(json.dumps({"today": today.isoformat(), "count": len(out), "habits": out}))
PYEOF
}

# Text rollup — a thin renderer over pbrain_habits_status. Shows the top 20
# habits by priority with per-habit progress (✅ met / ⏳ not yet / ⚠️ over),
# daily streaks, and last-done. Prints nothing when habit tracking isn't set up
# (caller treats empty as "not configured"). Surfacing commands (/plan-my-day,
# /end-of-day, /weekly-review) call this; the dashboard uses the JSON directly.
pbrain_habits_rollup() {
  command -v python3 >/dev/null 2>&1 || return 0
  local profile st_json
  profile="$(pbrain_habits_profile_file)"
  [[ -f "$profile" ]] || return 0
  st_json="$(pbrain_habits_status "${1:-$(date +%Y-%m-%d)}")"
  # Pass the status JSON as argv (NOT stdin): `python3 -` reads the program from
  # the heredoc, so stdin is unavailable for data here.
  python3 - "$st_json" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
habits = data.get("habits") or []
if not habits:
    sys.exit(0)
LIMIT = 20

def fmt(n):
    # drop trailing .0 so 4.0 → "4" but 2.5 stays "2.5"
    if isinstance(n, float) and n.is_integer():
        return str(int(n))
    return str(n)

def render(h):
    direction = h["direction"]
    st = h["schedule_type"]
    sk = (h.get("schedule") or {}).get("type", "daily")
    used, target = h["period_used"], h["period_target"]
    tgt = fmt(target) if target is not None else "—"
    tag = "·limit" if direction == "at_most" else ""
    head = f"- {h['name']} ({h.get('schedule_label', 'daily')}{tag}, {h['priority']}): "
    if h["measured"]:
        # amount-based: "2.5/4 L today ✅" — period word per schedule_type. A
        # scored habit reads as a running weekly/monthly SUM (banked points).
        scored = isinstance(h.get("scoring"), dict)
        period_word = {"daily": "today", "weekly": "this week", "monthly": "this month"}.get(st, "today")
        unit = (" " + h["unit"]) if h["unit"] else ""
        if direction == "at_most":
            flag = " — OVER ⚠️" if h["over"] else (" — at cap" if h["at_cap"] else " ✅")
        else:
            flag = " ✅" if h["fulfilled"] else " ⏳"
        # A scored habit's progress denominator is the period MAX (1 for a day,
        # 7 for a week), not measure_target (the pass threshold the ✅/⏳ flag
        # checks). Measured non-scored habits keep their real target.
        if scored and st == "daily":
            disp_tgt = "1"
        elif scored and st == "weekly":
            disp_tgt = "7"
        else:
            disp_tgt = f"{tgt}{unit}"
        body = f"{fmt(used)}/{disp_tgt} {period_word}{flag}"
        if direction == "at_least" and h["streak"] > 0:
            body += f" · streak {h['streak']}"
    elif direction == "at_most":
        # cap / limit — count of lapses vs cap over the period
        if st == "daily":
            body = f"{fmt(h['today_count'])} today" + (" — OVER ⚠️" if h["over"] else "")
        else:
            period_word = "this week" if st == "weekly" else "this month"
            flag = " — OVER ⚠️" if h["over"] else (" — at cap" if h["at_cap"] else " ✅")
            body = f"{fmt(used)}/{tgt} {period_word}{flag}"
    elif h.get("has_schedule") and sk in ("weekdays", "interval", "monthly"):
        # explicit fixed schedule — show today's due-status, then period progress.
        # On a due day: done/not-yet; on an off day: say so, never a miss.
        if h["due_today"]:
            today_line = "done today ✅" if h["today_count"] > 0 else "not yet today ⏳"
        else:
            nd = h.get("next_due")
            today_line = "off today" + (f" (next {nd})" if nd else "")
        period_word = "this month" if sk in ("monthly", "interval") else "this week"
        body = today_line + f" · {fmt(used)}/{tgt} {period_word}"
        if h["streak"] > 0:
            body += f" · streak {h['streak']}"
    elif st == "daily":
        # daily build (legacy or explicit-daily) — today-based with a streak
        body = ("done today ✅" if h["today_count"] > 0 else "not yet today ⏳")
        body += f" · {fmt(h['week_count'])}/7 this week"
        if h["streak"] > 0:
            body += f" · streak {h['streak']}"
    else:
        # legacy floating "N times a week/month, any days" — period count
        period_word = "this week" if st == "weekly" else "this month"
        flag = " ✅" if h["fulfilled"] else " ⏳"
        body = f"{fmt(used)}/{tgt} {period_word}{flag}"
    last = h["last_done"]
    body += f" · last {last}" if last else " · never logged"
    rem = h.get("reminder") or {}
    if rem.get("state") == "linked":
        body += f" · 🔔 {rem.get('time') or 'on'}"
    return head + body

# `habits` arrives sorted by priority. When any habit carries a category, group
# under part headers (canonical order, then custom, then uncategorized last) —
# priority order is preserved WITHIN each part. With nothing categorized, fall
# back to the flat priority list (unchanged behaviour). LIMIT caps total rows.
any_cat = any((h.get("category") or "").strip() for h in habits)
lines = []
if not any_cat:
    for h in habits[:LIMIT]:
        lines.append(render(h))
    if len(habits) > LIMIT:
        lines.append(f"… +{len(habits) - LIMIT} more (showing top {LIMIT} by priority)")
else:
    from collections import OrderedDict
    groups = OrderedDict()
    for h in habits:
        groups.setdefault((h.get("category") or "").strip(), []).append(h)
    def gkey(item):
        h0 = item[1][0]
        return (h0.get("category_order", 1000), (h0.get("category_label") or "Uncategorized").lower())
    shown = 0
    for _key, hs in sorted(groups.items(), key=gkey):
        if shown >= LIMIT:
            break
        lines.append(f"**{hs[0].get('category_label') or 'Uncategorized'}**")
        for h in hs:
            if shown >= LIMIT:
                break
            lines.append(render(h))
            shown += 1
    if len(habits) > shown:
        lines.append(f"… +{len(habits) - shown} more (showing top {LIMIT} by priority)")
print("\n".join(lines))
PYEOF
}

# pbrain_habits_scores [today] — read back engine-computed scores for every
# scored habit (habits whose JSON carries a "scoring" block) for a given date.
# Scores are stored in habit_events.amount at mark time (score_from_spec writes
# the 0.0–1.0 unit float through the `amount` channel). Habits not yet marked
# that day show as "not marked" / null.
#
# Output:
#   - <name> · <0.NN> · <scoring_type> · <priority>   (one line per scored habit)
#   ...
#   HABIT_SCORES [{"name":..,"id":..,"scoring_type":..,"priority":..,"score":..},…]
#
# Never exits non-zero.
pbrain_habits_scores() {
  command -v python3 >/dev/null 2>&1 || { printf 'HABIT_SCORES []\n'; return 0; }
  local today profile db
  today="${1:-$(date +%Y-%m-%d)}"
  profile="$(pbrain_habits_profile_file)"
  db="$PBRAIN_DB_FILE"
  [[ -f "$profile" ]] || { printf 'HABIT_SCORES []\n'; return 0; }
  python3 - "$profile" "$db" "$today" <<'PYEOF' 2>/dev/null || printf 'HABIT_SCORES []\n'
import json, re, sys, sqlite3, os

profile, db, today_s = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(profile) as fh:
        text = fh.read()
except Exception:
    print("HABIT_SCORES []")
    sys.exit(0)

m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
raw = m.group(1).strip() if m else text.strip()
try:
    data = json.loads(raw)
except Exception:
    print("HABIT_SCORES []")
    sys.exit(0)

def slug(name):
    s = re.sub(r"[^a-z0-9]+", "-", (name or "").strip().lower()).strip("-")
    return s or "habit"

habits = data.get("habits") or []
scored = []
for h in habits:
    if h.get("archived"):
        continue
    scoring = h.get("scoring")
    if not isinstance(scoring, dict):
        continue
    name = str(h.get("name", "")).strip()
    if not name:
        continue
    hid = str(h.get("id", "")).strip() or slug(name)
    prio = str(h.get("priority", "medium")).strip().lower()
    stype = str(scoring.get("type", "")).strip()
    scored.append({"id": hid, "name": name, "priority": prio, "scoring_type": stype, "score": None})

if not scored:
    print("HABIT_SCORES []")
    sys.exit(0)

ids = [h["id"] for h in scored]
amounts = {}
if os.path.exists(db):
    try:
        con = sqlite3.connect(db, timeout=5)
        con.execute("PRAGMA busy_timeout=5000")
        q = ("SELECT habit_id, amount FROM habit_events WHERE habit_id IN (%s) AND occurred_on=?"
             % ",".join("?" * len(ids)))
        for hid, amt in con.execute(q, ids + [today_s]):
            if amt is not None:
                amounts[hid] = float(amt)
        con.close()
    except Exception:
        amounts = {}

lines = []
result = []
for h in scored:
    raw_score = amounts.get(h["id"])
    if raw_score is not None:
        score_val = round(raw_score, 2)
        score_disp = "%g" % score_val   # 1.0 -> "1", 0.83 -> "0.83", 0 -> "0"
    else:
        score_disp = "not marked"
        score_val = None
    lines.append(f"- {h['name']} · {score_disp} · {h['scoring_type']} · {h['priority']}")
    result.append({"name": h["name"], "id": h["id"], "scoring_type": h["scoring_type"],
                   "priority": h["priority"], "score": score_val})

print("\n".join(lines))
print("HABIT_SCORES " + json.dumps(result))
PYEOF
}

# ── daily markdown tracking layer ───────────────────────────────────────────
#
# The human-facing log is a dated markdown file, one per day, generated from the
# Habits Profile — same pattern as /fitness-journal and /journal:
#
#   life/habit-tracking/<date>.md   ← you (and the agent) edit this
#         │  sync: parse the table's "Done" rows → mirror into the DB for <date>
#         ▼
#   SQLite habit_events             ← analysis store (history/rollup/reviews read it)
#
# Markdown is the source of truth for a day; the DB is derived. `sync` mirrors a
# date (so unchecking a habit removes its event); `consolidate` (run by
# /end-of-day) syncs then prunes the day's file to only the habits actually done.
# Read commands sync recent days first so the DB stays current.
#
# All table parsing/rendering lives in ONE python dispatcher so the format can't
# drift between init/mark/sync/consolidate. Thin bash wrappers call it.

pbrain_habit_track_dir() {
  printf '%s\n' "${PBRAIN_HABIT_TRACK_DIR:-${VAULT_DIR:-$HOME}/life/habit-tracking}"
}

pbrain_habit_track_file() {
  printf '%s\n' "$(pbrain_habit_track_dir)/${1:-$(date +%Y-%m-%d)}.md"
}

# _pbrain_habit_track_py <op> <args…> — the single owner of the md table format.
#   init        <profile> <db> <file> <date>
#   mark        <profile> <db> <file> <date> <name> <count> <note> <amount>
#   sync        <profile> <db> <dir>  <end_date> <days> <now>
#   consolidate <profile> <db> <file> <date> <now>
_pbrain_habit_track_py() {
  command -v python3 >/dev/null 2>&1 || return 0
  local _libdir; _libdir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  PBRAIN_HABITS_LIBDIR="$_libdir" python3 - "$@" <<'PYEOF'
import sys, os, re, json, sqlite3, datetime
sys.path.insert(0, os.environ.get("PBRAIN_HABITS_LIBDIR", ""))
try:
    from habit_category import normalize as cat_norm, label as cat_label, order as cat_order
except Exception:
    def cat_norm(v): return re.sub(r"[^a-z0-9]+", "-", str(v or "").strip().lower()).strip("-")
    def cat_label(v): return (" ".join(w.capitalize() for w in cat_norm(v).split("-"))) or "Uncategorized"
    def cat_order(v): return 1000 if not cat_norm(v) else 100

# The dated tracking file is SPLIT into one table per part (category), each under
# a `## <Part>` heading. Within a section the table is the plain 6-column shape
# below — the heading carries the part. Grouping + section order are DERIVED from
# the profile on every render (finalize_rows), never trusted from the file, so
# editing a habit's category re-sections the file on the next sync/refresh.
HEADER = "| Habit | Criteria | Progress | Done | Count | Note |"
SEP    = "|-------|----------|----------|------|-------|------|"
# The Done column carries a per-day STATE token, not just a checkbox:
#   done    → x / yes / ✓ / …   (a real completion; count>=1)
#   skipped → skip / skipped / ⊘ (deliberately cancelled today — an off day)
#   missed  → miss / missed / ✗  (scheduled but never done — a real miss)
#   blank   → not yet (in-day)
DONE_TRUE = {"x", "yes", "y", "done", "true", "1", "✅", "✓"}
SKIP_TOK  = {"skip", "skipped", "⊘"}
MISS_TOK  = {"miss", "missed", "✗"}

def slugify(s):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "").strip().lower()).strip("-")
    return s or "habit"

def load_habits(profile):
    try:
        text = open(profile).read()
    except Exception:
        return []
    m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
    raw = m.group(1) if m else text
    try:
        data = json.loads(raw)
    except Exception:
        return []
    out = []
    for h in (data.get("habits") or []):
        name = str(h.get("name", "")).strip()
        if not name:
            continue
        st = str(h.get("schedule_type", "")).strip().lower()
        if st not in ("daily", "weekly", "monthly"):
            cp = str(h.get("cap_period", "")).strip().lower()
            st = "monthly" if cp.startswith("month") else ("weekly" if cp.startswith("week") else "daily")
        direction = str(h.get("direction", "")).strip().lower()
        if direction not in ("at_least", "at_most"):
            direction = "at_most" if str(h.get("kind", "")).strip().lower() == "limit" else "at_least"
        tc = h.get("target_count", h.get("cap_count"))
        try:
            tc = int(tc) if tc not in (None, "") else None
        except (TypeError, ValueError):
            tc = None
        unit = str(h.get("unit", "")).strip()
        mt = h.get("measure_target")
        try:
            mt = float(mt) if mt not in (None, "") else None
        except (TypeError, ValueError):
            mt = None
        sc = h.get("scoring")
        cat = cat_norm(h.get("category"))
        out.append({"id": str(h.get("id", "")).strip() or slugify(name), "name": name,
                    "schedule_type": st, "direction": direction, "target_count": tc,
                    "priority": str(h.get("priority", "medium")).strip().lower(),
                    "unit": unit, "measure_target": mt, "measured": mt is not None,
                    "scoring": sc if isinstance(sc, dict) else None,
                    "archived": bool(h.get("archived")),
                    "category": cat, "category_label": cat_label(cat),
                    "category_order": cat_order(cat)})
    return out


def fmtnum(n):
    if isinstance(n, float) and n.is_integer():
        return str(int(n))
    return str(n)

def _to_int(s):
    """Parse an optional integer arg; '' / None / junk -> None."""
    try:
        s = str(s).strip()
        return int(float(s)) if s != "" else None
    except (TypeError, ValueError):
        return None

def _parse_hhmm(s):
    """HH:MM -> minutes since midnight; None when unparsable."""
    try:
        parts = str(s).strip().split(":")
        return int(parts[0]) * 60 + int(parts[1])
    except (TypeError, ValueError, IndexError):
        return None

def _to_float(s):
    try:
        s = str(s).strip()
        return float(s) if s != "" else None
    except (TypeError, ValueError):
        return None

def score_from_spec(spec, good=None, bad=None, slips=None,
                    actual_time=None, actual_hours=None,
                    items=None, session=None, focus=None, done=None):
    """Generic, deterministic habit-score evaluator. The habit's profile owns
    the rule (spec); the caller supplies only raw inputs. Returns a float
    score on a 0.0–1.0 UNIT scale (every scored habit shares this scale; only
    the model differs), or None when the spec is unusable / no inputs were
    given (callers fall back to their normal path on None). Ratio types round
    half-up to 2 decimals; ladder types return the ladder rung verbatim (so
    a profile's ladder must already be expressed on the 0–1 scale).

    Spec types:

    "slip_ladder" (the original):
      slips = given --slips, else max(bad, good_target - good)  (clamped >= 0)
      score = ladder[min(slips, len(ladder)-1)]   (rungs are 0–1, e.g. [1,0.6,0.3,0])
      'good_target' is optional (0 = no good-count requirement -> pure bad ladder).

    "meal_ratio" (eat-clean): inputs good = clean MEALS, bad = unclean MEALS.
      score = good / (good + bad), rounded to 2 dp. The score depends on the
      NUMBER of meals — one slip out of 3 meals scores worse than one of 6.

    "deviation" (sleep-well): spec carries normal_time "HH:MM", normal_hours,
      unit_minutes (default 30), unit_hours (default 0.5), ladder. Inputs
      actual_time "HH:MM" + actual_hours.
      slips = round(circular_minutes(actual_time, normal_time) / unit_minutes)
            + round(max(0, normal_hours - actual_hours) / unit_hours)
      score = ladder[min(slips, len(ladder)-1)]. The bed-time diff is circular
      (00:30 vs 23:00 = 90 min, not 1350), so just-past-midnight stays sane.

    Nothing here is habit-specific: what counts as a good/bad unit (or which
    session supplied the times) is the caller's classification, not the code's."""
    if not isinstance(spec, dict):
        return None
    stype = str(spec.get("type", "slip_ladder")).strip()

    if stype == "meal_ratio":
        if good is None and bad is None:
            return None
        g = max(0, good or 0)
        b = max(0, bad or 0)
        total = g + b
        if total <= 0:
            return None
        # Unit scale (0.0–1.0): share of clean meals. int(x+0.5)/100 keeps
        # predictable half-up rounding to 2 dp (python round() is banker's).
        return int(100.0 * g / total + 0.5) / 100.0

    if stype == "deviation":
        ladder = spec.get("ladder")
        if not isinstance(ladder, list) or not ladder:
            return None
        nt = _parse_hhmm(spec.get("normal_time"))
        nh = _to_float(spec.get("normal_hours"))
        at = _parse_hhmm(actual_time)
        ah = _to_float(actual_hours)
        if at is None and ah is None:
            return None  # no inputs -> caller falls back to its normal path
        unit_min = _to_float(spec.get("unit_minutes")) or 30.0
        unit_hrs = _to_float(spec.get("unit_hours")) or 0.5
        # int(x + 0.5): predictable half-up (python round() is banker's — round(2.5)=2).
        n = 0
        if at is not None and nt is not None:
            d = abs(at - nt)
            d = min(d, 1440 - d)
            n += int(d / unit_min + 0.5)
        if ah is not None and nh is not None:
            n += int(max(0.0, nh - ah) / unit_hrs + 0.5)
        idx = min(max(0, n), len(ladder) - 1)
        try:
            return float(ladder[idx])
        except (TypeError, ValueError):
            return None

    if stype == "checklist":
        # A fixed daily SET of named components, each with a weight; the caller
        # passes the list of components actually completed (`done`, by id OR
        # name). score = sum(completed weights) / sum(all weights) (0–1).
        # Generalises any multi-item daily routine — e.g. a supplement stack
        # (morning ×2 + a night magnesium = 3 components, each weight 1, so a
        # morning-only day scores 67). Equal weights = a plain fraction-done.
        comps = spec.get("components")
        if not isinstance(comps, list) or not comps or not isinstance(done, list):
            return None
        done_set = set(str(x).strip().lower() for x in done if str(x).strip())
        total = 0.0
        earned = 0.0
        for c in comps:
            if not isinstance(c, dict):
                continue
            w = _to_float(c.get("weight"))
            if w is None or w <= 0:
                w = 1.0
            total += w
            cid = str(c.get("id", "")).strip().lower()
            cname = str(c.get("name", "")).strip().lower()
            if (cid and cid in done_set) or (cname and cname in done_set):
                earned += w
        if total <= 0.0:
            return None
        # Unit scale (0.0–1.0); int(x+0.5)/100 keeps half-up rounding to 2 dp.
        return int(100.0 * earned / total + 0.5) / 100.0

    if stype == "weighted_completion":
        if not isinstance(items, list) or not items:
            return None
        dw = spec.get("difficulty_weights", {"easy": 1, "normal": 2, "hard": 3, "nightmare": 5})
        sc_map = spec.get("status_credit", {"done": 1.0, "partial": 0.5, "dropped": 0.0, "carried": 0.0})
        pivot = float(spec.get("priority_pivot", 3))
        step = float(spec.get("priority_step", 0.25))
        possible = 0.0
        earned = 0.0
        for t in items:
            if not isinstance(t, dict):
                continue
            diff = str(t.get("difficulty", "normal")).strip()
            status = str(t.get("status", "dropped")).strip().lower()
            pri = _to_int(t.get("priority")) or 3
            w = float(dw.get(diff, 2))
            w *= 1.0 + max(0.0, pivot - pri) * step
            possible += w
            earned += w * float(sc_map.get(status, 0.0))
        if possible <= 0.0:
            return None
        return int(100.0 * earned / possible + 0.5) / 100.0

    if stype == "focus_ratio":
        # "Deep work": inputs = a dict of per-category active minutes during the
        # day's work blocks, e.g. {"work":120,"social":30,"entertainment":15,
        # "neutral":10}. score = work / (work + distraction) (0–1); neutral and
        # afk are excluded from the formula. Which categories count as work vs
        # distraction is the spec's call, not the code's.
        if not isinstance(focus, dict):
            return None
        work_cats = spec.get("work_categories") or ["work"]
        distr_cats = spec.get("distraction_categories") or ["social", "entertainment"]
        def _sum_cats(cats):
            t = 0.0
            for c in cats:
                v = _to_float(focus.get(c))
                if v and v > 0:
                    t += v
            return t
        w = _sum_cats(work_cats)
        d = _sum_cats(distr_cats)
        if (w + d) <= 0.0:
            return None  # no active work-or-distraction time -> caller leaves it unmarked
        return int(100.0 * w / (w + d) + 0.5) / 100.0

    if stype == "session_volume":
        if not isinstance(session, dict):
            return None
        status = str(session.get("status", "skipped")).strip().lower()
        sc_map = spec.get("status_credit", {"completed": 1.0, "partial": 0.5, "skipped": 0.0})
        mode = str(session.get("mode", "binary")).strip().lower()
        planned = _to_float(session.get("planned"))
        actual_vol = _to_float(session.get("actual"))
        volume_cap = float(spec.get("volume_cap", 1.0))
        if status == "skipped":
            return 0.0
        if mode in ("strength", "duration") and planned is not None and planned > 0.0 and actual_vol is not None:
            ratio = min(max(0.0, actual_vol / planned), volume_cap)
            return int(100.0 * ratio + 0.5) / 100.0
        credit = float(sc_map.get(status, 0.0))
        return int(100.0 * credit + 0.5) / 100.0

    if stype != "slip_ladder":
        return None
    ladder = spec.get("ladder")
    if not isinstance(ladder, list) or not ladder:
        return None
    if slips is not None:
        n = slips
    elif good is None and bad is None:
        return None  # no inputs -> caller falls back to its normal path
    else:
        gt = _to_int(spec.get("good_target")) or 0
        deficit = max(0, gt - (good or 0)) if gt else 0
        n = max(bad or 0, deficit)
    n = max(0, int(n))
    idx = min(n, len(ladder) - 1)
    try:
        return float(ladder[idx])
    except (TypeError, ValueError, IndexError):
        return None

def criteria_str(h):
    st = h["schedule_type"]
    sym = "≤" if h["direction"] == "at_most" else "≥"
    if h["measured"]:
        # measured habits read by amount: "daily ≥4 L", "weekly ≥20 km"
        unit = (" " + h["unit"]) if h["unit"] else ""
        return f"{st} {sym}{fmtnum(h['measure_target'])}{unit}"
    if st == "daily":
        return "daily (limit)" if h["direction"] == "at_most" else "daily"
    tc = h["target_count"] if h["target_count"] is not None else "?"
    return f"{st} {sym}{tc}"

def is_done(v):
    return (v or "").strip().lower() in DONE_TRUE

def is_skipped(v):
    return (v or "").strip().lower() in SKIP_TOK

def is_missed(v):
    return (v or "").strip().lower() in MISS_TOK

def day_status(v):
    """Classify a Done-column token into one of the 3 states (or '' = not yet)."""
    t = (v or "").strip().lower()
    if t in DONE_TRUE:
        return "done"
    if t in SKIP_TOK:
        return "skipped"
    if t in MISS_TOK:
        return "missed"
    return ""

# Canonical Done-column token for each state (what mark/autostatus write).
STATUS_TOKEN = {"done": "x", "skipped": "skip", "missed": "miss"}

def db_progress(con, h, date):
    if con is None:
        return "—"
    today = datetime.date.fromisoformat(date)
    week_start = today - datetime.timedelta(days=today.weekday())
    month_start = today.replace(day=1)
    col = "amount" if h["measured"] else "count"
    def agg(start):
        row = con.execute(f"SELECT COALESCE(SUM({col}),0) FROM habit_events "
                          "WHERE habit_id=? AND occurred_on>=? AND occurred_on<=?",
                          (h["id"], start.isoformat(), today.isoformat())).fetchone()
        return row[0] if row else 0
    st = h["schedule_type"]
    if h["measured"]:
        # amount-based progress, e.g. "2.5/4 L wk" / "12/20 km mo" / "1.5/4 L day".
        # Weekly/monthly read as the SUM (agg) over the period — for a scored
        # habit that's the running total of daily scores, not an average.
        unit = (" " + h["unit"]) if h["unit"] else ""
        tgt = fmtnum(h["measure_target"]) if h["measure_target"] is not None else "?"
        scored = isinstance(h.get("scoring"), dict)
        # A SCORED habit stores a 0–1 unit score per day, so its progress
        # denominator is the period's MAX possible sum (1 for a day, 7 for a
        # week) — NOT measure_target, which for a scored habit is the pass
        # THRESHOLD (< max) shown in Criteria/fulfillment. A weekly scored habit
        # banks the week's daily scores like Eat clean ("4/7 wk"). Measured
        # non-scored habits keep their real target as the denominator.
        if scored and st == "daily":
            return f"{fmtnum(agg(today))}/1 day"
        if scored and st == "weekly":
            return f"{fmtnum(agg(week_start))}/7 wk"
        if st == "weekly":
            return f"{fmtnum(agg(week_start))}/{tgt}{unit} wk"
        if st == "monthly":
            return f"{fmtnum(agg(month_start))}/{tgt}{unit} mo"
        return f"{fmtnum(agg(today))}/{tgt}{unit} day"
    tc = h["target_count"]
    if st == "weekly":
        return f"{agg(week_start)}/{tc if tc is not None else '?'} wk"
    if st == "monthly":
        return f"{agg(month_start)}/{tc if tc is not None else '?'} mo"
    # daily: a limit reads today's count against the per-day cap ("2/1 day" =
    # over); a build reads how many days done so far this week out of 7.
    if h["direction"] == "at_most":
        cap = tc if tc is not None else 0
        return f"{agg(today)}/{cap} day"
    return f"{agg(week_start)}/7 wk"

def front(date):
    return ("---\n"
            "type: habit-tracking\n"
            f"date: {date}\n"
            "tags: []\n"
            "---\n\n"
            f"# Habits — {date}\n\n"
            "Mark what you did today: put `x` in **Done**. Count/Note optional.\n"
            "Generated from your Habits Profile; weekly/monthly progress is shown\n"
            "for context. Habits are split into a table per **part** (category).\n"
            "Unchecked habits are pruned at end of day.\n\n")

def parse_table(text):
    # The file holds one table per part section. Collect EVERY section's habit
    # rows into one flat list; the `## <Part>` headings are throwaway (re-derived
    # + re-emitted on render). pre = content before the first section/table;
    # post = anything after the last table. Header-aware per table, so old
    # single-table files (6- or 7-column, with or without a Part column) parse
    # too.
    lines = text.splitlines()
    hdr_idxs = [i for i, l in enumerate(lines) if re.match(r"\s*\|\s*Habit\s*\|", l)]
    if not hdr_idxs:
        return text, [], ""
    first = hdr_idxs[0]
    # pre = everything before the first table, minus a trailing "## " section
    # heading + surrounding blanks (regenerated on render).
    k = first - 1
    while k >= 0 and lines[k].strip() == "":
        k -= 1
    if k >= 0 and lines[k].lstrip().startswith("##"):
        k -= 1
        while k >= 0 and lines[k].strip() == "":
            k -= 1
    pre = "\n".join(lines[:k + 1])
    rows = []
    last_end = first
    for hi in hdr_idxs:
        hdr = [c.strip().lower() for c in lines[hi].strip().strip("|").split("|")]
        idx = {nm: kk for kk, nm in enumerate(hdr)}
        def col(cells, nm, _idx=idx):
            kk = _idx.get(nm)
            return cells[kk].strip() if (kk is not None and kk < len(cells)) else ""
        j = hi + 2
        while j < len(lines) and lines[j].strip().startswith("|"):
            cells = [c.strip() for c in lines[j].strip().strip("|").split("|")]
            rows.append({"name": col(cells, "habit"), "part": col(cells, "part"),
                         "criteria": col(cells, "criteria"), "progress": col(cells, "progress"),
                         "done": col(cells, "done"), "count": col(cells, "count"),
                         "note": col(cells, "note")})
            j += 1
        last_end = j
    post = "\n".join(lines[last_end:])
    return pre, rows, post

def row_line(r):
    return ("| %s | %s | %s | %s | %s | %s |"
            % (r["name"], r["criteria"], r["progress"], r["done"], r["count"], r["note"]))

def finalize_rows(rows, by_name):
    # Derive each row's Part + sort index from the profile (the source of truth),
    # then GROUP by part: canonical order, then custom, then uncategorized last —
    # preserving the original (profile) order within a part. A row whose habit is
    # gone sorts to the end (Uncategorized).
    for i, r in enumerate(rows):
        h = by_name.get(r["name"].strip().lower())
        if h:
            r["part"] = h["category_label"] if h.get("category") else ""
            r["_order"] = h.get("category_order", 1000)
        else:
            r.setdefault("part", "")
            r["_order"] = 1000
        r["_i"] = i
    return sorted(rows, key=lambda r: (r.get("_order", 1000), (r.get("part") or "").lower(), r["_i"]))

def render(pre, rows, post):
    # `rows` is already finalized (part set + grouped). Emit one `## <Part>`
    # section + table per part, in that grouped order. Uncategorized -> "Other".
    body = []
    cur = object()
    for r in rows:
        part = (r.get("part") or "").strip()
        if part != cur:
            if body:
                body.append("")
            body.append("## " + (part if part else "Other"))
            body.append("")
            body.append(HEADER)
            body.append(SEP)
            cur = part
        body.append(row_line(r))
    out = pre.rstrip() + "\n\n" + "\n".join(body) + "\n"
    if post.strip():
        out += "\n" + post.rstrip() + "\n"
    return out

def new_rows(habits, con, date):
    return [{"name": h["name"], "criteria": criteria_str(h), "progress": db_progress(con, h, date),
             "done": "", "count": "", "note": ""} for h in habits]

def mirror_rows(con, rows, date, by_name, now):
    # Mirror a parsed table's MARKED rows into the DB for <date>: the DB must
    # end up matching exactly the md's marked rows (so un-checking removes the
    # event). A row is "marked" when its Done column carries any of the 3 state
    # tokens — done (count>=1), skipped or missed (both count=0 so they never
    # inflate done-tallies, but the record survives consolidate). A blank Done
    # column is "not yet" → no DB row.
    marked = []
    for r in rows:
        status = day_status(r["done"])
        if not status:
            continue
        nm = r["name"].strip()
        if not nm:
            continue
        h = by_name.get(nm.lower())
        hid = (h["id"] if h else None) or slugify(nm)
        if status != "done":
            # skipped / missed: recorded but not a completion
            marked.append((hid, nm, 0, None, (r["note"].strip() or None), status))
            continue
        cell = str(r["count"]).strip()
        if h and h["measured"]:
            # the Count cell holds the measured amount (e.g. 2.5); count stays 1
            try:
                amount = float(cell) if cell else None
            except (TypeError, ValueError):
                amount = None
            c = 1
        else:
            amount = None
            try:
                c = max(1, int(float(cell))) if cell else 1
            except (TypeError, ValueError):
                c = 1
        marked.append((hid, nm, c, amount, (r["note"].strip() or None), "done"))
    ids = [d[0] for d in marked]
    if ids:
        con.execute("DELETE FROM habit_events WHERE occurred_on=? AND habit_id NOT IN (%s)"
                    % ",".join("?" * len(ids)), [date] + ids)
    else:
        con.execute("DELETE FROM habit_events WHERE occurred_on=?", (date,))
    for hid, nm, c, amount, note, status in marked:
        con.execute(
            "INSERT INTO habit_events (habit_id,habit,occurred_on,count,amount,status,source,note,created_at) "
            "VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(habit_id,occurred_on) DO UPDATE SET "
            "count=excluded.count, amount=excluded.amount, status=excluded.status, "
            "habit=excluded.habit, source=excluded.source, note=excluded.note",
            (hid, nm, date, c, amount, status, "habit-tracking", note, now))
    return sum(1 for d in marked if d[5] == "done")

def refresh_progress(con, rows, by_name, date):
    # Recompute every row's Criteria + Progress from the profile/DB (call AFTER
    # mirror_rows so the day's own marks are reflected). Mutates rows in place.
    for r in rows:
        h = by_name.get(r["name"].strip().lower())
        if h:
            r["criteria"] = criteria_str(h)
            r["progress"] = db_progress(con, h, date)

def sync_one(con, f, date, by_name, now):
    if not os.path.exists(f):
        return 0
    _, rows, _ = parse_table(open(f).read())
    return mirror_rows(con, rows, date, by_name, now)

op = sys.argv[1]

if op == "init":
    profile, db, f, date = sys.argv[2:6]
    habits = [h for h in load_habits(profile) if not h["archived"]]
    hbn = {h["name"].strip().lower(): h for h in habits}
    con = sqlite3.connect(db) if os.path.exists(db) else None
    if os.path.exists(f):
        pre, rows, post = parse_table(open(f).read())
        by_name = {r["name"].strip().lower(): r for r in rows}
        for h in habits:
            cr, pr = criteria_str(h), db_progress(con, h, date)
            r = by_name.get(h["name"].strip().lower())
            if r:
                r["criteria"], r["progress"] = cr, pr
            else:
                rows.append({"name": h["name"], "criteria": cr, "progress": pr,
                             "done": "", "count": "", "note": ""})
        out = render(pre if pre.strip() else front(date).rstrip(),
                     finalize_rows(rows, hbn), post)
    else:
        out = render(front(date).rstrip(), finalize_rows(new_rows(habits, con, date), hbn), "")
    if con:
        con.close()
    open(f, "w").write(out)
    print(f)

elif op == "mark":
    profile, db, f, date, name, count, note, amount, now = sys.argv[2:11]
    # Optional trailing classification inputs for scored habits (backward-compatible).
    good  = sys.argv[11] if len(sys.argv) > 11 else ""
    bad   = sys.argv[12] if len(sys.argv) > 12 else ""
    slips = sys.argv[13] if len(sys.argv) > 13 else ""
    a_time  = sys.argv[14] if len(sys.argv) > 14 else ""   # deviation: actual HH:MM
    a_hours = sys.argv[15] if len(sys.argv) > 15 else ""   # deviation: actual hours
    items_json   = sys.argv[16] if len(sys.argv) > 16 else ""  # weighted_completion
    session_json = sys.argv[17] if len(sys.argv) > 17 else ""  # session_volume
    focus_json   = sys.argv[18] if len(sys.argv) > 18 else ""  # focus_ratio
    done_json    = sys.argv[19] if len(sys.argv) > 19 else ""  # checklist
    status       = sys.argv[20] if len(sys.argv) > 20 else ""  # done|skipped|missed
    status = (status or "").strip().lower()
    if status not in ("done", "skipped", "missed"):
        status = "done"
    habits = load_habits(profile)
    active = {h["name"].strip().lower(): h for h in habits if not h["archived"]}
    byid = {h["id"]: h for h in habits if not h["archived"]}
    h = active.get(name.strip().lower()) or byid.get(name.strip().lower())
    if not h:
        print(f"not a tracked habit: {name.strip()} — add it with /habits (not marked)")
        sys.exit(0)
    # Scored habit: when the caller supplied classification inputs, the score is
    # computed from the habit's profile rule — the caller never picks the number.
    g, b, sl = _to_int(good), _to_int(bad), _to_int(slips)
    items_parsed = None
    session_parsed = None
    focus_parsed = None
    done_parsed = None
    if items_json.strip():
        try:
            items_parsed = json.loads(items_json)
        except Exception:
            pass
    if session_json.strip():
        try:
            session_parsed = json.loads(session_json)
        except Exception:
            pass
    if focus_json.strip():
        try:
            focus_parsed = json.loads(focus_json)
        except Exception:
            pass
    if done_json.strip():
        try:
            done_parsed = json.loads(done_json)
        except Exception:
            pass
    if status == "done" and h.get("scoring") and (
                             g is not None or b is not None or sl is not None
                             or a_time.strip() or a_hours.strip()
                             or items_parsed is not None or session_parsed is not None
                             or focus_parsed is not None or done_parsed is not None):
        val = score_from_spec(h["scoring"], good=g, bad=b, slips=sl,
                              actual_time=a_time.strip() or None,
                              actual_hours=a_hours.strip() or None,
                              items=items_parsed, session=session_parsed,
                              focus=focus_parsed, done=done_parsed)
        if val is not None:
            amount = fmtnum(val)  # feed the measured-amount path below
    con = sqlite3.connect(db) if os.path.exists(db) else None
    if not os.path.exists(f):
        _act = [x for x in habits if not x["archived"]]
        _hbn = {x["name"].strip().lower(): x for x in _act}
        open(f, "w").write(render(front(date).rstrip(),
                                  finalize_rows(new_rows(_act, con, date), _hbn), ""))
    pre, rows, post = parse_table(open(f).read())
    token = STATUS_TOKEN.get(status, "x")
    if status != "done":
        # skipped / missed: a recorded non-completion — no count/amount.
        cval = ""
    elif h["measured"]:
        # measured habit: the Count cell carries the amount (e.g. "2.5").
        # Prefer --amount; fall back to --count if that's the number given.
        raw = amount.strip() if amount.strip() else count.strip()
        try:
            cval = fmtnum(float(raw)) if raw else ""
        except (TypeError, ValueError):
            cval = ""
    else:
        try:
            cval = str(max(1, int(float(count))))
        except (TypeError, ValueError):
            cval = "1"
        if cval == "1":
            cval = ""   # leave default count blank to keep the cell clean
    target = h["name"].strip().lower()
    found = False
    for r in rows:
        if r["name"].strip().lower() == target:
            r["done"] = token
            # On a skip/miss, clear any stale count from an earlier done mark.
            r["count"] = cval if cval else ("" if status != "done" else r["count"])
            if note.strip():
                r["note"] = note.strip()
            found = True
            break
    if not found:
        rows.append({"name": h["name"], "criteria": criteria_str(h),
                     "progress": db_progress(con, h, date), "done": token,
                     "count": cval, "note": note.strip()})
    # Mirror today's marks into the DB and recompute every row's Progress so the
    # file shows live numbers the instant a habit is marked (not a stale snapshot
    # from when the tracker was created).
    if con is not None:
        mirror_rows(con, rows, date, active, now)
        refresh_progress(con, rows, active, date)
    # Write markdown first (source of truth), then commit DB so that if the
    # file write fails the DB is not committed — consolidate will re-mirror on
    # next run and recover consistency.
    open(f, "w").write(render(pre, finalize_rows(rows, active), post))
    if con is not None:
        con.commit()
        con.close()
    verb = {"skipped": "skipped", "missed": "missed"}.get(status, "marked")
    print(f"{verb}: {h['name']} on {date}")

elif op == "score":
    # Pure deterministic evaluator — compute a habit's score from its profile
    # rule + caller-supplied inputs. No DB / md write. Prints the numeric
    # score (blank if the habit has no usable scoring spec).
    profile, name = sys.argv[2:4]
    good  = sys.argv[4] if len(sys.argv) > 4 else ""
    bad   = sys.argv[5] if len(sys.argv) > 5 else ""
    slips = sys.argv[6] if len(sys.argv) > 6 else ""
    a_time  = sys.argv[7] if len(sys.argv) > 7 else ""
    a_hours = sys.argv[8] if len(sys.argv) > 8 else ""
    items_json   = sys.argv[9]  if len(sys.argv) > 9  else ""
    session_json = sys.argv[10] if len(sys.argv) > 10 else ""
    focus_json   = sys.argv[11] if len(sys.argv) > 11 else ""
    done_json    = sys.argv[12] if len(sys.argv) > 12 else ""
    habits = load_habits(profile)
    active = {h["name"].strip().lower(): h for h in habits if not h["archived"]}
    byid = {h["id"]: h for h in habits if not h["archived"]}
    h = active.get(name.strip().lower()) or byid.get(name.strip().lower())
    items_parsed = None
    session_parsed = None
    focus_parsed = None
    done_parsed = None
    if items_json.strip():
        try:
            items_parsed = json.loads(items_json)
        except Exception:
            pass
    if session_json.strip():
        try:
            session_parsed = json.loads(session_json)
        except Exception:
            pass
    if focus_json.strip():
        try:
            focus_parsed = json.loads(focus_json)
        except Exception:
            pass
    if done_json.strip():
        try:
            done_parsed = json.loads(done_json)
        except Exception:
            pass
    val = score_from_spec(h.get("scoring"), good=_to_int(good), bad=_to_int(bad),
                          slips=_to_int(slips),
                          actual_time=a_time.strip() or None,
                          actual_hours=a_hours.strip() or None,
                          items=items_parsed, session=session_parsed,
                          focus=focus_parsed, done=done_parsed) if h else None
    print(fmtnum(val) if val is not None else "")

elif op == "sync":
    profile, db, trackdir, end_date, days, now = sys.argv[2:8]
    if not os.path.exists(db):
        print("synced 0")
        sys.exit(0)
    habits = load_habits(profile)
    by_name = {h["name"].strip().lower(): h for h in habits}
    end = datetime.date.fromisoformat(end_date)
    con = sqlite3.connect(db)
    con.execute("PRAGMA busy_timeout=5000")
    total = 0
    for n in range(int(days) + 1):
        d = (end - datetime.timedelta(days=n)).isoformat()
        total += sync_one(con, os.path.join(trackdir, d + ".md"), d, by_name, now)
    con.commit()
    con.close()
    print(f"synced {total}")

elif op == "consolidate":
    profile, db, f, date, now = sys.argv[2:7]
    habits = load_habits(profile)
    by_name = {h["name"].strip().lower(): h for h in habits}
    if not os.path.exists(f):
        print("consolidated")
        sys.exit(0)
    pre, rows, post = parse_table(open(f).read())
    if os.path.exists(db):
        con = sqlite3.connect(db)
        con.execute("PRAGMA busy_timeout=5000")
        mirror_rows(con, rows, date, by_name, now)
        refresh_progress(con, rows, by_name, date)
        con.commit()
        con.close()
    # prune the day's file to the habits with a recorded STATE (done / skipped /
    # missed) — the day's record survives, only the untouched "not yet" rows go.
    kept = [r for r in rows if day_status(r["done"])]
    open(f, "w").write(render(pre, finalize_rows(kept, by_name), post))
    print("consolidated")

elif op == "refresh":
    # Recompute a date's Progress column from the (already-synced) DB without
    # changing any Done marks. Mirrors the file's done rows first so the day's
    # own marks are reflected, then rewrites the file. Used to backfill / keep
    # historical trackers accurate after the DB or the formula changes.
    profile, db, f, date, now = sys.argv[2:7]
    if not os.path.exists(f):
        print("refresh skip (no file)")
        sys.exit(0)
    habits = load_habits(profile)
    by_name = {h["name"].strip().lower(): h for h in habits}
    pre, rows, post = parse_table(open(f).read())
    if os.path.exists(db):
        con = sqlite3.connect(db)
        con.execute("PRAGMA busy_timeout=5000")
        mirror_rows(con, rows, date, by_name, now)
        refresh_progress(con, rows, by_name, date)
        con.commit()
        con.close()
    open(f, "w").write(render(pre, finalize_rows(rows, by_name), post))
    print(f"refreshed {f}")
PYEOF
}

# Ensure today's tracking file exists with a row per active habit (idempotent;
# preserves existing marks, refreshes progress, adds rows for new habits).
pbrain_habit_track_init() {
  local date file
  date="${1:-$(date +%Y-%m-%d)}"
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  file="$(pbrain_habit_track_file "$date")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  _pbrain_habit_track_py init "$(pbrain_habits_profile_file)" "$PBRAIN_DB_FILE" "$file" "$date"
}

# Mark a habit done in the date's tracking file (creating it if needed). Rejects
# names that aren't a tracked habit. count/note/amount optional. For a measured
# habit (one with a unit + target) the amount is what's recorded. Scored habits
# take classification inputs instead: good/bad/slips (slip_ladder, meal_ratio)
# or actual_time/actual_hours (deviation) — the score lands in amount.
pbrain_habit_mark() {  # <date> <name> [count] [note] [amount] [good] [bad] [slips] [actual_time] [actual_hours] [items_json] [session_json] [focus_json] [done_json] [status]
  local date file
  date="${1:-$(date +%Y-%m-%d)}"
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  file="$(pbrain_habit_track_file "$date")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  _pbrain_habit_track_py mark "$(pbrain_habits_profile_file)" "$PBRAIN_DB_FILE" "$file" \
    "$date" "${2:-}" "${3:-1}" "${4:-}" "${5:-}" "$(date '+%Y-%m-%d %H:%M')" \
    "${6:-}" "${7:-}" "${8:-}" "${9:-}" "${10:-}" "${11:-}" "${12:-}" "${13:-}" "${14:-}" "${15:-}"
}

# Compute (without writing) a scored habit's score from its profile rule + raw
# inputs. Echoes the numeric score, or "" if not a scored habit.
pbrain_habit_score() {  # <name> [good] [bad] [slips] [actual_time] [actual_hours] [items_json] [session_json] [focus_json] [done_json]
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  _pbrain_habit_track_py score "$(pbrain_habits_profile_file)" \
    "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" "${10:-}"
}

# Mirror the last <days> days of tracking files into the DB (idempotent). Run by
# read commands so the DB reflects the md before querying. Dates with no md file
# are left untouched. After mirroring, the end-date file's Progress column is
# refreshed so the visible tracker the user opens always agrees with the DB
# rollup the caller is about to read — a manual `x` ticked in Obsidian (or an
# Apple-Reminder completion already mirrored in) updates the file's counts
# automatically, instead of showing a stale creation-time snapshot until the
# end-of-day consolidate finally rewrites it.
pbrain_habits_sync_range() {  # [days] [end_date]
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  local _end_date="${2:-$(date +%Y-%m-%d)}"
  _pbrain_habit_track_py sync "$(pbrain_habits_profile_file)" "$PBRAIN_DB_FILE" \
    "$(pbrain_habit_track_dir)" "$_end_date" "${1:-7}" "$(date '+%Y-%m-%d %H:%M')" >/dev/null 2>&1 || true
  # Reconcile the visible (end-date) tracker's Progress column with the DB so the
  # file and the rollup never disagree. Idempotent; only rewrites if the file
  # exists (refresh is a no-op otherwise).
  pbrain_habit_refresh "$_end_date" >/dev/null 2>&1 || true
}

# Sync one date's md into the DB and prune that file to the habits actually done.
# Run by /end-of-day.
pbrain_habit_consolidate() {  # <date>
  local date file
  date="${1:-$(date +%Y-%m-%d)}"
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  file="$(pbrain_habit_track_file "$date")"
  _pbrain_habit_track_py consolidate "$(pbrain_habits_profile_file)" "$PBRAIN_DB_FILE" \
    "$file" "$date" "$(date '+%Y-%m-%d %H:%M')"
}

# Recompute one date's Progress column from the DB (no Done changes). Mirrors the
# file's marks first so the day's own marks count.
pbrain_habit_refresh() {  # <date>
  local date file
  date="${1:-$(date +%Y-%m-%d)}"
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  file="$(pbrain_habit_track_file "$date")"
  _pbrain_habit_track_py refresh "$(pbrain_habits_profile_file)" "$PBRAIN_DB_FILE" \
    "$file" "$date" "$(date '+%Y-%m-%d %H:%M')"
}

# Refresh the Progress column across the last <days> trackers (oldest→newest so
# each day's week-to-date totals see the earlier days already mirrored). Missing
# days are skipped. Used to backfill historical files after a formula/data change.
pbrain_habit_refresh_range() {  # [days] [end_date]
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  local days end n d
  days="${1:-30}"
  end="${2:-$(date +%Y-%m-%d)}"
  for ((n=days; n>=0; n--)); do
    d="$(python3 - "$end" "$n" <<'PYEOF' 2>/dev/null || true
import sys, datetime
end, n = sys.argv[1], int(sys.argv[2])
print((datetime.date.fromisoformat(end) - datetime.timedelta(days=n)).isoformat())
PYEOF
)"
    [[ -n "$d" ]] || continue
    [[ -f "$(pbrain_habit_track_file "$d")" ]] || continue
    pbrain_habit_refresh "$d" >/dev/null 2>&1 || true
  done
}

# ── new-habit suggestion suppression ────────────────────────────────────────
# A tiny state file records candidates the agent has already suggested, so the
# cross-command "want to track this as a habit?" nudge doesn't re-nag the same
# thing across separate command runs / days. Each line is "<slug>\t<YYYY-MM-DD>".
# A candidate is suppressed for PBRAIN_HABIT_SUGGEST_TTL_DAYS (default 14).
pbrain_habit_suggest_file() {
  printf '%s\n' "${PBRAIN_HABIT_SUGGEST_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/habit-suggest-seen}"
}

# Echo the slugs suggested within the TTL window (newline-separated).
pbrain_habit_suggest_recent() {
  command -v python3 >/dev/null 2>&1 || return 0
  local f ttl today
  f="$(pbrain_habit_suggest_file)"
  ttl="${PBRAIN_HABIT_SUGGEST_TTL_DAYS:-14}"
  today="${1:-$(date +%Y-%m-%d)}"
  [[ -f "$f" ]] || return 0
  python3 - "$f" "$ttl" "$today" <<'PYEOF' 2>/dev/null || true
import sys, datetime
f, ttl, today_s = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    today = datetime.date.fromisoformat(today_s)
except Exception:
    sys.exit(0)
out = []
try:
    with open(f) as fh:
        for line in fh:
            parts = line.strip().split("\t")
            if len(parts) < 2:
                continue
            slug, ds = parts[0], parts[1]
            try:
                d = datetime.date.fromisoformat(ds)
            except Exception:
                continue
            if (today - d).days <= ttl:
                out.append(slug)
except Exception:
    sys.exit(0)
print("\n".join(sorted(set(out))))
PYEOF
}

# Record that <slug> was suggested on <today> (upsert). Used by the suggest-seen
# subcommand so the agent can mark a candidate as nudged.
pbrain_habit_suggest_record() {
  command -v python3 >/dev/null 2>&1 || return 0
  local f slug today
  f="$(pbrain_habit_suggest_file)"
  slug="${1:-}"
  today="${2:-$(date +%Y-%m-%d)}"
  [[ -n "${slug//[[:space:]]/}" ]] || return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  python3 - "$f" "$slug" "$today" <<'PYEOF' 2>/dev/null || true
import sys, os
f, slug, today = sys.argv[1], sys.argv[2], sys.argv[3]
rows = {}
if os.path.exists(f):
    try:
        for line in open(f):
            p = line.strip().split("\t")
            if len(p) >= 2:
                rows[p[0]] = p[1]
    except Exception:
        pass
rows[slug] = today
try:
    with open(f, "w") as fh:
        for k, v in rows.items():
            fh.write(f"{k}\t{v}\n")
except Exception:
    pass
PYEOF
}

# Ride-along emitter: when a habits profile exists, append a compact block at
# the end of a command's output telling Claude to (1) log any habits the user
# actually evidenced this session via the /habits log subcommand, and (2)
# suggest adding a NEW habit if the user shows a standing intention to build one
# that isn't tracked yet — gated to one suggestion per session and suppressed
# per-candidate for ~14 days so it never re-nags. Silent when no profile exists
# (so it costs nothing until the user opts into habit tracking — setup is only
# nudged by /habits, /plan-my-day, and /end-of-day).
pbrain_emit_habits_extract() {
  local cmd json names today cmd_path
  cmd="${1:-}"
  [[ -n "$cmd" ]] || return 0
  json="$(pbrain_habits_json)"
  [[ "$json" =~ [^[:space:]] ]] || return 0

  # Habits flagged eod_only are confirmed/scored at /end-of-day (or via their own
  # reminder) from what ACTUALLY happened across the day — never marked mid-day
  # from planned or partial activity. They are dropped from the tracked list for
  # every command EXCEPT end-of-day, and surfaced as "deferred" instead. The
  # calling command name is passed as argv[1] so the python can apply the gate.
  names="$(printf '%s' "$json" | python3 -c '
import json, sys
cmd = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
eod_phase = (cmd == "end-of-day")
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
out = []
for h in data.get("habits") or []:
    n = str(h.get("name", "")).strip()
    if not n or h.get("archived"):
        continue
    # Scored habits need whole-day evidence (diet log, sleep, etc.) to score, so
    # they are deferred to /end-of-day exactly like eod_only habits (PB-50).
    if (h.get("eod_only") or isinstance(h.get("scoring"), dict)) and not eod_phase:
        continue
    direction = str(h.get("direction", "")).strip().lower()
    if direction not in ("at_least", "at_most"):
        direction = "at_most" if str(h.get("kind", "")).strip().lower() == "limit" else "at_least"
    kind = "limit" if direction == "at_most" else "build"
    mt = h.get("measure_target")
    tags = [kind]
    if mt not in (None, ""):
        unit = str(h.get("unit", "")).strip()
        tags.append("measured: " + str(mt) + ((" " + unit) if unit else ""))
    if isinstance(h.get("scoring"), dict):
        tags.append("scored")
    out.append(f"{n} [" + ", ".join(tags) + "]")
print(" | ".join(out))
' "$cmd" 2>/dev/null || true)"
  [[ -n "$names" ]] || return 0

  # Names of the eod_only habits held back from THIS command (empty at end-of-day).
  local deferred
  deferred="$(printf '%s' "$json" | python3 -c '
import json, sys
cmd = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
if cmd == "end-of-day":
    sys.exit(0)
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
out = [str(h.get("name", "")).strip() for h in (data.get("habits") or [])
       if (h.get("eod_only") or isinstance(h.get("scoring"), dict))
       and not h.get("archived") and str(h.get("name", "")).strip()]
print(", ".join(out))
' "$cmd" 2>/dev/null || true)"

  today="$(date +%Y-%m-%d)"
  cmd_path="$(pbrain_habits_cmd)"

  # Collect classification rules for scored habits (their profile notes), so the
  # model has exact good/bad definitions inline — not buried in the profile.
  local scored_rules
  scored_rules="$(printf '%s' "$json" | python3 -c '
import json, sys
cmd = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
eod_phase = (cmd == "end-of-day")
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
out = []
for h in data.get("habits") or []:
    if h.get("archived"):
        continue
    # PB-50: scored habits are deferred to end-of-day; do not surface their
    # classification rules in mid-day commands where they cannot be marked.
    if (h.get("eod_only") or isinstance(h.get("scoring"), dict)) and not eod_phase:
        continue
    sc = h.get("scoring")
    if isinstance(sc, dict):
        n = str(h.get("name", "")).strip()
        notes = str(h.get("notes", "")).strip()
        if not n:
            continue
        # Notes carry the classification logic of a USER-DEFINED habit; the default
        # scored habits have blank notes, so point the model at the /habits spec
        # (their classification + flags live there, the math in score_from_spec).
        line = f"  {n}: {notes}" if notes else f"  {n}: [scored habit — no notes; classify by the /habits spec \"Default scored habits\" and pass the per-type flag, never pick the score]"
        if str(sc.get("type", "")).strip() == "checklist":
            comps = [c for c in (sc.get("components") or []) if isinstance(c, dict)]
            labels = ", ".join(
                str(c.get("name") or c.get("id") or "").strip()
                + (f" (w{c.get('weight')})" if c.get("weight") not in (None, 1, 1.0) else "")
                for c in comps if (c.get("name") or c.get("id")))
            if labels:
                line = (line + " " if line else f"  {n}: ") + f"[checklist components — pass the ones done via --done: {labels}]"
        if line:
            out.append(line)
print("\n".join(out))
' "$cmd" 2>/dev/null || true)"

  printf '%s\n' ""
  printf '%s\n' "--- HABIT EXTRACTION ($cmd) ---"
  printf '%s\n' "Run this AFTER the command's main work, silently. Tracked habits:"
  printf '%s\n' "  $names"
  printf '%s\n' ""
  printf '%s\n' "If — and only if — the user ACTUALLY DID one of these habits this session"
  printf '%s\n' "(genuinely completed it, or explicitly skipped it — never merely PLANNED"
  printf '%s\n' "it), MARK each ONE TIME in today's tracking markdown with:"
  printf '%s\n' "  bash \"$cmd_path\" mark --name \"<exact habit name>\" --date $today [--count N] [--amount X] [--note \"...\"]"
  printf '%s\n' "For a habit tagged [measured: …] above, pass the quantity with --amount (e.g."
  printf '%s\n' "--amount 2.5 for 2.5 L of water); plain habits need no count/amount at all."
  printf '%s\n' ""
  printf '%s\n' "NEVER mark a habit from something only PLANNED or scheduled (a planned"
  printf '%s\n' "workout, a meal the user intends to eat later) or from a routine/template"
  printf '%s\n' "that merely lists it — planned is not done. A fitness file with"
  printf '%s\n' "status: planned is NOT a completed workout. Mark the action actually"
  printf '%s\n' "performed, and match the user's wording to the habit's definition (a habit"
  printf '%s\n' "named for a NIGHT action is not evidenced by a MORNING mention, and vice"
  printf '%s\n' "versa) — when a habit carries a definition below, the action must match it."
  printf '%s\n' ""
  printf '%s\n' "For a habit tagged [scored] above, DO NOT choose the amount/score yourself —"
  printf '%s\n' "the number is computed deterministically from the habit's rule in your"
  printf '%s\n' "profile. Your ONLY job is to classify and pass the raw inputs:"
  printf '%s\n' "  bash \"$cmd_path\" mark --name \"<exact name>\" --date $today --good <N> --bad <N> [--note \"...\"]"
  printf '%s\n' "where --good = qualifying units (e.g. clean home-cooked meals) and --bad ="
  printf '%s\n' "slip units (e.g. outside/junk meals). habits.sh applies the profile formula."
  printf '%s\n' "(If you've already reduced it to one slip count, pass --slips <N> instead.)"
  printf '%s\n' "Meal-ratio scored habits (e.g. Eat clean): count clean vs unclean MEALS from"
  printf '%s\n' "today's diet log/table — every eating occasion counts — and pass them as"
  printf '%s\n' "--good/--bad; the score scales with how many meals the day actually had."
  printf '%s\n' "Deviation-scored habits (e.g. Sleep well): derive the ACTUAL bed time and"
  printf '%s\n' "sleep hours from the session (the fitness check-in answers, or the"
  printf '%s\n' "plan-my-day wake/bed exchange) and mark with:"
  printf '%s\n' "  bash \"$cmd_path\" mark --name \"<exact name>\" --date $today --actual-time HH:MM --actual-hours <N.N>"
  printf '%s\n' "(--actual-time = when they got to bed; the score is computed from the"
  printf '%s\n' "deviation vs their normal sleep window in the habit's rule.)"
  printf '%s\n' "Weighted-completion scored habits (e.g. Work the plan): at /end-of-day, collect"
  printf '%s\n' "every row in the ## Task log table (priority integer, difficulty string,"
  printf '%s\n' "status string) and pass them as a JSON array:"
  printf '%s\n' "  bash \"$cmd_path\" mark --name \"<exact name>\" --date $today \\"
  printf '%s\n' "    --items '[{\"priority\":1,\"difficulty\":\"hard\",\"status\":\"done\"}, ...]'"
  printf '%s\n' "Status values: done | partial | dropped | carried. Never guess the score."
  printf '%s\n' "Session-volume scored habits (e.g. Train): after a fitness session is logged,"
  printf '%s\n' "derive mode (strength|duration|binary), status (completed|partial|skipped),"
  printf '%s\n' "planned volume (target sets x reps for strength; target minutes for duration),"
  printf '%s\n' "and actual volume from the session log table, then mark with:"
  printf '%s\n' "  bash \"$cmd_path\" mark --name \"<exact name>\" --date $today \\"
  printf '%s\n' "    --session '{\"mode\":\"strength\",\"status\":\"completed\",\"planned\":120,\"actual\":115}'"
  printf '%s\n' "For binary sessions (yoga, sport): omit planned/actual, set mode=binary;"
  printf '%s\n' "score is status_credit on a 0–1 scale (completed=1, partial=0.5, skipped=0)."
  printf '%s\n' "Checklist scored habits (e.g. Supplements): a fixed daily set of named"
  printf '%s\n' "components, each with a weight. Pass the JSON list of components the user"
  printf '%s\n' "actually took/did today (by component name or id — see the rules below):"
  printf '%s\n' "  bash \"$cmd_path\" mark --name \"<exact name>\" --date $today \\"
  printf '%s\n' "    --done '[\"Morning vitamin D\", \"Magnesium (night)\"]'"
  printf '%s\n' "score = done-weight / total-weight on a 0–1 scale (e.g. 2 of 3 equal items = 0.67)."
  printf '%s\n' "List ONLY what was done; omit the rest. Never guess the score yourself."
  if [[ "$scored_rules" =~ [^[:space:]] ]]; then
    printf '%s\n' "Classification rules per scored habit — use EXACTLY each habit's own"
    printf '%s\n' "definition below to count its good/bad units (the definition states which"
    printf '%s\n' "meals/occasions count toward good vs bad — do not assume all of them do):"
    printf '%s\n' "$scored_rules"
  fi
  printf '%s\n' ""
  printf '%s\n' "[limit] habits work INVERSELY — they are caps on something to avoid (e.g. No"
  printf '%s\n' "smoking, No drinking, No masturbation, TV under 1hr). MARK a [limit] habit"
  printf '%s\n' "ONLY when the user LAPSED — actually did the capped thing — putting the"
  printf '%s\n' "amount in --count and the detail in --note (e.g. mark \"No smoking\" --count 3"
  printf '%s\n' "--note \"3 cigarettes\"). A clean / abstinent day is NOT a mark: leave it"
  printf '%s\n' "blank — for a limit, no mark IS the success. NEVER mark a [limit] habit"
  printf '%s\n' "because the user avoided it; that would count the success against them."
  printf '%s\n' "This ticks the habit in today's habit-tracking/<date>.md (the human-facing"
  printf '%s\n' "log); /end-of-day consolidates that file into the analysis DB. Match the"
  printf '%s\n' "user's words to a habit name above; don't invent or infer habits they didn't"
  printf '%s\n' "actually mention. Marking is idempotent (one cell per habit per day), so"
  printf '%s\n' "re-running is safe. If nothing was evidenced, do nothing and stay silent."
  printf '%s\n' "Surface at most one short line summarising what you marked (or nothing)."
  if [[ "$deferred" =~ [^[:space:]] ]]; then
    printf '%s\n' ""
    printf '%s\n' "END-OF-DAY ONLY — do NOT mark these now: $deferred. They are confirmed/"
    printf '%s\n' "scored at /end-of-day (or when their own reminder is ticked) from what"
    printf '%s\n' "actually happened across the whole day, NOT from planned or partial"
    printf '%s\n' "activity mid-day. They are intentionally omitted from the list above."
  fi
  printf '%s\n' "--- END HABIT EXTRACTION ---"

  # (2) New-habit suggestion — gated, once/session, TTL-suppressed per candidate.
  local recent
  recent="$(pbrain_habit_suggest_recent "$today" | tr '\n' ' ')"
  printf '%s\n' ""
  printf '%s\n' "--- HABIT SUGGEST ($cmd) ---"
  printf '%s\n' "If the user shows a STANDING INTENTION to build or cap a NEW habit not"
  printf '%s\n' "already tracked above — e.g. \"I'm trying to X every day\", \"want to start"
  printf '%s\n' "Xing\", \"been Xing daily\", \"need to cut back on X\" — you MAY suggest"
  printf '%s\n' "tracking it, ONCE. Do NOT suggest on a one-off mention, and at most ONE"
  printf '%s\n' "suggestion per session. Never suggest a habit already tracked above."
  if [[ -n "${recent// /}" ]]; then
    printf '%s\n' "Suggested recently — do NOT re-suggest these: $recent"
  fi
  printf '%s\n' "If the user wants it, add it with:"
  printf '%s\n' "  bash \"$cmd_path\" add --name \"<X>\" --type daily|weekly|monthly --direction at_least|at_most [--target N] [--unit \"L\"] [--measure-target N] [--priority low|medium|high]"
  printf '%s\n' "For a multi-item daily routine scored out of its parts (e.g. a supplement"
  printf '%s\n' "stack, a skincare routine), add it as a CHECKLIST scored habit with"
  printf '%s\n' "--components \"Item A; Item B=2; Item C\" (weight after = is optional, default 1)."
  printf '%s\n' "Whether or not they accept, record the suggestion so it isn't re-nagged:"
  printf '%s\n' "  bash \"$cmd_path\" suggest-seen --name \"<X>\""
  printf '%s\n' "If the user has told you they don't want habit suggestions, skip this."
  printf '%s\n' "--- END HABIT SUGGEST ---"
  return 0
}

# pbrain_emit_habits_scan <cmd>
# The daily planner's habit reconcile, owned here in the habit module so the logic
# lives with /habits rather than spread across plan-my-day. Two deterministic parts
# the script provides, then the model acts on:
#   (A) enumerate which of TODAY'S vault entries exist (journal, gratitude, thoughts,
#       fitness, diet, planning) → the model reads them for habit evidence and marks;
#   (B) time-match today's ONE-SHOT habit reminders to the planned block times —
#       a single deterministic batch (reminders-realign-plan, run AFTER the plan
#       file is written) ensures+reschedules every linked habit's one-shot; the
#       model only cancels one-shots for habits clearly not happening today.
# Reuses pbrain_emit_habits_extract verbatim for the full mark + suggest mechanics
# (no duplication). Silent when no habits profile exists. PERMANENT reminder
# add/delete (changing a habit's schedule) stays in /habits, not here.
pbrain_emit_habits_scan() {
  local cmd today vault cmd_path json
  cmd="${1:-}"
  [[ -n "$cmd" ]] || return 0
  json="$(pbrain_habits_json)"
  [[ "$json" =~ [^[:space:]] ]] || return 0   # silent without a habits profile

  today="$(date +%Y-%m-%d)"
  cmd_path="$(pbrain_habits_cmd)"
  # VAULT_DIR is set when habits.sh is sourced through vault.sh (the normal path);
  # fall back to PBRAIN_VAULT so the function still resolves entries when sourced
  # standalone (e.g. unit tests).
  vault="${VAULT_DIR:-${PBRAIN_VAULT:-}}"

  # Which of today's entry files exist (honoring the same env overrides the daily
  # commands use). The model reads ONLY the ones present — no inference from gaps.
  local journal_dir grat_dir thought_dir fitness_dir diet_dir plan_dir
  journal_dir="${PBRAIN_JOURNAL_DIR:-$vault/life/daily-tracking}"
  grat_dir="${PBRAIN_GRATITUDE_DIR:-$vault/life/gratitude-journal}"
  thought_dir="${PBRAIN_THOUGHTS_DIR:-$vault/life/thought-tracking}"
  fitness_dir="${PBRAIN_FITNESS_DIR:-$vault/fitness/daily-tracking}"
  diet_dir="${PBRAIN_DIET_DIR:-$vault/fitness/diet-tracking}"
  plan_dir="${PBRAIN_PLAN_DIR:-$vault/life/daily-planning}"

  local present=()
  local pair label path
  for pair in \
    "journal:$journal_dir/$today.md" \
    "gratitude:$grat_dir/$today.md" \
    "thoughts:$thought_dir/$today.md" \
    "fitness:$fitness_dir/$today.md" \
    "diet:$diet_dir/$today.md" \
    "planning:$plan_dir/$today.md"; do
    label="${pair%%:*}"; path="${pair#*:}"
    [[ -f "$path" ]] && present+=("$label → $path")
  done

  printf '%s\n' ""
  printf '%s\n' "--- HABIT SCAN ($cmd) ---"
  printf '%s\n' "Run this AFTER the command's main work. Do it SILENTLY and do NOT"
  printf '%s\n' "NARRATE the mechanism: do not announce which entry files you are"
  printf '%s\n' "scanning, what evidence you found, or that you are realigning/syncing"
  printf '%s\n' "reminders, and do not echo command output (\"REALIGNED <n> SKIPPED <n>\","
  printf '%s\n' "\"SYNCED …\", NOT_LINKED/NOT_FOUND, etc.). Treat command errors as no-ops"
  printf '%s\n' "— do not report them. Surface ONLY a user-facing outcome they would care"
  printf '%s\n' "about (e.g. \"Marked Gym ✓\"), nothing about the internal steps or skips."
  printf '%s\n' "Two parts:"
  printf '%s\n' ""
  printf '%s\n' "(A) EVIDENCE SCAN — today's vault entries that exist. Read these for any"
  printf '%s\n' "    tracked habit the user did / skipped / lapsed, then mark per the HABIT"
  printf '%s\n' "    EXTRACTION block below (which lists the habits + exact mark syntax):"
  if [[ ${#present[@]} -eq 0 ]]; then
    printf '%s\n' "    (no entries logged today yet — nothing to scan; use what the user said)"
  else
    local e
    for e in "${present[@]}"; do printf '%s\n' "    - $e"; done
  fi
  printf '%s\n' "    Read only what's there; never infer a habit from a missing file. Combine"
  printf '%s\n' "    with what the user said this session. Mark each evidenced habit ONE time."
  printf '%s\n' "    A PLANNED entry is NOT completion: a fitness file with status: planned,"
  printf '%s\n' "    or a meal the user only intends to eat later, does not evidence its"
  printf '%s\n' "    habit. Mark only what actually happened."
  printf '%s\n' ""
  printf '%s\n' "(B) REMINDER ALIGNMENT — run this ONCE, AFTER you have written today's plan"
  printf '%s\n' "    file ($plan_dir/$today.md), so the realign reads the FINAL block times."
  printf '%s\n' "    One deterministic batch command time-matches every linked habit's one-shot"
  printf '%s\n' "    Apple Reminder to its row in the plan's \"## Today at a glance\" table"
  printf '%s\n' "    (it ensures the one-shot exists first, then reschedules — so it no longer"
  printf '%s\n' "    silently NOT_FOUNDs when the day was re-timed), then pushes state through:"
  printf '%s\n' "      bash \"$cmd_path\" reminders-realign-plan --plan \"$plan_dir/$today.md\" --date $today"
  printf '%s\n' "      bash \"$cmd_path\" reminders-sync --date $today"
  printf '%s\n' "    It prints \"REALIGNED <n> SKIPPED <n>\" — no per-habit looping needed. Do NOT"
  printf '%s\n' "    hand-call reminders-reschedule per habit; the batch owns the matching."
  printf '%s\n' "    To stand down a one-shot for a habit clearly NOT happening today (e.g. a"
  printf '%s\n' "    scheduled activity the user dropped), cancel it explicitly:"
  printf '%s\n' "      bash \"$cmd_path\" reminders-cancel --habit \"<exact habit name>\" --date $today"
  printf '%s\n' "    Do NOT add or delete a habit's PERMANENT reminder here — changing a habit's"
  printf '%s\n' "    schedule is /habits' job."
  printf '%s\n' ""
  printf '%s\n' "Reminder: run all of the above as quiet bookkeeping. The user should see"
  printf '%s\n' "only habits that got marked, never the scan/realign/sync plumbing."
  printf '%s\n' "--- END HABIT SCAN ---"

  # Full mark syntax + new-habit suggestion (reused verbatim, not duplicated).
  pbrain_emit_habits_extract "$cmd"
  return 0
}
