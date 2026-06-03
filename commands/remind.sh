#!/usr/bin/env bash
set -euo pipefail

# remind.sh — lightweight reminders that fire as macOS notifications.
#
# Reminders are stored in the shared pbrain SQLite DB (lib/db.sh). They fire as
# macOS notifications via osascript, either opportunistically when /plan-my-day,
# /end-of-day, or /remind run, or — if you opt in with `/remind install` — from a
# launchd poller that ticks every 5 minutes in the background.
#
# Subcommands (the Claude-facing API; humans just type natural language and the
# /remind command translates):
#   remind.sh add --text "..." [--due "YYYY-MM-DD HH:MM"] [--repeat daily|weekdays|weekly|monthly] [--source X]
#   remind.sh list
#   remind.sh done <id> [<id> ...]
#   remind.sh cancel <id> [<id> ...]
#   remind.sh clear --yes
#   remind.sh tick                 # fire anything due now (used by launchd + plan/eod)
#   remind.sh install | uninstall  # background launchd poller
#   remind.sh help
#   remind.sh <natural language>   # entry path → emits intent block for Claude
#
# Overrides:
#   PBRAIN_VAULT     — vault root (only needed for prefs/self-improve)
#   PBRAIN_DB_FILE   — SQLite DB path (default ~/.config/pbrain/pbrain.db)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
SELF="$_SCRIPT_DIR/remind.sh"
_LIB_DIR="$(cd -P -- "$_SCRIPT_DIR/../lib" && pwd -P)"

SUB="${1:-}"
PLIST="$HOME/Library/LaunchAgents/com.pbrain.reminders.plist"

# ---------------------------------------------------------------------------
# tick — the background poller. Decoupled from vault.sh on purpose: it only
# needs the DB + the notify/tick helpers, and must not die if the vault dir is
# absent (vault.sh exits 1 in that case). Keep this path dependency-light.
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
pbrain_emit_prefs "remind" || true
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
    R_TEXT=""; R_DUE=""; R_REPEAT=""; R_SOURCE="remind"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --text)   R_TEXT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --due)    R_DUE="${2:-}"; shift 2 2>/dev/null || shift ;;
        --repeat) R_REPEAT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --source) R_SOURCE="${2:-remind}"; shift 2 2>/dev/null || shift ;;
        *) shift ;;
      esac
    done
    if [[ -z "${R_TEXT//[[:space:]]/}" ]]; then
      echo "remind: add requires --text" >&2
      exit 1
    fi
    # Validate --due BEFORE inserting. parse_due (lib/reminders.sh) only accepts
    # 'YYYY-MM-DD HH:MM' or 'YYYY-MM-DD'; anything else parses to None, which
    # would silently render as a "someday" reminder that tick never fires. Fail
    # loud here instead of storing a dated reminder that never goes off.
    if [[ -n "${R_DUE//[[:space:]]/}" ]]; then
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
        echo "remind: --due must be 'YYYY-MM-DD HH:MM' or 'YYYY-MM-DD' (got: $R_DUE). Reminder NOT set." >&2
        exit 1
      fi
    fi
    # Insert; normalise repeat; echo the new id + a confirmation line.
    NEW_ID="$(python3 - "$PBRAIN_DB_FILE" "$R_TEXT" "$R_DUE" "$R_REPEAT" "$R_SOURCE" "$NOW_DT" <<'PYEOF'
import sqlite3, sys
db, text, due, repeat, source, now = sys.argv[1:7]
text = text.strip()
due = (due or "").strip() or None
repeat = (repeat or "").strip().lower() or None
if repeat not in ("daily", "weekdays", "weekly", "monthly"):
    repeat = None
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    cur = con.execute(
        "INSERT INTO reminders (text, due_at, repeat, status, source, created_at) "
        "VALUES (?,?,?,?,?,?)",
        (text, due, repeat, "pending", source, now),
    )
    con.commit()
    print(cur.lastrowid)
    con.close()
