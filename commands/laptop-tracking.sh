#!/usr/bin/env bash
# laptop-tracking — resident macOS usage tracker + end-of-day report.
#
# Usage:
#   laptop-tracking start              # enable: build + install + launch the daemon
#                                      #   (alias: enable)
#   laptop-tracking stop               # disable: stop + uninstall the daemon
#                                      #   (alias: disable)
#   laptop-tracking status             # is it running? today's quick numbers
#   laptop-tracking access             # one-time per-browser Automation grant
#   laptop-tracking report [<date>]    # render life/laptop-tracking/<date>.md (default today)
#   laptop-tracking decline            # opt out of the /plan-my-day setup nudge
#   laptop-tracking help
#
# What it does:
#   A LaunchAgent daemon (pbrain-tracker.app, compiled on demand from
#   lib/pbrain-tracker.swift) records, per day, which app is frontmost and for
#   how long, and for the browser which DOMAIN the time is on — excluding time the
#   machine is away (locked, screensaver, asleep, or input-idle past ~5 min;
#   playing video/music still counts as active). Only ACTIVE spans are stored, in
#   their OWN local SQLite DB (tracker.db); away/idle is derived from the gaps at
#   render time. `report` turns a day's segments into a markdown summary in the
#   vault. The DB is local-only and never synced; only the domain-level md is.
#
# Overrides:
#   PBRAIN_TRACKER_DB_FILE  — segment DB (default ~/.config/pbrain/tracker.db)
#   PBRAIN_TRACKER_APP      — compiled daemon app (default ~/.config/pbrain/pbrain-tracker.app)
#   PBRAIN_TRACKER_DIR      — md write dir (default $VAULT_DIR/life/laptop-tracking)
#   PBRAIN_TRACKER_POLL     — daemon poll seconds (default 10)
#   PBRAIN_TRACKER_IDLE     — idle-away threshold seconds (default 300)
#   PBRAIN_TRACKER_TOPN     — rows in the top apps/domains tables (default 12)

set -euo pipefail

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
SELF="$_SCRIPT_DIR/laptop-tracking.sh"
_LIB_DIR="$(cd -P -- "$_SCRIPT_DIR/../lib" && pwd -P)"

SUB="${1:-}"

# Normal command harness (vault, prefs, shared swiftc/launchd helpers, DBs).
source "$_SCRIPT_DIR/../lib/vault.sh"
pbrain_emit_prefs "laptop-tracking" || true
pbrain_tracker_db_init || true

LABEL="com.pbrain.tracker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PBRAIN_TRACKER_APP="${PBRAIN_TRACKER_APP:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/pbrain-tracker.app}"
TRACKER_BIN="$PBRAIN_TRACKER_APP/Contents/MacOS/pbrain-tracker"
TRACKER_DIR="${PBRAIN_TRACKER_DIR:-$VAULT_DIR/life/laptop-tracking}"
POLL="${PBRAIN_TRACKER_POLL:-10}"
IDLE="${PBRAIN_TRACKER_IDLE:-300}"
TOPN="${PBRAIN_TRACKER_TOPN:-12}"

# Suppresses the one-time /plan-my-day "set up laptop tracking?" nudge. Written
# on an explicit `decline` or `disable` (the user clearly knows about it then),
# cleared on `start`/`enable`. /plan-my-day reads this same path.
TRACKER_NUDGE_OFF="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/tracker-nudge-off"

# Build (or rebuild) the daemon app via the shared source-hash-cached builder.
# Ad-hoc signed + stable bundle id so the Automation TCC grant survives rebuilds;
# carries NSAppleEventsUsageDescription (shown in the consent prompt) + LSUIElement.
tracker_build() {
  pbrain_swift_build "$PBRAIN_TRACKER_APP" "$_LIB_DIR/pbrain-tracker.swift" "com.pbrain.tracker" \
    --sign \
    --plist-extra '  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>pbrain records which website you are on by reading the active tab URL (domain only) from your browser.</string>'
}

