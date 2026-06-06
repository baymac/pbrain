// pbrain-reminders — minimal EventKit helper for pbrain's /remind.
//
// /remind creates real Apple **Reminders** (EKReminder), NOT Calendar events.
// A reminder is a to-do with an optional due date/time, optional recurrence,
// a priority, and zero or more alarms (incl. "early" alarms that fire some
// minutes before the due time). Reminders.app + iCloud own firing + sync; there
// is no pbrain DB or launchd poller for /remind.
//
// EventKit Reminders access is a TCC permission DISTINCT from Calendar access,
// keyed to a real app bundle — so this is compiled on demand into
// pbrain-reminders.app by pbrain_reminders_app_build and launched via `open`, so
// the permission prompt is attributed to the app (not the calling terminal).
//
// Every op writes ONE status line to --result (and stdout). Args (after exe):
//   --op access-check [--result F]
//   --op add  --title T [--due "YYYY-MM-DD HH:MM" | --due "YYYY-MM-DD"]
//             [--rrule RRULE] [--notes N] [--priority none|high|medium|low|0-9]
//             [--alarms 0,15,60] [--list NAME] [--marker M] [--result F]
//        → ADDED <calendarItemIdentifier>
//   --op list [--list NAME] [--marker M] [--result F]
//        → one line per reminder: <id>\t<due-or-(none)>\t<priority-word>\t<rrule-or->\t<title>
//   --op edit --id ID [--title T] [--due …] [--rrule RRULE] [--clear-recurrence]
//             [--priority …] [--alarms …] [--clear-alarms] [--notes N] [--result F]
//        → EDITED | NOT_FOUND
//   --op complete --id ID [--result F]      → COMPLETED | NOT_FOUND
//   --op delete   --id ID [--result F]      → DELETED   | NOT_FOUND
// Status tokens: OK | ADDED <id> | EDITED | COMPLETED | DELETED | NOT_FOUND |
//                ACCESS_DENIED | ERROR:<message>
//
// The --rrule is a small iCalendar subset: FREQ=DAILY|WEEKLY|MONTHLY|YEARLY,
// INTERVAL=N, BYDAY=MO,TU,1MO,-1FR, BYMONTHDAY=1,15, BYMONTH=1,6,
// COUNT=N, UNTIL=YYYYMMDD[THHMMSSZ]. (Sub-daily — HOURLY/MINUTELY — is NOT
// representable as an EKReminder recurrence and is rejected upstream in the
// shell; do not pass it here.)

import EventKit
import Foundation

func arg(_ key: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: key), i + 1 < a.count { return a[i + 1] }
    return nil
}
func hasFlag(_ key: String) -> Bool { CommandLine.arguments.contains(key) }

let op = arg("--op") ?? "access-check"
let resultPath = arg("--result")

func emit(_ s: String) {
    if let p = resultPath { try? s.write(toFile: p, atomically: true, encoding: .utf8) }
    print(s)
}

let store = EKEventStore()

// Reminders access — a DISTINCT TCC permission from Calendar. Blocks on the
// semaphore until the user answers the first prompt, then returns the remembered
// decision.
var granted = false
let accessSem = DispatchSemaphore(value: 0)
if #available(macOS 14.0, *) {
    store.requestFullAccessToReminders { ok, _ in granted = ok; accessSem.signal() }
} else {
    store.requestAccess(to: .reminder) { ok, _ in granted = ok; accessSem.signal() }
}
accessSem.wait()
guard granted else { emit("ACCESS_DENIED"); exit(2) }

// --- helpers ----------------------------------------------------------------

// fetchReminders is callback-based; wrap it synchronously.
func fetchReminders(_ pred: NSPredicate) -> [EKReminder] {
    var out: [EKReminder] = []
    let s = DispatchSemaphore(value: 0)
    store.fetchReminders(matching: pred) { rems in out = rems ?? []; s.signal() }
    s.wait()
    return out
}

// Resolve the target Reminders list: the one named --list, else the default.
func targetCalendar() -> EKCalendar? {
    let name = arg("--list")
    let cals = store.calendars(for: .reminder)
    if let n = name, !n.isEmpty, let c = cals.first(where: { $0.title == n }) { return c }
    return store.defaultCalendarForNewReminders()
}

