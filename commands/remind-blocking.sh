#!/usr/bin/env bash
set -euo pipefail

# remind-blocking.sh — reminders that fire as a FULL-SCREEN BLOCKING overlay.
#
# Same scheduling engine as /remind (the shared reminders table + the launchd
# poller), but instead of a dismissible notification these fire a hard-to-skip
# "Take a break"-style overlay: an opaque window across every display, above the
# menu bar and Dock, with a big message and an optional MM:SS countdown. The only
# way out is to HOLD THE CONTROL KEY for a few seconds, or let the countdown run
# out. The overlay app is pbrain-overlay.app, compiled on demand from
# lib/pbrain-overlay.swift (pbrain_overlay_build); see lib/reminders.sh.
#
# Blocking reminders live in two tables: reminder_schedules (a recurring SERIES,
# cron-defined) and reminders (per-occurrence instances; one-shots have a NULL
# schedule_id). /remind is Apple Calendar-only now (Calendar fires its own
# reminders), so the launchd poller exists SOLELY for blocking overlays — they
# can't ride Calendar — and this command owns it (install/uninstall/tick).
#
# An occurrence resolves to: skipped (held Control), done (waited out the
# countdown — the ONLY path to done), or missed (Mac slept/locked, or it came due
# while asleep/locked past the grace window). A series survives missed/skipped
# occurrences; only cancelling the series stops it.
#
# Subcommands (the Claude-facing API; humans type natural language and the
# /remind-blocking command translates):
#   remind-blocking.sh add --text "..." (--due "YYYY-MM-DD HH:MM"  ←one-shot
#                                        | --cron "<5-field expr>") ←recurring series
#                          [--duration <seconds>] [--hold <seconds>] [--source X]
#                            cron:     5-field cron (min hour dom month dow). Exactly one of --due/--cron.
#                            duration: how long the overlay stays / counts down (0 = until skipped). default 0.
#                            hold:     seconds of Control-key hold needed to skip. default 5.
#                          echoes a handle: S<id> (series) or R<id> (one-shot).
#   remind-blocking.sh list                 # active series (S<id>) + pending one-shots (R<id>)
#   remind-blocking.sh cancel <handle> ...  # S<id> stops a series; R<id> or <id> a one-shot
#   remind-blocking.sh test [--text "..."] [--duration N] [--hold N] [--background <hex>]  # show one NOW
#   remind-blocking.sh tick                 # fire anything due now (run by the poller)
#   remind-blocking.sh install | uninstall  # background launchd poller (owned here)
#   remind-blocking.sh help
#   remind-blocking.sh <natural language>   # entry path → emits intent block for Claude
#
# Overrides:
#   PBRAIN_DB_FILE         — SQLite DB path (default ~/.config/pbrain/pbrain.db)
#   PBRAIN_OVERLAY_APP     — compiled overlay app (default ~/.config/pbrain/pbrain-overlay.app)
#   PBRAIN_OVERLAY_BG      — default overlay background colour (hex, e.g. "#1e3a5f")

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
SELF="$_SCRIPT_DIR/remind-blocking.sh"
_LIB_DIR="$(cd -P -- "$_SCRIPT_DIR/../lib" && pwd -P)"

SUB="${1:-}"
PLIST="$HOME/Library/LaunchAgents/com.pbrain.reminders.plist"

# ---------------------------------------------------------------------------
# tick — shared poller path. Decoupled from vault.sh on purpose (same as
# remind.sh tick): only needs the DB + tick helper, must not die without a vault.
# ---------------------------------------------------------------------------
if [[ "$SUB" == "tick" ]]; then
  # shellcheck source=../lib/db.sh
  [[ -f "$_LIB_DIR/db.sh" ]] && source "$_LIB_DIR/db.sh" || true
  # shellcheck source=../lib/reminders.sh
  [[ -f "$_LIB_DIR/reminders.sh" ]] && source "$_LIB_DIR/reminders.sh" || true
  pbrain_db_init || true
  pbrain_reminders_tick || true
  exit 0
fi

