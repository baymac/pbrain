// pbrain-notify — minimal macOS notifier (fire-and-forget).
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
// It is now used SOLELY as the /remind-blocking overlay's degradation path: when
// swiftc is unavailable to build the full-screen overlay, a blocking reminder
// falls back to a plain notification so it still surfaces. (The old interactive
// Snooze/Cancel + SQLite write-back path was for /remind's notification queue,
// which is gone — /remind is Apple Calendar-only and never touches the DB.)
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
// USAGE
//   pbrain-notify --title "Reminder" --message "call the dentist"
//                 [--sound <name>|none] [--bundle-id <id>|""]
//
// Build: `swiftc -suppress-warnings pbrain-notify.swift`

import Foundation
import ObjectiveC.runtime

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

let title    = argValue("--title") ?? "pbrain"
let message  = argValue("--message") ?? ""
let soundArg = argValue("--sound")

// ---------------------------------------------------------------------------
// A minimal delegate that forces presentation even if a foreground app exists.
// ---------------------------------------------------------------------------
class PBrainDelegate: NSObject, NSUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool { true }
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

// SILENT BY DEFAULT (user decision): pbrain notifications make no sound unless
// a sound is named EXPLICITLY via --sound. The previous default here was
// NSUserNotificationDefaultSoundName, which meant every un-flagged caller
// chimed. Leaving soundName nil delivers the banner silently.
if let s = soundArg, !s.isEmpty, s.lowercased() != "none" {
    note.soundName = s
}

let delegate = PBrainDelegate()
center.delegate = delegate
center.deliver(note)

// ---------------------------------------------------------------------------
// Fire-and-forget: spin only until delivery is confirmed, then exit (~sub-second).
// ---------------------------------------------------------------------------
let deadline = Date().addingTimeInterval(3)
while Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    if center.deliveredNotifications.contains(where: { $0.identifier == ident }) { break }
}
