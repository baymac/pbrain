// pbrain-tracker — resident laptop-usage tracker daemon.
//
// WHY THIS EXISTS
// ---------------
// Records, per day, which app is frontmost and for how long, and for the browser
// which website (domain) the time is spent on — EXCLUDING time the machine is
// "away" (locked, screensaver, display/system asleep, or input-idle past a
// threshold). Watching a video with no keyboard/mouse input still counts as
// active (media-aware idle via IOKit power assertions). The granular record lives
// in its own SQLite DB (tracker.db); a separate python renderer turns a day's
// segments into life/laptop-tracking/<date>.md.
//
// DATA MODEL (Decisions T1 + 3A)
// ------------------------------
// Only ACTIVE time is persisted, as rows in tracker_segments — ONE row per
// contiguous (app, host) active span. Away/idle/locked/asleep is NOT a row: it is
// the ABSENCE of a segment, derived at render time from the gap between one
// segment's ended_at and the next's started_at. The daemon stores RAW signals
// (raw bundle id, raw URL host + path straight from AppleScript with the query
// string dropped except a tiny content-id allowlist — YouTube's `v` video id —
// so per-video time survives, an attribution reason);
// the python renderer does all normalization + active/away classification, so the
// edge-case logic is unit-testable and the Swift surface stays thin.
//
// CRASH SAFETY
// ------------
// While active, every poll rewrites the live row's ended_at = now (a heartbeat),
// so a SIGKILL / hard power-off loses at most one poll interval. New rows are
// inserted with ended_at = started_at (never NULL/"now-at-render"), and a startup
// sweep clamps any stray open row to started_at — so a crash can never credit
// hours of phantom time. Sleep closes the live span (willSleep) and wake opens a
// fresh one; a local-midnight rollover splits the span so each day buckets right.
//
// PERMISSIONS (TCC / Automation)
// ------------------------------
// Reading a browser's active-tab URL needs Apple Events (Automation) consent, per
// browser. The daemon NEVER triggers the consent dialog (a launchd process can't),
// it only CHECKS consent with AEDeterminePermissionToAutomateTarget(askUser:false)
// and degrades to app-level-only (host NULL, attribution=tcc_denied) when absent.
// The one-time grant is provoked foreground by `pbrain-tracker --probe-access`
// (run via `open` from `/laptop-tracking access`), which asks per RUNNING browser.
//
// USAGE
//   pbrain-tracker [--db <path>] [--poll-seconds 10] [--idle-seconds 300]
//   pbrain-tracker --probe-access      # foreground: provoke the per-browser grant
//
// Build: compiled by pbrain_swift_build (lib/launchd.sh) into
//        pbrain-tracker.app/Contents/MacOS/pbrain-tracker.

import Cocoa
import CoreGraphics
import IOKit.pwr_mgt
import Carbon
import SQLite3
import Darwin

// ---------------------------------------------------------------------------
// Args. Values come from argv — never interpolated into an interpreted string.
// ---------------------------------------------------------------------------
func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}

func defaultDBPath() -> String {
    if let env = ProcessInfo.processInfo.environment["PBRAIN_TRACKER_DB_FILE"], !env.isEmpty {
        return env
    }
    let cfg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        ?? (NSHomeDirectory() + "/.config")
    return cfg + "/pbrain/tracker.db"
}

let dbPath       = argValue("--db") ?? defaultDBPath()
let pollSeconds  = max(2.0, Double(argValue("--poll-seconds") ?? "10") ?? 10.0)
let idleSeconds  = max(30.0, Double(argValue("--idle-seconds") ?? "300") ?? 300.0)
let fetchTimeout = 2.0   // max seconds the main loop waits on an AppleScript URL fetch

// Browser bundle ids we know how to read. Safari uses "current tab"; the
// Chrome-family (incl. Arc, which shares Chrome's scripting dictionary for this)
// uses "active tab".
let safariBundle = "com.apple.Safari"
let chromeFamily: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.google.Chrome.beta",
    "com.brave.Browser",
    "com.brave.Browser.beta",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta",
    "company.thebrowser.Browser",   // Arc
    "company.thebrowser.dia",       // Dia
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
]
func isKnownBrowser(_ bundleId: String) -> Bool {
    return bundleId == safariBundle || chromeFamily.contains(bundleId)
}

