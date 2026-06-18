#!/usr/bin/env bash
# pbrain reminders helper — sourced by lib/vault.sh (after db.sh).
#
# TWO reminder backends live here:
#   * /remind          — Apple **Reminders** (EKReminder) via the bundled helper
#                        (pbrain-reminders.app). Reminders + iCloud own firing +
#                        cross-device sync; there is NO pbrain DB row and NO poller
#                        for /remind. The cron→Apple-recurrence mapper lives here too.
#   * /remind-blocking — full-screen blocking-overlay reminders, the SOLE owner of
#                        the SQLite store (lib/db.sh), split into reminder_schedules
#                        (recurring series) + reminders (per-occurrence instances).
#                        Owns create / list / cancel / tick / install.
# pbrain_calendar_today (real Calendar EVENTS, for /plan-my-day anchors) also lives
# here — separate from /remind's Reminders layer.
#
# THREE behaviors worth knowing at a glance (each fully documented at its fn):
#
# 1. FIRE / DEFER / MISS state machine + grace window (pbrain_reminders_tick, the
#    /remind-blocking poller, ~60s). For each due occurrence:
#      * FIRE  — within the grace window (PBRAIN_REMIND_GRACE_SECONDS, default 600)
#                and unlocked: launch the overlay.
#      * DEFER — locked-within-grace OR an overlay is already up (pgrep): leave
#                pending + untouched so a later tick handles it.
#      * MISS  — overdue past grace (asleep/off/locked-too-long): status=missed,
#                no overlay.
#    Both FIRE and MISS then ADVANCE the series (cron_next → insert next instance,
#    bump next_due_at) — advancing on *processing* not *display* keeps a series
#    alive across missed/locked/asleep fires; only cancelling stops it.
#
# 2. Overlay resolution paths (pbrain_overlay_show; degrades to a notification when
#    swiftc is absent). Hold **Control** → skipped; countdown elapses → done (the
#    ONLY path to done, no mark-done gesture); sleep/lock self-dismiss → missed. At
#    most ONE overlay on screen at a time.
#
# 3. cron→Apple-recurrence mapping (pbrain_cron_to_rrules, for /remind EKReminder
#    recurrence). Apple recurrence is daily/weekly/monthly/yearly only, so sub-daily
#    cron is REJECTED (→ /remind-blocking); multiple times-of-day SPLIT into one
#    reminder each; dom+dow (cron OR) SPLIT into two; nth/last weekday via dow#n /
#    dowL; true every-N intervals (cron can't express) use --repeat tokens via
#    pbrain_calendar_rrule.
#
# Defines:
#   pbrain_notify <title> <message>     fire a macOS notification, injection-safe, best-effort
#                                       (only the overlay's no-swiftc degradation path uses it)
#   pbrain_notify_build                 compile pbrain-notify.app from lib/pbrain-notify.swift (idempotent)
#   pbrain_overlay_build / _show        compile + launch the full-screen blocking overlay
#   pbrain_reminders_app_build / _run   compile + drive the EKReminder helper (/remind)
#   pbrain_cron_to_rrules               cron → Apple EKRecurrenceRule(s) (/remind)
#   pbrain_reminders_cmd                echo abs path to commands/remind.sh (/remind)
#   pbrain_reminders_tick               fire/defer/miss due blocking occurrences (poller only)
#   pbrain_cron_next                    next datetime matching a 5-field cron expr
#   pbrain_calendar_*                   Apple Calendar EVENTS layer (/plan-my-day anchors)
#
# Like the other lib/ helpers, this NEVER exits non-zero — it is sourced into
# commands under `set -euo pipefail`.

# The build helpers below delegate to pbrain_swift_build (lib/launchd.sh). vault.sh
# sources launchd.sh first, but reminders.sh is also sourced directly (e.g. by
# tests), so pull launchd.sh in if it isn't already loaded.
if ! declare -F pbrain_swift_build >/dev/null 2>&1; then
  _PBRAIN_RM_LIB_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || true
  [[ -n "${_PBRAIN_RM_LIB_DIR:-}" && -f "$_PBRAIN_RM_LIB_DIR/launchd.sh" ]] \
    && source "$_PBRAIN_RM_LIB_DIR/launchd.sh" || true
  unset _PBRAIN_RM_LIB_DIR