# Render a day's md from the DB. The python side NEVER writes on a read failure
# (the existing report is preserved) and writes atomically (temp + rename).
render_day() {
  local day="$1" out="$2"
  local today_real; today_real="$(date +%Y-%m-%d)"
  python3 - "$PBRAIN_TRACKER_DB_FILE" "$day" "$out" "$TOPN" "$today_real" <<'PYEOF'
import sqlite3, sys, os, datetime, tempfile
db, day, outpath, topn, today_real = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]

# READ FIRST, guarded. On ANY read failure we exit(0) WITHOUT writing, so a
# transient/locked/unreadable DB can never clobber an existing report with junk
# (prior learning: agents-md-oserror-destroy — never empty-and-overwrite).
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    # raw_path may be absent on a DB written by an older daemon; COALESCE so the
    # query works either way (it just yields NULL paths → no page-level rows).
    has_path = any(r[1] == "raw_path" for r in
                   con.execute("PRAGMA table_info(tracker_segments)").fetchall())
    path_col = "raw_path" if has_path else "NULL"
    rows = con.execute(
        "SELECT started_at, ended_at, app_bundle_id, app_name, raw_host, attribution, %s "
        "FROM tracker_segments WHERE occurred_on=? ORDER BY started_at" % path_col, (day,)
    ).fetchall()
    con.close()
except Exception as e:
    sys.stderr.write("render: cannot read tracker.db (%s) — existing report left untouched\n" % e)
    sys.exit(0)

def norm(host):
    if not host:
        return None
    h = host.strip().lower()
    if h.startswith("www."):
        h = h[4:]
    return h or None

def norm_path(hostpath):
    # raw_path is "host/seg/seg" (no scheme, no query — stripped at capture).
    # Lower-case the host portion + drop a leading www. for display; leave the
    # path segments untouched (they can be case-sensitive).
    if not hostpath:
        return None
    hp = hostpath.strip()
    if not hp:
        return None
    h, sep, rest = hp.partition("/")
    h = norm(h)
    if not h:
        return None
    return h + ("/" + rest if sep else "")

def hm(sec):
    sec = int(sec); h = sec // 3600; m = (sec % 3600) // 60
    return ("%dh %02dm" % (h, m)) if h else ("%dm" % m)

def hhmm(ep):
    return datetime.datetime.fromtimestamp(ep).strftime("%H:%M")

# A browser segment with no resolved domain carries an attribution reason
# (Decision T2) explaining the gap — surfaced in its own table so denied/timed-out
# browser time isn't silently invisible. 'ok' (domain resolved) and 'not_browser'
# (the app simply isn't a browser) need no explanation.
SECONDS_PER_DAY = 86400

ATTR_LABEL = {
    "tcc_denied": "permission not granted",
    "timeout":    "tab lookup timed out",
    "non_web":    "non-web window",
}

active = 0
app_secs, dom_secs, page_secs, attr_secs = {}, {}, {}, {}
segs = []
for s, e, bid, name, host, attr, path in rows:
    dur = (e - s) if (e is not None and s is not None and e >= s) else 0
    active += dur
    app = name or bid or "(unknown)"
    app_secs[app] = app_secs.get(app, 0) + dur
    d = norm(host)
    if d:
        dom_secs[d] = dom_secs.get(d, 0) + dur
    pg = norm_path(path)
    if pg:
        page_secs[pg] = page_secs.get(pg, 0) + dur
    if (attr in ATTR_LABEL) and dur > 0:
        attr_secs[attr] = attr_secs.get(attr, 0) + dur
    if dur > 0:
        segs.append((s, e))