let WEEKDAY_FROM_CODE: [String: EKWeekday] = [
    "SU": .sunday, "MO": .monday, "TU": .tuesday, "WE": .wednesday,
    "TH": .thursday, "FR": .friday, "SA": .saturday,
]
let CODE_FROM_WEEKDAY: [Int: String] = [
    1: "SU", 2: "MO", 3: "TU", 4: "WE", 5: "TH", 6: "FR", 7: "SA",
]

// Priority: accept a word or an int 0-9. EKReminderPriority rawValue is UInt —
// cast to Int (EKReminder.priority is Int). 0=none,1=high,5=medium,9=low.
func parsePriority(_ s: String?) -> Int? {
    guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    switch s.lowercased() {
    case "none", "0": return 0
    case "high":      return Int(EKReminderPriority.high.rawValue)    // 1
    case "medium",
         "med":       return Int(EKReminderPriority.medium.rawValue)  // 5
    case "low":       return Int(EKReminderPriority.low.rawValue)     // 9
    default:
        if let n = Int(s), (0...9).contains(n) { return n }
        return nil
    }
}
func priorityWord(_ p: Int) -> String {
    switch p {
    case 0: return "none"
    case 1...4: return "high"
    case 5: return "medium"
    case 6...9: return "low"
    default: return "none"
    }
}

// Parse "YYYY-MM-DD HH:MM" or "YYYY-MM-DD" into DateComponents. When a time is
// present the components include hour/minute (required for the reminder to fire
// a timed notification on macOS); date-only omits them.
func parseDueComponents(_ s: String) -> DateComponents? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let cal = Calendar.current
    let withTime = DateFormatter()
    withTime.locale = Locale(identifier: "en_US_POSIX")
    withTime.dateFormat = "yyyy-MM-dd HH:mm"
    if let d = withTime.date(from: t) {
        return cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
    }
    let dateOnly = DateFormatter()
    dateOnly.locale = Locale(identifier: "en_US_POSIX")
    dateOnly.dateFormat = "yyyy-MM-dd"
    if let d = dateOnly.date(from: t) {
        return cal.dateComponents([.year, .month, .day], from: d)
    }
    return nil
}

// Parse a BYDAY token like "MO", "1MO", "-1FR" into an EKRecurrenceDayOfWeek.
func parseDayOfWeek(_ tok: String) -> EKRecurrenceDayOfWeek? {
    let t = tok.trimmingCharacters(in: .whitespaces).uppercased()
    guard t.count >= 2 else { return nil }
    let code = String(t.suffix(2))
    guard let wd = WEEKDAY_FROM_CODE[code] else { return nil }
    let prefix = String(t.dropLast(2))
    if prefix.isEmpty {
        return EKRecurrenceDayOfWeek(wd)
    }
    guard let ord = Int(prefix), ord != 0 else { return nil }
    return EKRecurrenceDayOfWeek(dayOfTheWeek: wd, weekNumber: ord)
}