fi

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
# Delegates to the shared pbrain_swift_build (source-hash cached). The runtime
# notification identity is set by the binary itself (it impersonates
# com.apple.Terminal); CFBundleIdentifier here only gives the bundle a clean
# structure. Idempotent + best-effort; never exits non-zero, never prints.
pbrain_notify_build() {
  local lib_dir
  lib_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 0
  pbrain_swift_build "$PBRAIN_NOTIFY_APP" "$lib_dir/pbrain-notify.swift" "com.pbrain.notify" \
    --plist-extra '  <key>LSUIElement</key><true/>
  <key>NSUserNotificationAlertStyle</key><string>alert</string>'
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
# Delegates to the shared pbrain_swift_build (source-hash cached). A missing
# swiftc or a compile failure just leaves the app absent and pbrain_overlay_show
# falls back to a plain notification. Never exits non-zero, never prints.
pbrain_overlay_build() {
  local lib_dir
  lib_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 0
  pbrain_swift_build "$PBRAIN_OVERLAY_APP" "$lib_dir/pbrain-overlay.swift" "com.pbrain.overlay" \
    --plist-extra '  <key>LSUIElement</key><true/>'
  # Ship the lifecycle chime INTO the app bundle's Resources so Bundle.main resolves
  # it from any launchd/GUI session. Idempotent: only (re)copies when the bundled
  # copy is missing or differs from the shipped source. Best-effort — a missing
  # asset just leaves the overlay chimeless (it degrades silently).
  local chime_src="$lib_dir/assets/chime.mp3"
  local chime_dst="$PBRAIN_OVERLAY_APP/Contents/Resources/chime.mp3"
  if [[ -f "$chime_src" && -d "$PBRAIN_OVERLAY_APP/Contents" ]]; then
    if [[ ! -f "$chime_dst" ]] || ! cmp -s "$chime_src" "$chime_dst"; then
      mkdir -p "$PBRAIN_OVERLAY_APP/Contents/Resources" 2>/dev/null \
        && cp -f "$chime_src" "$chime_dst" 2>/dev/null || true
    fi
  fi
}

# Show the full-screen blocking overlay. Args reach the app as argv — never
# interpolated into an interpreted string — so arbitrary message text is inert.
#   pbrain_overlay_show <message> <seconds> [<hold>] [<bg-hex>] [<id>] [<db>] [<mark_done>] [<warning_seconds>] [<snooze_minutes>]
# <seconds> 0 = no countdown (stays until a gesture resolves it).
# <mark_done> 1 = enable Option-hold-to-done mode (no countdown needed).
# <warning_seconds> seconds for the pre-overlay warning panel (default "" = use overlay default of 10s;
#   pass "0" to skip the warning entirely, e.g. for the test command).
# <snooze_minutes> warning-panel "Snooze" button push-out (default "" = use overlay default of 5;
#   pass "0" to hide it). Env PBRAIN_OVERLAY_SNOOZE_MINUTES sets the fallback. Only shown when <id>+<db>
#   are passed (there's a row to reschedule).
# Launched with `open -n` so it runs in a proper Launch Services / GUI context
# (works from the launchd poller's gui session); falls back to a notification if
# the app can't be built (no swiftc).
# When <id> + <db> are passed the overlay resolves THAT instance row on dismissal:
# hold Control → skipped; countdown end or Option-hold → done; sleep/lock → missed.
# Every occurrence is its own row, so resolving one never touches the recurring series.
pbrain_overlay_show() {
  local msg="${1:-Take a break}" secs="${2:-0}" hold="${3:-3}" bg="${4:-${PBRAIN_OVERLAY_BG:-}}"
  local rid="${5:-}" db="${6:-}" mark_done="${7:-0}" warning="${8:-}"
  local snooze="${9:-${PBRAIN_OVERLAY_SNOOZE_MINUTES:-}}"
  pbrain_overlay_build
  local bin="$PBRAIN_OVERLAY_APP/Contents/MacOS/pbrain-overlay"
  if [[ -x "$bin" ]]; then
    local args=(--message "$msg" --seconds "$secs" --hold "$hold")
    [[ -n "$bg" ]]            && args+=(--background "$bg")
    [[ -n "$rid" ]]           && args+=(--id "$rid")
    [[ -n "$db" ]]            && args+=(--db "$db")
    [[ "$mark_done" == "1" ]] && args+=(--mark-done)
    [[ -n "$warning" ]]       && args+=(--warning-seconds "$warning")
    [[ -n "$snooze" ]]        && args+=(--snooze-minutes "$snooze")
    # Lifecycle chime (notif-start / blocking-start / blocking-end). Translate the
    # env gate into argv, since env doesn't survive `open -n`. PBRAIN_OVERLAY_CHIME
    # in {0,off,false,no} (any case) mutes it; PBRAIN_CHIME_FILE overrides the clip.
    case "$(printf '%s' "${PBRAIN_OVERLAY_CHIME:-}" | tr '[:upper:]' '[:lower:]')" in
      0|off|false|no) args+=(--no-chime) ;;
      *) [[ -n "${PBRAIN_CHIME_FILE:-}" ]] && args+=(--chime "$PBRAIN_CHIME_FILE") ;;
    esac
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

