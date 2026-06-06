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

# Full-screen blocking overlay -----------------------------------------------
# /remind-blocking fires a hard-to-dismiss "Take a break"-style overlay instead
# of a notification. It's a separate compiled app bundle (pbrain-overlay.app)
# built from lib/pbrain-overlay.swift — same packaging trick as pbrain-notify,
# which is what lets it launch reliably from the launchd poller. Override the
# build location with PBRAIN_OVERLAY_APP, the background colour with
# PBRAIN_OVERLAY_BG (hex, e.g. "#1e3a5f").
PBRAIN_OVERLAY_APP="${PBRAIN_OVERLAY_APP:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/pbrain-overlay.app}"
export PBRAIN_OVERLAY_APP

# Build (or rebuild) pbrain-overlay.app from the checked-in Swift source.
# Idempotent + best-effort, mirroring pbrain_notify_build: rebuilds only when the
# binary is missing or older than the source; a missing swiftc or a compile
# failure just leaves the app absent and pbrain_overlay_show falls back to a
# plain notification. Never exits non-zero, never prints.
pbrain_overlay_build() {
  command -v swiftc >/dev/null 2>&1 || return 0
  local lib_dir src bin
  lib_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 0
  src="$lib_dir/pbrain-overlay.swift"
  [[ -f "$src" ]] || return 0
  bin="$PBRAIN_OVERLAY_APP/Contents/MacOS/pbrain-overlay"
  [[ -x "$bin" && ! "$src" -nt "$bin" ]] && return 0
  mkdir -p "$PBRAIN_OVERLAY_APP/Contents/MacOS" 2>/dev/null || return 0
  if [[ ! -f "$PBRAIN_OVERLAY_APP/Contents/Info.plist" ]]; then
    cat > "$PBRAIN_OVERLAY_APP/Contents/Info.plist" 2>/dev/null <<'PLIST' || return 0
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.pbrain.overlay</string>
  <key>CFBundleName</key><string>pbrain-overlay</string>
  <key>CFBundleExecutable</key><string>pbrain-overlay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
  fi
  local tmp="$bin.tmp.$$"
  if swiftc -suppress-warnings "$src" -o "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$bin" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# Show the full-screen blocking overlay. Args reach the app as argv — never
# interpolated into an interpreted string — so arbitrary message text is inert.
#   pbrain_overlay_show <message> <seconds> [<hold_seconds>] [<background-hex>]
# <seconds> 0 = no countdown (stays until the user holds space to skip).
# Launched with `open -n` so it runs in a proper Launch Services / GUI context
# (works from the launchd poller's gui session); falls back to a notification if
# the app can't be built (no swiftc).
#   pbrain_overlay_show <message> <seconds> [<hold>] [<bg-hex>] [<id>] [<db>] [<repeat>]
# When <id> + <db> are passed the overlay resolves the reminder on dismissal
# (hold Control → cancelled, hold Return → done, countdown end → done). <repeat>
# (empty for one-shots) tells the overlay NOT to mutate a repeating row, whose
# next occurrence has already been scheduled by the tick.
pbrain_overlay_show() {
  local msg="${1:-Take a break}" secs="${2:-0}" hold="${3:-5}" bg="${4:-${PBRAIN_OVERLAY_BG:-}}"
  local rid="${5:-}" db="${6:-}" rep="${7:-}"
  pbrain_overlay_build
  local bin="$PBRAIN_OVERLAY_APP/Contents/MacOS/pbrain-overlay"
  if [[ -x "$bin" ]]; then
    local args=(--message "$msg" --seconds "$secs" --hold "$hold")
    [[ -n "$bg" ]]  && args+=(--background "$bg")
    [[ -n "$rid" ]] && args+=(--id "$rid")
    [[ -n "$db" ]]  && args+=(--db "$db")
    # Pass --repeat even when empty so the overlay treats it as a one-shot.
    args+=(--repeat "$rep")
    if command -v open >/dev/null 2>&1; then
      open -n "$PBRAIN_OVERLAY_APP" --args "${args[@]}" >/dev/null 2>&1 && return 0
    fi
    # Fallback: run the Mach-O directly (detached) if `open` is unavailable.
    "$bin" "${args[@]}" >/dev/null 2>&1 &
    return 0
  fi
  # No compiled app — degrade to a normal notification so the reminder still surfaces.
  pbrain_notify "Reminder" "$msg" || true
}

# Apple Calendar integration -------------------------------------------------
# /remind creates a real Calendar event per reminder, so Calendar owns firing
# (reliable, synced across devices, editable in Calendar.app) instead of our
# launchd poller. These helpers wrap osascript. macOS-only + best-effort: a
# missing osascript or a Calendar error returns non-zero/empty and the caller
# falls back. Override the target calendar with PBRAIN_CALENDAR.
PBRAIN_CALENDAR="${PBRAIN_CALENDAR:-Calendar}"
export PBRAIN_CALENDAR

# Marker stamped into every pbrain-created event's notes, so list/cancel can
# tell our reminders apart from the user's own calendar events. It's a normal
# (visible) footer line — harmless in Calendar.app, and unique enough to filter.
PBRAIN_CAL_MARKER="${PBRAIN_CAL_MARKER:-⟦pbrain-reminder⟧}"
export PBRAIN_CAL_MARKER

# EventKit helper app — robustly DELETES calendar events (incl. recurring iCloud
# series, which AppleScript can't reliably remove). It needs Calendar access (a
# TCC permission separate from AppleScript's Automation access), keyed to a real
# app bundle, so we compile lib/pbrain-calendar.swift into pbrain-calendar.app
# and launch it via `open` (the prompt is then attributed to the app, granted
# once by the user). Override the build location with PBRAIN_CALENDAR_APP.
PBRAIN_CALENDAR_APP="${PBRAIN_CALENDAR_APP:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/pbrain-calendar.app}"
export PBRAIN_CALENDAR_APP

# Build (or rebuild) pbrain-calendar.app from the checked-in Swift source.
# Idempotent + best-effort (mirrors pbrain_notify_build / pbrain_overlay_build):
# rebuilds only when the binary is missing or older than the source; a missing
# swiftc or a compile failure just leaves the app absent and pbrain_calendar_delete
# falls back to AppleScript. The Info.plist carries the Calendar usage strings
# (required for the access prompt) and LSUIElement (no Dock icon). Ad-hoc signs
# the bundle so TCC keeps a stable identity across runs. Never exits non-zero.
pbrain_calendar_app_build() {
  command -v swiftc >/dev/null 2>&1 || return 0
  local lib_dir src bin
  lib_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 0
  src="$lib_dir/pbrain-calendar.swift"
  [[ -f "$src" ]] || return 0
  bin="$PBRAIN_CALENDAR_APP/Contents/MacOS/pbrain-calendar"
  [[ -x "$bin" && ! "$src" -nt "$bin" ]] && return 0
  mkdir -p "$PBRAIN_CALENDAR_APP/Contents/MacOS" 2>/dev/null || return 0
  if [[ ! -f "$PBRAIN_CALENDAR_APP/Contents/Info.plist" ]]; then
    cat > "$PBRAIN_CALENDAR_APP/Contents/Info.plist" 2>/dev/null <<'PLIST' || return 0
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.pbrain.calendar</string>
  <key>CFBundleName</key><string>pbrain-calendar</string>
  <key>CFBundleExecutable</key><string>pbrain-calendar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsUsageDescription</key><string>pbrain manages your /remind reminders as Calendar events, including removing ones you cancel.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>pbrain manages your /remind reminders as Calendar events, including removing ones you cancel.</string>
</dict>
</plist>
PLIST
  fi
  local tmp="$bin.tmp.$$"
  if swiftc -suppress-warnings "$src" -o "$tmp" >/dev/null 2>&1; then
    mv -f "$tmp" "$bin" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
    # Ad-hoc sign so TCC tracks a stable identity across rebuilds (best-effort).
    command -v codesign >/dev/null 2>&1 && codesign --force --sign - "$PBRAIN_CALENDAR_APP" >/dev/null 2>&1 || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# _pbrain_cal_app_run <op-args...> — launch the EventKit app via `open` and return
# the one-line status it writes. Must go through `open` (not direct exec) so the
# Calendar TCC permission is attributed to the bundle identity. `open -W` waits
# for the app to quit, but a freshly built+signed binary can be slow on its very
# first launch (Gatekeeper assessment) and return before the result is flushed,
# so we ALSO poll the result file briefly. Echoes "" if nothing was produced.
_pbrain_cal_app_run() {
  local resf; resf="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/pbrain-cal-$$.res")"
  : > "$resf"
  open -W -n "$PBRAIN_CALENDAR_APP" --args "$@" --result "$resf" >/dev/null 2>&1 || true
  local res tries=0
  res="$(cat "$resf" 2>/dev/null || true)"
  while [[ -z "${res//[[:space:]]/}" && $tries -lt 20 ]]; do
    sleep 0.3
    res="$(cat "$resf" 2>/dev/null || true)"
    tries=$((tries + 1))
  done
  rm -f "$resf" 2>/dev/null || true
  printf '%s' "$res"
}

# pbrain_calendar_access — request/verify Calendar (EventKit) access via the app.
# Echoes OK if granted, ACCESS_DENIED if not, or UNAVAILABLE if the app can't be
# built. Used by `/remind calendar-access` to trigger the one-time grant.
pbrain_calendar_access() {
  pbrain_calendar_app_build
  local bin="$PBRAIN_CALENDAR_APP/Contents/MacOS/pbrain-calendar"
  if [[ ! -x "$bin" ]] || ! command -v open >/dev/null 2>&1; then
    printf 'UNAVAILABLE\n'; return 0
  fi
  local res; res="$(_pbrain_cal_app_run --op access-check)"
  printf '%s\n' "${res:-ERROR}"
}

# pbrain_calendar_add <summary> <YYYY-MM-DD HH:MM | YYYY-MM-DD> <rrule-or-empty> [<notes>]
# Creates a timed Calendar event with an alarm at start; echoes a pbrain HANDLE
# (a UUID embedded in the event notes) on success, prints nothing + returns 1 on
# failure. The handle — NOT the AppleScript uid or EventKit identifier — is what
# list/cancel use, because AppleScript's uid and EventKit's identifier don't line
# up (different identifier spaces). Embedding our own id in the notes and matching
# on it keeps create (AppleScript) and delete (EventKit) talking about the same
# event. The summary/notes reach osascript as argv (never interpolated) so quotes
# / $ / \ can't break or inject. A date-only due anchors to 09:00 local.
pbrain_calendar_add() {
  command -v osascript >/dev/null 2>&1 || return 1
  local summary="${1:-Reminder}" due="${2:-}" rrule="${3:-}" notes="${4:-}"
  [[ -n "${due//[[:space:]]/}" ]] || return 1
  # Mint a stable pbrain id and embed it in the notes as a hidden tag.
  local pbid
  pbid="$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || true)"
  [[ -n "${pbid//[[:space:]]/}" ]] || return 1
  # Compose the event notes: optional context, then the marker + id footer.
  local desc footer
  footer="$PBRAIN_CAL_MARKER"$'\n'"⟦pbrain-id:$pbid⟧"
  if [[ -n "${notes//[[:space:]]/}" ]]; then
    desc="$notes"$'\n\n'"$footer"
  else
    desc="$footer"
  fi
  # Split the due string into integer date components (date-only → 09:00) so the
  # AppleScript builds the date by assignment — robust against locale-dependent
  # AppleScript date-string parsing.
  local comps
  comps="$(python3 - "$due" <<'PY' 2>/dev/null || true
import sys, datetime
s = sys.argv[1].strip()
for fmt, anchor in (("%Y-%m-%d %H:%M", None), ("%Y-%m-%d", 9)):
    try:
        dt = datetime.datetime.strptime(s, fmt)
        if anchor is not None:
            dt = dt.replace(hour=anchor)
        print(f"{dt.year} {dt.month} {dt.day} {dt.hour} {dt.minute}")
        break
    except ValueError:
        continue
PY
)"
  [[ -n "${comps//[[:space:]]/}" ]] || return 1
  local uid
  # $comps is intentionally unquoted: it word-splits into the 5 integer argv items.
  uid="$(osascript - "$PBRAIN_CALENDAR" "$summary" "$rrule" "$desc" $comps <<'APPLESCRIPT' 2>/dev/null || true
on run argv
  set calName to item 1 of argv
  set theSummary to item 2 of argv
  set theRule to item 3 of argv
  set theDesc to item 4 of argv
  set y to (item 5 of argv) as integer
  set mo to (item 6 of argv) as integer
  set d to (item 7 of argv) as integer
  set hh to (item 8 of argv) as integer
  set mi to (item 9 of argv) as integer
  set startDate to (current date)
  set day of startDate to 1
  set year of startDate to y
  set month of startDate to mo
  set day of startDate to d
  set hours of startDate to hh
  set minutes of startDate to mi
  set seconds of startDate to 0
  set endDate to startDate + (15 * minutes)
  tell application "Calendar"
    tell calendar calName
      if theRule is "" then
        set ev to make new event with properties {summary:theSummary, start date:startDate, end date:endDate, description:theDesc}
      else
        set ev to make new event with properties {summary:theSummary, start date:startDate, end date:endDate, description:theDesc, recurrence:theRule}
      end if
      tell ev
        make new display alarm at end with properties {trigger interval:0}
      end tell
      return uid of ev
    end tell
  end tell
end run
APPLESCRIPT
)"
  # The AppleScript uid only confirms the event was created; the HANDLE we return
  # is our embedded pbrain id (what list/cancel match on).
  [[ -n "${uid//[[:space:]]/}" ]] || return 1
  printf '%s\n' "$pbid"
}

