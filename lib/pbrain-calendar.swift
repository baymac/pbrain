// pbrain-calendar — minimal EventKit helper for pbrain's /remind.
//
// Why this exists: AppleScript can reliably CREATE iCloud calendar events but
// cannot reliably DELETE recurring ones (the change doesn't propagate and the
// event resyncs back). EventKit's `remove(_:span:commit:)` deletes the whole
// series properly. EventKit needs Calendar access (a TCC permission separate
// from the Automation permission AppleScript uses), and that permission is
// keyed to a real app bundle — so this is compiled on demand into
// pbrain-calendar.app by pbrain_calendar_app_build and launched via `open`, so
// the permission prompt is attributed to the app (not the calling terminal).
//
// Args (after the executable):
//   --op delete --uid <iCloud UID> --calendar <name> [--result <file>]
//   --op access-check [--result <file>]     (just request/verify access)
// Writes ONE status line to --result (and stdout):
//   OK | DELETED | NOT_FOUND | ACCESS_DENIED | ERROR:<message>

import EventKit
import Foundation

func arg(_ key: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: key), i + 1 < a.count { return a[i + 1] }
    return nil
}

let op = arg("--op") ?? "access-check"
let resultPath = arg("--result")

func emit(_ s: String) {
    if let p = resultPath {
        try? s.write(toFile: p, atomically: true, encoding: .utf8)
    }
    print(s)
}

let store = EKEventStore()

// Request Calendar access. On macOS 14+ this is "full access"; the call blocks
// (via the semaphore) until the user answers the prompt the first time, or
// returns immediately with the remembered decision afterwards.
var granted = false
let sem = DispatchSemaphore(value: 0)
if #available(macOS 14.0, *) {
    store.requestFullAccessToEvents { ok, _ in granted = ok; sem.signal() }
} else {
    store.requestAccess(to: .event) { ok, _ in granted = ok; sem.signal() }
}
sem.wait()

guard granted else { emit("ACCESS_DENIED"); exit(2) }

switch op {
case "access-check":
    emit("OK")
    exit(0)

case "list":
    // Debug: dump events matching a title substring with their identifiers.
    let calName = arg("--calendar") ?? "Calendar"
    var cals = store.calendars(for: .event).filter { $0.title == calName }
    if cals.isEmpty { cals = store.calendars(for: .event) }
    let needle = (arg("--match") ?? "").lowercased()
    let start = Date().addingTimeInterval(-400 * 86400)
    let end = Date().addingTimeInterval(2000 * 86400)
    let pred = store.predicateForEvents(withStart: start, end: end, calendars: cals)
    var lines: [String] = []
    var seen = Set<String>()
    for ev in store.events(matching: pred) {
        let title = ev.title ?? ""
        if !needle.isEmpty && !title.lowercased().contains(needle) { continue }
        let ext = ev.calendarItemExternalIdentifier ?? "nil"
        if seen.contains(ext) { continue }
        seen.insert(ext)
        lines.append("\(ext)\t\(title)")
    }
    emit(lines.joined(separator: "\n"))
    exit(0)

case "delete":
    // Match by a pbrain id token embedded in the event notes (--id), since
    // EventKit's identifiers don't line up with AppleScript's uid (the two APIs
    // use different identifier spaces). --match-title is a cleanup fallback.
    let token = arg("--id").flatMap { $0.isEmpty ? nil : $0 }
    let titleNeedle = arg("--match-title").flatMap { $0.isEmpty ? nil : $0 }
    guard token != nil || titleNeedle != nil else { emit("ERROR:missing-id"); exit(1) }
    let calName = arg("--calendar") ?? "Calendar"
    var cals = store.calendars(for: .event).filter { $0.title == calName }
    if cals.isEmpty { cals = store.calendars(for: .event) }  // fall back to all
    // Window wide enough to catch a recurring master that started up to ~400
    // days ago and extends years ahead. events(matching:) expands instances, so
    // many rows can share one series; removing any instance with .futureEvents
    // tears the series down. Dedupe by externalIdentifier so we remove once.
    let start = Date().addingTimeInterval(-400 * 86400)
    let end = Date().addingTimeInterval(2000 * 86400)
    let pred = store.predicateForEvents(withStart: start, end: end, calendars: cals)
    func matchesEvent(_ ev: EKEvent) -> Bool {
        if let t = token { return (ev.notes ?? "").contains("⟦pbrain-id:\(t)⟧") }
        if let n = titleNeedle { return (ev.title ?? "") == n }  // EXACT (cleanup only)
        return false
    }
    var series: [String: EKEvent] = [:]   // externalIdentifier -> earliest instance
    for ev in store.events(matching: pred) where matchesEvent(ev) {
        let key = ev.calendarItemExternalIdentifier ?? ev.eventIdentifier ?? UUID().uuidString
        if let cur = series[key], cur.startDate <= ev.startDate { continue }
        series[key] = ev
    }
    if series.isEmpty { emit("NOT_FOUND"); exit(0) }
    var removed = 0
    for ev in series.values {
        do { try store.remove(ev, span: .futureEvents, commit: false); removed += 1 }
        catch { emit("ERROR:\(error.localizedDescription)"); exit(1) }
    }
    do { try store.commit() } catch { emit("ERROR:\(error.localizedDescription)"); exit(1) }
    emit("DELETED \(removed)")
    exit(0)

default:
    emit("ERROR:unknown-op")
    exit(1)
}
