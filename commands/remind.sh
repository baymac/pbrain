#!/usr/bin/env bash
set -euo pipefail

# remind.sh — natural-language reminders that land as Apple Calendar events.
#
# /remind is a SIMPLE "add to calendar": the model reads what you asked, works
# out the title, time, frequency, and any extra context, then this script
# creates a real Apple Calendar event (with an alarm at the start time and an
# optional recurrence). Calendar owns the firing + cross-device sync — there is
# NO pbrain DB row and no background poller involved for /remind. Each event is
# tagged with a marker in its notes so list/cancel can find pbrain's own events.
#
# (The shared SQLite reminders table + launchd poller in lib/db.sh / lib/
# reminders.sh still exist, but they belong to the separate `remind-block`
# feature — /remind no longer touches them.)
#
# Subcommands (the Claude-facing API; humans just type natural language and the
# /remind command translates):
#   remind.sh add --text "..." --due "YYYY-MM-DD HH:MM" [--repeat <token>] [--until YYYY-MM-DD | --count N] [--notes "context"]
#       repeat tokens: daily|weekdays|weekly|weekly:WE,SA|monthly|monthly:1MO|every-Nd|every-Nw[:WE,SA]|every-Nh|every-Nm|every-Ns
#   remind.sh list                 # upcoming pbrain reminders on the calendar
#   remind.sh done <uid> [<uid> ...]   # remove the calendar event(s) (EventKit)
#   remind.sh cancel <uid> [<uid> ...] # alias of done
#   remind.sh calendar-access      # trigger/verify the one-time Calendar grant
#   remind.sh help
#   remind.sh <natural language>   # entry path → emits intent block for Claude
#
# Deleting events uses a bundled EventKit helper (pbrain-calendar.app, built on
# demand from lib/pbrain-calendar.swift) because AppleScript can't reliably delete
# recurring iCloud events. It needs Calendar access, granted once via the macOS
# prompt (see `calendar-access`); without swiftc it falls back to AppleScript.
#
# Overrides:
#   PBRAIN_VAULT        — vault root (only needed for prefs/self-improve)
#   PBRAIN_CALENDAR     — target calendar name (default "Calendar")
#   PBRAIN_CAL_MARKER   — notes marker tagging pbrain events (default ⟦pbrain-reminder⟧)
#   PBRAIN_CALENDAR_APP — where the EventKit helper app is cached/built

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

# /remind is Apple Calendar-only: Calendar fires the reminders, so there is no
# launchd poller here (that lives in /remind-blocking, the only consumer left).

# All subcommands go through the normal command harness (prefs, helpers).
# No pbrain_db_init here: /remind is Apple Calendar-only and never touches the
# shared SQLite reminders table (that's /remind-blocking's, exclusively).
source "$_SCRIPT_DIR/../lib/vault.sh"
pbrain_emit_prefs "remind" || true

NOW_DT="$(date '+%Y-%m-%d %H:%M')"
NOW_ISO="$(date '+%Y-%m-%dT%H:%M')"
TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%A)"

