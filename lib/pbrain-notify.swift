// pbrain-notify — macOS notifier with optional Snooze / Cancel action buttons.
//
// WHY THIS EXISTS
// ---------------
// `osascript display notification` is silently dropped when fired from a launchd
// background agent: from that context there's no trusted app bundle identity for
// the notification permission check, so macOS discards the notification (exits 0,
// but nothing ever shows). That's the exact failure the reminders poller hit.
//
// This is a self-contained replacement. It is compiled by `pbrain_notify_build`
// (lib/reminders.sh) from this source into `pbrain-notify.app/Contents/MacOS/`,
// so it runs inside a real app bundle with a stable identity. `pbrain_notify`
// then calls it instead of osascript, with osascript kept only as a last-resort
// fallback when this binary can't be built (no swiftc).
//
// APPROACH: NSUserNotification + a borrowed identity
// --------------------------------------------------
// We use NSUserNotification (deprecated, but still functional on macOS 14/15 and
// the API the maintained `alerter` tool ships today) rather than the modern
// UNUserNotificationCenter. UN was tested and rejected for this use case: it
// requires a code-signed bundle AND a granted, first-run authorization, and from
// an unattended launchd poller `add(request:)` is silently dropped — empirically
// it returns "Notifications are not allowed for this application" for an ad-hoc
// CLI tool, even after lsregister. NSUserNotification needs neither signing nor
// an authorization dialog.
//
// The one Sequoia (macOS 15) gotcha: NSUserNotification drops notifications from
// an UNRECOGNIZED app identity (this broke terminal-notifier — julienXX/terminal-
// notifier#312). The fix, taken straight from `alerter`, is to swizzle
// `Bundle.main.bundleIdentifier` to return a pre-trusted, always-present identity
// — `com.apple.Terminal` — so the system accepts the notification. Side effects:
// the banner reads as "Terminal" and clicking it opens Terminal.app. That is the
// accepted trade for notifications that actually fire from the background.
//
// Override the borrowed identity with `--bundle-id <id>` (e.g. set
// PBRAIN_NOTIFY_IDENTITY in the shell), or disable the swizzle entirely with
// `--bundle-id ""` to deliver under this app's own com.pbrain.notify identity.
//
// ACTION BUTTONS (Snooze / Cancel)
// ---------------------------------
// Pass `--id <reminder_id>` and `--db <path>` to enable interactive mode:
// - The notification gains "Snooze 1h" (action button) and "Cancel" (additional
//   action, revealed via the ▼ dropdown in NC or banner long-press).
// - The binary stays alive for --timeout seconds (default 30) listening for the
//   delegate callback, then updates the DB directly via SQLite3 C API and exits.
// - Without --id / --db the binary falls back to the original fire-and-forget
//   behaviour (exits as soon as delivery is confirmed, ~sub-second).
//
// USAGE
//   pbrain-notify --title "Reminder" --message "call the dentist"
//                 [--id <reminder_id>] [--db <path>]
//                 [--timeout <seconds>]          # default 30; only with --id
//                 [--sound <name>|none] [--bundle-id <id>|""]
//
// Build: `swiftc -suppress-warnings pbrain-notify.swift`

import Foundation
import ObjectiveC.runtime
import SQLite3

// ---------------------------------------------------------------------------
// Bundle-identity hook. After method_exchangeImplementations, the original
// getter is reachable through the `pbrain_bundleIdentifier` selector, so the
// recursive-looking call below actually invokes the real implementation.
// ---------------------------------------------------------------------------
var pbrainImpersonatedID: String? = "com.apple.Terminal"

extension Bundle {
    @objc dynamic func pbrain_bundleIdentifier() -> String? {
        if self === Bundle.main { return pbrainImpersonatedID }
        return self.pbrain_bundleIdentifier()
    }
}