# Apple Reminders integration (/remind) --------------------------------------
# /remind creates real Apple Reminders (EKReminder) — a to-do with an optional
# timed due date, optional recurrence, a priority, and "early" alarms. Reminders
# + iCloud own firing + sync; there is NO pbrain DB or launchd poller for /remind.
# All ops go through a bundled EventKit helper (pbrain-reminders.app, compiled on
# demand from lib/pbrain-reminders.swift) launched via `open`, so the Reminders
# TCC permission is attributed to the bundle. Reminders access is a permission
# DISTINCT from Calendar access; grant once via `/remind access`.
#
# PBRAIN_CALENDAR is kept below because pbrain_calendar_today (read-only, for
# /plan-my-day's time anchors) still reads real Calendar EVENTS — that's separate
# from /remind, which now lives in Reminders and does NOT appear on the grid.
PBRAIN_CALENDAR="${PBRAIN_CALENDAR:-Calendar}"
export PBRAIN_CALENDAR

# PBRAIN_REMINDERS_LIST  — target Reminders list (empty = the default list)
# PBRAIN_REMINDER_MARKER — hidden notes footer tagging pbrain reminders (so list
#                          surfaces only ours), default the bracketed token below
# PBRAIN_REMINDERS_APP   — where the compiled EventKit helper app is cached/built
PBRAIN_REMINDERS_LIST="${PBRAIN_REMINDERS_LIST:-}"
export PBRAIN_REMINDERS_LIST
PBRAIN_REMINDER_MARKER="${PBRAIN_REMINDER_MARKER:-⟦pbrain-reminder⟧}"
export PBRAIN_REMINDER_MARKER
PBRAIN_REMINDERS_APP="${PBRAIN_REMINDERS_APP:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/pbrain-reminders.app}"
export PBRAIN_REMINDERS_APP

# Build (or rebuild) pbrain-reminders.app from the checked-in Swift source.
# Delegates to the shared pbrain_swift_build (source-hash cached, ad-hoc signed).
# The source-hash cache is load-bearing here: TCC keys Automation/Reminders
# consent partly on the signature, so we must rebuild only when the source
# actually changed — not on every mtime touch — or the grant churns. The
# Info.plist carries the Reminders usage strings (required for the access prompt)
# and LSUIElement (no Dock icon). A missing swiftc / compile failure leaves the
# app absent and pbrain_reminders_run returns UNAVAILABLE. Never exits non-zero.
pbrain_reminders_app_build() {
  local lib_dir
  lib_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || return 0
  pbrain_swift_build "$PBRAIN_REMINDERS_APP" "$lib_dir/pbrain-reminders.swift" "com.pbrain.reminders" \
    --sign \
    --plist-extra '  <key>LSUIElement</key><true/>
  <key>NSRemindersUsageDescription</key><string>pbrain manages your /remind reminders in Reminders, including creating, editing, and removing them.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>pbrain manages your /remind reminders in Reminders, including creating, editing, and removing them.</string>'
}