except Exception as e:
    print(f"ERR:{e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)"
    DUE_TXT="${R_DUE:-someday}"
    REPEAT_TXT=""
    [[ -n "$R_REPEAT" ]] && REPEAT_TXT=" (repeats $R_REPEAT)"
    # Confirmation notification — also proves the notification path works.
    pbrain_notify "Reminder set" "$R_TEXT — $DUE_TXT$REPEAT_TXT" || true
    echo "REMIND_ADDED id=$NEW_ID"
    echo "Set: \"$R_TEXT\" — due $DUE_TXT$REPEAT_TXT"
    if [[ "$(agent_installed)" == "no" ]]; then
      bash "$SELF" install || true
    fi
    ;;

  # -------------------------------------------------------------------------
  list|ls)
    echo "REMIND_LIST ($NOW_DT)"
    PENDING="$(pbrain_reminders_pending_text || true)"
    if [[ -n "${PENDING//[[:space:]]/}" ]]; then
      echo "$PENDING"
    else
      echo "(no pending reminders)"
    fi
    ;;

  # -------------------------------------------------------------------------
  done|complete|cancel|rm)
    ACTION="done"; STATUS="done"
    case "$SUB" in cancel|rm) ACTION="cancel"; STATUS="cancelled" ;; esac
    shift || true
    if [[ $# -eq 0 ]]; then
      echo "remind: $ACTION requires at least one reminder id" >&2
      exit 1
    fi
    python3 - "$PBRAIN_DB_FILE" "$STATUS" "$NOW_DT" "$@" <<'PYEOF'
import sqlite3, sys
db, status, now = sys.argv[1], sys.argv[2], sys.argv[3]
ids = sys.argv[4:]
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    changed = []
    for raw in ids:
        try:
            rid = int(raw)
        except ValueError:
            continue
        cur = con.execute(
            "UPDATE reminders SET status=?, done_at=? WHERE id=? AND status='pending'",
            (status, now, rid),
        )
        if cur.rowcount:
            changed.append(rid)
    con.commit()
    con.close()
    if changed:
        print(f"Marked {status}: " + ", ".join(f"#{i}" for i in changed))
    else:
        print("No matching pending reminders for those ids.")
except Exception as e:
    print(f"remind: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    ;;

  # -------------------------------------------------------------------------
  clear)
    shift || true
    YES="no"
    for a in "$@"; do [[ "$a" == "--yes" ]] && YES="yes"; done
    if [[ "$YES" != "yes" ]]; then
      echo "remind: clear cancels ALL pending reminders. Re-run with --yes to confirm." >&2
      exit 1
    fi
    python3 - "$PBRAIN_DB_FILE" "$NOW_DT" <<'PYEOF'
import sqlite3, sys
db, now = sys.argv[1], sys.argv[2]
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    cur = con.execute(
        "UPDATE reminders SET status='cancelled', done_at=? WHERE status='pending'",
        (now,),
    )
    con.commit()
    con.close()
    print(f"Cancelled {cur.rowcount} pending reminder(s).")
except Exception as e:
    print(f"remind: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    ;;

  # -------------------------------------------------------------------------
  install)
    mkdir -p "$HOME/Library/LaunchAgents"
    LOG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/.logs"
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/reminders.log"
    # XML-escape any path metacharacters (&, <, >) before interpolating into the
    # plist — a path containing them (legal in filenames) would otherwise produce
    # malformed XML that launchctl silently rejects while we report success.
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
  <key>StartInterval</key><integer>300</integer>
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
      echo "Installed background reminders poller (fires every ~5 min)."
    else
      # Fallback for older launchctl semantics.
      launchctl unload "$PLIST" 2>/dev/null || true
      launchctl load "$PLIST" 2>/dev/null || true
      echo "Installed background reminders poller (via load)."
    fi
    echo "Plist: $PLIST"
    echo "Log:   $LOG_FILE"
    ;;

  # -------------------------------------------------------------------------
  uninstall)
    UID_NUM="$(id -u)"
    launchctl bootout "gui/$UID_NUM/com.pbrain.reminders" 2>/dev/null || \
      launchctl unload "$PLIST" 2>/dev/null || true
    if [[ -f "$PLIST" ]]; then
      rm -f "$PLIST"
      echo "Removed background reminders poller."
    else
      echo "Background reminders poller was not installed."
    fi
    ;;

  # -------------------------------------------------------------------------
  help|-h|--help)
    sed -n '3,30p' "$SELF"
    ;;

  # -------------------------------------------------------------------------
  # Entry path: empty or natural-language input. Fire anything due, then hand a
  # context block to Claude to decide intent (create / list / complete).
  *)
    pbrain_reminders_tick || true
    RAW="$*"
    PENDING="$(pbrain_reminders_pending_text || true)"
    [[ -n "${PENDING//[[:space:]]/}" ]] || PENDING="(no pending reminders)"
    cat <<ENTRY
REMIND_ENTRY
now: $NOW_DT ($DOW)
now_iso: $NOW_ISO
today: $TODAY
background_poller_installed: $(agent_installed)
raw_input: $RAW

=== PENDING REMINDERS ===
$PENDING

---
INSTRUCTIONS — you are handling a /remind invocation.

The raw_input above is whatever the user typed after /remind (may be empty).
Reminders fire as macOS notifications. Decide the user's intent and act by
calling the relevant subcommand with the Bash tool. Use the absolute path:
  $SELF

1. CREATE a reminder (raw_input describes something to be reminded of):
   - Resolve a concrete due time from their words RELATIVE TO now ($NOW_DT,
     $DOW). "tomorrow 3pm" → the correct YYYY-MM-DD 15:00. "in 2 hours" → add to
     now. "every morning" → pick a sensible time (e.g. 08:00) + --repeat daily.
     Day-only ("friday", "next week") → a date with no time is fine.
   - Detect recurrence → --repeat daily|weekdays|weekly|monthly.
   - If the time is genuinely ambiguous, ask ONE short clarifying question first.
   - Then run:
       bash "$SELF" add --text "<clean reminder text>" --due "<YYYY-MM-DD HH:MM or YYYY-MM-DD>" [--repeat <r>]
     Omit --due only if the user truly wants an undated "someday" reminder.
   - Confirm back in one line what you set.

2. LIST / "what are my reminders": run \`bash "$SELF" list\` (or just read the
   PENDING block above) and show them.

3. COMPLETE / CANCEL ("mark #3 done", "I did the dentist one"): match their
   reference to an id in the PENDING block, then run
   \`bash "$SELF" done <id>\` (or \`cancel <id>\`).

Keep it tight. Don't over-explain. One confirmation line is enough.
ENTRY
    pbrain_emit_self_improve "remind" || true
    ;;
esac
