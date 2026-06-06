#!/usr/bin/env bash
set -euo pipefail

# remind.sh — natural-language reminders that land as real Apple Reminders.
#
# /remind creates Apple **Reminders** (EKReminder), NOT Calendar events. A
# reminder is a to-do with an optional timed due date, an optional recurrence, a
# priority, and zero or more "early" alarms (a heads-up some minutes before due).
# Reminders + iCloud own firing + cross-device sync — there is NO pbrain DB and
# no background poller for /remind (that's /remind-blocking, exclusively). Each
# reminder carries a hidden marker in its notes so list shows only pbrain's own.
#
# All Reminders ops go through a bundled EventKit helper (pbrain-reminders.app,
# compiled on demand from lib/pbrain-reminders.swift) launched via `open`, so the
# one-time Reminders access prompt is attributed to the bundle. If swiftc (Xcode
# Command Line Tools) is absent the helper can't be built and /remind reports it
# rather than silently half-working.
#
# Frequency is expressed as cron. The model maps the user's words to a 5-field
# cron expression; the shell validates it and maps it to an Apple recurrence —
# honestly: Apple reminder recurrence is daily/weekly/monthly/yearly only, so
#   * sub-daily cron (every N minutes/hours) is REJECTED → use /remind-blocking;
#   * multiple times-of-day (0 9,17 * * *) → SPLIT into one reminder per time;
#   * cron dom AND dow (OR semantics) → SPLIT into two reminders;
#   * nth/last weekday via the dow#n / dowL extensions (1#1, 5L).
# True every-N intervals (cron can't express them) use the --repeat tokens.
#
# Subcommands (the Claude-facing API; humans type natural language):
#   remind.sh add --text "..." (--due "YYYY-MM-DD HH:MM" | --cron "<5-field>" | --repeat <token>)
#                 [--priority high|medium|low] [--early "15" | "15,60"]
#                 [--until YYYY-MM-DD | --count N] [--notes "..."] [--list "<list>"]
#   remind.sh list                       # upcoming pbrain reminders
#   remind.sh edit <id> [--text ...] [--due ...] [--cron ...] [--repeat ...]
#                 [--clear-recurrence] [--priority ...] [--early ...] [--clear-early] [--notes ...]
#   remind.sh done <id> [<id> ...]       # mark complete (recurring → rolls to next occurrence)
#   remind.sh cancel <id> [<id> ...]     # delete the reminder (recurring → whole series)
#   remind.sh access                     # trigger/verify the one-time Reminders grant
#   remind.sh help
#   remind.sh <natural language>         # entry path → emits intent block for Claude
#
# Overrides:
#   PBRAIN_VAULT            — vault root (only needed for prefs/self-improve)
#   PBRAIN_REMINDERS_LIST   — target Reminders list (default: the system default)
#   PBRAIN_REMINDER_MARKER  — hidden notes marker tagging pbrain reminders
#   PBRAIN_REMINDERS_APP    — where the EventKit helper app is cached/built

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
SELF="$_SCRIPT_DIR/remind.sh"

SUB="${1:-}"

# /remind is Apple Reminders-only: Reminders fires the notifications, so there is
# no launchd poller here (that lives in /remind-blocking, the only consumer left).
# No pbrain_db_init: /remind never touches the shared SQLite reminders table.
source "$_SCRIPT_DIR/../lib/vault.sh"
pbrain_emit_prefs "remind" || true

NOW_DT="$(date '+%Y-%m-%d %H:%M')"
NOW_ISO="$(date '+%Y-%m-%dT%H:%M')"
TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%A)"

# Normalize a --due value: a bare YYYY-MM-DD anchors to 09:00 (a reminder needs a
# time component to fire a notification on macOS). Echoes the normalized value, or
# nothing if it doesn't parse.
_normalize_due() {
  python3 - "${1:-}" <<'PYEOF' 2>/dev/null || true
import sys, datetime
s = (sys.argv[1] or "").strip()
for fmt, addtime in (("%Y-%m-%d %H:%M", False), ("%Y-%m-%d", True)):
    try:
        dt = datetime.datetime.strptime(s, fmt)
        if addtime:
            dt = dt.replace(hour=9, minute=0)
        print(dt.strftime("%Y-%m-%d %H:%M"))
        sys.exit(0)
    except ValueError:
        continue
sys.exit(1)
PYEOF
}

