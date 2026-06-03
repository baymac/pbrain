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
  python3 - "$profile" "$db" "$today" <<'PYEOF' 2>/dev/null || printf '%s\n' "{}"
import json, re, sys, sqlite3, datetime, os
profile, db, today_s = sys.argv[1], sys.argv[2], sys.argv[3]

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
    return {"id": hid, "name": name, "schedule_type": st, "direction": direction,
            "target_count": tc, "priority": prio,
            "archived": bool(h.get("archived")), "notes": str(h.get("notes", "")).strip()}

habits = [norm(h) for h in (data.get("habits") or []) if str(h.get("name", "")).strip()]
active = [h for h in habits if not h["archived"]]

today = datetime.date.fromisoformat(today_s)
week_start = today - datetime.timedelta(days=today.weekday())     # Monday
week_end = week_start + datetime.timedelta(days=6)
month_start = today.replace(day=1)
lookback = today - datetime.timedelta(days=400)                   # bounds the streak scan

# Single windowed query for every active habit; aggregate per-habit in python.
events = {}  # id -> {date_iso: count}
ids = [h["id"] for h in active]
if ids and os.path.exists(db):
    try:
        con = sqlite3.connect(db, timeout=5)
        con.execute("PRAGMA busy_timeout=5000")
        q = ("SELECT habit_id, occurred_on, count FROM habit_events "
             "WHERE habit_id IN (%s) AND occurred_on>=? AND occurred_on<=?"
             % ",".join("?" * len(ids)))
        for hid, d, c in con.execute(q, ids + [lookback.isoformat(), today.isoformat()]):
            events.setdefault(hid, {})
            events[hid][d] = events[hid].get(d, 0) + (c or 0)
        con.close()
    except Exception:
        events = {}

def in_range(dates, start, end):
    s, e = start.isoformat(), end.isoformat()
    return sum(c for d, c in dates.items() if s <= d <= e)

def streak(dates):
    if not dates:
        return 0
    cur = today
    if cur.isoformat() not in dates:        # not done today → streak runs up to yesterday
        cur = cur - datetime.timedelta(days=1)
    n = 0
    while cur.isoformat() in dates:
        n += 1
        cur = cur - datetime.timedelta(days=1)
    return n