case "$SUB" in
  # -------------------------------------------------------------------------
  add)
    shift || true
    R_TEXT=""; R_DUE=""; R_REPEAT=""; R_NOTES=""; R_UNTIL=""; R_COUNT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --text)   R_TEXT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --due)    R_DUE="${2:-}"; shift 2 2>/dev/null || shift ;;
        --repeat) R_REPEAT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --notes)  R_NOTES="${2:-}"; shift 2 2>/dev/null || shift ;;
        --until)  R_UNTIL="${2:-}"; shift 2 2>/dev/null || shift ;;
        --count)  R_COUNT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --source) shift 2 2>/dev/null || shift ;;  # accepted + ignored (back-compat)
        *) shift ;;
      esac
    done
    if [[ -z "${R_TEXT//[[:space:]]/}" ]]; then
      echo "remind: add requires --text" >&2
      exit 1
    fi
    # A calendar event needs a concrete time — require --due in the accepted shape.
    if [[ -z "${R_DUE//[[:space:]]/}" ]]; then
      echo "remind: add requires --due 'YYYY-MM-DD HH:MM' (or 'YYYY-MM-DD'). A calendar event needs a time." >&2
      exit 1
    fi
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
    # Map the repeat token to an iCalendar RRULE (empty => one-shot event).
    RRULE="$(pbrain_calendar_rrule "$R_REPEAT")"
    if [[ "$RRULE" == "INVALID" ]]; then
      echo "remind: unrecognized --repeat '$R_REPEAT'. Use one of: daily | weekdays | weekly | weekly:WE,SA | monthly | monthly:1MO | every-Nd | every-Nw[:WE,SA] | every-Nh | every-Nm | every-Ns. Nothing was set." >&2
      exit 1
    fi
    # Bounded recurrence: --until <date> or --count <N> (mutually exclusive, and
    # only meaningful with a --repeat). Append to the RRULE; Calendar enforces it.
    if [[ -n "${R_UNTIL//[[:space:]]/}" || -n "${R_COUNT//[[:space:]]/}" ]]; then
      if [[ -z "$RRULE" ]]; then
        echo "remind: --until/--count only apply to a recurring reminder — add a --repeat too. Nothing was set." >&2
        exit 1
      fi
      if [[ -n "${R_UNTIL//[[:space:]]/}" && -n "${R_COUNT//[[:space:]]/}" ]]; then
        echo "remind: use either --until or --count, not both. Nothing was set." >&2
        exit 1
      fi
      if [[ -n "${R_UNTIL//[[:space:]]/}" ]]; then
        # Accept YYYY-MM-DD; convert to the iCalendar UNTIL form (end of that day).
        UNTIL_ICAL="$(python3 - "$R_UNTIL" <<'PYEOF' 2>/dev/null || true
import sys, datetime
s = sys.argv[1].strip()
try:
    d = datetime.datetime.strptime(s, "%Y-%m-%d")
    print(d.strftime("%Y%m%dT235959Z"))
except ValueError:
    pass