# All other subcommands go through the normal command harness (prefs, helpers).
source "$_SCRIPT_DIR/../lib/vault.sh"
pbrain_emit_prefs "remind-blocking" || true
pbrain_db_init || true

NOW_DT="$(date '+%Y-%m-%d %H:%M')"
NOW_ISO="$(date '+%Y-%m-%dT%H:%M')"
TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%A)"

agent_installed() { [[ -f "$PLIST" ]] && echo yes || echo no; }

case "$SUB" in
  # -------------------------------------------------------------------------
  add)
    shift || true
    R_TEXT=""; R_DUE=""; R_SOURCE="remind-blocking"; R_DURATION="0"; R_HOLD="5"; R_CRON=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --text)     R_TEXT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --due)      R_DUE="${2:-}"; shift 2 2>/dev/null || shift ;;
        --cron)     R_CRON="${2:-}"; shift 2 2>/dev/null || shift ;;
        --duration) R_DURATION="${2:-0}"; shift 2 2>/dev/null || shift ;;
        --hold)     R_HOLD="${2:-5}"; shift 2 2>/dev/null || shift ;;
        --source)   R_SOURCE="${2:-remind-blocking}"; shift 2 2>/dev/null || shift ;;
        *) shift ;;
      esac
    done
    if [[ -z "${R_TEXT//[[:space:]]/}" ]]; then
      echo "remind-blocking: add requires --text" >&2
      exit 1
    fi
    # A blocking reminder is EITHER recurring (--cron, a series) or one-shot
    # (--due). Exactly one is required — a blocking overlay is time-sensitive, so
    # there is no "someday".
    if [[ -n "${R_CRON//[[:space:]]/}" && -n "${R_DUE//[[:space:]]/}" ]]; then
      echo "remind-blocking: pass EITHER --cron (recurring) OR --due (one-shot), not both." >&2
      exit 1
    fi
    if [[ -z "${R_CRON//[[:space:]]/}" && -z "${R_DUE//[[:space:]]/}" ]]; then
      echo "remind-blocking: add needs --due 'YYYY-MM-DD HH:MM' (one-shot) or --cron '<5-field expr>' (recurring)." >&2
      exit 1
    fi
    # duration / hold must be non-negative integers (seconds).
    if ! [[ "$R_DURATION" =~ ^[0-9]+$ ]]; then
      echo "remind-blocking: --duration must be a whole number of seconds (got: $R_DURATION)." >&2
      exit 1
    fi
    if ! [[ "$R_HOLD" =~ ^[0-9]+$ ]] || [[ "$R_HOLD" -lt 1 ]]; then
      echo "remind-blocking: --hold must be a whole number of seconds >= 1 (got: $R_HOLD)." >&2
      exit 1
    fi
    # Recurring: compute the first fire from the cron expr (also validates it).
    if [[ -n "${R_CRON//[[:space:]]/}" ]]; then
      CRON_DUE="$(pbrain_cron_next "$R_CRON" "$NOW_DT" || true)"
      if [[ -z "${CRON_DUE//[[:space:]]/}" ]]; then
        echo "remind-blocking: invalid --cron '$R_CRON'. Need 5 fields: 'min hour day-of-month month day-of-week' (e.g. '0 14,17 * * 2,6'). Nothing was set." >&2
        exit 1
      fi
      R_DUE="$CRON_DUE"
    else
      # One-shot: validate the due format. Only 'YYYY-MM-DD HH:MM' / 'YYYY-MM-DD'.
      if ! python3 - "$R_DUE" <<'PYEOF' 2>/dev/null
import sys, datetime
s = sys.argv[1].strip()
for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d"):
    try:
        datetime.datetime.strptime(s, fmt)
        sys.exit(0)
    except ValueError:
        continue
sys.exit(1)
PYEOF
      then
        echo "remind-blocking: --due must be 'YYYY-MM-DD HH:MM' or 'YYYY-MM-DD' (got: $R_DUE). Reminder NOT set." >&2
        exit 1
      fi
    fi
    # Insert: a recurring --cron creates a reminder_schedules series + its first
    # pending instance; a one-shot --due creates a single instance (schedule_id
    # NULL). Echoes the handle to reference it by: S<id> (series) or R<id> (one-shot).
    NEW_ID="$(python3 - "$PBRAIN_DB_FILE" "$R_TEXT" "$R_DUE" "$R_CRON" "$R_SOURCE" "$NOW_DT" "$R_DURATION" "$R_HOLD" <<'PYEOF'