// Parse the iCalendar RRULE subset into an EKRecurrenceRule. Returns nil on an
// empty/blank rule, throws-as-nil on anything unparseable (caller treats nil as
// "no recurrence" only when the input was blank — see callers).
func parseRRule(_ rrule: String) -> EKRecurrenceRule? {
    let s = rrule.trimmingCharacters(in: .whitespaces)
    if s.isEmpty { return nil }
    var fields: [String: String] = [:]
    for part in s.split(separator: ";") {
        let kv = part.split(separator: "=", maxSplits: 1)
        if kv.count == 2 { fields[kv[0].uppercased()] = String(kv[1]) }
    }
    let freq: EKRecurrenceFrequency
    switch (fields["FREQ"] ?? "").uppercased() {
    case "DAILY":   freq = .daily
    case "WEEKLY":  freq = .weekly
    case "MONTHLY": freq = .monthly
    case "YEARLY":  freq = .yearly
    default: return nil
    }
    let interval = max(1, Int(fields["INTERVAL"] ?? "1") ?? 1)

    var days: [EKRecurrenceDayOfWeek]? = nil
    if let by = fields["BYDAY"], !by.isEmpty {
        let parsed = by.split(separator: ",").compactMap { parseDayOfWeek(String($0)) }
        days = parsed.isEmpty ? nil : parsed
    }
    var monthDays: [NSNumber]? = nil
    if let by = fields["BYMONTHDAY"], !by.isEmpty {
        let parsed = by.split(separator: ",").compactMap { Int($0) }.map { NSNumber(value: $0) }
        monthDays = parsed.isEmpty ? nil : parsed
    }
    var months: [NSNumber]? = nil
    if let by = fields["BYMONTH"], !by.isEmpty {
        let parsed = by.split(separator: ",").compactMap { Int($0) }.map { NSNumber(value: $0) }
        months = parsed.isEmpty ? nil : parsed
    }
    var setPos: [NSNumber]? = nil
    if let by = fields["BYSETPOS"], !by.isEmpty {
        let parsed = by.split(separator: ",").compactMap { Int($0) }.map { NSNumber(value: $0) }
        setPos = parsed.isEmpty ? nil : parsed
    }

    var end: EKRecurrenceEnd? = nil
    if let c = fields["COUNT"], let n = Int(c), n > 0 {
        end = EKRecurrenceEnd(occurrenceCount: n)
    } else if let u = fields["UNTIL"], !u.isEmpty {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        if let d = f.date(from: String(u.prefix(8))) { end = EKRecurrenceEnd(end: d) }
    }

    return EKRecurrenceRule(
        recurrenceWith: freq,
        interval: interval,
        daysOfTheWeek: days,
        daysOfTheMonth: monthDays,
        monthsOfTheYear: months,
        weeksOfTheYear: nil,
        daysOfTheYear: nil,
        setPositions: setPos,
        end: end)
}

// Render an EKRecurrenceRule back to a compact RRULE for `list` display.
func renderRRule(_ rule: EKRecurrenceRule) -> String {
    var parts: [String] = []
    switch rule.frequency {
    case .daily:   parts.append("FREQ=DAILY")
    case .weekly:  parts.append("FREQ=WEEKLY")
    case .monthly: parts.append("FREQ=MONTHLY")
    case .yearly:  parts.append("FREQ=YEARLY")
    @unknown default: parts.append("FREQ=DAILY")
    }
    if rule.interval > 1 { parts.append("INTERVAL=\(rule.interval)") }
    if let days = rule.daysOfTheWeek, !days.isEmpty {
        let toks = days.map { d -> String in
            let code = CODE_FROM_WEEKDAY[d.dayOfTheWeek.rawValue] ?? "?"
            return d.weekNumber != 0 ? "\(d.weekNumber)\(code)" : code
        }
        parts.append("BYDAY=" + toks.joined(separator: ","))
    }
    if let md = rule.daysOfTheMonth, !md.isEmpty {
        parts.append("BYMONTHDAY=" + md.map { "\($0.intValue)" }.joined(separator: ","))
    }
    if let mo = rule.monthsOfTheYear, !mo.isEmpty {
        parts.append("BYMONTH=" + mo.map { "\($0.intValue)" }.joined(separator: ","))
    }
    return parts.joined(separator: ";")
}

// Build the alarms array from a comma list of "minutes before due" (0 = at due).
func buildAlarms(_ spec: String?) -> [EKAlarm] {
    guard let spec = spec, !spec.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
    var out: [EKAlarm] = []
    for tok in spec.split(separator: ",") {
        if let m = Int(tok.trimmingCharacters(in: .whitespaces)) {
            out.append(EKAlarm(relativeOffset: TimeInterval(-m * 60)))
        }
    }
    return out
}

let MARKER = arg("--marker") ?? "⟦pbrain-reminder⟧"

func appendMarker(_ notes: String?) -> String {
    let body = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? MARKER : body + "\n\n" + MARKER
}