import time as _time
# Reconcile the day window to the full calendar day. The start is always the
# day's midnight; the end depends on whether the day is complete:
#   • a PAST day (day < today) is reconciled to the NEXT midnight, so away-time
#     includes the untracked tail (laptop asleep/off before midnight) — a true
#     full-day view from start to end.
#   • TODAY (in progress) ends at the last recorded activity ("so far").
full_day = bool(day < today_real)
if segs:
    day_midnight = int(_time.mktime(datetime.datetime.strptime(day, "%Y-%m-%d").timetuple()))
    first = day_midnight
    seg_last = max(e for s, e in segs)
    # Use calendar arithmetic for the next midnight (not +86400) so DST
    # transitions (23h/25h days) don't inflate or deflate the away window.
    next_midnight = datetime.datetime.strptime(day, "%Y-%m-%d") + datetime.timedelta(days=1)
    last = int(_time.mktime(next_midnight.timetuple())) if full_day else seg_last
    window = max(0, last - first)
    away = max(0, window - active)
else:
    first = last = window = away = 0

L = []
L.append("# Laptop usage — %s" % day)
L.append("")
if not segs:
    L.append("_No active laptop time recorded for this day._")
else:
    pct = (100 * active // window) if window else 0
    L.append("- **Active time:** %s" % hm(active))
    if full_day:
        L.append("- **Day window:** 00:00 → 24:00 (full day)")
    else:
        L.append("- **Tracked window:** %s → %s (%s, so far)" % (hhmm(first), hhmm(seg_last), hm(window)))
    L.append("- **Active vs away:** %s active · %s away (%d%% active)" % (hm(active), hm(away), pct))
    L.append("")
    L.append("## Top apps")
    L.append("")
    L.append("| App | Active time | % |")
    L.append("|-----|------------|---|")
    for app, secs in sorted(app_secs.items(), key=lambda x: -x[1])[:topn]:
        p = (100 * secs // active) if active else 0
        L.append("| %s | %s | %d%% |" % (app, hm(secs), p))
    if dom_secs:
        L.append("")
        L.append("## Top browser domains")
        L.append("")
        L.append("| Domain | Active time | % |")
        L.append("|--------|------------|---|")
        btot = sum(dom_secs.values())
        for dom, secs in sorted(dom_secs.items(), key=lambda x: -x[1])[:topn]:
            p = (100 * secs // btot) if btot else 0
            L.append("| %s | %s | %d%% |" % (dom, hm(secs), p))
    # Page-level (host + path) breakdown — only rows that actually carry a path
    # (a bare host already shows in the domains table above, so skip those here).
    paged = {k: v for k, v in page_secs.items() if "/" in k}
    if paged:
        L.append("")
        L.append("## Top pages")
        L.append("")
        L.append("| Page | Active time | % |")
        L.append("|------|------------|---|")
        ptot = sum(page_secs.values())
        for pg, secs in sorted(paged.items(), key=lambda x: -x[1])[:topn]:
            p = (100 * secs // ptot) if ptot else 0
            L.append("| %s | %s | %d%% |" % (pg, hm(secs), p))
    if attr_secs:
        L.append("")
        L.append("## Browser attribution")
        L.append("")
        L.append("Browser time with no recorded domain, by reason:")
        L.append("")
        L.append("| Reason | Active time |")
        L.append("|--------|------------|")
        for attr, secs in sorted(attr_secs.items(), key=lambda x: -x[1]):
            L.append("| %s | %s |" % (ATTR_LABEL[attr], hm(secs)))
content = "\n".join(L) + "\n"

# WRITE only after content is fully built (never empty). Atomic temp + rename.
if not content.strip():
    sys.exit(0)
outdir = os.path.dirname(outpath) or "."
os.makedirs(outdir, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=outdir, prefix=".lt-", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        f.write(content)
    os.replace(tmp, outpath)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print(outpath)
PYEOF
}

case "$SUB" in
  start|enable)
    # Enabling clears any prior decline so the state is unambiguously "active".
    rm -f "$TRACKER_NUDGE_OFF" 2>/dev/null || true
    if ! command -v swiftc >/dev/null 2>&1; then
      echo "swiftc (Xcode Command Line Tools) not found — can't build the tracker daemon."
      echo "Install it with:  xcode-select --install"
      exit 0
    fi
    tracker_build
    if [[ ! -x "$TRACKER_BIN" ]]; then
      echo "Failed to build pbrain-tracker.app — see swiftc errors."
      exit 0
    fi
    pbrain_tracker_db_init || true
    LOG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/.logs"
    LOG_FILE="$LOG_DIR/tracker.log"
    DBF_X="$(_pbrain_xml_escape "$PBRAIN_TRACKER_DB_FILE")"
    # Resident GUI-session agent: relaunch at login + keep alive, but ONLY in an
    # Aqua (GUI) session — every API it uses (NSWorkspace, screen-lock notes,
    # AppleScript, idle query) needs a logged-in graphical session.
    TRACK_EXTRA="  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PBRAIN_TRACKER_DB_FILE</key><string>$DBF_X</string>
  </dict>"
    pbrain_launchagent_install "$LABEL" "$PLIST" "$LOG_FILE" "$TRACK_EXTRA" \
      -- "$TRACKER_BIN" --db "$PBRAIN_TRACKER_DB_FILE" --poll-seconds "$POLL" --idle-seconds "$IDLE"
    echo "Started laptop tracker — resident daemon, relaunches at login."
    echo "App:   $PBRAIN_TRACKER_APP"
    echo "DB:    $PBRAIN_TRACKER_DB_FILE"
    echo "Log:   $LOG_FILE"
    echo
    echo "Next: grant per-browser domain access (one-time):  /laptop-tracking access"
    ;;

  stop|disable)
    # Disabling also suppresses the setup nudge — the user clearly knows it exists.
    touch "$TRACKER_NUDGE_OFF" 2>/dev/null || true
    if [[ -f "$PLIST" ]]; then
      pbrain_launchagent_uninstall "$LABEL" "$PLIST"
      echo "Stopped laptop tracker and removed its LaunchAgent."
    else
      pbrain_launchagent_uninstall "$LABEL" "$PLIST"
      echo "Laptop tracker was not installed."
    fi
    ;;

  decline)
    # Opt out of the one-time /plan-my-day setup nudge without starting anything.
    mkdir -p "$(dirname "$TRACKER_NUDGE_OFF")" 2>/dev/null || true
    touch "$TRACKER_NUDGE_OFF" 2>/dev/null || true
    echo "Okay — I won't suggest laptop tracking again. Enable it anytime with /laptop-tracking start."
    ;;

  status)
    if pbrain_launchagent_loaded "$LABEL"; then
      echo "Daemon: running (loaded in the GUI session)."
    elif [[ -f "$PLIST" ]]; then
      echo "Daemon: installed but not loaded. Try /laptop-tracking start."
    else
      echo "Daemon: not installed. Start it with /laptop-tracking start."
    fi
    [[ -x "$TRACKER_BIN" ]] && echo "App: built ($PBRAIN_TRACKER_APP)" \
      || echo "App: not built (run /laptop-tracking start; needs swiftc)."
    TODAY="$(date +%Y-%m-%d)"
    python3 - "$PBRAIN_TRACKER_DB_FILE" "$TODAY" <<'PYEOF' || true