import sqlite3, sys
db, text, due, cron, source, now, duration, hold = sys.argv[1:9]
text = text.strip()
due = (due or "").strip() or None
cron = (cron or "").strip() or None
try:
    block_seconds = int(duration)
except ValueError:
    block_seconds = 0
try:
    hold_seconds = int(hold)
except ValueError:
    hold_seconds = 5
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    if cron:
        sc = con.execute(
            "INSERT INTO reminder_schedules (text, cron, block_seconds, hold_seconds, status, next_due_at, source, created_at) "
            "VALUES (?,?,?,?, 'active', ?, ?, ?)",
            (text, cron, block_seconds, hold_seconds, due, source, now),
        )
        con.execute(
            "INSERT INTO reminders (schedule_id, text, due_at, block_seconds, hold_seconds, status, source, created_at) "
            "VALUES (?,?,?,?,?, 'pending', ?, ?)",
            (sc.lastrowid, text, due, block_seconds, hold_seconds, source, now),
        )
        con.commit()
        print(f"S{sc.lastrowid}")
    else:
        cur = con.execute(
            "INSERT INTO reminders (schedule_id, text, due_at, block_seconds, hold_seconds, status, source, created_at) "
            "VALUES (NULL,?,?,?,?, 'pending', ?, ?)",
            (text, due, block_seconds, hold_seconds, source, now),
        )
        con.commit()
        print(f"R{cur.lastrowid}")
    con.close()
except Exception as e:
    print(f"ERR:{e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)"
    if [[ -z "$NEW_ID" || "$NEW_ID" == ERR:* ]]; then
      echo "Error: failed to store blocking reminder (DB write failed)" >&2
      exit 1
    fi
    if [[ -n "${R_CRON//[[:space:]]/}" ]]; then
      WHEN_TXT="cron: $R_CRON — next fires $R_DUE"
    else
      WHEN_TXT="due $R_DUE"
    fi
    if [[ "$R_DURATION" == "0" ]]; then
      DUR_TXT="stays until you hold Control ${R_HOLD}s to skip"
    else
      DUR_TXT="stays ${R_DURATION}s (done if you wait it out; hold Control ${R_HOLD}s to skip early)"
    fi
    echo "REMIND_BLOCKING_ADDED id=$NEW_ID"
    echo "Set blocking: \"$R_TEXT\" — $WHEN_TXT — $DUR_TXT"
    # Blocking overlays fire only via the background poller; make sure it exists.
    if [[ "$(agent_installed)" == "no" ]]; then
      bash "$SELF" install || true
    fi
    ;;

  # -------------------------------------------------------------------------
  list|ls)
    echo "REMIND_BLOCKING_LIST ($NOW_DT)"
    LISTED="$(python3 - "$PBRAIN_DB_FILE" "$NOW_DT" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys, datetime
db, now_s = sys.argv[1], sys.argv[2]
now = datetime.datetime.strptime(now_s, "%Y-%m-%d %H:%M")
today = now.date()

def parse_due(s):
    if not s:
        return None
    s = s.strip()
    for fmt, anchor in (("%Y-%m-%d %H:%M", None), ("%Y-%m-%d", 9)):
        try:
            dt = datetime.datetime.strptime(s, fmt)
            return dt.replace(hour=anchor) if anchor is not None else dt
        except ValueError:
            continue
    return None

def dur(b):
    return "until skipped" if not b else f"{b//60}:{b%60:02d}"

try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    schedules = con.execute(
        "SELECT id, text, cron, block_seconds, hold_seconds, next_due_at FROM reminder_schedules "
        "WHERE status='active' ORDER BY (next_due_at IS NULL), next_due_at"
    ).fetchall()
    oneshots = con.execute(
        "SELECT id, text, due_at, block_seconds, hold_seconds, fired_at FROM reminders "
        "WHERE status='pending' AND schedule_id IS NULL ORDER BY due_at"
    ).fetchall()
    con.close()