func installBundleIDHook() {
    guard
        let orig = class_getInstanceMethod(Bundle.self, #selector(getter: Bundle.bundleIdentifier)),
        let repl = class_getInstanceMethod(Bundle.self, #selector(Bundle.pbrain_bundleIdentifier))
    else { return }
    method_exchangeImplementations(orig, repl)
}

// ---------------------------------------------------------------------------
// Args. Values are read straight from argv and assigned to object properties —
// never interpolated into any interpreted string — so arbitrary reminder text
// (quotes, backslashes, $, etc.) is inert and cannot inject.
// ---------------------------------------------------------------------------
func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}

// --bundle-id present: "" disables the swizzle (use our own identity); any other
// value overrides the borrowed identity. Absent: default to com.apple.Terminal.
if let bid = argValue("--bundle-id") {
    pbrainImpersonatedID = bid.isEmpty ? nil : bid
}
if pbrainImpersonatedID != nil { installBundleIDHook() }

let title      = argValue("--title") ?? "pbrain"
let message    = argValue("--message") ?? ""
let soundArg   = argValue("--sound")
let dbPath     = argValue("--db")
let timeoutSec = Double(argValue("--timeout") ?? "30") ?? 30.0
let reminderID: Int32? = argValue("--id").flatMap { Int32($0) }
let hasInteractivity = reminderID != nil && dbPath != nil

// ---------------------------------------------------------------------------
// SQLite helpers — update the reminder row directly from Swift so the shell
// caller can fire the binary asynchronously (fire-and-forget from remind.sh).
// ---------------------------------------------------------------------------
func isoDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}

func snoozeReminder(db: String, id: Int32, hours: Double) {
    var conn: OpaquePointer?
    guard sqlite3_open(db, &conn) == SQLITE_OK else { return }
    defer { sqlite3_close(conn) }
    let newDue = isoDate(Date().addingTimeInterval(hours * 3600))
    let sql = "UPDATE reminders SET due_at=?, fired_at=NULL WHERE id=? AND status='pending'"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    newDue.withCString { cstr in
        sqlite3_bind_text(stmt, 1, cstr, -1, nil)
        sqlite3_bind_int(stmt, 2, id)
        sqlite3_step(stmt)
    }
}

func cancelReminder(db: String, id: Int32) {
    var conn: OpaquePointer?
    guard sqlite3_open(db, &conn) == SQLITE_OK else { return }
    defer { sqlite3_close(conn) }
    let sql = "UPDATE reminders SET status='cancelled', done_at=? WHERE id=? AND status='pending'"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    isoDate(Date()).withCString { cstr in
        sqlite3_bind_text(stmt, 1, cstr, -1, nil)
        sqlite3_bind_int(stmt, 2, id)
        sqlite3_step(stmt)
    }
}

// ---------------------------------------------------------------------------
// Delegate — receives action button callbacks while the run loop is live.
// ---------------------------------------------------------------------------
class PBrainDelegate: NSObject, NSUserNotificationCenterDelegate {
    let targetID: String
    let reminderID: Int32?
    let dbPath: String?
    var handled = false

    init(_ targetID: String, _ reminderID: Int32?, _ dbPath: String?) {
        self.targetID = targetID
        self.reminderID = reminderID
        self.dbPath = dbPath
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool { true }

    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                didActivate notification: NSUserNotification) {
        defer {
            handled = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        guard notification.identifier == targetID,
              let rid = reminderID, let db = dbPath else { return }
        switch notification.activationType {
        case .actionButtonClicked:
            cancelReminder(db: db, id: rid)
        case .additionalActionClicked:
            if notification.additionalActivationAction?.identifier == "snooze" {
                snoozeReminder(db: db, id: rid, hours: 1.0)
            }
        default:
            break
        }
    }
}

// ---------------------------------------------------------------------------
// Notification setup + delivery.
// ---------------------------------------------------------------------------
let center = NSUserNotificationCenter.default
let note   = NSUserNotification()
let ident  = "pbrain-\(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970))"
note.identifier    = ident
note.title         = title
note.informativeText = message

if let s = soundArg {
    if !s.isEmpty && s.lowercased() != "none" { note.soundName = s }
} else {
    note.soundName = NSUserNotificationDefaultSoundName
}

if hasInteractivity {
    note.hasActionButton   = true
    note.actionButtonTitle = "Cancel"
    note.additionalActions = [NSUserNotificationAction(identifier: "snooze", title: "Snooze 1h")]
}

let delegate = PBrainDelegate(ident, reminderID, dbPath)
center.delegate = delegate
center.deliver(note)

// ---------------------------------------------------------------------------
// Run loop — spin until delivery is confirmed and, in interactive mode, until
// the user acts (or the timeout elapses). Early exit keeps the poller snappy.
// ---------------------------------------------------------------------------
if hasInteractivity {
    // Stay alive so action button callbacks can reach the delegate.
    let deadline = Date().addingTimeInterval(timeoutSec)
    while !delegate.handled && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
} else {
    // Fire-and-forget path: just confirm delivery then exit (~sub-second).
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        if center.deliveredNotifications.contains(where: { $0.identifier == ident }) { break }
    }
}