import sqlite3, sys
db, day = sys.argv[1], sys.argv[2]
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    rows = con.execute(
        "SELECT app_name, app_bundle_id, started_at, ended_at FROM tracker_segments "
        "WHERE occurred_on=?", (day,)).fetchall()
    con.close()
except Exception:
    sys.exit(0)
def hm(s):
    s = int(s); h = s // 3600; m = (s % 3600) // 60
    return ("%dh %02dm" % (h, m)) if h else ("%dm" % m)
active = 0; apps = {}
for name, bid, s, e in rows:
    d = (e - s) if (e and s and e >= s) else 0
    active += d
    apps[name or bid or "(unknown)"] = apps.get(name or bid or "(unknown)", 0) + d
if active:
    top = sorted(apps.items(), key=lambda x: -x[1])[0]
    print("Today: %s active across %d apps; top: %s (%s)." % (hm(active), len(apps), top[0], hm(top[1])))
else:
    print("Today: no active time recorded yet.")
PYEOF
    ;;

  access)
    if ! command -v swiftc >/dev/null 2>&1; then
      echo "swiftc not found — can't build the helper that requests browser access."
      exit 0
    fi
    tracker_build
    if [[ ! -x "$TRACKER_BIN" ]] || ! command -v open >/dev/null 2>&1; then
      echo "Tracker app not available — run /laptop-tracking start first."
      exit 0
    fi
    echo "Requesting one-time browser Automation access (per browser)."
    echo "Open the browsers you want tracked first, then approve each prompt."
    RESF="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/pbrain-track-access.$$")"
    : > "$RESF"
    open -W -n "$PBRAIN_TRACKER_APP" --args --probe-access --result "$RESF" >/dev/null 2>&1 || true
    if [[ -s "$RESF" ]]; then
      echo
      while IFS=$'\t' read -r _tag bid result; do
        [[ "$_tag" == "PROBE" ]] || continue
        if [[ "$bid" == "-" ]]; then
          echo "No supported browsers were running — open Safari/Chrome/Arc/etc. and re-run /laptop-tracking access."
        elif [[ "$result" == "ok" ]]; then
          echo "  ✓ $bid — access granted"
        else
          echo "  ✗ $bid — $result (approve the prompt, or grant it in System Settings → Privacy & Security → Automation)"
        fi
      done < "$RESF"
    else
      echo "No result returned — make sure at least one supported browser is running, then re-run."
    fi
    rm -f "$RESF" 2>/dev/null || true
    ;;

  report)
    DATE="${2:-$(date +%Y-%m-%d)}"
    if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      echo "Bad date '$DATE' — expected YYYY-MM-DD."
      exit 0
    fi
    # Auto-backfill the previous/last-active day when no explicit date is given.
    if [[ -z "${2:-}" ]]; then
      PREV_DATE="$(python3 - "$PBRAIN_TRACKER_DB_FILE" "$DATE" 2>/dev/null <<'PYEOF_PREV'