except Exception:
    sys.exit(0)

def when_tag(due_at):
    dt = parse_due(due_at)
    if dt is None:
        return ""
    d = dt.date()
    if d < today or (d == today and dt <= now):
        return "OVERDUE"
    if d == today:
        return "today"
    days = (d - today).days
    return "tomorrow" if days == 1 else f"in {days} days"

lines = []
for sid, text, cron, bs, hs, nxt in schedules:
    lines.append(f"- [S{sid}] {text} — cron: {cron} — next {nxt or '?'} — "
                 f"stays {dur(bs)}, hold Control {hs or 5}s to skip")
for rid, text, due_at, bs, hs, fired_at in oneshots:
    tag = "fired — awaiting outcome" if fired_at else when_tag(due_at)
    suffix = f" ({tag})" if tag else ""
    lines.append(f"- [R{rid}] {text} — due {due_at}{suffix} — "
                 f"stays {dur(bs)}, hold Control {hs or 5}s to skip")

if lines:
    print("\n".join(lines))
PYEOF
)"
    if [[ -n "${LISTED//[[:space:]]/}" ]]; then
      echo "$LISTED"
    else
      echo "(no active blocking reminders)"
    fi
    ;;

  # -------------------------------------------------------------------------
  done|complete|cancel|rm)
    # Cancelling is the only management action now ("done" is an overlay outcome,
    # not a CLI verb). Reference a recurring SERIES as S<id> (stops the whole
    # series + its pending occurrence) or a one-shot as R<id> / <id>.
    shift || true
    if [[ $# -eq 0 ]]; then
      echo "remind-blocking: cancel requires at least one id (S<n> for a series, R<n>/<n> for a one-shot)" >&2
      exit 1
    fi
    python3 - "$PBRAIN_DB_FILE" "$NOW_DT" "$@" <<'PYEOF'
import sqlite3, sys, re
db, now = sys.argv[1], sys.argv[2]
refs = sys.argv[3:]
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    done_series, done_inst, misses = [], [], []
    for raw in refs:
        m = re.match(r'^\s*([sSrR]?)(\d+)\s*$', raw)
        if not m:
            misses.append(raw); continue
        kind, num = m.group(1).lower(), int(m.group(2))
        if kind == "s":
            c1 = con.execute("UPDATE reminder_schedules SET status='cancelled' WHERE id=? AND status='active'", (num,))
            # Stop the series' still-pending occurrence(s) too.
            con.execute("UPDATE reminders SET status='cancelled', resolved_at=? WHERE schedule_id=? AND status='pending'", (now, num))
            if c1.rowcount:
                done_series.append(num)
            else:
                misses.append(raw)
        else:
            # R<n> or bare <n>: a one-shot occurrence.
            c1 = con.execute("UPDATE reminders SET status='cancelled', resolved_at=? WHERE id=? AND status='pending' AND schedule_id IS NULL", (now, num))
            if c1.rowcount:
                done_inst.append(num)
            else:
                misses.append(raw)
    con.commit()
    con.close()
    parts = []
    if done_series: parts.append("cancelled series " + ", ".join(f"S{i}" for i in done_series))
    if done_inst:   parts.append("cancelled " + ", ".join(f"R{i}" for i in done_inst))
    if misses:      parts.append("no match for " + ", ".join(misses))
    print("; ".join(parts) if parts else "Nothing to cancel.")
except Exception as e:
    print(f"remind-blocking: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    ;;

  # -------------------------------------------------------------------------
  test|show|preview)
    shift || true
    T_TEXT="Take a break"; T_DURATION="10"; T_HOLD="3"; T_BG=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --text)       T_TEXT="${2:-Take a break}"; shift 2 2>/dev/null || shift ;;
        --duration)   T_DURATION="${2:-10}"; shift 2 2>/dev/null || shift ;;
        --hold)       T_HOLD="${2:-3}"; shift 2 2>/dev/null || shift ;;
        --background) T_BG="${2:-}"; shift 2 2>/dev/null || shift ;;
        *) shift ;;
      esac
    done
    pbrain_overlay_show "$T_TEXT" "$T_DURATION" "$T_HOLD" "$T_BG" || true
    BIN="$PBRAIN_OVERLAY_APP/Contents/MacOS/pbrain-overlay"
    if [[ -x "$BIN" ]]; then
      echo "Showing test overlay: \"$T_TEXT\" — ${T_DURATION}s. Hold Control ${T_HOLD}s to skip, or Return ${T_HOLD}s to mark done."
    else
      echo "swiftc not available — pbrain-overlay.app couldn't be built; showed a fallback notification instead."
    fi
    ;;

  # -------------------------------------------------------------------------
  # install / uninstall — the background launchd poller. /remind is Apple
  # Calendar-only now (Calendar fires its reminders), so the poller exists
  # SOLELY for blocking overlays, which can't ride Calendar. This command owns
  # it. The plist runs `remind-blocking.sh tick` every ~60s.
  install)
    # Pre-build the overlay app so the first background tick can fire instantly
    # (best-effort; if swiftc is missing a blocking reminder degrades to a notification).
    pbrain_overlay_build || true
    mkdir -p "$HOME/Library/LaunchAgents"
    LOG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/.logs"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/reminders.log"
    # XML-escape path metacharacters (&, <, >) before interpolating into the
    # plist — otherwise a path containing them yields malformed XML that
    # launchctl silently rejects while we report success.
    _xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
    SELF_X="$(_xml_escape "$SELF")"
    DBF_X="$(_xml_escape "$PBRAIN_DB_FILE")"
    LOG_X="$(_xml_escape "$LOG_FILE")"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.pbrain.reminders</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SELF_X</string>
    <string>tick</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PBRAIN_DB_FILE</key><string>$DBF_X</string>
  </dict>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_X</string>
  <key>StandardErrorPath</key><string>$LOG_X</string>