# Append a bounded-recurrence clause (--until or --count) to an RRULE. Echoes the
# RRULE unchanged when there's no bound. $1=rrule $2=until(YYYY-MM-DD) $3=count.
_apply_bound() {
  local rrule="$1" until_d="$2" count="$3"
  [[ -n "$rrule" ]] || { printf '%s' "$rrule"; return 0; }
  if [[ -n "${count//[[:space:]]/}" ]]; then
    printf '%s;COUNT=%s' "$rrule" "$count"
  elif [[ -n "${until_d//[[:space:]]/}" ]]; then
    local u; u="$(python3 - "$until_d" <<'PYEOF' 2>/dev/null || true
import sys, datetime
try:
    d = datetime.datetime.strptime(sys.argv[1].strip(), "%Y-%m-%d")
    print(d.strftime("%Y%m%dT235959Z"))
except ValueError:
    pass
PYEOF
)"
    [[ -n "$u" ]] && printf '%s;UNTIL=%s' "$rrule" "$u" || printf '%s' "$rrule"
  else
    printf '%s' "$rrule"
  fi
}

# Friendly message for a non-actionable helper status. $1 = status line.
# Returns 0 and prints guidance for UNAVAILABLE/ACCESS_DENIED; returns 1 if the
# status was actionable (caller proceeds).
_helper_guidance() {
  case "$1" in
    UNAVAILABLE)
      echo "remind: can't reach Reminders — the EventKit helper isn't built." >&2
      echo "Install Xcode Command Line Tools (\`xcode-select --install\`, which provides swiftc), then retry." >&2
      return 0 ;;
    ACCESS_DENIED)
      echo "remind: pbrain doesn't have Reminders access yet." >&2
      echo "Run \`bash \"$SELF\" access\` once and approve the macOS prompt (or enable pbrain-reminders in System Settings → Privacy & Security → Reminders), then retry." >&2
      return 0 ;;
  esac
  return 1
}