import sqlite3, sys
db, today = sys.argv[1], sys.argv[2]
try:
    con = sqlite3.connect(db, timeout=5)
    row = con.execute(
        "SELECT occurred_on FROM tracker_segments WHERE occurred_on < ? "
        "GROUP BY occurred_on ORDER BY occurred_on DESC LIMIT 1", (today,)
    ).fetchone()
    con.close()
    if row:
        print(row[0])
except Exception:
    pass
PYEOF_PREV
      )" || true
      if [[ -n "$PREV_DATE" ]]; then
        render_day "$PREV_DATE" "$TRACKER_DIR/$PREV_DATE.md" >/dev/null 2>&1 || true
      fi
    fi
    OUT="$TRACKER_DIR/$DATE.md"
    WROTE="$(render_day "$DATE" "$OUT" || true)"
    if [[ -n "$WROTE" ]]; then
      echo "Wrote $WROTE"
    else
      echo "No report written for $DATE (no data, or the DB was unreadable — any existing report was left untouched)."
    fi
    ;;

  help|-h|--help)
    sed -n '4,28p' "$SELF"
    ;;

  *)
    if [[ -z "$SUB" ]]; then
      echo "laptop-tracking — resident macOS usage tracker (opt-in)."
      echo
      echo "  /laptop-tracking start     enable: install + launch the daemon"
      echo "  /laptop-tracking access    grant per-browser domain access (one-time)"
      echo "  /laptop-tracking status    is it running? today's quick numbers"
      echo "  /laptop-tracking report    render today's life/laptop-tracking/<date>.md"
      echo "  /laptop-tracking stop      disable: stop + uninstall"
      echo
      echo "(\`enable\`/\`disable\` are aliases for start/stop.)"
    else
      echo "Unknown subcommand '$SUB'. Try: start (enable) | stop (disable) | status | access | report | decline | help"
    fi
    ;;
esac

pbrain_emit_self_improve "laptop-tracking" || true