</dict>
</plist>
PLISTEOF
    UID_NUM="$(id -u)"
    # Reload cleanly whether or not it was already loaded.
    launchctl bootout "gui/$UID_NUM/com.pbrain.reminders" 2>/dev/null || true
    if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then
      echo "Installed background blocking-reminders poller (fires every ~1 min)."
    else
      launchctl unload "$PLIST" 2>/dev/null || true
      launchctl load "$PLIST" 2>/dev/null || true
      echo "Installed background blocking-reminders poller (via load)."
    fi
    if [[ -x "$PBRAIN_OVERLAY_APP/Contents/MacOS/pbrain-overlay" ]]; then
      echo "Overlay: pbrain-overlay.app built — reliable background overlays."
    else
      echo "Overlay: swiftc not found; blocking reminders will degrade to notifications."
    fi
    echo "Plist: $PLIST"
    echo "Log:   $LOG_FILE"
    ;;
  uninstall)
    UID_NUM="$(id -u)"
    launchctl bootout "gui/$UID_NUM/com.pbrain.reminders" 2>/dev/null || \
      launchctl unload "$PLIST" 2>/dev/null || true
    if [[ -f "$PLIST" ]]; then
      rm -f "$PLIST"
      echo "Removed background blocking-reminders poller."
    else
      echo "Background blocking-reminders poller was not installed."
    fi
    ;;

  # -------------------------------------------------------------------------
  help|-h|--help)
    sed -n '4,45p' "$SELF"
    ;;

  # -------------------------------------------------------------------------
  # Entry path: empty or natural-language input. Hand a context block to Claude
  # to decide intent. NOTHING is fired here — blocking overlays are time-sensitive
  # and fire ONLY via the background poller (near their due time), never as a late
  # catch-up just because a command happened to run.
  *)
    RAW="$*"
    LISTED="$(bash "$SELF" list 2>/dev/null | sed '1d' || true)"
    [[ -n "${LISTED//[[:space:]]/}" ]] || LISTED="(no active blocking reminders)"
    cat <<ENTRY