func dueString(_ comps: DateComponents?) -> String {
    guard let c = comps, let d = Calendar.current.date(from: c) else { return "(none)" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = (c.hour != nil) ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
    return f.string(from: d)
}

// --- ops --------------------------------------------------------------------

switch op {

case "access-check":
    emit("OK"); exit(0)

case "add":
    guard let cal = targetCalendar() else { emit("ERROR:no-reminder-list"); exit(1) }
    let r = EKReminder(eventStore: store)
    r.calendar = cal
    r.title = arg("--title") ?? "Reminder"
    r.notes = appendMarker(arg("--notes"))
    if let p = parsePriority(arg("--priority")) { r.priority = p }
    if let due = arg("--due"), let comps = parseDueComponents(due) {
        r.dueDateComponents = comps
        // Alarms: explicit --alarms list, else a single at-due alarm when timed.
        let alarms = buildAlarms(arg("--alarms"))
        if !alarms.isEmpty {
            for a in alarms { r.addAlarm(a) }
        } else if comps.hour != nil {
            r.addAlarm(EKAlarm(relativeOffset: 0))
        }
    }
    if let rr = arg("--rrule"), let rule = parseRRule(rr) {
        r.addRecurrenceRule(rule)
    }
    do {
        try store.save(r, commit: true)
        emit("ADDED \(r.calendarItemIdentifier)")
    } catch { emit("ERROR:\(error.localizedDescription)"); exit(1) }
    exit(0)

case "list":
    let pred = store.predicateForIncompleteReminders(
        withDueDateStarting: nil, ending: nil, calendars: nil)
    var lines: [String] = []
    for r in fetchReminders(pred) {
        if !(r.notes ?? "").contains(MARKER) { continue }
        let due = dueString(r.dueDateComponents)
        let pri = priorityWord(r.priority)
        let rr = r.recurrenceRules?.first.map(renderRRule) ?? "-"
        lines.append("\(r.calendarItemIdentifier)\t\(due)\t\(pri)\t\(rr)\t\(r.title ?? "")")
    }
    emit(lines.joined(separator: "\n")); exit(0)

case "edit":
    guard let id = arg("--id"),
          let r = store.calendarItem(withIdentifier: id) as? EKReminder
    else { emit("NOT_FOUND"); exit(0) }
    if let t = arg("--title") { r.title = t }
    if let n = arg("--notes") { r.notes = appendMarker(n) }
    if let p = parsePriority(arg("--priority")) { r.priority = p }
    if let due = arg("--due"), let comps = parseDueComponents(due) {
        r.dueDateComponents = comps
        // Re-anchor the at-due alarm unless explicit --alarms follow below.
        if arg("--alarms") == nil && !hasFlag("--clear-alarms") {
            (r.alarms ?? []).forEach { r.removeAlarm($0) }
            if comps.hour != nil { r.addAlarm(EKAlarm(relativeOffset: 0)) }
        }
    }
    if hasFlag("--clear-alarms") {
        (r.alarms ?? []).forEach { r.removeAlarm($0) }
    }
    if let spec = arg("--alarms") {
        (r.alarms ?? []).forEach { r.removeAlarm($0) }
        for a in buildAlarms(spec) { r.addAlarm(a) }
    }
    if hasFlag("--clear-recurrence") {
        (r.recurrenceRules ?? []).forEach { r.removeRecurrenceRule($0) }
    }
    if let rr = arg("--rrule"), let rule = parseRRule(rr) {
        (r.recurrenceRules ?? []).forEach { r.removeRecurrenceRule($0) }
        r.addRecurrenceRule(rule)
    }
    do { try store.save(r, commit: true); emit("EDITED") }
    catch { emit("ERROR:\(error.localizedDescription)"); exit(1) }
    exit(0)

case "complete":
    guard let id = arg("--id"),
          let r = store.calendarItem(withIdentifier: id) as? EKReminder
    else { emit("NOT_FOUND"); exit(0) }
    // For a recurring reminder this rolls the due date to the next occurrence;
    // for a one-shot it just marks it done.
    r.isCompleted = true
    do { try store.save(r, commit: true); emit("COMPLETED") }
    catch { emit("ERROR:\(error.localizedDescription)"); exit(1) }
    exit(0)

case "delete":
    guard let id = arg("--id"),
          let r = store.calendarItem(withIdentifier: id) as? EKReminder
    else { emit("NOT_FOUND"); exit(0) }
    do { try store.remove(r, commit: true); emit("DELETED") }
    catch { emit("ERROR:\(error.localizedDescription)"); exit(1) }
    exit(0)

default:
    emit("ERROR:unknown-op"); exit(1)
}