// Apps whose BACKGROUND / PiP playback is tracked as "background media" — a
// separate ledger from foreground active time. Browsers cover PiP + background
// tabs (bg/PiP tab URLs aren't reachable, so bg media is app-level only); the
// rest are dedicated players. Used to (a) decide what counts as bg media and
// (b) recognise when the FRONTMOST app is itself a media app you're watching.
let mediaBaseIds: Set<String> = chromeFamily
    .union([safariBundle, "org.mozilla.firefox"])
    .union([
        "com.spotify.client", "com.apple.Music", "com.apple.TV",
        "org.videolan.vlc", "com.apple.QuickTimePlayerX", "com.colliderli.iina",
        "com.apple.podcasts", "tv.plex.desktop", "com.apple.WebKit.GPU",
    ])

// Map a bundle id (possibly a "<base>.helper…"/renderer child that actually holds
// the audio assertion) back to its media base id, else nil.
func mediaBase(of bundleId: String?) -> String? {
    guard let b = bundleId else { return nil }
    for base in mediaBaseIds where b == base || b.hasPrefix(base + ".") { return base }
    return nil
}
func urlScript(for bundleId: String) -> String {
    if bundleId == safariBundle {
        return "tell application id \"\(bundleId)\" to return URL of current tab of front window"
    }
    return "tell application id \"\(bundleId)\" to return URL of active tab of front window"
}

// ---------------------------------------------------------------------------
// Time helpers — occurred_on is a LOCAL calendar day; epochs are UTC seconds.
// ---------------------------------------------------------------------------
func epoch(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970) }

let dayFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    return f
}()
func localDay(_ d: Date) -> String { dayFmt.string(from: d) }
func startOfLocalDay(_ d: Date) -> Date { Calendar.current.startOfDay(for: d) }