case "$SUB" in
  # -------------------------------------------------------------------------
  add)
    shift || true
    R_TEXT=""; R_DUE=""; R_CRON=""; R_REPEAT=""; R_PRIORITY=""; R_EARLY=""
    R_UNTIL=""; R_COUNT=""; R_NOTES=""; R_LIST=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --text|--title) R_TEXT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --due)          R_DUE="${2:-}"; shift 2 2>/dev/null || shift ;;
        --cron)         R_CRON="${2:-}"; shift 2 2>/dev/null || shift ;;
        --repeat)       R_REPEAT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --priority)     R_PRIORITY="${2:-}"; shift 2 2>/dev/null || shift ;;
        --early)        R_EARLY="${2:-}"; shift 2 2>/dev/null || shift ;;
        --until)        R_UNTIL="${2:-}"; shift 2 2>/dev/null || shift ;;
        --count)        R_COUNT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --notes)        R_NOTES="${2:-}"; shift 2 2>/dev/null || shift ;;
        --list)         R_LIST="${2:-}"; shift 2 2>/dev/null || shift ;;
        *) shift ;;
      esac
    done
    [[ -n "${R_LIST//[[:space:]]/}" ]] && export PBRAIN_REMINDERS_LIST="$R_LIST"

    if [[ -z "${R_TEXT//[[:space:]]/}" ]]; then
      echo "remind: add requires --text" >&2; exit 1
    fi
    # Validate priority early.
    if [[ -n "${R_PRIORITY//[[:space:]]/}" ]]; then
      case "$(printf '%s' "$R_PRIORITY" | tr '[:upper:]' '[:lower:]')" in
        none|high|medium|med|low|0|1|2|3|4|5|6|7|8|9) ;;
        *) echo "remind: --priority must be high|medium|low (or 0-9). Nothing was set." >&2; exit 1 ;;
      esac
    fi
    # Validate --until / --count combination.
    if [[ -n "${R_UNTIL//[[:space:]]/}" && -n "${R_COUNT//[[:space:]]/}" ]]; then
      echo "remind: use either --until or --count, not both. Nothing was set." >&2; exit 1
    fi
    if [[ -n "${R_COUNT//[[:space:]]/}" ]] && { ! [[ "$R_COUNT" =~ ^[0-9]+$ ]] || [[ "$R_COUNT" -lt 1 ]]; }; then
      echo "remind: --count must be a positive integer. Nothing was set." >&2; exit 1
    fi

    # Build the alarm spec from --early: always keep the at-due alarm (0), then
    # add each "minutes before" value. Empty when no early reminder requested.
    ALARMS=""
    if [[ -n "${R_EARLY//[[:space:]]/}" ]]; then
      ALARMS="0"
      IFS=',' read -ra _earls <<< "$R_EARLY"
      for e in "${_earls[@]}"; do
        e="${e//[[:space:]]/}"
        [[ -n "$e" ]] || continue
        if ! [[ "$e" =~ ^[0-9]+$ ]]; then
          echo "remind: --early values are minutes-before-due (e.g. \"15\" or \"15,60\"). Nothing was set." >&2; exit 1
        fi
        ALARMS="$ALARMS,$e"
      done
    fi

    # Resolve the recurrence path into parallel DUES[] / RRULES[] arrays.
    DUES=(); RRULES=()
    if [[ -n "${R_CRON//[[:space:]]/}" ]]; then
      # Cron path: the expression sets the time(s); --due (if any) is the anchor.
      MAP="$(pbrain_cron_to_rrules "$R_CRON" "${R_DUE:-}")"
      if [[ "$MAP" == REJECT* ]]; then
        CODE="$(printf '%s' "$MAP" | head -1 | cut -f2)"
        MSG="$(printf '%s' "$MAP" | head -1 | cut -f3)"
        echo "remind: can't turn that into a reminder — $MSG" >&2
        [[ "$CODE" == "SUBDAILY" ]] && echo "Tip: minute/hour cadences belong in /remind-blocking (it polls real cron)." >&2
        exit 1
      fi
      while IFS=$'\t' read -r tag due rrule; do
        [[ "$tag" == "OK" ]] || continue
        DUES+=("$due"); RRULES+=("$rrule")
      done <<< "$MAP"
    elif [[ -n "${R_REPEAT//[[:space:]]/}" ]]; then
      # Token path: for true every-N intervals cron can't express.
      if [[ -z "${R_DUE//[[:space:]]/}" ]]; then
        echo "remind: --repeat needs a --due anchor (the first occurrence). Nothing was set." >&2; exit 1
      fi
      DUE_N="$(_normalize_due "$R_DUE")"
      [[ -n "$DUE_N" ]] || { echo "remind: --due must be 'YYYY-MM-DD HH:MM' or 'YYYY-MM-DD' (got: $R_DUE). Nothing was set." >&2; exit 1; }
      RRULE="$(pbrain_calendar_rrule "$R_REPEAT")"
      if [[ "$RRULE" == "INVALID" ]]; then
        echo "remind: unrecognized --repeat '$R_REPEAT'. Use daily | weekdays | weekly | weekly:WE,SA | monthly | monthly:1MO | every-Nd | every-Nw[:WE,SA]. Nothing was set." >&2; exit 1
      fi
      if [[ "$RRULE" == *"FREQ=HOURLY"* || "$RRULE" == *"FREQ=MINUTELY"* ]]; then
        echo "remind: Apple Reminders can't repeat sub-daily (every-Nh/Nm/Ns). Use /remind-blocking for minute/hour cadences. Nothing was set." >&2; exit 1
      fi
      DUES+=("$DUE_N"); RRULES+=("$RRULE")
    else
      # One-shot.
      if [[ -z "${R_DUE//[[:space:]]/}" ]]; then
        echo "remind: a one-shot reminder needs --due 'YYYY-MM-DD HH:MM'. For a repeating one pass --cron or --repeat. Nothing was set." >&2; exit 1
      fi
      DUE_N="$(_normalize_due "$R_DUE")"
      [[ -n "$DUE_N" ]] || { echo "remind: --due must be 'YYYY-MM-DD HH:MM' or 'YYYY-MM-DD' (got: $R_DUE). Nothing was set." >&2; exit 1; }
      DUES+=("$DUE_N"); RRULES+=("")
    fi

    # --until / --count only meaningful with a recurrence.
    if [[ -n "${R_UNTIL//[[:space:]]/}" || -n "${R_COUNT//[[:space:]]/}" ]]; then
      HAS_REC=0
      for rr in "${RRULES[@]}"; do [[ -n "$rr" ]] && HAS_REC=1; done
      if [[ "$HAS_REC" -eq 0 ]]; then
        echo "remind: --until/--count only apply to a recurring reminder (add --cron or --repeat). Nothing was set." >&2; exit 1
      fi
    fi

    # Create each resolved reminder.
    ADDED=(); FAILED=0
    for i in "${!DUES[@]}"; do
      due="${DUES[$i]}"; rrule="${RRULES[$i]}"
      rrule="$(_apply_bound "$rrule" "$R_UNTIL" "$R_COUNT")"
      ARGS=(add --title "$R_TEXT" --due "$due")
      [[ -n "$rrule" ]]       && ARGS+=(--rrule "$rrule")
      [[ -n "$R_PRIORITY" ]]  && ARGS+=(--priority "$R_PRIORITY")
      [[ -n "$ALARMS" ]]      && ARGS+=(--alarms "$ALARMS")
      [[ -n "$R_NOTES" ]]     && ARGS+=(--notes "$R_NOTES")
      RES="$(pbrain_reminders_run "${ARGS[@]}")"
      if _helper_guidance "$RES"; then exit 1; fi
      case "$RES" in
        ADDED\ *) ADDED+=("${RES#ADDED }  @ $due${rrule:+  ($rrule)}") ;;
        *) echo "remind: failed to create reminder for $due ($RES)" >&2; FAILED=1 ;;
      esac
    done

    if [[ ${#ADDED[@]} -gt 0 ]]; then
      LIST_TXT="${PBRAIN_REMINDERS_LIST:-default list}"
      if [[ ${#ADDED[@]} -eq 1 ]]; then
        echo "REMIND_ADDED ${ADDED[0]%%  *}"
        echo "Added to Reminders ($LIST_TXT): \"$R_TEXT\" — ${ADDED[0]#*  @ }"
      else
        echo "REMIND_ADDED (${#ADDED[@]} reminders)"
        echo "Added ${#ADDED[@]} reminders to Reminders ($LIST_TXT) for \"$R_TEXT\":"
        for a in "${ADDED[@]}"; do echo "  - ${a#*  @ }  [id: ${a%%  *}]"; done
      fi
    fi
    [[ "$FAILED" -eq 0 ]] || exit 1
    ;;

  # -------------------------------------------------------------------------
  list|ls)
    echo "REMIND_LIST ($NOW_DT)"
    RES="$(pbrain_reminders_run list)"
    if _helper_guidance "$RES"; then exit 1; fi
    if [[ -z "${RES//[[:space:]]/}" || "$RES" == "ERROR:no-output" ]]; then
      echo "(no upcoming pbrain reminders)"
    else
      # Each row: id<TAB>due<TAB>priority<TAB>rrule<TAB>title
      while IFS=$'\t' read -r id due pri rrule title; do
        [[ -n "$id" ]] || continue
        line="- $title — $due"
        [[ "$pri" != "none" ]] && line="$line  [$pri]"
        [[ "$rrule" != "-" && -n "$rrule" ]] && line="$line  {$rrule}"
        echo "$line  [id: $id]"
      done <<< "$RES"
    fi
    ;;

  # -------------------------------------------------------------------------
  edit)
    shift || true
    E_ID="${1:-}"; shift || true
    if [[ -z "${E_ID//[[:space:]]/}" || "$E_ID" == --* ]]; then
      echo "remind: edit requires a reminder id (see \`remind.sh list\`)" >&2; exit 1
    fi
    E_TEXT=""; E_DUE=""; E_CRON=""; E_REPEAT=""; E_PRIORITY=""; E_EARLY=""
    E_NOTES=""; E_CLEAR_REC=0; E_CLEAR_EARLY=0; E_UNTIL=""; E_COUNT=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --text|--title)     E_TEXT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --due)              E_DUE="${2:-}"; shift 2 2>/dev/null || shift ;;
        --cron)             E_CRON="${2:-}"; shift 2 2>/dev/null || shift ;;
        --repeat)           E_REPEAT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --priority)         E_PRIORITY="${2:-}"; shift 2 2>/dev/null || shift ;;
        --early)            E_EARLY="${2:-}"; shift 2 2>/dev/null || shift ;;
        --until)            E_UNTIL="${2:-}"; shift 2 2>/dev/null || shift ;;
        --count)            E_COUNT="${2:-}"; shift 2 2>/dev/null || shift ;;
        --notes)            E_NOTES="${2:-}"; shift 2 2>/dev/null || shift ;;
        --clear-recurrence) E_CLEAR_REC=1; shift ;;
        --clear-early)      E_CLEAR_EARLY=1; shift ;;
        *) shift ;;
      esac
    done
    if [[ -n "${E_UNTIL//[[:space:]]/}" && -n "${E_COUNT//[[:space:]]/}" ]]; then
      echo "remind: use either --until or --count, not both." >&2; exit 1
    fi
    if [[ ( -n "${E_UNTIL//[[:space:]]/}" || -n "${E_COUNT//[[:space:]]/}" ) \
          && -z "${E_CRON//[[:space:]]/}" && -z "${E_REPEAT//[[:space:]]/}" ]]; then
      echo "remind: --until/--count on edit need the recurrence too — re-state it with --cron or --repeat (e.g. --cron \"<same expr>\" --until <date>)." >&2; exit 1
    fi
    ARGS=(edit --id "$E_ID")
    [[ -n "$E_TEXT" ]]     && ARGS+=(--title "$E_TEXT")
    [[ -n "$E_NOTES" ]]    && ARGS+=(--notes "$E_NOTES")
    [[ -n "$E_PRIORITY" ]] && ARGS+=(--priority "$E_PRIORITY")
    if [[ -n "${E_DUE//[[:space:]]/}" ]]; then
      DUE_N="$(_normalize_due "$E_DUE")"
      [[ -n "$DUE_N" ]] || { echo "remind: --due must be 'YYYY-MM-DD HH:MM' or 'YYYY-MM-DD'." >&2; exit 1; }
      ARGS+=(--due "$DUE_N")
    fi
    # Recurrence edit: a single rule only (editing can't split into many).
    if [[ -n "${E_CRON//[[:space:]]/}" ]]; then
      MAP="$(pbrain_cron_to_rrules "$E_CRON" "")"
      if [[ "$MAP" == REJECT* ]]; then
        echo "remind: can't edit to that schedule — $(printf '%s' "$MAP" | head -1 | cut -f3)" >&2; exit 1
      fi
      NLINES="$(printf '%s\n' "$MAP" | grep -c '^OK' || true)"
      if [[ "$NLINES" -ne 1 ]]; then
        echo "remind: that schedule needs $NLINES separate reminders, which edit can't do. Cancel this one and add the new schedule instead." >&2; exit 1
      fi
      EDUE="$(printf '%s' "$MAP" | head -1 | cut -f2)"
      ERRULE="$(printf '%s' "$MAP" | head -1 | cut -f3)"
      ERRULE="$(_apply_bound "$ERRULE" "$E_UNTIL" "$E_COUNT")"
      # Re-anchor due to the next occurrence unless an explicit --due was given.
      [[ -n "${E_DUE//[[:space:]]/}" ]] || ARGS+=(--due "$EDUE")
      ARGS+=(--rrule "$ERRULE")
    elif [[ -n "${E_REPEAT//[[:space:]]/}" ]]; then
      ERRULE="$(pbrain_calendar_rrule "$E_REPEAT")"
      if [[ "$ERRULE" == "INVALID" ]]; then
        echo "remind: unrecognized --repeat '$E_REPEAT'." >&2; exit 1
      fi
      if [[ "$ERRULE" == *"FREQ=HOURLY"* || "$ERRULE" == *"FREQ=MINUTELY"* ]]; then
        echo "remind: Apple Reminders can't repeat sub-daily. Use /remind-blocking." >&2; exit 1
      fi
      ERRULE="$(_apply_bound "$ERRULE" "$E_UNTIL" "$E_COUNT")"
      ARGS+=(--rrule "$ERRULE")
    fi
    [[ "$E_CLEAR_REC" -eq 1 ]]   && ARGS+=(--clear-recurrence)
    if [[ "$E_CLEAR_EARLY" -eq 1 ]]; then
      ARGS+=(--clear-alarms)
    elif [[ -n "${E_EARLY//[[:space:]]/}" ]]; then
      AL="0"; IFS=',' read -ra _e2 <<< "$E_EARLY"
      for e in "${_e2[@]}"; do e="${e//[[:space:]]/}"; [[ -n "$e" ]] && AL="$AL,$e"; done
      ARGS+=(--alarms "$AL")
    fi
    RES="$(pbrain_reminders_run "${ARGS[@]}")"
    if _helper_guidance "$RES"; then exit 1; fi
    case "$RES" in
      EDITED)    echo "Updated reminder $E_ID." ;;
      NOT_FOUND) echo "remind: no reminder with id $E_ID (see \`remind.sh list\`)." >&2; exit 1 ;;
      *)         echo "remind: edit failed ($RES)." >&2; exit 1 ;;
    esac
    ;;

  # -------------------------------------------------------------------------
  done|complete)
    shift || true
    [[ $# -gt 0 ]] || { echo "remind: done requires at least one reminder id (see \`remind.sh list\`)" >&2; exit 1; }
    OK=(); GONE=(); ERR=()
    for id in "$@"; do
      [[ -n "${id//[[:space:]]/}" ]] || continue
      RES="$(pbrain_reminders_run complete --id "$id")"
      if _helper_guidance "$RES"; then exit 1; fi
      case "$RES" in
        COMPLETED) OK+=("$id") ;;
        NOT_FOUND) GONE+=("$id") ;;
        *)         ERR+=("$id") ;;
      esac
    done
    [[ ${#OK[@]}   -gt 0 ]] && echo "Marked done: ${OK[*]}" || true
    [[ ${#GONE[@]} -gt 0 ]] && echo "Not found (already gone?): ${GONE[*]}" || true
    [[ ${#ERR[@]}  -gt 0 ]] && { echo "Failed: ${ERR[*]}" >&2; exit 1; }
    [[ ${#OK[@]} -eq 0 && ${#GONE[@]} -eq 0 ]] && echo "Nothing to do." || true
    ;;

  # -------------------------------------------------------------------------
  cancel|delete|rm)
    shift || true
    [[ $# -gt 0 ]] || { echo "remind: cancel requires at least one reminder id (see \`remind.sh list\`)" >&2; exit 1; }
    OK=(); GONE=(); ERR=()
    for id in "$@"; do
      [[ -n "${id//[[:space:]]/}" ]] || continue
      RES="$(pbrain_reminders_run delete --id "$id")"
      if _helper_guidance "$RES"; then exit 1; fi
      case "$RES" in
        DELETED)   OK+=("$id") ;;
        NOT_FOUND) GONE+=("$id") ;;
        *)         ERR+=("$id") ;;
      esac
    done
    [[ ${#OK[@]}   -gt 0 ]] && echo "Removed: ${OK[*]}" || true
    [[ ${#GONE[@]} -gt 0 ]] && echo "Already gone (no matching reminder): ${GONE[*]}" || true
    [[ ${#ERR[@]}  -gt 0 ]] && { echo "Failed to remove: ${ERR[*]}" >&2; exit 1; }
    [[ ${#OK[@]} -eq 0 && ${#GONE[@]} -eq 0 ]] && echo "Nothing to remove." || true
    ;;

  # -------------------------------------------------------------------------
  access|reminders-access|calendar-access|grant)
    RES="$(pbrain_reminders_access || true)"
    case "$RES" in
      OK)            echo "Reminders access granted — /remind can create, edit, and remove your reminders." ;;
      ACCESS_DENIED) echo "Reminders access was denied. Enable pbrain-reminders in System Settings → Privacy & Security → Reminders, then re-run." ;;
      UNAVAILABLE)   echo "EventKit helper unavailable (needs swiftc from Xcode Command Line Tools: \`xcode-select --install\`). /remind can't manage Reminders without it." ;;
      *)             echo "Couldn't determine Reminders access state ($RES)." ;;
    esac
    ;;

  # -------------------------------------------------------------------------
  help|-h|--help)
    sed -n '4,50p' "$SELF"
    ;;

  # -------------------------------------------------------------------------
  # Entry path: empty or natural-language input. Hand a context block to Claude
  # to decide intent (create / list / edit / complete / cancel) and act on Apple
  # Reminders.
  *)
    RAW="$*"
    UPCOMING="$(pbrain_reminders_run list 2>/dev/null || true)"
    case "$UPCOMING" in
      UNAVAILABLE|ACCESS_DENIED|ERROR:*|"") UPCOMING="(none listed — run /remind access if reminders exist)";;
    esac
    cat <<ENTRY
REMIND_ENTRY
now: $NOW_DT ($DOW)
now_iso: $NOW_ISO
today: $TODAY
reminders_list: ${PBRAIN_REMINDERS_LIST:-default}
raw_input: $RAW

=== UPCOMING PBRAIN REMINDERS (id<TAB>due<TAB>priority<TAB>rrule<TAB>title) ===
$UPCOMING

---
INSTRUCTIONS — you are handling a /remind invocation.

/remind creates real Apple **Reminders** (EKReminder), NOT Calendar events. They
fire in Reminders + Notification Center and sync across the user's Apple devices.
They do NOT appear on the calendar grid, so they do NOT anchor /plan-my-day. The
raw_input above is whatever the user typed after /remind (may be empty). Read it,
work out the details, and act by calling the right subcommand with the Bash tool.
Use the absolute path:
  $SELF

1. CREATE (raw_input describes something to be reminded of) — the common case.
   Derive:
   - TITLE (--text): a short clean imperative title; strip "remind me to".
   - PRIORITY (--priority high|medium|low): only if the user signals urgency
     ("important", "urgent", "high priority"). Omit otherwise.
   - EARLY ALARM (--early "15" or "15,60"): minutes BEFORE the due time, only if
     they ask for a heads-up ("warn me 15 min before"). The at-due alert is
     always added; --early adds extra earlier ones.
   - NOTES (--notes): extra context worth keeping (a link, phone number, the why).

   Then choose ONE timing form:
   a) ONE-OFF → --due "YYYY-MM-DD HH:MM", a concrete future datetime relative to
      now ($NOW_DT, $DOW). "tomorrow 3pm" → that date 15:00. A reminder needs a
      TIME to alert; a date-only --due anchors to 09:00. A one-off due must be in
      the future — if a clock time already passed today, assume the next day or
      ask which day.
   b) RECURRING → --cron "<5-field cron>"  (PREFERRED for repeats). The cron's
      minute+hour set the time, so NO --due is needed. Map the user's words to
      cron:
        every day 8am            → "0 8 * * *"
        weekdays 7:30            → "30 7 * * 1-5"
        every Monday 6pm         → "0 18 * * 1"
        Wed & Sat 9am            → "0 9 * * 3,6"
        1st of month 10am        → "0 10 1 * *"
        15th 9am                 → "0 9 15 * *"
        first Monday 8am         → "0 8 * * 1#1"     (dow#n = nth weekday)
        last Friday 10pm         → "0 22 * * 5L"     (dowL = last weekday)
        Dec 25 9am               → "0 9 25 12 *"
        quarterly 1st 12pm       → "0 12 1 1,4,7,10 *"
        9am AND 5pm daily        → "0 9,17 * * *"    (auto-splits into 2 reminders)
      cron dow: 0/7=Sun,1=Mon..6=Sat. The shell validates the cron and maps it to
      an Apple recurrence; it will REJECT sub-daily ("every 5 min", "hourly") —
      those belong to /remind-blocking, tell the user.
   c) EVERY-N INTERVAL that cron can't express (every 2 days/weeks/months) →
      --due "anchor datetime" --repeat <token>, token one of:
        every-Nd | every-Nw[:WE,SA] | daily | weekdays | weekly | weekly:TU |
        monthly | monthly:1MO
   - BOUNDED (with --cron or --repeat): add ONE of --until "YYYY-MM-DD" or
     --count N. Don't pass both.
   - Run (examples):
       bash "$SELF" add --text "drink water" --cron "0 9,13,17 * * *"
       bash "$SELF" add --text "call mom" --due "2026-06-08 18:00" --priority high --early "30"
       bash "$SELF" add --text "pay rent" --cron "0 9 1 * *" --until "2027-01-01"
   - Confirm back in one line.

2. LIST: run \`bash "$SELF" list\` (or read the UPCOMING block) and show them.

3. COMPLETE vs CANCEL — these now DIFFER:
   - "I did it / mark done" → \`bash "$SELF" done <id>\` (marks complete; a
     recurring reminder rolls forward to its next occurrence).
   - "remove it / cancel / delete" → \`bash "$SELF" cancel <id>\` (deletes the
     reminder; a recurring one removes the whole series).
   Match the user's words to an id in the UPCOMING block.

4. EDIT (change time/recurrence/priority/title of an existing reminder, incl.
   "this and all future" — a recurring reminder is one series, so editing it
   changes all future occurrences):
     bash "$SELF" edit <id> [--text ...] [--due "..."] [--cron "..."]
        [--repeat <token>] [--until YYYY-MM-DD | --count N] [--clear-recurrence]
        [--priority ...] [--early "..."] [--clear-early] [--notes ...]

   PAUSE / SKIP A DATE RANGE of a recurring reminder (e.g. "remove my daily
   reminder from Jun 10 to Jun 20") — the API has no per-occurrence skip, so do
   it as cap-then-resume: end the series the day BEFORE the gap, then start a
   fresh identical series the day AFTER. Resolve the dates and the original
   cron+title (read them from the UPCOMING block), state it in ONE line, and ask
   the user to confirm — then run BOTH commands on yes:
     "I'll end the daily reminder on Jun 9 and restart it Jun 21 (skipping Jun 10–20) — ok?"
     → on yes:
        bash "$SELF" edit <id> --cron "<same cron>" --until "2026-06-09"
        bash "$SELF" add  --text "<same title>" --cron "<same cron>" --due "2026-06-21 00:00" [carry --priority/--early]
   (The --due on the resume add is just an anchor — the first new occurrence is
   the cron's time on/after that date.) Use the same confirm-then-act shape for
   any other per-occurrence change. Always end with the one-line alternative:
   "— or you can pause/skip individual dates directly in the Reminders app."

5. ACCESS: if any op reports access isn't granted, tell the user to run
   \`/remind access\` once and approve the macOS Reminders prompt.

The command's output is authoritative — relay it. Keep it tight; one line is enough.
ENTRY
    pbrain_emit_self_improve "remind" || true
    ;;
esac