# _pbrain_rem_app_run <op-args...> — launch the EventKit app via `open` and echo
# the one-line status it writes to the --result file. Must go through `open` (not
# direct exec) so the Reminders TCC permission is attributed to the bundle. We
# poll the result file briefly because a freshly built+signed binary can return
# from `open -W` before its first-launch output is flushed.
_pbrain_rem_app_run() {
  local resf; resf="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/pbrain-rem-$$.res")"
  : > "$resf"
  open -W -n "$PBRAIN_REMINDERS_APP" --args "$@" --result "$resf" >/dev/null 2>&1 || true
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

# pbrain_reminders_run <op> [extra-args...] — run any helper op and echo its
# one-line status: ADDED <id> | OK | EDITED | COMPLETED | DELETED | NOT_FOUND |
# ACCESS_DENIED | ERROR:<msg> | UNAVAILABLE (helper can't be built: no swiftc /
# no `open`). The marker and target list are injected centrally so callers don't
# repeat them.
pbrain_reminders_run() {
  local op="${1:-}"; shift || true
  pbrain_reminders_app_build
  local bin="$PBRAIN_REMINDERS_APP/Contents/MacOS/pbrain-reminders"
  if [[ ! -x "$bin" ]] || ! command -v open >/dev/null 2>&1; then
    printf 'UNAVAILABLE\n'; return 0
  fi
  local extra=(--marker "$PBRAIN_REMINDER_MARKER")
  [[ -n "${PBRAIN_REMINDERS_LIST:-}" ]] && extra+=(--list "$PBRAIN_REMINDERS_LIST")
  local out; out="$(_pbrain_rem_app_run --op "$op" "$@" "${extra[@]}")"
  printf '%s\n' "${out:-ERROR:no-output}"
}

# pbrain_reminders_access — request/verify Reminders (EventKit) access via the
# helper. Echoes OK | ACCESS_DENIED | UNAVAILABLE. Used by `/remind access`.
pbrain_reminders_access() {
  pbrain_reminders_app_build
  local bin="$PBRAIN_REMINDERS_APP/Contents/MacOS/pbrain-reminders"
  if [[ ! -x "$bin" ]] || ! command -v open >/dev/null 2>&1; then
    printf 'UNAVAILABLE\n'; return 0
  fi
  local res; res="$(_pbrain_rem_app_run --op access-check)"
  printf '%s\n' "${res:-ERROR}"
}