# pbrain_calendar_delete <uid> — remove the event carrying this UID. Echoes a
# status token so the caller can report honestly:
#   DELETED       — the EventKit helper removed it (reliable, incl. recurring)
#   NOT_FOUND     — no event with that UID (already gone)
#   ACCESS_DENIED — Calendar access not granted (run `/remind calendar-access`)
#   FALLBACK      — EventKit helper unavailable; tried AppleScript (UNRELIABLE for
#                   recurring iCloud events — may resync back)
#   ERROR         — the helper errored
# Never errors out (sourced under set -euo pipefail).
#
# Primary path: the bundled EventKit app, launched via `open` so the Calendar
# permission is attributed to the app bundle. AppleScript is the fallback only
# when the app can't be built (no swiftc) — and it's the unreliable path that
# motivated the EventKit helper in the first place.
pbrain_calendar_delete() {
  local uid="${1:-}"
  [[ -n "${uid//[[:space:]]/}" ]] || { printf 'NOT_FOUND\n'; return 0; }
  pbrain_calendar_app_build
  local bin="$PBRAIN_CALENDAR_APP/Contents/MacOS/pbrain-calendar"
  if [[ -x "$bin" ]] && command -v open >/dev/null 2>&1; then
    local res; res="$(_pbrain_cal_app_run --op delete --id "$uid" --calendar "$PBRAIN_CALENDAR")"
    case "$res" in
      DELETED*)       printf 'DELETED\n' ;;
      NOT_FOUND)      printf 'NOT_FOUND\n' ;;
      ACCESS_DENIED)  printf 'ACCESS_DENIED\n' ;;
      *)              printf 'ERROR\n' ;;
    esac
    return 0
  fi
  # Fallback: AppleScript (unreliable for recurring iCloud events). Single fresh
  # query + `exit repeat` on first match to dodge the delete-during-iteration
  # fault (-1728).
  command -v osascript >/dev/null 2>&1 || { printf 'ERROR\n'; return 0; }
  osascript - "$PBRAIN_CALENDAR" "$uid" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  set calName to item 1 of argv
  set theTag to "⟦pbrain-id:" & (item 2 of argv) & "⟧"
  set lo to (current date) - (400 * days)
  set hi to (current date) + (730 * days)
  tell application "Calendar"
    tell calendar calName
      set hit to missing value
      repeat with ev in (every event whose start date ≥ lo and start date ≤ hi)
        set dsc to description of ev
        if dsc is not missing value and dsc contains theTag then
          set hit to ev
          exit repeat
        end if
      end repeat
      if hit is not missing value then delete hit
    end tell
  end tell