// ---------------------------------------------------------------------------
// SQLite layer (C API, like pbrain-overlay). Keeps one connection open; WAL +
// busy_timeout so the brief python renderer never collides with the writer.
// The CREATE TABLE here MUST stay in sync with lib/db.sh pbrain_tracker_db_init
// (tests pin the column set).
// ---------------------------------------------------------------------------
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class TrackerDB {
    private var db: OpaquePointer?

    init?(path: String) {
        guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA busy_timeout=5000")
        exec("""
        CREATE TABLE IF NOT EXISTS tracker_segments (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at    INTEGER NOT NULL,
            ended_at      INTEGER,
            occurred_on   TEXT NOT NULL,
            app_bundle_id TEXT,
            app_name      TEXT,
            raw_host      TEXT,
            raw_path      TEXT,
            attribution   TEXT NOT NULL DEFAULT 'ok',
            kind          TEXT NOT NULL DEFAULT 'foreground'
        );
        """)
        // Migrations for DBs created before a column existed. ALTER is a no-op-safe
        // failure if the column is already present (older sqlite has no IF NOT
        // EXISTS for ADD COLUMN), so we just swallow the error.
        exec("ALTER TABLE tracker_segments ADD COLUMN raw_path TEXT;")
        exec("ALTER TABLE tracker_segments ADD COLUMN kind TEXT NOT NULL DEFAULT 'foreground';")
        exec("CREATE INDEX IF NOT EXISTS idx_tracker_seg_day ON tracker_segments(occurred_on);")
        exec("CREATE INDEX IF NOT EXISTS idx_tracker_seg_open ON tracker_segments(ended_at);")
        // Startup sweep: clamp any stray open row (ended_at NULL, e.g. a crash
        // between INSERT and the first heartbeat) to its start — NEVER to "now".
        exec("UPDATE tracker_segments SET ended_at=started_at WHERE ended_at IS NULL;")
    }

    deinit { if db != nil { sqlite3_close(db) } }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ val: String?) {
        if let v = val {
            sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    // Open a new active segment; returns its row id (0 on failure). ended_at is
    // seeded to started_at so even an instant crash credits ~0s, never "now".
    func insertSegment(start: Int64, occurredOn: String, bundleId: String?,
                       appName: String?, host: String?, path: String?,
                       attribution: String, kind: String = "foreground") -> Int64 {
        let sql = """
        INSERT INTO tracker_segments
          (started_at, ended_at, occurred_on, app_bundle_id, app_name, raw_host, raw_path, attribution, kind)
        VALUES (?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, start)
        sqlite3_bind_int64(stmt, 2, start)
        bindText(stmt, 3, occurredOn)
        bindText(stmt, 4, bundleId)
        bindText(stmt, 5, appName)
        bindText(stmt, 6, host)
        bindText(stmt, 7, path)
        bindText(stmt, 8, attribution)
        bindText(stmt, 9, kind)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    // Heartbeat / close: move the live row's end forward. Guard ended_at >=
    // started_at so a backwards clock never inverts a span.
    func touchEnded(rowId: Int64, end: Int64) {
        let sql = "UPDATE tracker_segments SET ended_at=? WHERE id=? AND ?>=started_at"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, end)
        sqlite3_bind_int64(stmt, 2, rowId)
        sqlite3_bind_int64(stmt, 3, end)
        sqlite3_step(stmt)
    }
}

// ---------------------------------------------------------------------------
// Automation consent + the active-tab URL fetch.
// ---------------------------------------------------------------------------

// Check (don't ask) whether we may automate `bundleId`. noErr => permitted.
func automationPermitted(_ bundleId: String) -> Bool {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
    guard let desc = target.aeDesc else { return false }
    let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
    return status == noErr
}

// Ask (foreground only) — provokes the per-browser consent dialog. Returns the
// resulting OSStatus. Only meaningful when the target app is running.
func automationRequest(_ bundleId: String) -> OSStatus {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
    guard let desc = target.aeDesc else { return OSStatus(errAEEventNotPermitted) }
    return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true)
}

// Run the per-browser AppleScript and reduce it to (host?, path?, attribution).
// Blocks the calling thread (always invoked on a background queue). We keep the
// URL host AND path but DROP the query string (?…) — the privacy boundary: a
// query can carry tokens, search terms, and session secrets. The ONE exception
// is a tiny allowlist of query params that identify distinct CONTENT rather than
// secrets (currently just YouTube's `v` video id), so per-video watch time is
// tracked instead of every video collapsing to youtube.com/watch. www-stripping
// / display normalization is left to the python renderer.
func runURLScript(_ src: String) -> (String?, String?, String) {
    guard let script = NSAppleScript(source: src) else { return (nil, nil, "non_web") }
    var errInfo: NSDictionary?
    let result = script.executeAndReturnError(&errInfo)
    if let err = errInfo {
        let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -1743 { return (nil, nil, "tcc_denied") }   // not permitted
        return (nil, nil, "non_web")                           // no window / no tab / other
    }
    guard let urlString = result.stringValue,
          let u = URL(string: urlString),
          let scheme = u.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = u.host, !host.isEmpty else {
        return (nil, nil, "non_web")
    }
    // path excludes query+fragment by construction (URL.path). Trim a lone
    // trailing slash so "/" and "" collapse to the bare host.
    var path = u.path
    if path == "/" { path = "" }
    var hostPath = path.isEmpty ? host : host + path
    // Content-id allowlist: preserve YouTube's `v` (the video id) so each video
    // gets its own row. Only the value of `v` is kept — never the rest of the
    // query (search terms, session tokens, &list=, &t=, …).
    let youtubeDomains: Set<String> = ["youtube.com", "m.youtube.com", "music.youtube.com"]
    let bare = host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host.lowercased()
    if youtubeDomains.contains(bare),
       path == "/watch",
       let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
       let vid = comps.queryItems?.first(where: { $0.name == "v" })?.value,
       !vid.isEmpty, vid.count <= 16,
       vid.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
        hostPath += "?v=" + vid
    }
    return (host, hostPath, "ok")
}

// ---------------------------------------------------------------------------
// Probe (foreground): provoke the one-time Automation grant per RUNNING browser.
// Prints one "PROBE<TAB><bundleId><TAB><status>" line each, then the caller exits.
// ---------------------------------------------------------------------------
func runProbeAccess() {
    let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    var out: [String] = []
    for b in ([safariBundle] + chromeFamily.sorted()) {
        guard running.contains(b) else { continue }
        let status = automationRequest(b)
        let label = (status == noErr) ? "ok" : "denied(\(status))"
        out.append("PROBE\t\(b)\t\(label)")
    }
    if out.isEmpty { out.append("PROBE\t-\tno_browsers_running") }
    let text = out.joined(separator: "\n") + "\n"
    print(text, terminator: "")
    // Mirror to a --result file so the caller (launched via `open`, which doesn't
    // capture our stdout) can read the outcome — same trick as the reminders helper.
    if let resPath = argValue("--result"), !resPath.isEmpty {
        try? text.write(toFile: resPath, atomically: true, encoding: .utf8)
    }
}

// ---------------------------------------------------------------------------
// Tracker — owns the state machine and the poll loop.
// ---------------------------------------------------------------------------
final class Tracker {
    private let db: TrackerDB
    private let pollInterval: TimeInterval
    private let idleThreshold: TimeInterval

    // live foreground segment
    private var liveRow: Int64 = 0
    private var liveKey: String? = nil       // "\(bundleId)\u{1f}\(path ?? host ?? "")\u{1f}\(attr)"
    private var liveDay: String = ""

    // live BACKGROUND-media segments, one per asserting media app (base bundle id
    // → row id). Tracked in parallel with the foreground span and independent of
    // lock/idle state: audio can play while you work in another app OR while the
    // screen is locked. Never counted as foreground active time.
    private var liveBg: [String: Int64] = [:]

    // away latches
    private var asleep = false
    private var screenLocked = false
    private var screensaverOn = false

    // async URL fetch state (non-reentrant)
    private let aeQueue = DispatchQueue(label: "pbrain.tracker.ae")
    private var hostFetchInFlight = false

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(db: TrackerDB, poll: TimeInterval, idle: TimeInterval) {
        self.db = db
        self.pollInterval = poll
        self.idleThreshold = idle
        self.liveDay = localDay(Date())
    }

    func start() {
        let wsnc = NSWorkspace.shared.notificationCenter
        observers.append(wsnc.addObserver(forName: NSWorkspace.willSleepNotification,
                                          object: nil, queue: .main) { [weak self] _ in
            // System sleep stops audio → close foreground AND bg media. (Screen
            // LOCK does not close bg media — audio keeps playing while locked.)
            self?.asleep = true; self?.closeLive(at: Date()); self?.closeAllBg()
        })
        observers.append(wsnc.addObserver(forName: NSWorkspace.didWakeNotification,
                                          object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false; self?.tick()
        })
        // Frontmost-app switch — react immediately rather than waiting a poll.
        observers.append(wsnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                          object: nil, queue: .main) { [weak self] _ in
            self?.tick()
        })

        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                         object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = true; self?.closeLive(at: Date())
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                         object: nil, queue: .main) { [weak self] _ in
            self?.screenLocked = false; self?.tick()
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"),
                                         object: nil, queue: .main) { [weak self] _ in
            self?.screensaverOn = true; self?.closeLive(at: Date())
        })
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"),
                                         object: nil, queue: .main) { [weak self] _ in
            self?.screensaverOn = false; self?.tick()
        })

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
        tick()
    }

    // Idle seconds since the last HID input across the whole session.
    private func idleTime() -> TimeInterval {
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                       eventType: CGEventType(rawValue: ~0)!)
    }

    // Bundle ids of every process currently holding a "prevent user idle" power
    // assertion (display OR system) — i.e. something is playing/presenting/calling
    // that keeps the Mac awake without input. Per-PROCESS (not the global count)
    // so we can tell WHICH app is asserting: the frontmost one (you're watching it)
    // vs a background one (bg media). Helper/renderer child PIDs resolve to their
    // own bundle id (e.g. com.google.Chrome.helper); mediaBase() folds them back.
    // Scan IOKit power assertions ONCE per tick and return two bundle-id sets:
    //   all   — every app RESPONSIBLE for a PreventUserIdle* assertion (call /
    //           presentation / download / media). Keeps the FOREGROUND active past
    //           the idle threshold when the frontmost app is in it.
    //   media — apps actively playing MEDIA, by two reliable signals:
    //     (1) AUDIO: coreaudiod holds the assertion ON BEHALF OF an app
    //         (AssertionOnBehalfOfPID). coreaudiod only asserts during real audio
    //         playback, for ANY app — no allowlist needed (catches rekordbox,
    //         Spotify, browser PiP/bg audio, VLC, …). Detected via Process Name
    //         "coreaudiod" / AssertName "com.apple.audio…" / ResourcesUsed audio-out.
    //     (2) VIDEO: an allowlisted media app (browser/player) holding the assertion
    //         directly — video keeping the Mac awake, possibly muted. Allowlisted
    //         to avoid false positives from non-media holders.
    private func scanAssertions() -> (all: Set<String>, media: Set<String>) {
        var byProc: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProc) == kIOReturnSuccess,
              let dict = byProc?.takeRetainedValue() as? [AnyHashable: Any] else {
            return ([], [])
        }
        func bundle(forPid pid: pid_t) -> String? {
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
        var all: Set<String> = []
        var media: Set<String> = []
        for (pidKey, val) in dict {
            guard let assertions = val as? [[String: Any]] else { continue }
            let ownerPid = (pidKey as? NSNumber)?.int32Value ?? -1
            for a in assertions {
                let type = (a["AssertType"] as? String) ?? ""
                guard type == "PreventUserIdleDisplaySleep" || type == "PreventUserIdleSystemSleep"
                else { continue }
                let onBehalf = (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value ?? -1
                // Responsible app = the on-behalf-of app if present, else the owner.
                let respBundle = (onBehalf > 0 ? bundle(forPid: onBehalf) : nil) ?? (ownerPid > 0 ? bundle(forPid: ownerPid) : nil)
                if let rb = respBundle { all.insert(rb) }
                // (1) Audio playback: owner is the audio daemon, on behalf of an app.
                let proc = (a["Process Name"] as? String) ?? ""
                let aname = (a["AssertName"] as? String) ?? ""
                let resources = ((a["ResourcesUsed"] as? [Any])?.map { "\($0)" } ?? []).joined(separator: ",")
                let isAudio = proc == "coreaudiod" || aname.contains("com.apple.audio") || resources.contains("audio-out")
                if isAudio, onBehalf > 0, let b = bundle(forPid: onBehalf) {
                    media.insert(b)
                } else if let rb = respBundle, mediaBase(of: rb) != nil {
                    // (2) Video by an allowlisted media app.
                    media.insert(rb)
                }
            }
        }
        return (all, media)
    }

    // Does the FRONTMOST app (or a helper child / same media base) hold an
    // assertion? Keeps the foreground active past the idle threshold — you're
    // watching / on a call / presenting IN FRONT. A purely background assertion
    // does NOT qualify (that's handled as bg media instead).
    private func matchesFrontmost(_ frontBundle: String?, _ set: Set<String>) -> Bool {
        guard let fb = frontBundle else { return false }
        if set.contains(fb) { return true }
        if set.contains(where: { $0.hasPrefix(fb + ".") }) { return true }   // helper child
        let fbBase = mediaBase(of: fb)
        return fbBase != nil && set.contains { mediaBase(of: $0) == fbBase }
    }

    // active = unlocked AND not screensaver AND not asleep AND
    //          (input idle < threshold OR the FRONTMOST app holds an assertion)
    private func foregroundActive(frontBundle: String?, asserting: Set<String>) -> Bool {
        if asleep || screensaverOn || isLocked() { return false }
        if idleTime() < idleThreshold { return true }
        return matchesFrontmost(frontBundle, asserting)
    }

    // Live query for screen-lock via the private CGSSessionScreenIsLocked symbol,
    // resolved with dlsym so a macOS removal degrades gracefully (we fall back to
    // the distributed-notification latch, with idle-after-threshold as backstop).
    private func cgsScreenLocked() -> Bool? {
        typealias Fn = @convention(c) () -> Bool
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                              "CGSSessionScreenIsLocked") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)()
    }

    private func isLocked() -> Bool {
        if let live = cgsScreenLocked() { return live }
        return screenLocked
    }

    // Update the BACKGROUND-media ledger for this tick. `media` = apps playing
    // media right now (audio via coreaudiod, or allowlisted video), MINUS the one
    // (if any) you're watching in FRONT (that's foreground active time, tracked
    // with its URL elsewhere). Open a row per new bg app, heartbeat existing ones,
    // close any that stopped. App-level only — a background/PiP tab's URL (and, on
    // macOS 15.4+, the Now Playing title) isn't reachable. Independent of lock/idle:
    // runs every tick regardless of foreground state.
    private func updateBackgroundMedia(now: Int64, today: String,
                                       media: Set<String>, frontWatching: String?) {
        var bgBundles = media
        if let f = frontWatching {
            let fBase = mediaBase(of: f)
            bgBundles = bgBundles.filter { b in
                b != f && !b.hasPrefix(f + ".") && !(fBase != nil && mediaBase(of: b) == fBase)
            }
        }
        for b in bgBundles where liveBg[b] == nil {
            let name = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == b }?.localizedName ?? b
            let row = db.insertSegment(start: now, occurredOn: today, bundleId: b,
                                       appName: name, host: nil, path: nil,
                                       attribution: "ok", kind: "bg_media")
            if row != 0 { liveBg[b] = row }
        }
        var toRemove: [String] = []
        for (b, row) in liveBg {
            if bgBundles.contains(b) {
                db.touchEnded(rowId: row, end: now)   // still playing → heartbeat
            } else {
                toRemove.append(b)                      // stopped → ended_at stays at last heartbeat
            }
        }
        for b in toRemove { liveBg.removeValue(forKey: b) }
    }

    // Drop all live bg rows without extending them (sleep / day-rollover): the
    // ended_at already sits at the last heartbeat, so we never credit silence.
    private func closeAllBg() { liveBg.removeAll() }

    // Close the live span (leave ended_at at the last heartbeat / `at`, never
    // extend it for time we now know was away).
    private func closeLive(at date: Date) {
        guard liveRow != 0 else { return }
        // ended_at already tracks the last active heartbeat; nothing to extend.
        liveRow = 0
        liveKey = nil
    }

    // Resolve the frontmost app's (bundleId, name) and, if it's a browser we can
    // read and are permitted to, its active-tab host + attribution.
    private func currentTarget() -> (bundleId: String?, name: String?, host: String?, path: String?, attr: String) {
        let front = NSWorkspace.shared.frontmostApplication
        let bundleId = front?.bundleIdentifier
        let name = front?.localizedName
        guard let bid = bundleId, isKnownBrowser(bid) else {
            return (bundleId, name, nil, nil, "not_browser")
        }
        guard automationPermitted(bid) else {
            return (bundleId, name, nil, nil, "tcc_denied")
        }
        let (host, path, attr) = fetchHostBounded(bid)
        return (bundleId, name, host, path, attr)
    }

    // Non-reentrant, timeout-bounded AppleScript fetch. The common case returns in
    // well under fetchTimeout, giving an accurate host this poll. A wedged browser
    // is abandoned after fetchTimeout (attribution=timeout) and NOT re-issued until
    // the in-flight task finishes — so a hung browser can never wedge the recorder.
    private func fetchHostBounded(_ bundleId: String) -> (String?, String?, String) {
        if hostFetchInFlight { return (nil, nil, "timeout") }
        hostFetchInFlight = true
        let src = urlScript(for: bundleId)
        final class Box { var v: (String?, String?, String) = (nil, nil, "timeout") }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        aeQueue.async {
            let r = runURLScript(src)
            box.v = r
            sem.signal()
            DispatchQueue.main.async { self.hostFetchInFlight = false }
        }
        if sem.wait(timeout: .now() + fetchTimeout) == .timedOut {
            // Leave hostFetchInFlight = true; the bg task clears it when it finishes.
            return (nil, nil, "timeout")
        }
        return box.v
    }

    // One sampling step: app-switch event OR the ~10s poll. The whole state
    // machine lives here.
    func tick() {
        let now = Date()
        let nowEpoch = epoch(now)

        // Midnight rollover: if a span is live and the local day changed, split it
        // exactly at local midnight so each day's seconds bucket correctly. Applies
        // to the foreground span AND every live bg-media span.
        let today = localDay(now)
        if today != liveDay {
            let midnight = epoch(startOfLocalDay(now))
            if liveRow != 0 {
                db.touchEnded(rowId: liveRow, end: midnight)
                liveRow = 0
                liveKey = nil
            }
            for (_, row) in liveBg { db.touchEnded(rowId: row, end: midnight) }
            closeAllBg()
        }
        liveDay = today

        // Shared per-tick signals, computed once. `all` = every app holding a
        // prevent-idle assertion (foreground grace); `media` = apps actually
        // playing media (bg ledger). Nothing plays while the system is asleep.
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let scan = asleep ? (all: Set<String>(), media: Set<String>()) : scanAssertions()
        let fgActive = foregroundActive(frontBundle: frontBundle, asserting: scan.all)
        // If the frontmost app is itself the media you're consuming, that's
        // foreground — exclude it from the bg ledger so it's never double-counted.
        let frontWatching = (fgActive && matchesFrontmost(frontBundle, scan.media)) ? frontBundle : nil
        updateBackgroundMedia(now: nowEpoch, today: today, media: scan.media,
                              frontWatching: frontWatching)

        guard fgActive else {
            closeLive(at: now)
            return
        }

        let t = currentTarget()
        // Path is part of the key: navigating to a new path within the same host
        // closes the old span and opens a fresh one, so each path buckets its own
        // active seconds.
        let key = "\(t.bundleId ?? "")\u{1f}\(t.path ?? t.host ?? "")\u{1f}\(t.attr)"

        if liveRow == 0 || key != liveKey {
            // Close the old span (ended_at already ~now from its last heartbeat),
            // then open a fresh one for the new (app, host, path, attribution).
            if liveRow != 0 { db.touchEnded(rowId: liveRow, end: nowEpoch) }
            liveRow = db.insertSegment(start: nowEpoch, occurredOn: today,
                                       bundleId: t.bundleId, appName: t.name,
                                       host: t.host, path: t.path, attribution: t.attr)
            liveKey = (liveRow != 0) ? key : nil
        } else {
            // Same target, still active → heartbeat.
            db.touchEnded(rowId: liveRow, end: nowEpoch)
        }
    }
}

// ---------------------------------------------------------------------------
// Entry point.
// ---------------------------------------------------------------------------
if CommandLine.arguments.contains("--probe-access") {
    // Foreground grant flow — no run loop. Needs an app instance for AE plumbing.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    runProbeAccess()
    exit(0)
}

guard let database = TrackerDB(path: dbPath) else {
    FileHandle.standardError.write("pbrain-tracker: cannot open DB at \(dbPath)\n".data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; resident background agent
let tracker = Tracker(db: database, poll: pollSeconds, idle: idleSeconds)

final class AppDelegate: NSObject, NSApplicationDelegate {
    let tracker: Tracker
    init(_ t: Tracker) { tracker = t }
    func applicationDidFinishLaunching(_ note: Notification) { tracker.start() }
}
let delegate = AppDelegate(tracker)
app.delegate = delegate
app.run()