# pbrain_cron_to_rrules <cron-expr> [<after 'YYYY-MM-DD HH:MM'>] — translate a
# 5-field cron expression into one or MORE Apple-reminder recurrences. Apple
# reminder recurrence (EKRecurrenceRule) is far less expressive than cron, so the
# translation is honest about the impedance mismatch instead of silently lying:
#   * NO sub-daily: a cron with many distinct fire-times/day (minutely/hourly)
#     can't be a reminder — REJECT (route the user to /remind-blocking).
#   * MULTIPLE times-of-day (e.g. 0 9,17 * * *) → SPLIT into one reminder each.
#   * cron dom AND dow both restricted = OR semantics → SPLIT (a single rule
#     would silently flip OR→AND).
#   * cron has no interval: */step in a field is a SET (mapped via BY* lists),
#     never INTERVAL. Use the --repeat tokens for true every-N cadences.
#   * nth/last weekday via the dow#n / dowL extensions (1#1 = first Monday,
#     5L = last Friday) → BYDAY=1MO / -1FR.
# Output (stdout), one line per resulting reminder, OR a single REJECT line:
#   OK<TAB><due 'YYYY-MM-DD HH:MM'><TAB><RRULE>
#   REJECT<TAB><CODE><TAB><human message>
# CODE in INVALID | SUBDAILY | UNREP | TOOMANY. Never exits non-zero.
pbrain_cron_to_rrules() {
  command -v python3 >/dev/null 2>&1 || { printf 'REJECT\tINVALID\tpython3 unavailable\n'; return 0; }
  local expr="${1:-}" after="${2:-}"
  [[ -n "$after" ]] || after="$(date '+%Y-%m-%d %H:%M')"
  python3 - "$expr" "$after" <<'PYEOF' 2>/dev/null || printf 'REJECT\tINVALID\tcould not parse expression\n'
import sys, datetime, re
import calendar as calmod

expr = (sys.argv[1] or "").strip()
after_s = sys.argv[2]
try:
    after = datetime.datetime.strptime(after_s, "%Y-%m-%d %H:%M")
except ValueError:
    print("REJECT\tINVALID\tbad 'after' time"); sys.exit(0)

def reject(code, msg):
    print("REJECT\t%s\t%s" % (code, msg)); sys.exit(0)

parts = expr.split()
if len(parts) != 5:
    reject("INVALID", "a cron expression has 5 fields: minute hour day-of-month month day-of-week")
min_raw, hour_raw, dom_raw, mon_raw, dow_raw = parts

CODES = {0: "SU", 1: "MO", 2: "TU", 3: "WE", 4: "TH", 5: "FR", 6: "SA"}  # cron dow -> RRULE
def cron_dow_to_py(c):   # cron Sun=0..Sat=6 -> python Mon=0..Sun=6
    return (c - 1) % 7
def cron_dow_to_code(c):
    return CODES[c]

def parse_field(field, lo, hi):
    vals = set()
    for part in field.split(","):
        part = part.strip()
        if not part:
            return None
        step, rng = 1, part
        if "/" in part:
            rng, step_s = part.split("/", 1)
            if not step_s.isdigit() or int(step_s) < 1:
                return None
            step = int(step_s)
        if rng == "*":
            a, b = lo, hi
        elif "-" in rng:
            x, y = rng.split("-", 1)
            if not (x.isdigit() and y.isdigit()):
                return None
            a, b = int(x), int(y)
        else:
            if not rng.isdigit():
                return None
            a = b = int(rng)
        if a > b or a < lo or b > hi:
            return None
        for v in range(a, b + 1, step):
            vals.add(v)
    return vals or None

minutes = parse_field(min_raw, 0, 59)
hours = parse_field(hour_raw, 0, 23)
months = parse_field(mon_raw, 1, 12)
if minutes is None or hours is None or months is None:
    reject("INVALID", "could not parse minute/hour/month field")

dom_restricted = dom_raw.strip() != "*"
doms = None
if dom_restricted:
    doms = parse_field(dom_raw, 1, 31)
    if doms is None:
        reject("INVALID", "could not parse day-of-month field")

mon_restricted = mon_raw.strip() != "*"
mon_list = sorted(months) if mon_restricted else None

dow_restricted = dow_raw.strip() != "*"
ordinal_byday = None
dows = None
if dow_restricted:
    if "#" in dow_raw or "L" in dow_raw.upper():
        ordinal_byday = []
        for tok in dow_raw.split(","):
            t = tok.strip().upper()
            m = re.match(r'^([0-7])#([1-5])$', t)
            mL = re.match(r'^([0-7])L$', t)
            if m:
                cd, ordn = int(m.group(1)) % 7, int(m.group(2))
            elif mL:
                cd, ordn = int(mL.group(1)) % 7, -1
            else:
                reject("INVALID", "bad day-of-week token '%s' (use d#n like 1#1, or dL like 5L)" % tok)
            ordinal_byday.append((ordn, cron_dow_to_py(cd), cron_dow_to_code(cd)))
    else:
        raw = parse_field(dow_raw, 0, 7)
        if raw is None:
            reject("INVALID", "could not parse day-of-week field")
        dows = set((0 if d == 7 else d) for d in raw)

CAP_TIMES = 6
times = sorted([(h, m) for h in hours for m in minutes])
if len(times) > CAP_TIMES:
    reject("SUBDAILY", "more than %d fire-times a day — Apple Reminders can't repeat sub-daily; use /remind-blocking for minute/hour cadences" % CAP_TIMES)

def wd_codes(s):
    return [CODES[c] for c in sorted(s)]

clauses = []
if ordinal_byday is not None:
    if dom_restricted:
        reject("UNREP", "an nth-weekday combined with a day-of-month is ambiguous — use one or the other")
    clauses.append({
        "freq": "YEARLY" if mon_restricted else "MONTHLY",
        "byday_ord": [(o, c) for (o, _py, c) in ordinal_byday],
        "byday_ord_py": [(o, py) for (o, py, _c) in ordinal_byday],
        "bymonth": mon_list,
    })
elif dom_restricted and dow_restricted:
    if mon_restricted:
        reject("UNREP", "day-of-month AND weekday within specific months can't be one reminder — simplify or set it in the Reminders app")
    clauses.append({"freq": "WEEKLY", "byday": wd_codes(dows),
                    "byday_py": set(cron_dow_to_py(c) for c in dows)})
    clauses.append({"freq": "MONTHLY", "bymonthday": sorted(doms)})
elif dow_restricted:
    if mon_restricted:
        reject("UNREP", "a weekly schedule limited to specific months isn't a reminder recurrence — drop the month limit or use the Reminders app")
    clauses.append({"freq": "WEEKLY", "byday": wd_codes(dows),
                    "byday_py": set(cron_dow_to_py(c) for c in dows)})
elif dom_restricted:
    if mon_restricted:
        clauses.append({"freq": "YEARLY", "bymonth": mon_list, "bymonthday": sorted(doms)})
    else:
        clauses.append({"freq": "MONTHLY", "bymonthday": sorted(doms)})
else:
    if mon_restricted:
        reject("UNREP", "every day within specific months isn't a reminder recurrence — drop the month limit or use the Reminders app")
    clauses.append({"freq": "DAILY"})

if len(times) * len(clauses) > 8:
    reject("TOOMANY", "this expands to too many reminders; simplify the schedule")

def nth_ok(d, ordn):
    if ordn > 0:
        return (d.day - 1) // 7 == ordn - 1
    last = calmod.monthrange(d.year, d.month)[1]
    return d.day > last - 7

def date_matches(d, cl):
    bm = cl.get("bymonth")
    if bm and d.month not in bm:
        return False
    f = cl["freq"]
    if f == "DAILY":
        return True
    if cl.get("byday_ord_py"):
        for (ordn, py) in cl["byday_ord_py"]:
            if d.weekday() == py and nth_ok(d, ordn):
                return True
        return False
    if cl.get("byday_py"):
        return d.weekday() in cl["byday_py"]
    if cl.get("bymonthday"):
        return d.day in cl["bymonthday"]
    return True

def rrule_of(cl):
    p = ["FREQ=" + cl["freq"]]
    if cl.get("byday"):
        p.append("BYDAY=" + ",".join(cl["byday"]))
    if cl.get("byday_ord"):
        p.append("BYDAY=" + ",".join("%d%s" % (o, c) for (o, c) in cl["byday_ord"]))
    if cl.get("bymonth"):
        p.append("BYMONTH=" + ",".join(str(x) for x in cl["bymonth"]))
    if cl.get("bymonthday"):
        p.append("BYMONTHDAY=" + ",".join(str(x) for x in cl["bymonthday"]))
    return ";".join(p)

def next_occ(hour, minute, cl):
    base = after.date()
    for i in range(0, 366 * 5 + 1):
        d = base + datetime.timedelta(days=i)
        if date_matches(d, cl):
            cand = datetime.datetime(d.year, d.month, d.day, hour, minute)
            if cand > after:
                return cand
    return None

out = []
for (h, m) in times:
    for cl in clauses:
        nx = next_occ(h, m, cl)
        if nx is None:
            reject("INVALID", "no valid occurrence (impossible date like Feb 30, or out of range)")
        out.append("OK\t%s\t%s" % (nx.strftime("%Y-%m-%d %H:%M"), rrule_of(cl)))
print("\n".join(out))
PYEOF
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

# Process every blocking occurrence that is due now. Selection + state changes
# happen in a single IMMEDIATE transaction so two concurrent ticks can't double-
# fire. Each due instance is handled by ONE of three paths:
#
#   FIRE    — within the grace window, screen unlocked, no overlay already up:
#             stamp fired_at and launch the overlay (which resolves the instance
#             to done/skipped/missed itself).
#   MISSED  — overdue by more than the grace window (laptop was asleep/off, or
#             locked too long): mark the instance `missed`. No overlay — a
#             time-sensitive break is pointless hours late.
#   DEFER   — within grace but the screen is locked, or an overlay is already on
#             screen, or one was already launched this tick: leave it pending and
#             untouched so a later tick fires (or eventually misses) it.
#
# Crucially, both FIRE and MISSED then ADVANCE the parent series: compute the
# next cron occurrence and insert the next pending instance. Advancing on
# *processing* (fire OR miss) — never on successful display — is what keeps a
# recurring reminder alive across a missed/locked/asleep fire. Only cancelling
# the schedule stops it.
#
# Fired ONLY by the background poller (remind-blocking.sh tick, ~60s). There are
# deliberately NO opportunistic callers: a full-screen overlay is time-sensitive,
# and catching one up late just because some other command ran is wrong.
# PBRAIN_REMIND_GRACE_SECONDS (default 600 = 10 min) sets the miss threshold.
pbrain_reminders_tick() {
  local rid rtext rblock rhold rmarkdone   # dispatch-loop vars — local so we don't clobber the caller's
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -f "$PBRAIN_DB_FILE" ]] || return 0
  local now due overlay_busy=0 is_screen_locked=0 grace
  grace="${PBRAIN_REMIND_GRACE_SECONDS:-600}"
  [[ "$grace" =~ ^[0-9]+$ ]] || grace=600
  now="$(date '+%Y-%m-%d %H:%M')"
  # Serialize overlays: if one is already on screen, defer firing more this tick.
  if command -v pgrep >/dev/null 2>&1 && pgrep -x pbrain-overlay >/dev/null 2>&1; then
    overlay_busy=1
  fi
  # Skip blocking overlays when the screen is locked — they'd fire invisibly and
  # be consumed without the user ever seeing them. The console lock state lives in
  # IOConsoleUsers under the Root node as a stable always-present boolean
  # ("IOConsoleLocked" = Yes|No). Best-effort; if ioreg is unavailable we assume
  # unlocked (safe to fire). PBRAIN_SCREEN_LOCKED (0/1) overrides the probe — a
  # test seam and a manual "never fire while I'm at this" switch.
  if [[ "${PBRAIN_SCREEN_LOCKED:-}" == "1" ]]; then
    is_screen_locked=1
  elif [[ "${PBRAIN_SCREEN_LOCKED:-}" == "0" ]]; then
    is_screen_locked=0
  elif command -v ioreg >/dev/null 2>&1; then
    ioreg -n Root -d1 2>/dev/null | grep -q '"IOConsoleLocked" = Yes' \
      && is_screen_locked=1 || true
  fi
  due="$(python3 - "$PBRAIN_DB_FILE" "$now" "$overlay_busy" "$is_screen_locked" "$grace" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys, datetime