end run
APPLESCRIPT
  printf 'FALLBACK\n'
  return 0
}

# pbrain_calendar_list [<days-ahead>] — print pbrain-created upcoming events as
# lines "handle<TAB>start<TAB>summary", filtered by the marker in their notes so
# the user's own calendar events are excluded. The handle is the embedded
# pbrain-id (what cancel matches on); events with the marker but no id (legacy)
# fall back to "legacy". Best-effort; prints nothing on error / when none match.
pbrain_calendar_list() {
  command -v osascript >/dev/null 2>&1 || return 0
  local days="${1:-60}"
  osascript - "$PBRAIN_CALENDAR" "$PBRAIN_CAL_MARKER" "$days" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
  set calName to item 1 of argv
  set marker to item 2 of argv
  set daysAhead to (item 3 of argv) as integer
  set startWin to (current date)
  set hours of startWin to 0
  set minutes of startWin to 0
  set seconds of startWin to 0
  set endWin to startWin + (daysAhead * days)
  set outLines to {}
  tell application "Calendar"
    tell calendar calName
      set evs to (every event whose start date ≥ startWin and start date ≤ endWin)
      repeat with ev in evs
        set dsc to description of ev
        if dsc is not missing value and dsc contains marker then
          set theHandle to "legacy"
          if dsc contains "⟦pbrain-id:" then
            set AppleScript's text item delimiters to "⟦pbrain-id:"
            set afterTag to text item 2 of dsc
            set AppleScript's text item delimiters to "⟧"
            set theHandle to text item 1 of afterTag
            set AppleScript's text item delimiters to ""
          end if
          set end of outLines to theHandle & tab & ((start date of ev) as string) & tab & (summary of ev)
        end if
      end repeat
    end tell
  end tell
  set AppleScript's text item delimiters to (ASCII character 10)
  return outLines as text
end run
APPLESCRIPT
  return 0
}

