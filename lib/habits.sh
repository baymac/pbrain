#!/usr/bin/env bash
# pbrain habits helper — sourced by lib/vault.sh (after profile.sh and db.sh).
#
# Two-layer design, mirroring how goals/diet/fitness already split definition
# from data:
#   - The habits PROFILE (which habits to track, their kind / priority / cap)
#     is a vault markdown note carrying its structured data in a fenced ```json
#     block — same discipline as the goals profile, so pbrain_profile_json reads
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
# Resolution:
#   PBRAIN_HABITS_PROFILE_FILE  override (default $VAULT_DIR/life/Habits Profile.md)
#
# Never exits non-zero. Assumes lib/vault.sh has set VAULT_DIR and sourced
# profile.sh + db.sh first.

pbrain_habits_profile_file() {
  printf '%s\n' "${PBRAIN_HABITS_PROFILE_FILE:-${VAULT_DIR:-$HOME}/life/Habits Profile.md}"
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
    return {"id": hid, "name": name, "schedule_type": st, "direction": direction,
            "target_count": tc, "priority": prio, "unit": unit,
            "measure_target": mt, "measured": measured,
            "schedule": sched, "schedule_label": schedule_label(sched),
            "has_schedule": has_schedule,
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
# Each date maps to (count, amount): count = occurrences, amount = measured sum.
events = {}  # id -> {date_iso: [count, amount]}
ids = [h["id"] for h in active]
if ids and os.path.exists(db):
    try:
        con = sqlite3.connect(db, timeout=5)
        con.execute("PRAGMA busy_timeout=5000")
        q = ("SELECT habit_id, occurred_on, count, amount FROM habit_events "
             "WHERE habit_id IN (%s) AND occurred_on>=? AND occurred_on<=?"
             % ",".join("?" * len(ids)))
        for hid, d, c, a in con.execute(q, ids + [lookback.isoformat(), today.isoformat()]):
            slot = events.setdefault(hid, {}).setdefault(d, [0, 0.0])
            slot[0] += (c or 0)
            slot[1] += (a or 0.0)
        con.close()
    except Exception:
        events = {}

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
    is skipped (never breaks the streak); today being due-but-not-yet-done does
    not break it either. So a Mon/Wed/Fri habit isn't 'missed' on a Tuesday."""
    n, d, limit = 0, today, today - datetime.timedelta(days=400)
    while d >= limit:
        di = d.isoformat()
        if is_due(sched, di):
            if di in dates and dates[di][0] > 0:
                n += 1
            elif di == today.isoformat():
                pass   # today due but not done yet — don't break
            else:
                break
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
    last = max(dates) if dates else None
    st, tc, direction = h["schedule_type"], h["target_count"], h["direction"]
    sched = h["schedule"]
    sk = sched.get("type", "daily")
    due_today = bool(is_due(sched, today.isoformat()))
    nd = today.isoformat() if due_today else next_due(sched, today)
    fulfilled = over = at_cap = False
    streak_val = 0
    if h["measured"]:
        # amount-based: summed measure over the (legacy-period) window vs target
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
        due_in_period = due_dates_in(sched, p_start, p_end)
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

lines = []
for h in habits[:LIMIT]:
    direction = h["direction"]
    st = h["schedule_type"]
    sk = (h.get("schedule") or {}).get("type", "daily")
    used, target = h["period_used"], h["period_target"]
    tgt = fmt(target) if target is not None else "—"
    tag = "·limit" if direction == "at_most" else ""
    head = f"- {h['name']} ({h.get('schedule_label', 'daily')}{tag}, {h['priority']}): "
    if h["measured"]:
        # amount-based: "2.5/4 L today ✅" — period word per schedule_type
        period_word = {"daily": "today", "weekly": "this week", "monthly": "this month"}.get(st, "today")
        unit = (" " + h["unit"]) if h["unit"] else ""
        if direction == "at_most":
            flag = " — OVER ⚠️" if h["over"] else (" — at cap" if h["at_cap"] else " ✅")
        else:
            flag = " ✅" if h["fulfilled"] else " ⏳"
        body = f"{fmt(used)}/{tgt}{unit} {period_word}{flag}"
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
    lines.append(head + body)
if len(habits) > LIMIT:
    lines.append(f"… +{len(habits) - LIMIT} more (showing top {LIMIT} by priority)")
print("\n".join(lines))
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
  python3 - "$@" <<'PYEOF'
import sys, os, re, json, sqlite3, datetime

HEADER = "| Habit | Criteria | Progress | Done | Count | Note |"
SEP    = "|-------|----------|----------|------|-------|------|"
DONE_TRUE = {"x", "yes", "y", "done", "true", "1", "✅", "✓"}

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
        out.append({"id": str(h.get("id", "")).strip() or slugify(name), "name": name,
                    "schedule_type": st, "direction": direction, "target_count": tc,
                    "priority": str(h.get("priority", "medium")).strip().lower(),
                    "unit": unit, "measure_target": mt, "measured": mt is not None,
                    "scoring": sc if isinstance(sc, dict) else None,
                    "archived": bool(h.get("archived"))})
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

def score_from_spec(spec, good=None, bad=None, slips=None):
    """Generic, deterministic habit-score evaluator. The habit's profile owns the
    rule (spec); the caller supplies only raw classification counts. Returns a
    float score, or None when the spec is unusable / no inputs were given.

    Supported spec type "slip_ladder":
      slips = given --slips, else max(bad, good_target - good)  (clamped >= 0)
      score = ladder[min(slips, len(ladder)-1)]
    'good_target' is optional (0 = no good-count requirement -> pure bad ladder).
    Nothing here is habit-specific: what counts as a good/bad unit is the
    caller's (model's) classification, not the code's."""
    if not isinstance(spec, dict):
        return None
    if str(spec.get("type", "slip_ladder")).strip() != "slip_ladder":
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
        # amount-based progress, e.g. "2.5/4 L wk" / "12/20 km mo" / "1.5/4 L day"
        unit = (" " + h["unit"]) if h["unit"] else ""
        tgt = fmtnum(h["measure_target"]) if h["measure_target"] is not None else "?"
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
    # over); a build reads how many days done so far this week (count is 1/day
    # for these, so the sum is a day-count).
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
            "for context. Unchecked habits are pruned at end of day.\n\n")

def parse_table(text):
    lines = text.splitlines()
    hi = None
    for i, l in enumerate(lines):
        if re.match(r"\s*\|\s*Habit\s*\|", l):
            hi = i
            break
    if hi is None:
        return text, [], ""
    j = hi + 2
    rows = []
    while j < len(lines) and lines[j].strip().startswith("|"):
        cells = [c.strip() for c in lines[j].strip().strip("|").split("|")]
        while len(cells) < 6:
            cells.append("")
        rows.append({"name": cells[0], "criteria": cells[1], "progress": cells[2],
                     "done": cells[3], "count": cells[4], "note": cells[5]})
        j += 1
    return "\n".join(lines[:hi]), rows, "\n".join(lines[j:])

def render(pre, rows, post):
    body = [HEADER, SEP]
    for r in rows:
        body.append(f"| {r['name']} | {r['criteria']} | {r['progress']} | {r['done']} | {r['count']} | {r['note']} |")
    out = pre.rstrip() + "\n\n" + "\n".join(body) + "\n"
    if post.strip():
        out += post.rstrip() + "\n"
    return out

def new_rows(habits, con, date):
    return [{"name": h["name"], "criteria": criteria_str(h), "progress": db_progress(con, h, date),
             "done": "", "count": "", "note": ""} for h in habits]

def mirror_rows(con, rows, date, by_name, now):
    # Mirror a parsed table's done rows into the DB for <date>: the DB must end
    # up matching exactly the md's done rows (so un-checking removes the event).
    done = []
    for r in rows:
        if not is_done(r["done"]):
            continue
        nm = r["name"].strip()
        if not nm:
            continue
        h = by_name.get(nm.lower())
        hid = (h["id"] if h else None) or slugify(nm)
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
        done.append((hid, nm, c, amount, (r["note"].strip() or None)))
    ids = [d[0] for d in done]
    if ids:
        con.execute("DELETE FROM habit_events WHERE occurred_on=? AND habit_id NOT IN (%s)"
                    % ",".join("?" * len(ids)), [date] + ids)
    else:
        con.execute("DELETE FROM habit_events WHERE occurred_on=?", (date,))
    for hid, nm, c, amount, note in done:
        con.execute(
            "INSERT INTO habit_events (habit_id,habit,occurred_on,count,amount,source,note,created_at) "
            "VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(habit_id,occurred_on) DO UPDATE SET "
            "count=excluded.count, amount=excluded.amount, habit=excluded.habit, "
            "source=excluded.source, note=excluded.note",
            (hid, nm, date, c, amount, "habit-tracking", note, now))
    return len(done)

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
        out = render(pre if pre.strip() else front(date).rstrip(), rows, post)
    else:
        out = front(date) + "\n".join([HEADER, SEP] + [
            f"| {r['name']} | {r['criteria']} | {r['progress']} | {r['done']} | {r['count']} | {r['note']} |"
            for r in new_rows(habits, con, date)]) + "\n"
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
    habits = load_habits(profile)
    active = {h["name"].strip().lower(): h for h in habits if not h["archived"]}
    byid = {h["id"]: h for h in habits if not h["archived"]}
    h = active.get(name.strip().lower()) or byid.get(name.strip().lower())
    if not h:
        print(f"not a tracked habit: {name.strip()} — add it with /habits (not marked)")
        sys.exit(0)
    # Scored habit: when the caller supplied classification counts, the score is
    # computed from the habit's profile rule — the caller never picks the number.
    g, b, sl = _to_int(good), _to_int(bad), _to_int(slips)
    if h.get("scoring") and (g is not None or b is not None or sl is not None):
        val = score_from_spec(h["scoring"], good=g, bad=b, slips=sl)
        if val is not None:
            amount = fmtnum(val)  # feed the measured-amount path below
    con = sqlite3.connect(db) if os.path.exists(db) else None
    if not os.path.exists(f):
        open(f, "w").write(front(date) + "\n".join([HEADER, SEP] + [
            f"| {r['name']} | {r['criteria']} | {r['progress']} | {r['done']} | {r['count']} | {r['note']} |"
            for r in new_rows([x for x in habits if not x["archived"]], con, date)]) + "\n")
    pre, rows, post = parse_table(open(f).read())
    if h["measured"]:
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
            r["done"] = "x"
            if cval:
                r["count"] = cval
            if note.strip():
                r["note"] = note.strip()
            found = True
            break
    if not found:
        rows.append({"name": h["name"], "criteria": criteria_str(h),
                     "progress": db_progress(con, h, date), "done": "x",
                     "count": cval, "note": note.strip()})
    # Mirror today's marks into the DB and recompute every row's Progress so the
    # file shows live numbers the instant a habit is marked (not a stale snapshot
    # from when the tracker was created).
    if con is not None:
        mirror_rows(con, rows, date, active, now)
        refresh_progress(con, rows, active, date)
        con.commit()
        con.close()
    open(f, "w").write(render(pre, rows, post))
    print(f"marked: {h['name']} on {date}")

elif op == "score":
    # Pure deterministic evaluator — compute a habit's score from its profile
    # rule + caller-supplied classification counts. No DB / md write. Prints the
    # numeric score (blank if the habit has no usable scoring spec).
    profile, name = sys.argv[2:4]
    good  = sys.argv[4] if len(sys.argv) > 4 else ""
    bad   = sys.argv[5] if len(sys.argv) > 5 else ""
    slips = sys.argv[6] if len(sys.argv) > 6 else ""
    habits = load_habits(profile)
    active = {h["name"].strip().lower(): h for h in habits if not h["archived"]}
    byid = {h["id"]: h for h in habits if not h["archived"]}
    h = active.get(name.strip().lower()) or byid.get(name.strip().lower())
    val = score_from_spec(h.get("scoring"), good=_to_int(good), bad=_to_int(bad),
                          slips=_to_int(slips)) if h else None
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
    # prune the day's file to only the habits actually done
    kept = [r for r in rows if is_done(r["done"])]
    open(f, "w").write(render(pre, kept, post))
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
    open(f, "w").write(render(pre, rows, post))
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
# habit (one with a unit + target) the amount is what's recorded.
pbrain_habit_mark() {  # <date> <name> [count] [note] [amount] [good] [bad] [slips]
  local date file
  date="${1:-$(date +%Y-%m-%d)}"
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  file="$(pbrain_habit_track_file "$date")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  _pbrain_habit_track_py mark "$(pbrain_habits_profile_file)" "$PBRAIN_DB_FILE" "$file" \
    "$date" "${2:-}" "${3:-1}" "${4:-}" "${5:-}" "$(date '+%Y-%m-%d %H:%M')" \
    "${6:-}" "${7:-}" "${8:-}"
}

# Compute (without writing) a scored habit's score from its profile rule + raw
# classification counts. Echoes the numeric score, or "" if not a scored habit.
pbrain_habit_score() {  # <name> [good] [bad] [slips]
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  _pbrain_habit_track_py score "$(pbrain_habits_profile_file)" \
    "${1:-}" "${2:-}" "${3:-}" "${4:-}"
}

# Mirror the last <days> days of tracking files into the DB (idempotent). Run by
# read commands so the DB reflects the md before querying. Dates with no md file
# are left untouched.
pbrain_habits_sync_range() {  # [days] [end_date]
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  local _end_date="${2:-$(date +%Y-%m-%d)}"
  _pbrain_habit_track_py sync "$(pbrain_habits_profile_file)" "$PBRAIN_DB_FILE" \
    "$(pbrain_habit_track_dir)" "$_end_date" "${1:-7}" "$(date '+%Y-%m-%d %H:%M')" >/dev/null 2>&1 || true
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
  [[ -n "${json//[[:space:]]/}" ]] || return 0

  names="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
out = []
for h in data.get("habits") or []:
    n = str(h.get("name", "")).strip()
    if not n or h.get("archived"):
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
' 2>/dev/null || true)"
  [[ -n "$names" ]] || return 0

  today="$(date +%Y-%m-%d)"
  cmd_path="$(pbrain_habits_cmd)"

  # Collect classification rules for scored habits (their profile notes), so the
  # model has exact good/bad definitions inline — not buried in the profile.
  local scored_rules
  scored_rules="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
out = []
for h in data.get("habits") or []:
    if h.get("archived"):
        continue
    if isinstance(h.get("scoring"), dict):
        n = str(h.get("name", "")).strip()
        notes = str(h.get("notes", "")).strip()
        if n and notes:
            out.append(f"  {n}: {notes}")
print("\n".join(out))
' 2>/dev/null || true)"

  printf '%s\n' ""
  printf '%s\n' "--- HABIT EXTRACTION ($cmd) ---"
  printf '%s\n' "Run this AFTER the command's main work, silently. Tracked habits:"
  printf '%s\n' "  $names"
  printf '%s\n' ""
  printf '%s\n' "If — and only if — the user evidenced any of these habits this session"
  printf '%s\n' "(did it, is about to, or explicitly skipped it), MARK each ONE TIME in"
  printf '%s\n' "today's tracking markdown with:"
  printf '%s\n' "  bash \"$cmd_path\" mark --name \"<exact habit name>\" --date $today [--count N] [--amount X] [--note \"...\"]"
  printf '%s\n' "For a habit tagged [measured: …] above, pass the quantity with --amount (e.g."
  printf '%s\n' "--amount 2.5 for 2.5 L of water); plain habits need no count/amount at all."
  printf '%s\n' ""
  printf '%s\n' "For a habit tagged [scored] above, DO NOT choose the amount/score yourself —"
  printf '%s\n' "the number is computed deterministically from the habit's rule in your"
  printf '%s\n' "profile. Your ONLY job is to classify and pass the raw counts:"
  printf '%s\n' "  bash \"$cmd_path\" mark --name \"<exact name>\" --date $today --good <N> --bad <N> [--note \"...\"]"
  printf '%s\n' "where --good = qualifying units (e.g. clean home-cooked meals) and --bad ="
  printf '%s\n' "slip units (e.g. outside/junk meals). habits.sh applies the profile formula."
  printf '%s\n' "(If you've already reduced it to one slip count, pass --slips <N> instead.)"
  if [[ -n "${scored_rules//[[:space:]]/}" ]]; then
    printf '%s\n' "Classification rules per scored habit — use EXACTLY these definitions to count"
    printf '%s\n' "good/bad units; every eating occasion counts (snacks included), not just mains:"
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
  printf '%s\n' "Whether or not they accept, record the suggestion so it isn't re-nagged:"
  printf '%s\n' "  bash \"$cmd_path\" suggest-seen --name \"<X>\""
  printf '%s\n' "If the user has told you they don't want habit suggestions, skip this."
  printf '%s\n' "--- END HABIT SUGGEST ---"
  return 0
}