prio_rank = {"high": 0, "medium": 1, "low": 2}
out = []
for h in active:
    dates = events.get(h["id"], {})
    today_count = dates.get(today.isoformat(), 0)
    week_count = in_range(dates, week_start, week_end)
    month_count = in_range(dates, month_start, today)
    last = max(dates) if dates else None
    st, tc, direction = h["schedule_type"], h["target_count"], h["direction"]
    if st == "daily":
        used, target = today_count, (tc if tc else 1)
    elif st == "weekly":
        used, target = week_count, tc
    else:
        used, target = month_count, tc
    fulfilled = over = at_cap = False
    if direction == "at_most":
        if target is not None:
            over, at_cap, fulfilled = used > target, used == target, used <= target
    else:
        fulfilled = (used >= target) if target is not None else (used > 0)
    row = dict(h)
    row.update({"today_count": today_count, "week_count": week_count,
                "month_count": month_count, "period_used": used, "period_target": target,
                "last_done": last, "streak": streak(dates) if st == "daily" else 0,
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
lines = []
for h in habits[:LIMIT]:
    st, direction = h["schedule_type"], h["direction"]
    used, target = h["period_used"], h["period_target"]
    tgt = target if target is not None else "—"
    tag = "·limit" if direction == "at_most" else ""
    head = f"- {h['name']} ({st}{tag}, {h['priority']}): "
    if st == "daily":
        if direction == "at_most":
            body = f"{h['today_count']} today" + (" — OVER ⚠️" if h["over"] else "")
        else:
            body = ("done today ✅" if h["today_count"] > 0 else "not yet today ⏳")
            body += f" · {h['week_count']}/7 this week"
            if h["streak"] > 0:
                body += f" · streak {h['streak']}"
    else:
        period_word = "this week" if st == "weekly" else "this month"
        if direction == "at_most":
            flag = " — OVER ⚠️" if h["over"] else (" — at cap" if h["at_cap"] else " ✅")
        else:
            flag = " ✅" if h["fulfilled"] else " ⏳"
        body = f"{used}/{tgt} {period_word}{flag}"
    last = h["last_done"]
    body += f" · last {last}" if last else " · never logged"
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
#   mark        <profile> <db> <file> <date> <name> <count> <note>
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
        out.append({"id": str(h.get("id", "")).strip() or slugify(name), "name": name,
                    "schedule_type": st, "direction": direction, "target_count": tc,
                    "priority": str(h.get("priority", "medium")).strip().lower(),
                    "archived": bool(h.get("archived"))})
    return out

def criteria_str(h):
    st = h["schedule_type"]
    if st == "daily":
        return "daily (limit)" if h["direction"] == "at_most" else "daily"
    sym = "≤" if h["direction"] == "at_most" else "≥"
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
    def cnt(start):
        row = con.execute("SELECT COALESCE(SUM(count),0) FROM habit_events "
                          "WHERE habit_id=? AND occurred_on>=? AND occurred_on<=?",
                          (h["id"], start.isoformat(), today.isoformat())).fetchone()
        return row[0] if row else 0
    st = h["schedule_type"]; tc = h["target_count"]
    if st == "weekly":
        return f"{cnt(week_start)}/{tc if tc is not None else '?'} wk"
    if st == "monthly":
        return f"{cnt(month_start)}/{tc if tc is not None else '?'} mo"
    return f"{cnt(week_start)}/7 wk"

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

def sync_one(con, f, date, name2id, now):
    if not os.path.exists(f):
        return 0
    _, rows, _ = parse_table(open(f).read())
    done = []
    for r in rows:
        if not is_done(r["done"]):
            continue
        nm = r["name"].strip()
        if not nm:
            continue
        hid = name2id.get(nm.lower()) or slugify(nm)
        try:
            c = max(1, int(r["count"])) if str(r["count"]).strip() else 1
        except (TypeError, ValueError):
            c = 1
        done.append((hid, nm, c, (r["note"].strip() or None)))
    ids = [d[0] for d in done]
    # mirror: the DB for this date must match the md's done rows
    if ids:
        con.execute("DELETE FROM habit_events WHERE occurred_on=? AND habit_id NOT IN (%s)"
                    % ",".join("?" * len(ids)), [date] + ids)
    else:
        con.execute("DELETE FROM habit_events WHERE occurred_on=?", (date,))
    for hid, nm, c, note in done:
        con.execute(
            "INSERT INTO habit_events (habit_id,habit,occurred_on,count,source,note,created_at) "
            "VALUES (?,?,?,?,?,?,?) ON CONFLICT(habit_id,occurred_on) DO UPDATE SET "
            "count=excluded.count, habit=excluded.habit, source=excluded.source, note=excluded.note",
            (hid, nm, date, c, "habit-tracking", note, now))
    return len(done)

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
    profile, db, f, date, name, count, note = sys.argv[2:9]
    habits = load_habits(profile)
    active = {h["name"].strip().lower(): h for h in habits if not h["archived"]}
    byid = {h["id"]: h for h in habits if not h["archived"]}
    h = active.get(name.strip().lower()) or byid.get(name.strip().lower())
    if not h:
        print(f"not a tracked habit: {name.strip()} — add it with /habits (not marked)")
        sys.exit(0)
    con = sqlite3.connect(db) if os.path.exists(db) else None
    if not os.path.exists(f):
        open(f, "w").write(front(date) + "\n".join([HEADER, SEP] + [
            f"| {r['name']} | {r['criteria']} | {r['progress']} | {r['done']} | {r['count']} | {r['note']} |"
            for r in new_rows([x for x in habits if not x["archived"]], con, date)]) + "\n")
    pre, rows, post = parse_table(open(f).read())
    try:
        cval = str(max(1, int(count)))
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
    if con:
        con.close()
    open(f, "w").write(render(pre, rows, post))
    print(f"marked: {h['name']} on {date}")

elif op == "sync":
    profile, db, trackdir, end_date, days, now = sys.argv[2:8]
    if not os.path.exists(db):
        print("synced 0")
        sys.exit(0)
    habits = load_habits(profile)
    name2id = {h["name"].strip().lower(): h["id"] for h in habits}
    end = datetime.date.fromisoformat(end_date)
    con = sqlite3.connect(db)
    con.execute("PRAGMA busy_timeout=5000")
    total = 0
    for n in range(int(days) + 1):
        d = (end - datetime.timedelta(days=n)).isoformat()
        total += sync_one(con, os.path.join(trackdir, d + ".md"), d, name2id, now)
    con.commit()
    con.close()
    print(f"synced {total}")

elif op == "consolidate":
    profile, db, f, date, now = sys.argv[2:7]
    habits = load_habits(profile)
    name2id = {h["name"].strip().lower(): h["id"] for h in habits}
    if os.path.exists(db):
        con = sqlite3.connect(db)
        con.execute("PRAGMA busy_timeout=5000")
        sync_one(con, f, date, name2id, now)
        con.commit()
        con.close()
    # prune the day's file to only the habits actually done
    if os.path.exists(f):
        pre, rows, post = parse_table(open(f).read())
        kept = [r for r in rows if is_done(r["done"])]
        open(f, "w").write(render(pre, kept, post))
    print("consolidated")
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
# names that aren't a tracked habit. count/note optional.
pbrain_habit_mark() {  # <date> <name> [count] [note]
  local date file
  date="${1:-$(date +%Y-%m-%d)}"
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  file="$(pbrain_habit_track_file "$date")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  _pbrain_habit_track_py mark "$(pbrain_habits_profile_file)" "$PBRAIN_DB_FILE" "$file" \
    "$date" "${2:-}" "${3:-1}" "${4:-}"
}

# Mirror the last <days> days of tracking files into the DB (idempotent). Run by
# read commands so the DB reflects the md before querying. Dates with no md file
# are left untouched.
pbrain_habits_sync_range() {  # [days]
  [[ -f "$(pbrain_habits_profile_file)" ]] || return 0
  _pbrain_habit_track_py sync "$(pbrain_habits_profile_file)" "$PBRAIN_DB_FILE" \
    "$(pbrain_habit_track_dir)" "$(date +%Y-%m-%d)" "${1:-7}" "$(date '+%Y-%m-%d %H:%M')" >/dev/null 2>&1 || true
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
    if not n:
        continue
    kind = str(h.get("kind", "build")).strip().lower()
    out.append(f"{n} [{kind}]")
print(" | ".join(out))
' 2>/dev/null || true)"
  [[ -n "$names" ]] || return 0

  today="$(date +%Y-%m-%d)"
  cmd_path="$(pbrain_habits_cmd)"

  printf '%s\n' ""
  printf '%s\n' "--- HABIT EXTRACTION ($cmd) ---"
  printf '%s\n' "Run this AFTER the command's main work, silently. Tracked habits:"
  printf '%s\n' "  $names"
  printf '%s\n' ""
  printf '%s\n' "If — and only if — the user evidenced any of these habits this session"
  printf '%s\n' "(did it, is about to, or explicitly skipped it), MARK each ONE TIME in"
  printf '%s\n' "today's tracking markdown with:"
  printf '%s\n' "  bash \"$cmd_path\" mark --name \"<exact habit name>\" --date $today [--count N] [--note \"...\"]"
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
  printf '%s\n' "  bash \"$cmd_path\" add --name \"<X>\" --type daily|weekly|monthly --direction at_least|at_most [--target N] [--priority low|medium|high]"
  printf '%s\n' "Whether or not they accept, record the suggestion so it isn't re-nagged:"
  printf '%s\n' "  bash \"$cmd_path\" suggest-seen --name \"<X>\""
  printf '%s\n' "If the user has told you they don't want habit suggestions, skip this."
  printf '%s\n' "--- END HABIT SUGGEST ---"
  return 0
}