# pbrain_calendar_today [<YYYY-MM-DD>] — print the calendar events that occur on
# the given day (default: today) as time anchors, for /plan-my-day to build the
# day around. Output is three labelled groups:
#   TIMED:    "HH:MM-HH:MM<TAB>title"   one per timed occurrence, sorted
#   ALLDAY:   "title"                   all-day events landing today
#   FREQUENT: "every Nh|Nm<TAB>title"   sub-daily repeats (hourly/minutely pings)
# Prints "(none)" groups omitted. Best-effort; prints nothing on error.
#
# Why the two-stage dance: Apple Calendar's AppleScript returns recurrence
# MASTERS only (it does NOT expand instances into a date-window query), so a naive
# "events today" query misses any recurring event whose master started earlier.
# We therefore dump every master that started in the last ~400 days together with
# its RRULE, and expand "does it occur on <day>?" in Python. Reads the calendar
# named by PBRAIN_CALENDAR.
pbrain_calendar_today() {
  command -v osascript >/dev/null 2>&1 || return 0
  command -v python3   >/dev/null 2>&1 || return 0
  local day="${1:-}"
  local y mo d
  if [[ -n "$day" ]]; then
    y="${day%%-*}"; mo="${day#*-}"; mo="${mo%%-*}"; d="${day##*-}"
  else
    y="$(date +%Y)"; mo="$(date +%m)"; d="$(date +%d)"
  fi
  # Stage 1 — dump masters (started within [day-400d, end-of-day]) as records.
  # Fields are unit-separated (US, \x1f); records record-separated (RS, \x1e).
  local dump
  dump="$(osascript - "$PBRAIN_CALENDAR" "$y" "$mo" "$d" <<'APPLESCRIPT' 2>/dev/null || true
on run argv
  set calName to item 1 of argv
  set yy to (item 2 of argv) as integer
  set mm to (item 3 of argv) as integer
  set dd to (item 4 of argv) as integer
  set fld to (ASCII character 31)
  set rec to (ASCII character 30)
  set dayStart to (current date)
  set day of dayStart to 1
  set year of dayStart to yy
  set month of dayStart to mm
  set day of dayStart to dd
  set hours of dayStart to 0
  set minutes of dayStart to 0
  set seconds of dayStart to 0
  set dayEnd to dayStart + (1 * days) - 1
  set lo to dayStart - (400 * days)
  set outText to ""
  tell application "Calendar"
    tell calendar calName
      repeat with ev in (every event whose start date ≥ lo and start date ≤ dayEnd)
        try
          set sd to start date of ev
          set ed to end date of ev
          set ad to allday event of ev
          set adn to "0"
          if ad then set adn to "1"
          set rr to recurrence of ev
          if rr is missing value then set rr to ""
          set sm to summary of ev
          if sm is missing value then set sm to "(untitled)"
          set rowf to ((year of sd) as string) & fld & (((month of sd) as integer) as string) & fld & ((day of sd) as string) & fld & ((hours of sd) as string) & fld & ((minutes of sd) as string) & fld & ((hours of ed) as string) & fld & ((minutes of ed) as string) & fld & ((year of ed) as string) & fld & (((month of ed) as integer) as string) & fld & ((day of ed) as string) & fld & adn & fld & rr & fld & sm
          set outText to outText & rowf & rec
        end try
      end repeat
    end tell
  end tell
  return outText
end run
APPLESCRIPT
)"
  [[ -n "${dump//[[:space:]]/}" ]] || return 0
  # Stage 2 — expand occurrences for the target day. The dump is passed as argv
  # (NOT stdin): the heredoc already occupies python's stdin as the program text.
  python3 - "$y" "$mo" "$d" "$dump" <<'PYEOF' 2>/dev/null || true
