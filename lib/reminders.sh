#!/usr/bin/env bash
# pbrain reminders helper — sourced by lib/vault.sh (after db.sh).
#
# Reminders live in the shared SQLite DB (lib/db.sh). The /remind command owns
# create / list / complete / tick / install; this helper provides the pieces
# reused by /plan-my-day and /end-of-day (surfacing + opportunistic firing) and
# the notification primitive.
#
# Defines:
#   pbrain_notify <title> <message>     fire a macOS notification, injection-safe, best-effort
#   pbrain_notify_build                 compile pbrain-notify.app from lib/pbrain-notify.swift (idempotent)
#   pbrain_reminders_cmd                echo abs path to commands/remind.sh
#   pbrain_reminders_tick               fire any due-and-unfired reminders now (advances repeats)
#   pbrain_reminders_pending_text       text list of pending reminders (overdue/fired marked) for surfacing
#
# Like the other lib/ helpers, this NEVER exits non-zero — it is sourced into
# commands under `set -euo pipefail`.

# Where the compiled notifier app lives. It's a per-machine build artifact (like
# the DB), NOT in the vault or the source tree — it sits beside the configs in
# ~/.config/pbrain. Override with PBRAIN_NOTIFY_APP.
PBRAIN_NOTIFY_APP="${PBRAIN_NOTIFY_APP:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/pbrain-notify.app}"
export PBRAIN_NOTIFY_APP

# Build (or rebuild) pbrain-notify.app from the checked-in Swift source. This is
# our own minimal terminal-notifier: a real app bundle whose stable identity lets
# notifications fire reliably even from the launchd poller, where osascript gets
# silently dropped (no trusted calling app). See lib/pbrain-notify.swift.
#
# Idempotent + best-effort: rebuilds only when the binary is missing or older than
# the source; a missing swiftc or a compile failure just leaves the app absent and
# pbrain_notify falls back to osascript. Never exits non-zero, never prints.
pbrain_notify_build() {
  command -v swiftc >/dev/null 2>&1 || return 0
  local lib_dir src bin
  lib_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 0
  src="$lib_dir/pbrain-notify.swift"
  [[ -f "$src" ]] || return 0
  bin="$PBRAIN_NOTIFY_APP/Contents/MacOS/pbrain-notify"
  # Up to date? binary exists and is at least as new as the source.
  [[ -x "$bin" && ! "$src" -nt "$bin" ]] && return 0
  mkdir -p "$PBRAIN_NOTIFY_APP/Contents/MacOS" 2>/dev/null || return 0
  # Static bundle metadata — written once. The runtime identity is set by the
  # binary itself (it impersonates com.apple.Terminal); CFBundleIdentifier here
  # only gives the bundle a clean structure and keeps the UN path open later.
  if [[ ! -f "$PBRAIN_NOTIFY_APP/Contents/Info.plist" ]]; then
    cat > "$PBRAIN_NOTIFY_APP/Contents/Info.plist" 2>/dev/null <<'PLIST' || return 0
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.pbrain.notify</string>
  <key>CFBundleName</key><string>pbrain-notify</string>
  <key>CFBundleExecutable</key><string>pbrain-notify</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSUserNotificationAlertStyle</key><string>alert</string>
</dict>
</plist>
PLIST
  fi
  # Compile to a temp path in the same dir, then atomic-rename into place so a
  # concurrent poller never executes a half-written binary.
  local tmp="$bin.tmp.$$"
  if swiftc -suppress-warnings "$src" -o "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$bin" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# Fire a macOS notification (best-effort). Title + message reach the notifier as
# argv — NEVER interpolated into an interpreted string — so arbitrary reminder
# text (quotes, backslashes, $, …) can never break or inject.
#
# Preferred path: our own bundled notifier (pbrain-notify.app), which carries a
# real app-bundle identity so notifications fire reliably even from the launchd
# poller. Fallback: osascript, which works from an interactive terminal/app that
# already has notification permission but is dropped from launchd — better than
# nothing when swiftc is unavailable to build the app.
pbrain_notify() {
  local title="${1:-pbrain}" msg="${2:-}"
  pbrain_notify_build
  local bin="$PBRAIN_NOTIFY_APP/Contents/MacOS/pbrain-notify"
  if [[ -x "$bin" ]]; then
    # PBRAIN_NOTIFY_IDENTITY (if set, even to empty) overrides the borrowed
    # bundle identity; empty disables the swizzle (deliver as com.pbrain.notify).
    if [[ -n "${PBRAIN_NOTIFY_IDENTITY+x}" ]]; then
      "$bin" --bundle-id "$PBRAIN_NOTIFY_IDENTITY" --title "$title" --message "$msg" >/dev/null 2>&1 && return 0
    else
      "$bin" --title "$title" --message "$msg" >/dev/null 2>&1 && return 0
    fi
  fi
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

# Like pbrain_notify but for reminder notifications — passes --id and --db so the
# binary can enable Snooze / Cancel action buttons and update the DB on click.
# Runs the binary async (background &) so the tick loop is never blocked by the
# 30-second interaction window. Falls back to pbrain_notify if the binary is absent.
pbrain_notify_reminder() {
  local rid="${1:-}" msg="${2:-}"
  pbrain_notify_build
  local bin="$PBRAIN_NOTIFY_APP/Contents/MacOS/pbrain-notify"
  if [[ -x "$bin" ]]; then
    local extra_id_args=(--id "$rid" --db "$PBRAIN_DB_FILE")
    if [[ -n "${PBRAIN_NOTIFY_IDENTITY+x}" ]]; then
      "$bin" --bundle-id "$PBRAIN_NOTIFY_IDENTITY" "${extra_id_args[@]}" \
             --title "Reminder" --message "$msg" >/dev/null 2>&1 &
    else
      "$bin" "${extra_id_args[@]}" --title "Reminder" --message "$msg" >/dev/null 2>&1 &
    fi
    return 0
  fi
  pbrain_notify "Reminder" "$msg" || true
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
  while IFS=$'\t' read -r rid rtext; do
    [[ -n "$rtext" ]] || continue
    pbrain_notify_reminder "$rid" "$rtext"
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
        "SELECT id, text, due_at, repeat, fired_at FROM reminders WHERE status='pending' "
        "ORDER BY (due_at IS NULL), due_at"
    ).fetchall()
    con.close()
except Exception:
    sys.exit(0)

lines = []
for rid, text, due_at, repeat, fired_at in rows:
    rep = f" (repeats {repeat})" if repeat else ""
    dt = parse_due(due_at)
    if dt is None:
        lines.append(f"- [#{rid}] {text} — someday{rep}")
        continue
    d = dt.date()
    when = due_at
    if fired_at:
        # Already notified (a one-shot that fired) but not marked done yet, so it
        # stays pending; do not keep reading it as OVERDUE. (A repeat clears
        # fired_at as it rolls forward, so this branch only hits one-shots.)
        tag = "fired — mark done"
    elif d < today or (d == today and dt <= now):
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