PYEOF
)"
        if [[ -z "$UNTIL_ICAL" ]]; then
          echo "remind: --until must be 'YYYY-MM-DD' (got: $R_UNTIL). Nothing was set." >&2
          exit 1
        fi
        RRULE="$RRULE;UNTIL=$UNTIL_ICAL"
      else
        if ! [[ "$R_COUNT" =~ ^[0-9]+$ ]] || [[ "$R_COUNT" -lt 1 ]]; then
          echo "remind: --count must be a positive integer (got: $R_COUNT). Nothing was set." >&2
          exit 1
        fi
        RRULE="$RRULE;COUNT=$R_COUNT"
      fi
    fi
    # Create the Apple Calendar event; capture its UID for later cancel.
    UID_OUT="$(pbrain_calendar_add "$R_TEXT" "$R_DUE" "$RRULE" "$R_NOTES" || true)"
    if [[ -z "${UID_OUT//[[:space:]]/}" ]]; then
      echo "remind: failed to create the Apple Calendar event (is Calendar accessible, and does the calendar \"$PBRAIN_CALENDAR\" exist?). Nothing was set." >&2
      exit 1
    fi
    REPEAT_TXT=""
    if [[ -n "${R_REPEAT//[[:space:]]/}" ]]; then
      REPEAT_TXT=" (repeats $R_REPEAT"
      [[ -n "${R_UNTIL//[[:space:]]/}" ]] && REPEAT_TXT="$REPEAT_TXT until $R_UNTIL"
      [[ -n "${R_COUNT//[[:space:]]/}" ]] && REPEAT_TXT="$REPEAT_TXT, ${R_COUNT}×"
      REPEAT_TXT="$REPEAT_TXT)"
    fi
    NOTES_TXT=""
    [[ -n "${R_NOTES//[[:space:]]/}" ]] && NOTES_TXT=" — note: $R_NOTES"
    echo "REMIND_ADDED uid=$UID_OUT"
    echo "Added to $PBRAIN_CALENDAR: \"$R_TEXT\" — $R_DUE$REPEAT_TXT$NOTES_TXT"
    ;;

  # -------------------------------------------------------------------------
  list|ls)
    echo "REMIND_LIST ($NOW_DT) — calendar: $PBRAIN_CALENDAR"
    CAL_ROWS="$(pbrain_calendar_list 60 || true)"
    if [[ -n "${CAL_ROWS//[[:space:]]/}" ]]; then
      # Each row is "id<TAB>start<TAB>summary"; render readably, keep the id.
      while IFS=$'\t' read -r id start summary; do
        [[ -n "$id" ]] || continue
        echo "- $summary — $start  [id: $id]"
      done <<< "$CAL_ROWS"
    else
      echo "(no upcoming pbrain reminders on \"$PBRAIN_CALENDAR\")"
    fi
    ;;

  # -------------------------------------------------------------------------
  done|complete|cancel|rm)
    shift || true
    if [[ $# -eq 0 ]]; then
      echo "remind: $SUB requires at least one calendar event uid (see \`remind.sh list\`)" >&2
      exit 1
    fi
    REMOVED=(); GONE=(); DENIED=(); FELLBACK=(); ERRORED=()
    for uid in "$@"; do
      [[ -n "${uid//[[:space:]]/}" ]] || continue
      RES="$(pbrain_calendar_delete "$uid" || true)"
      case "$RES" in
        DELETED)       REMOVED+=("$uid") ;;
        NOT_FOUND)     GONE+=("$uid") ;;
        ACCESS_DENIED) DENIED+=("$uid") ;;
        FALLBACK)      FELLBACK+=("$uid") ;;
        *)             ERRORED+=("$uid") ;;
      esac
    done
    [[ ${#REMOVED[@]}  -gt 0 ]] && echo "Removed from $PBRAIN_CALENDAR: ${REMOVED[*]}"
    [[ ${#GONE[@]}     -gt 0 ]] && echo "Already gone (no matching event): ${GONE[*]}"
    if [[ ${#DENIED[@]} -gt 0 ]]; then
      echo "Couldn't remove — pbrain doesn't have Calendar access yet: ${DENIED[*]}"
      echo "Run \`bash \"$SELF\" calendar-access\` once and approve the macOS prompt (or enable pbrain-calendar in System Settings → Privacy & Security → Calendars), then try again."
    fi
    if [[ ${#FELLBACK[@]} -gt 0 ]]; then
      echo "Requested removal (no EventKit helper — used AppleScript, which is UNRELIABLE for recurring iCloud events): ${FELLBACK[*]}"
      echo "If one reappears, remove it in Calendar.app. Installing Xcode Command Line Tools (swiftc) enables reliable deletion."
    fi
    [[ ${#ERRORED[@]} -gt 0 ]] && echo "Failed to remove (unexpected error): ${ERRORED[*]}"
    if [[ ${#REMOVED[@]} -eq 0 && ${#GONE[@]} -eq 0 && ${#DENIED[@]} -eq 0 && ${#FELLBACK[@]} -eq 0 && ${#ERRORED[@]} -eq 0 ]]; then
      echo "Nothing to remove."
    fi
    ;;

  # -------------------------------------------------------------------------
  calendar-access|grant-calendar)
    # Trigger / verify the one-time Calendar (EventKit) permission used by cancel.
    RES="$(pbrain_calendar_access || true)"
    case "$RES" in
      OK)            echo "Calendar access granted — \`/remind cancel\` can reliably remove events." ;;
      ACCESS_DENIED) echo "Calendar access was denied. Enable pbrain-calendar in System Settings → Privacy & Security → Calendars, then re-run." ;;
      UNAVAILABLE)   echo "EventKit helper unavailable (needs swiftc from Xcode Command Line Tools). \`/remind cancel\` will fall back to AppleScript, which can't reliably delete recurring iCloud events." ;;
      *)             echo "Couldn't determine Calendar access state ($RES)." ;;
    esac
    ;;

  # -------------------------------------------------------------------------
  help|-h|--help)
    sed -n '4,37p' "$SELF"
    ;;

  # -------------------------------------------------------------------------
  # Entry path: empty or natural-language input. Hand a context block to Claude
  # to decide intent (create / list / cancel) and act on Apple Calendar.
  *)
    RAW="$*"
    UPCOMING="$(pbrain_calendar_list 60 || true)"
    [[ -n "${UPCOMING//[[:space:]]/}" ]] || UPCOMING="(no upcoming pbrain reminders)"
    cat <<ENTRY
REMIND_ENTRY
now: $NOW_DT ($DOW)
now_iso: $NOW_ISO
today: $TODAY
calendar: $PBRAIN_CALENDAR
raw_input: $RAW

=== UPCOMING PBRAIN REMINDERS (calendar events; id<TAB>start<TAB>title) ===
$UPCOMING

---
INSTRUCTIONS — you are handling a /remind invocation.

/remind is a SIMPLE "add to Apple Calendar". The raw_input above is whatever the
user typed after /remind (may be empty). Read it, work out the details, and act
by calling the relevant subcommand with the Bash tool. Use the absolute path:
  $SELF

1. CREATE a reminder (raw_input describes something to be reminded of) — the
   common case. Derive from their words:
   - TITLE: a short, clean event title (the --text). Strip filler like "remind
     me to"; keep it imperative and specific.
   - TIME (--due): a concrete start RELATIVE TO now ($NOW_DT, $DOW).
     "tomorrow 3pm" → the correct YYYY-MM-DD 15:00. "in 2 hours" → add to now.
     "every morning" → pick a sensible time (e.g. 08:00). Day-only is allowed
     ("friday" → YYYY-MM-DD, anchors to 09:00).
     PAST-TIME GUARD: for a ONE-OFF (no --repeat), the --due must be in the
     future — a calendar alarm in the past won't fire. If the user names a clock
     time that has already passed today (e.g. "at 9am" when it's afternoon) and
     gives no date, assume the next day, or ask which day they mean. (For a
     recurring reminder a past anchor is fine — it just starts next occurrence.)
   - FREQUENCY (--repeat), only if they imply recurrence:
       daily | weekdays | weekly | monthly
       weekly:WE,SA   — specific weekday(s); "Wed and Sat" → weekly:WE,SA,
                        "every Tuesday" → weekly:TU. Day codes MO TU WE TH FR SA SU.
       monthly:1MO    — nth (or last) weekday of the month; "first Monday" →
                        monthly:1MO, "last Friday" → monthly:-1FR.
       every-Nd       — every N days; "every 3 days" → every-3d.
       every-Nw[:DAYS]— every N weeks; "every other week" → every-2w,
                        "biweekly on Mon" → every-2w:MO.
       every-Nh | every-Nm | every-Ns — hourly / minutely / secondly.
     "every hour" → every-1h, "every 5 minutes" → every-5m. (Apple Calendar's
     finest grain is one minute, so every-Ns becomes a 1-minute cadence.)
     For a single weekly:DAYS / monthly:NWD / every-Nw, pick a --due whose date IS
     the first matching occurrence so it lands right.
   - BOUNDED RECURRENCE (with --repeat only): add ONE of
       --until "YYYY-MM-DD"   — stop repeating after this date ("until Friday").
       --count N              — stop after N occurrences ("10 times", "for 3 days").
     Don't pass both. Resolve "until Friday" to the concrete date.
   - MULTIPLE DISTINCT TIMES a day (e.g. "9am and 5pm every day") aren't one
     event — make a SEPARATE add call per time (each with the same --repeat).
   - CONTEXT (--notes), optional: any extra detail worth keeping in the event
     notes — the why, a phone number, a link, a checklist. Skip if there's none.
   - If the time is genuinely ambiguous, ask ONE short clarifying question first.
   - Then run (only --text and --due are required):
       bash "$SELF" add --text "<title>" --due "<YYYY-MM-DD HH:MM or YYYY-MM-DD>" [--repeat <r>] [--notes "<context>"]
   - Confirm back in one line what you added.

2. LIST / "what are my reminders": run \`bash "$SELF" list\` (or read the UPCOMING
   block above) and show them.

3. CANCEL / "I did X" / "remove the dentist one": match their reference to an id
   in the UPCOMING block, then run \`bash "$SELF" cancel <id>\` (done is an alias).
   Deletion uses a bundled EventKit helper and is reliable (incl. recurring). The
   command's output is authoritative — relay it. If it says Calendar access isn't
   granted, tell the user to run \`/remind calendar-access\` once and approve the
   prompt. (Without swiftc it falls back to AppleScript, which can't reliably
   delete recurring iCloud events — then point them to Calendar.app.)

Keep it tight. Don't over-explain. One confirmation line is enough.
ENTRY
    pbrain_emit_self_improve "remind" || true
    ;;
esac