import sys, datetime
y, mo, d = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
target = datetime.date(y, mo, d)
raw = sys.argv[4]
US, RS = "\x1f", "\x1e"

BYDAY = {"MO":0,"TU":1,"WE":2,"TH":3,"FR":4,"SA":5,"SU":6}

def parse_rrule(s):
    out = {}
    for part in (s or "").split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip().upper()] = v.strip().upper()
    return out

def until_date(v):
    # UNTIL is YYYYMMDD or YYYYMMDDTHHMMSSZ
    try:
        return datetime.datetime.strptime(v[:8], "%Y%m%d").date()
    except Exception:
        return None

import re as _re
def _nth_weekday(year, month, ordinal, weekday):
    # ordinal: +1..+5 (nth) or -1..-5 (nth from end). weekday: Mon=0..Sun=6.
    import calendar as _cal
    days = [d for d in range(1, _cal.monthrange(year, month)[1] + 1)
            if datetime.date(year, month, d).weekday() == weekday]
    idx = ordinal - 1 if ordinal > 0 else ordinal
    try:
        return datetime.date(year, month, days[idx])
    except (IndexError, ValueError):
        return None

def _monthly_byday_dates(year, month, byday_spec):
    # byday_spec like "1MO,-1FR" → set of dates in that month.
    out = set()
    for tok in byday_spec.split(","):
        tok = tok.strip().upper()
        m = _re.match(r'^(-?\d+)?(MO|TU|WE|TH|FR|SA|SU)$', tok)
        if not m:
            continue
        ordn = int(m.group(1)) if m.group(1) else 1
        wd = BYDAY[m.group(2)]
        dt = _nth_weekday(year, month, ordn, wd)
        if dt:
            out.add(dt)
    return out

