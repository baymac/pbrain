#!/usr/bin/env bash
# pbrain reminders helper — sourced by lib/vault.sh (after db.sh).
#
# Reminders live in the shared SQLite DB (lib/db.sh). The /remind command owns
# create / list / complete / tick / install; this helper provides the pieces
# reused by /plan-my-day and /end-of-day (surfacing + opportunistic firing) and
# the notification primitive.
#
# Defines:
#   pbrain_notify <title> <message>     macOS notification (osascript), injection-safe, best-effort
#   pbrain_reminders_cmd                echo abs path to commands/remind.sh
#   pbrain_reminders_tick               fire any due-and-unfired reminders now (advances repeats)
#   pbrain_reminders_pending_text       text list of pending reminders (overdue marked) for surfacing
#
# Like the other lib/ helpers, this NEVER exits non-zero — it is sourced into
# commands under `set -euo pipefail`.

# Fire a macOS notification. Title + message are passed to osascript as argv
# (NOT interpolated into the AppleScript source), so arbitrary reminder text —
# quotes, backslashes, etc. — can never break or inject into the script.
pbrain_notify() {
  local title="${1:-pbrain}" msg="${2:-}"
  command -v osascript >/dev/null 2>&1 || return 0
  osascript - "$title" "$msg" >/dev/null 2>&1 <<'APPLESCRIPT' || true
on run argv
  set theTitle to item 1 of argv
  set theMsg to item 2 of argv
  display notification theMsg with title theTitle
end run
APPLESCRIPT
  return 0
}

# Absolute path to the /remind command script (sibling of this lib dir).
pbrain_reminders_cmd() {
  local lib_dir repo_dir
  lib_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  repo_dir="$(cd -P -- "$lib_dir/.." && pwd -P)"
  printf '%s\n' "$repo_dir/commands/remind.sh"
}

# Fire notifications for every reminder that is due now and hasn't fired yet.
# Selection + marking happen in a single IMMEDIATE transaction so two concurrent
# ticks (e.g. the launchd poller racing a /plan-my-day run) can't double-fire.
# One-shot reminders get fired_at stamped (so they won't fire again, but stay
# pending until the user marks them done). Repeating reminders advance due_at to
# the next occurrence and clear fired_at so the next cycle is eligible.
pbrain_reminders_tick() {
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -f "$PBRAIN_DB_FILE" ]] || return 0
  local now due
  now="$(date '+%Y-%m-%d %H:%M')"
  due="$(python3 - "$PBRAIN_DB_FILE" "$now" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys, datetime
db, now_s = sys.argv[1], sys.argv[2]
now = datetime.datetime.strptime(now_s, "%Y-%m-%d %H:%M")

DATE_ONLY_HOUR = 9  # a date with no time is treated as ~9am local

def parse_due(s):
    if not s:
        return None
    s = s.strip()
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%d %H:%M")
    except ValueError:
        pass
    try:
        # date-only YYYY-MM-DD: anchor to a sensible morning hour so it does
        # not fire or read as overdue at local midnight.
        return datetime.datetime.strptime(s, "%Y-%m-%d").replace(hour=DATE_ONLY_HOUR)
    except ValueError:
        return None

def add_month(dt):
    # same day next month, clamped to month length
    y, m = dt.year, dt.month + 1
    if m > 12:
        y, m = y + 1, 1
    import calendar
    d = min(dt.day, calendar.monthrange(y, m)[1])
    return dt.replace(year=y, month=m, day=d)

def next_occurrence(dt, repeat):
    repeat = (repeat or "").lower()
    if repeat == "daily":
        return dt + datetime.timedelta(days=1)
    if repeat == "weekly":
        return dt + datetime.timedelta(days=7)
    if repeat == "weekdays":
        nxt = dt + datetime.timedelta(days=1)
        while nxt.weekday() >= 5:  # Sat=5, Sun=6
            nxt += datetime.timedelta(days=1)
        return nxt
    if repeat == "monthly":
        return add_month(dt)
    return None