REMIND_BLOCKING_ENTRY
now: $NOW_DT ($DOW)
now_iso: $NOW_ISO
today: $TODAY
background_poller_installed: $(agent_installed)
raw_input: $RAW

=== ACTIVE BLOCKING REMINDERS ===
$LISTED

---
INSTRUCTIONS — you are handling a /remind-blocking invocation.

A BLOCKING reminder fires as a FULL-SCREEN overlay (a "Take a break" screen
across every display, above the menu bar/Dock) that is hard to dismiss — the
user HOLDS THE CONTROL KEY a few seconds to skip, or waits out a countdown. Use
this for things the user wants to be forced to stop and notice (stretch breaks,
screen-time limits, hard stops), NOT routine pings (those are plain /remind).

How an occurrence resolves: holding Control = SKIPPED; the countdown elapsing =
DONE (only way to get "done"); the Mac sleeping or locking while it's up = MISSED;
and the poller marks it MISSED if it comes due while asleep/locked past the grace
window (default 10 min) rather than firing it hours late. Recurring reminders are
a SERIES that survives missed/skipped occurrences — only cancelling the series
stops it.

The raw_input above is whatever the user typed after /remind-blocking (may be
empty). Decide intent and act via the Bash tool using the absolute path:
  $SELF

1. CREATE a blocking reminder (raw_input describes something to be reminded of):
   Pass EXACTLY ONE of --due (one-shot) or --cron (recurring):
   - ONE-OFF → resolve a concrete time RELATIVE TO now ($NOW_DT, $DOW) and pass
       --due "YYYY-MM-DD HH:MM"   ("in 90 minutes", "at 3pm", "tomorrow 9am").
   - RECURRING → translate the cadence into a 5-field CRON expression and pass
       --cron "<min hour day-of-month month day-of-week>"   (dow 0 or 7 = Sunday).
     Examples:
       "every weekday at 9am"                     → --cron "0 9 * * 1-5"
       "every saturday and tuesday, 2pm and 5pm"  → --cron "0 14,17 * * 2,6"
       "every hour at 5 past"                      → --cron "5 * * * *"
       "every 5 minutes"                           → --cron "*/5 * * * *"
       "1st of each month at 11pm"                 → --cron "0 23 1 * *"
     The poller resolution is ~1 minute, so sub-minute cadences ("every 30s")
     aren't possible — round to a whole minute and tell the user.
   - DURATION = how long the overlay stays on screen, and the ONLY path to a
     "done" outcome (wait it out). "for 5 minutes" → --duration 300, "for 15
     min" → 900. No duration / "until I'm done" → omit it (defaults to 0 = stays
     until they hold Control to skip; such a reminder can only ever be SKIPPED).
   - HOLD = seconds of Control-key hold to skip (friction). Default 5; only set
     --hold if the user asks for harder/easier dismissal.
   - Then run:
       bash "$SELF" add --text "<clean message shown on screen>" ( --due "<YYYY-MM-DD HH:MM>" | --cron "<expr>" ) [--duration <seconds>] [--hold <seconds>]
   - Keep --text short — it's shown huge on screen (e.g. "Take a break", "Stand up", "Stop — hard limit").
   - Confirm back in one line (the command echoes a handle: S<id> for a series, R<id> for a one-shot).

2. TEST / "show me what it looks like": run
     bash "$SELF" test
   (optionally --text/--duration/--hold/--background <hex>). It shows one overlay
   right now. Tell the user to hold the Control key to dismiss.

3. LIST / "what blocking reminders do I have": run \`bash "$SELF" list\` (or read
   the ACTIVE block above) and show them. Series are listed as S<id>, one-shots as R<id>.

4. CANCEL ("cancel the break one", "stop the stretch reminder", "remove R3"): match
   their reference to a handle, then run \`bash "$SELF" cancel <handle>\` — use
   S<id> to stop a whole recurring SERIES, or R<id> (a bare number also works) for
   a one-shot. There is no "mark done" action; cancelling is the only management verb.

Keep it tight. One confirmation line is enough.
ENTRY
    pbrain_emit_self_improve "remind-blocking" || true
    ;;
esac