db, now_s = sys.argv[1], sys.argv[2]
overlay_busy, is_screen_locked, grace = sys.argv[3] == "1", sys.argv[4] == "1", int(sys.argv[5])
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
    # One pending instance per active series at a time (the frontier). Join the
    # schedule so an instance of a cancelled series is never fired. fired_at IS
    # NULL excludes an already-shown-but-unresolved occurrence from re-firing.
    rows = con.execute(
        "SELECT r.id, r.text, r.due_at, r.block_seconds, r.hold_seconds, r.schedule_id, s.cron, r.mark_done "
        "FROM reminders r LEFT JOIN reminder_schedules s ON r.schedule_id = s.id "
        "WHERE r.status='pending' AND r.fired_at IS NULL AND r.due_at IS NOT NULL "
        "AND (r.schedule_id IS NULL OR s.status='active')"
    ).fetchall()
    rows = sorted(rows, key=lambda r: (r[2] or ""))   # earliest due wins the overlay slot

    def advance(schedule_id, cron):
        # Materialise the NEXT occurrence of a series from its cron — independent
        # of whether this occurrence fired or was missed. That independence is
        # what keeps a series alive across a locked/asleep/missed fire. Idempotent
        # via UNIQUE(schedule_id, due_at). No-op for one-shots (schedule_id NULL).
        if not schedule_id or not cron:
            return
        nxt = cron_next(cron, now)
        if nxt is None:
            return
        nfmt = nxt.strftime("%Y-%m-%d %H:%M")
        sch = con.execute(
            "SELECT text, block_seconds, hold_seconds, source, mark_done FROM reminder_schedules WHERE id=?",
            (schedule_id,),
        ).fetchone()
        if not sch:
            return
        try:
            con.execute(
                "INSERT INTO reminders (schedule_id, text, due_at, block_seconds, hold_seconds, mark_done, status, source, created_at) "
                "VALUES (?,?,?,?,?,?, 'pending', ?, ?)",
                (schedule_id, sch[0], nfmt, sch[1], sch[2], sch[4] or 0, sch[3], now_s),
            )
        except sqlite3.IntegrityError:
            pass   # the next instance already exists (a prior tick created it)
        con.execute("UPDATE reminder_schedules SET next_due_at=? WHERE id=?", (nfmt, schedule_id))

    fired = []
    overlay_fired = False   # serialize: at most ONE overlay launched per tick
    for rid, text, due_at, block_seconds, hold_seconds, schedule_id, cron, mark_done in rows:
        dt = parse_due(due_at)
        if dt is None or dt > now:
            continue
        overdue = (now - dt).total_seconds()
        if overdue > grace:
            # MISSED — too stale to show (asleep/off, or locked past the grace
            # window). Reconcile this occurrence and advance the series so it
            # never stalls. No overlay: a time-sensitive break is moot hours late.
            con.execute(
                "UPDATE reminders SET status='missed', resolved_at=? WHERE id=? AND status='pending'",
                (now_s, rid),
            )
            advance(schedule_id, cron)
            continue
        # Within grace → fire candidate. DEFER (touch nothing) if the screen is
        # locked, an overlay is already up, or we already launched one this tick;
        # a later tick fires it, or it eventually ages into MISSED.
        if is_screen_locked or overlay_busy or overlay_fired:
            continue
        # FIRE: stamp fired_at (the overlay then resolves the row itself), advance
        # the series, and emit the launch record for the shell.
        con.execute("UPDATE reminders SET fired_at=? WHERE id=?", (now_s, rid))
        overlay_fired = True
        fired.append((rid, text, str(int(block_seconds or 0)), str(int(hold_seconds or 3)), str(int(mark_done or 0))))
        advance(schedule_id, cron)
    con.execute("COMMIT")
    con.close()
    for rid, text, bs, hs, md in fired:
        print(f"{rid}\t{text}\t{bs}\t{hs}\t{md}")
except Exception:
    pass
PYEOF
)"
  [[ -n "$due" ]] || return 0
  # At most one record (we serialize to one overlay per tick), but loop for safety.
  while IFS=$'\t' read -r rid rtext rblock rhold rmarkdone; do
    [[ -n "$rtext" ]] || continue
    # Pass the instance id + db so the overlay resolves THAT occurrence on
    # dismissal (Control → skipped, countdown/Option-hold → done, sleep/lock → missed).
    pbrain_overlay_show "$rtext" "${rblock:-0}" "${rhold:-3}" "" "$rid" "$PBRAIN_DB_FILE" "${rmarkdone:-0}"
  done <<< "$due"
  return 0
}