try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    con.isolation_level = None
    con.execute("BEGIN IMMEDIATE")
    rows = con.execute(
        "SELECT id, text, due_at, repeat FROM reminders "
        "WHERE status='pending' AND due_at IS NOT NULL AND fired_at IS NULL"
    ).fetchall()
    fired = []
    for rid, text, due_at, repeat in rows:
        dt = parse_due(due_at)
        if dt is None or dt > now:
            continue
        fired.append((rid, text))
        nxt = next_occurrence(dt, repeat)
        if nxt is not None:
            # Roll forward PAST now so a reminder that missed several cycles
            # (laptop asleep, or just after install) fires once here and lands on
            # its next FUTURE occurrence, instead of one ping per missed cycle
            # across successive ticks. Daily and weekly jump arithmetically so an
            # ancient backlog does not need thousands of steps; the bounded loop
            # then finalises weekdays/monthly and guarantees a strictly-future
            # result. The guard caps the loop in case next_occurrence ever fails
            # to advance; it cannot for these repeat types.
            rl = (repeat or "").lower()
            if rl == "daily" and nxt <= now:
                nxt = nxt + datetime.timedelta(days=(now.date() - nxt.date()).days)
            elif rl == "weekly" and nxt <= now:
                nxt = nxt + datetime.timedelta(weeks=((now - nxt).days // 7))
            guard = 0
            while nxt <= now and guard < 100000:
                adv = next_occurrence(nxt, repeat)
                if adv is None or adv <= nxt:
                    break
                nxt = adv
                guard += 1
            # keep the original time-of-day; carry the same string precision
            fmt = "%Y-%m-%d %H:%M" if (" " in (due_at or "")) else "%Y-%m-%d"
            con.execute(
                "UPDATE reminders SET due_at=?, fired_at=NULL WHERE id=?",
                (nxt.strftime(fmt), rid),
            )
        else:
            con.execute(
                "UPDATE reminders SET fired_at=? WHERE id=?", (now_s, rid)
            )
    con.execute("COMMIT")
    con.close()
    for rid, text in fired:
        print(f"{rid}\t{text}")
except Exception:
    pass
PYEOF
)"
  [[ -n "$due" ]] || return 0
  while IFS=$'\t' read -r _rid rtext; do
    [[ -n "$rtext" ]] || continue
    pbrain_notify "Reminder" "$rtext"
  done <<< "$due"
  return 0
}

# Print pending reminders as a human-readable list, overdue ones marked. Used by
# /plan-my-day and /end-of-day to surface what's outstanding. Prints nothing if
# there are none (caller treats empty as "no reminders").
pbrain_reminders_pending_text() {
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -f "$PBRAIN_DB_FILE" ]] || return 0
  local now
  now="$(date '+%Y-%m-%d %H:%M')"
  python3 - "$PBRAIN_DB_FILE" "$now" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys, datetime
db, now_s = sys.argv[1], sys.argv[2]
now = datetime.datetime.strptime(now_s, "%Y-%m-%d %H:%M")
today = now.date()

DATE_ONLY_HOUR = 9  # a date with no time is treated as ~9am local

def parse_due(s):
    if not s:
        return None
    s = s.strip()
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%d %H:%M")
    except ValueError:
        pass
    try:
        # date-only YYYY-MM-DD: anchor to a sensible morning hour so it does
        # not fire or read as overdue at local midnight.
        return datetime.datetime.strptime(s, "%Y-%m-%d").replace(hour=DATE_ONLY_HOUR)
    except ValueError:
        return None

try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    rows = con.execute(
        "SELECT id, text, due_at, repeat FROM reminders WHERE status='pending' "
        "ORDER BY (due_at IS NULL), due_at"
    ).fetchall()
    con.close()
except Exception:
    sys.exit(0)

lines = []
for rid, text, due_at, repeat in rows:
    rep = f" (repeats {repeat})" if repeat else ""
    dt = parse_due(due_at)
    if dt is None:
        lines.append(f"- [#{rid}] {text} — someday{rep}")
        continue
    d = dt.date()
    when = due_at
    if d < today or (d == today and dt <= now):
        tag = "OVERDUE"
    elif d == today:
        tag = "today"
    else:
        days = (d - today).days
        tag = "tomorrow" if days == 1 else f"in {days} days"
    lines.append(f"- [#{rid}] {text} — due {when} ({tag}){rep}")

if lines:
    print("\n".join(lines))
PYEOF
}