def base_occurs(date, start_date, rule):
    """Does `date` match the recurrence PATTERN (ignoring UNTIL/COUNT)?"""
    freq = rule.get("FREQ", "")
    interval = int(rule.get("INTERVAL", "1") or "1")
    if date < start_date:
        return False
    if freq == "DAILY":
        return (date - start_date).days % interval == 0
    if freq == "WEEKLY":
        days = rule.get("BYDAY", "")
        wdset = {BYDAY[x] for x in days.split(",") if x in BYDAY} if days else {start_date.weekday()}
        if date.weekday() not in wdset:
            return False
        sm = start_date - datetime.timedelta(days=start_date.weekday())
        tm = date - datetime.timedelta(days=date.weekday())
        return ((tm - sm).days // 7) % interval == 0
    if freq == "MONTHLY":
        months = (date.year - start_date.year) * 12 + (date.month - start_date.month)
        if months < 0 or months % interval != 0:
            return False
        byday_spec = rule.get("BYDAY", "")
        if byday_spec:
            return date in _monthly_byday_dates(date.year, date.month, byday_spec)
        return date.day == start_date.day
    if freq == "YEARLY":
        return (date.month, date.day) == (start_date.month, start_date.day) and (date.year - start_date.year) % interval == 0
    return False

def occurs_today(start_date, rule):
    if not base_occurs(target, start_date, rule):
        return False
    u = until_date(rule.get("UNTIL", "")) if "UNTIL" in rule else None
    if u and target > u:
        return False
    if "COUNT" in rule:
        try:
            cnt = int(rule["COUNT"])
        except ValueError:
            cnt = None
        if cnt is not None:
            # 1-based index of `target` among occurrences from start_date.
            seen = 0
            cur = start_date
            while cur <= target:
                if base_occurs(cur, start_date, rule):
                    seen += 1
                cur += datetime.timedelta(days=1)
            if seen > cnt:
                return False
    return True

timed, allday, freq_list = [], [], []
for row in raw.split(RS):
    row = row.strip("\n\r")
    if not row.strip():
        continue
    f = row.split(US)
    if len(f) < 13:
        continue
    try:
        sy, smo, sd_, sh, smi, eh, emi, ey, emo, ed_, adn, rr, sm = f[:13]
        start_dt = datetime.datetime(int(sy), int(smo), int(sd_), int(sh), int(smi))
        end_dt = datetime.datetime(int(ey), int(emo), int(ed_), int(eh), int(emi))
    except Exception:
        continue
    sm = sm.strip()
    rule = parse_rrule(rr)
    freq = rule.get("FREQ", "")
    is_allday = adn == "1"
    has_rec = bool(rr.strip())

    # Sub-daily repeats are background pings, not single day anchors.
    if freq in ("HOURLY", "MINUTELY"):
        u = until_date(rule.get("UNTIL", "")) if "UNTIL" in rule else None
        if target >= start_dt.date() and (u is None or target <= u):
            iv = rule.get("INTERVAL", "1")
            unit = "h" if freq == "HOURLY" else "m"
            freq_list.append(f"every {iv}{unit}\t{sm}")
        continue

    if has_rec:
        hit = occurs_today(start_dt.date(), rule)
    else:
        hit = start_dt.date() == target
    if not hit:
        continue

    if is_allday:
        allday.append(sm)
    else:
        dur = max(0, int((end_dt - start_dt).total_seconds() // 60))
        end_label = (datetime.datetime.combine(target, start_dt.time()) + datetime.timedelta(minutes=dur))
        timed.append((start_dt.hour * 60 + start_dt.minute,
                      f"{start_dt:%H:%M}-{end_label:%H:%M}\t{sm}"))

timed.sort(key=lambda t: t[0])
out = []
if timed:
    out.append("TIMED:")
    out.extend(x[1] for x in timed)
if allday:
    out.append("ALLDAY:")
    out.extend(allday)
if freq_list:
    out.append("FREQUENT:")
    out.extend(sorted(set(freq_list)))
if out:
    print("\n".join(out))
PYEOF
}

# Map a pbrain repeat token to an iCalendar RRULE. Echoes:
#   - the RRULE string for a recognized token,
#   - "" (empty) for an empty token (one-shot event),
#   - "INVALID" for a non-empty token that doesn't parse (caller should error,
#     NOT silently create a one-shot).
# Supported tokens (case-insensitive):
#   daily                      FREQ=DAILY
#   weekdays                   FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR
#   weekly                     FREQ=WEEKLY              (on the --due weekday)
#   weekly:WE,SA               FREQ=WEEKLY;BYDAY=WE,SA  (specific days)
#   monthly                    FREQ=MONTHLY
#   monthly:1MO / monthly:-1FR FREQ=MONTHLY;BYDAY=1MO   (nth/last weekday of month)
#   every-Nd                   FREQ=DAILY;INTERVAL=N    (every N days)
#   every-Nw  / every-Nw:WE,SA FREQ=WEEKLY;INTERVAL=N[;BYDAY=…]  (every N weeks)
#   every-Nh / every-Nm        FREQ=HOURLY|MINUTELY;INTERVAL=N
#   every-Ns                   FREQ=MINUTELY;INTERVAL=1 (Calendar's floor is 1 min)
# Day codes: MO TU WE TH FR SA SU. All of these are expanded correctly by
# pbrain_calendar_today (so they anchor /plan-my-day right).
pbrain_calendar_rrule() {
  command -v python3 >/dev/null 2>&1 || { printf '\n'; return 0; }
  python3 - "${1:-}" <<'PY'
import sys, re
t = (sys.argv[1] or "").strip().lower()
if t == "":
    print(""); sys.exit(0)

def byday(s, allow_ordinal=False):
    parts = [p.strip() for p in s.split(",") if p.strip()]
    out = []
    pat = r'^(-?\d+)?(mo|tu|we|th|fr|sa|su)$' if allow_ordinal else r'^(mo|tu|we|th|fr|sa|su)$'
    for p in parts:
        m = re.match(pat, p)
        if not m:
            return None
        if allow_ordinal:
            ordn = m.group(1) or ""
            if ordn in ("0", "-0"):
                return None
            out.append(ordn + m.group(2).upper())
        else:
            out.append(p.upper())
    return out or None

if t == "daily":    print("FREQ=DAILY"); sys.exit(0)
if t == "weekdays": print("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"); sys.exit(0)
if t == "weekly":   print("FREQ=WEEKLY"); sys.exit(0)
if t == "monthly":  print("FREQ=MONTHLY"); sys.exit(0)

m = re.match(r'^weekly:(.+)$', t)
if m:
    bl = byday(m.group(1))
    print("FREQ=WEEKLY;BYDAY=" + ",".join(bl) if bl else "INVALID"); sys.exit(0)

m = re.match(r'^monthly:(.+)$', t)
if m:
    bl = byday(m.group(1), allow_ordinal=True)
    print("FREQ=MONTHLY;BYDAY=" + ",".join(bl) if bl else "INVALID"); sys.exit(0)

m = re.match(r'^every-(\d+)([dwhms])(?::(.+))?$', t)
if m:
    n, unit, days = int(m.group(1)), m.group(2), m.group(3)
    if n < 1:
        print("INVALID"); sys.exit(0)
    if days is not None and unit != 'w':
        print("INVALID"); sys.exit(0)   # day list only valid with weeks
    if unit == 'd': print(f"FREQ=DAILY;INTERVAL={n}"); sys.exit(0)
    if unit == 'w':
        rule = f"FREQ=WEEKLY;INTERVAL={n}"
        if days is not None:
            bl = byday(days)
            if not bl:
                print("INVALID"); sys.exit(0)
            rule += ";BYDAY=" + ",".join(bl)
        print(rule); sys.exit(0)
    if unit == 'h': print(f"FREQ=HOURLY;INTERVAL={n}"); sys.exit(0)
    if unit == 'm': print(f"FREQ=MINUTELY;INTERVAL={n}"); sys.exit(0)
    if unit == 's': print("FREQ=MINUTELY;INTERVAL=1"); sys.exit(0)

print("INVALID")
PY
}

# Echo the next datetime matching a 5-field cron expression strictly after
# <after> (default: now), formatted 'YYYY-MM-DD HH:MM'. Prints nothing if the
# expression is invalid — callers treat empty as "reject". Used by
# /remind-blocking to compute a cron reminder's initial due_at and to validate.
# (cron_next is also inlined in the tick; the two are kept in sync by tests.)
pbrain_cron_next() {
  command -v python3 >/dev/null 2>&1 || return 0
  local expr="${1:-}" after="${2:-}"
  [[ -n "$after" ]] || after="$(date '+%Y-%m-%d %H:%M')"
  python3 - "$expr" "$after" <<'PYEOF' 2>/dev/null || true
import sys, datetime
expr, after_s = sys.argv[1], sys.argv[2]

def _cron_field(field, lo, hi):
    vals = set()
    for part in field.strip().split(","):
        part = part.strip()
        if not part:
            continue
        step, rng = 1, part
        if "/" in part:
            rng, step_s = part.split("/", 1)
            try:
                step = int(step_s)
            except ValueError:
                return None
            if step < 1:
                return None
        if rng == "*":
            start, end = lo, hi
        elif "-" in rng:
            a, b = rng.split("-", 1)
            try:
                start, end = int(a), int(b)
            except ValueError:
                return None
        else:
            try:
                start = end = int(rng)
            except ValueError:
                return None
        if start > end or start < lo or end > hi:
            return None
        for v in range(start, end + 1, step):
            vals.add(v)
    return vals or None

def cron_next(expr, after):
    if not expr:
        return None
    parts = expr.split()
    if len(parts) != 5:
        return None
    fields = [_cron_field(parts[i], lo, hi) for i, (lo, hi) in
              enumerate([(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)])]
    if None in fields:
        return None
    mins, hours, doms, months, dows = fields
    dows = {0 if d == 7 else d for d in dows}
    dom_restricted = parts[2].strip() != "*"
    dow_restricted = parts[4].strip() != "*"
    t = (after + datetime.timedelta(minutes=1)).replace(second=0, microsecond=0)
    for _ in range(366 * 24 * 60):
        if t.minute in mins and t.hour in hours and t.month in months:
            cron_dow = (t.weekday() + 1) % 7
            dom_ok = t.day in doms
            dow_ok = cron_dow in dows
            if dom_restricted and dow_restricted:
                day_ok = dom_ok or dow_ok
            elif dom_restricted:
                day_ok = dom_ok
            elif dow_restricted:
                day_ok = dow_ok
            else:
                day_ok = True
            if day_ok:
                return t
        t += datetime.timedelta(minutes=1)
    return None

after = datetime.datetime.strptime(after_s, "%Y-%m-%d %H:%M")
nxt = cron_next(expr, after)
if nxt:
    print(nxt.strftime("%Y-%m-%d %H:%M"))
PYEOF
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
# Fired ONLY by the background poller (remind-blocking.sh tick, ~60s). There are
# deliberately NO opportunistic callers: a full-screen overlay is time-sensitive,
# and catching one up late just because some other command happened to run is the
# wrong behaviour. Notification reminders (/remind) live on Apple Calendar now and
# are fired by Calendar — pbrain no longer fires any notifications itself.
# Mode (first arg):
#   all          (default) — fire every due reminder. The poller passes this.
#   notify-only  — fire only NOTIFICATION reminders; leave blocking-overlay rows
#                 untouched. Retained as a guard mode for callers that must never
#                 pop an overlay; no command uses it currently.
pbrain_reminders_tick() {
  local mode="${1:-all}"
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -f "$PBRAIN_DB_FILE" ]] || return 0
  local now due overlay_busy=0 is_screen_locked=0
  now="$(date '+%Y-%m-%d %H:%M')"
  # Serialize overlays: if one is already on screen, defer firing more this tick.
  if command -v pgrep >/dev/null 2>&1 && pgrep -x pbrain-overlay >/dev/null 2>&1; then
    overlay_busy=1
  fi
  # Skip blocking overlays when the screen is locked — they'd fire invisibly and
  # be consumed without the user ever seeing them. Best-effort; if ioreg is
  # unavailable or the key is absent, we assume unlocked (safe to fire).
  if command -v ioreg >/dev/null 2>&1; then
    ioreg -n IOPMrootDomain -r 2>/dev/null | grep -q '"CGSSessionScreenIsLocked" = Yes' \
      && is_screen_locked=1 || true
  fi
  due="$(python3 - "$PBRAIN_DB_FILE" "$now" "$mode" "$overlay_busy" "$is_screen_locked" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys, datetime
db, now_s, mode, overlay_busy, is_screen_locked = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5] == "1"
now = datetime.datetime.strptime(now_s, "%Y-%m-%d %H:%M")
# In notify-only mode, exclude blocking-overlay rows from selection entirely, so
# they are neither fired nor advanced — they stay due for the next poller tick.
BLOCK_FILTER = " AND block_seconds IS NULL" if mode == "notify-only" else ""

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

# --- cron --------------------------------------------------------------------
# A standard 5-field cron expression: "minute hour day-of-month month day-of-week".
# Supports *, comma lists, a-b ranges, and */step or a-b/step. dow 0 or 7 = Sunday.
# When both dom and dow are restricted, a row matches on EITHER (standard cron).
def _cron_field(field, lo, hi):
    vals = set()
    for part in field.strip().split(","):
        part = part.strip()
        if not part:
            continue
        step, rng = 1, part
        if "/" in part:
            rng, step_s = part.split("/", 1)
            try:
                step = int(step_s)
            except ValueError:
                return None
            if step < 1:
                return None
        if rng == "*":
            start, end = lo, hi
        elif "-" in rng:
            a, b = rng.split("-", 1)
            try:
                start, end = int(a), int(b)
            except ValueError:
                return None
        else:
            try:
                start = end = int(rng)
            except ValueError:
                return None
        if start > end or start < lo or end > hi:
            return None
        for v in range(start, end + 1, step):
            vals.add(v)
    return vals or None

def cron_next(expr, after):
    if not expr:
        return None
    parts = expr.split()
    if len(parts) != 5:
        return None
    mins   = _cron_field(parts[0], 0, 59)
    hours  = _cron_field(parts[1], 0, 23)
    doms   = _cron_field(parts[2], 1, 31)
    months = _cron_field(parts[3], 1, 12)
    dows   = _cron_field(parts[4], 0, 7)
    if None in (mins, hours, doms, months, dows):
        return None
    dows = {0 if d == 7 else d for d in dows}
    dom_restricted = parts[2].strip() != "*"
    dow_restricted = parts[4].strip() != "*"
    # Search minute-by-minute from the next minute, up to ~1 year ahead.
    t = (after + datetime.timedelta(minutes=1)).replace(second=0, microsecond=0)
    for _ in range(366 * 24 * 60):
        if t.minute in mins and t.hour in hours and t.month in months:
            cron_dow = (t.weekday() + 1) % 7   # py Mon=0..Sun=6 → cron Sun=0..Sat=6
            dom_ok = t.day in doms
            dow_ok = cron_dow in dows
            if dom_restricted and dow_restricted:
                day_ok = dom_ok or dow_ok
            elif dom_restricted:
                day_ok = dom_ok
            elif dow_restricted:
                day_ok = dow_ok
            else:
                day_ok = True
            if day_ok:
                return t
        t += datetime.timedelta(minutes=1)
    return None

try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    con.isolation_level = None
    con.execute("BEGIN IMMEDIATE")
    # block_seconds / hold_seconds drive the /remind-blocking full-screen overlay;
    # older DBs predate those columns, so fall back to the base shape and treat
    # every row as a normal notification reminder.
    # BLOCK_FILTER is a fixed literal (not user input) — safe to concatenate.
    try:
        rows = con.execute(
            "SELECT id, text, due_at, repeat, block_seconds, hold_seconds, cron FROM reminders "
            "WHERE status='pending' AND due_at IS NOT NULL AND fired_at IS NULL" + BLOCK_FILTER
        ).fetchall()
    except sqlite3.OperationalError:
        # Old DB without block_seconds/cron: every row is a notification reminder,
        # so notify-only needs no filter here.
        rows = [(r[0], r[1], r[2], r[3], None, None, None) for r in con.execute(
            "SELECT id, text, due_at, repeat FROM reminders "
            "WHERE status='pending' AND due_at IS NOT NULL AND fired_at IS NULL"
        ).fetchall()]
    fired = []
    overlay_fired = False   # serialize: at most ONE overlay launched per tick
    # due_at order so the earliest blocking reminder wins the single overlay slot.
    rows = sorted(rows, key=lambda r: (r[2] or ""))
    for rid, text, due_at, repeat, block_seconds, hold_seconds, cron in rows:
        dt = parse_due(due_at)
        if dt is None or dt > now:
            continue
        is_block = block_seconds is not None
        # Serialize blocking overlays: only one on screen at a time. If one is
        # already up (overlay_busy) or we already launched one this tick, SKIP
        # this row WITHOUT stamping/advancing — it stays due for the next tick.
        # Also skip when the screen is locked — the overlay would launch invisibly
        # and be consumed without the user ever seeing it.
        if is_block and (overlay_busy or overlay_fired or is_screen_locked):
            continue
        if is_block:
            overlay_fired = True
        # Emit a tab-separated record; block/hold are empty for normal reminders
        # so the shell loop can dispatch overlay vs notification. rep is non-empty
        # for any recurring row (token or cron) so the overlay leaves the series
        # alone; empty only for true one-shots, which the overlay may resolve.
        bs = "" if block_seconds is None else str(int(block_seconds))
        hs = "" if hold_seconds is None else str(int(hold_seconds))
        rep = repeat or ("cron" if cron else "")
        fired.append((rid, text, bs, hs, rep))
        # Recurrence: cron (flexible) supersedes the legacy repeat token.
        if cron:
            nxt = cron_next(cron, now)   # already strictly future
        else:
            nxt = next_occurrence(dt, repeat)
        if nxt is not None and cron:
            fmt = "%Y-%m-%d %H:%M"
            con.execute(
                "UPDATE reminders SET due_at=?, fired_at=NULL WHERE id=?",
                (nxt.strftime(fmt), rid),
            )
        elif nxt is not None:
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
    for rid, text, bs, hs, rep in fired:
        print(f"{rid}\t{text}\t{bs}\t{hs}\t{rep}")
except Exception:
    pass
PYEOF
)"
  [[ -n "$due" ]] || return 0
  while IFS=$'\t' read -r rid rtext rblock rhold rrep; do
    [[ -n "$rtext" ]] || continue
    if [[ -n "$rblock" ]]; then
      # Blocking reminder → full-screen overlay (stays/counts down rblock secs).
      # Pass id/db/repeat so the overlay can mark the (one-shot) reminder
      # done/cancelled on dismissal.
      pbrain_overlay_show "$rtext" "$rblock" "${rhold:-5}" "" "$rid" "$PBRAIN_DB_FILE" "$rrep"
    else
      pbrain_notify_reminder "$rid" "$rtext"
    fi
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
    try:
        rows = con.execute(
            "SELECT id, text, due_at, repeat, fired_at, block_seconds FROM reminders WHERE status='pending' "
            "ORDER BY (due_at IS NULL), due_at"
        ).fetchall()
    except sqlite3.OperationalError:
        rows = [(r[0], r[1], r[2], r[3], r[4], None) for r in con.execute(
            "SELECT id, text, due_at, repeat, fired_at FROM reminders WHERE status='pending' "
            "ORDER BY (due_at IS NULL), due_at"
        ).fetchall()]
    con.close()
except Exception:
    sys.exit(0)

lines = []
for rid, text, due_at, repeat, fired_at, block_seconds in rows:
    rep = f" (repeats {repeat})" if repeat else ""
    if block_seconds is not None:
        rep += " [blocking]"
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
