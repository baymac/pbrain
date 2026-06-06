// pbrain-overlay — full-screen blocking "take a break" overlay.
//
// WHY THIS EXISTS
// ---------------
// A plain notification (pbrain-notify) is trivially ignorable — it slides in and
// out and the user never breaks focus. /remind-blocking wants the opposite: a
// reminder you CANNOT casually dismiss. This draws an opaque overlay across every
// display, above the menu bar and Dock, with a big message and an optional
// MM:SS countdown — the "Take a break" pattern.
//
// RESOLVING THE REMINDER
// ----------------------
// The overlay can also resolve the reminder it represents, so the user doesn't
// have to go mark it off afterwards. Two deliberate hold gestures (held, so they
// can't be hit by accident):
//   • Hold CONTROL  → SKIP  → marks the reminder `cancelled`
//   • Hold RETURN   → DONE  → marks the reminder `done`
//   • Countdown ends → DONE (you waited out the break)
// The status write happens here via the SQLite3 C API (same approach as
// pbrain-notify), enabled by passing --id and --db. It only writes for ONE-SHOT
// reminders: a repeating reminder has already rolled forward to its next
// occurrence by the time the overlay shows, so skipping/finishing one occurrence
// must NOT change the row (that would cancel the whole series) — for repeats the
// gestures simply dismiss.
//
// It is compiled by `pbrain_overlay_build` (lib/reminders.sh) from this source
// into `pbrain-overlay.app/Contents/MacOS/`, so it runs inside a real app bundle
// with a stable identity and a WindowServer connection — the same packaging trick
// pbrain-notify uses, which is what lets it fire reliably from the launchd poller.
//
// KIOSK BEHAVIOUR
// ---------------
// - One borderless, opaque window per screen at the maximum window level, joined
//   to all Spaces, so it covers everything including full-screen apps' menu bar.
// - NSApp.presentationOptions hides the Dock + menu bar and disables process
//   switching (Cmd-Tab), force quit (Cmd-Opt-Esc), and Hide — so the obvious
//   escape hatches are closed. Best-effort friction, not a prison.
// - All key events are swallowed; only a sustained Control / Return hold acts.
//
// SMOOTHNESS
// ----------
// The hold bar is driven by a single Core Animation (transform.scale.x 0→1 over
// the hold duration), NOT a per-frame timer — so it fills perfectly smoothly on
// the GPU. The countdown is computed from a fixed end-date each tick, so seconds
// never skip or bunch up under coalescing.
//
// USAGE
//   pbrain-overlay --message "Take a break"
//                  [--seconds 300]          # countdown; 0 / omitted = no countdown
//                  [--hold 5]               # seconds of hold required to act
//                  [--background "#1e3a5f"] # solid bg colour (hex); default slate
//                  [--subtext "..."]        # optional smaller line under the message
//                  [--id <reminder_id>] [--db <path>] [--repeat <token|"">]
//
// Build: `swiftc -suppress-warnings pbrain-overlay.swift`

import Cocoa
import QuartzCore
import SQLite3

// ---------------------------------------------------------------------------
// Args. Values come straight from argv — never interpolated into an interpreted
// string — so arbitrary reminder text (quotes, $, backslashes) is inert.
// ---------------------------------------------------------------------------
func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}

let message      = argValue("--message") ?? "Take a break"
let subtext      = argValue("--subtext")
let totalSeconds = max(0, Int(argValue("--seconds") ?? "0") ?? 0)   // 0 = no countdown
let holdSeconds  = max(0.5, Double(argValue("--hold") ?? "5") ?? 5.0)

let reminderID: Int32?   = argValue("--id").flatMap { Int32($0) }
let dbPath: String?      = { let p = argValue("--db"); return (p?.isEmpty == false) ? p : nil }()
let repeatToken: String  = (argValue("--repeat") ?? "").trimmingCharacters(in: .whitespaces)
let isOneShot: Bool      = repeatToken.isEmpty        // repeats already rolled forward → don't mutate
let canWrite: Bool       = reminderID != nil && dbPath != nil

func colorFromHex(_ hex: String?) -> NSColor {
    let fallback = NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.34, alpha: 1) // slate
    guard var h = hex else { return fallback }
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = Int(h, radix: 16) else { return fallback }
    return NSColor(
        calibratedRed: CGFloat((v >> 16) & 0xff) / 255.0,
        green:         CGFloat((v >> 8)  & 0xff) / 255.0,
        blue:          CGFloat( v        & 0xff) / 255.0,
        alpha: 1)
}
let background = colorFromHex(argValue("--background"))

// ---------------------------------------------------------------------------
// SQLite write-back — set the reminder's status directly (like pbrain-notify).
// No-op unless this is a one-shot reminder with an --id and --db.
// ---------------------------------------------------------------------------
func isoNow() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date())
}

func setReminderStatus(_ status: String) {
    guard isOneShot, canWrite, let db = dbPath, let rid = reminderID else { return }
    var conn: OpaquePointer?
    guard sqlite3_open(db, &conn) == SQLITE_OK else { return }
    defer { sqlite3_close(conn) }
    let sql = "UPDATE reminders SET status=?, done_at=? WHERE id=? AND status='pending'"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    status.withCString { s in
        isoNow().withCString { n in
            sqlite3_bind_text(stmt, 1, s, -1, nil)
            sqlite3_bind_text(stmt, 2, n, -1, nil)
            sqlite3_bind_int(stmt, 3, rid)
            sqlite3_step(stmt)
        }
    }
}

// A borderless window won't accept key input unless it says it can.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// ---------------------------------------------------------------------------
// HoldBar — a slim rounded progress bar whose fill is driven by ONE Core
// Animation (scale.x 0→1) rather than a per-frame timer, so it is perfectly
// smooth. begin(duration:color:) starts the fill; cancel() snaps it to empty.
// ---------------------------------------------------------------------------
final class HoldBar: NSView {
    private let track = CALayer()
    private let fill  = CALayer()
    private let barHeight: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        track.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        fill.backgroundColor  = NSColor.white.withAlphaComponent(0.95).cgColor
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)   // grow from the left edge
        layer?.addSublayer(track)
        track.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let y = (bounds.height - barHeight) / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = CGRect(x: 0, y: y, width: bounds.width, height: barHeight)
        track.cornerRadius = barHeight / 2
        fill.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        fill.position = CGPoint(x: 0, y: track.bounds.midY)
        fill.cornerRadius = barHeight / 2
        fill.transform = CATransform3DMakeScale(0.0001, 1, 1)   // resting (empty)
        CATransaction.commit()
    }

    func begin(duration: CFTimeInterval, color: NSColor) {
        fill.removeAnimation(forKey: "fill")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.backgroundColor = color.cgColor
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "transform.scale.x")
        a.fromValue = 0.0
        a.toValue = 1.0
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        fill.add(a, forKey: "fill")
    }

    func cancel() {
        fill.removeAnimation(forKey: "fill")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.transform = CATransform3DMakeScale(0.0001, 1, 1)
        CATransaction.commit()
    }
}

// ---------------------------------------------------------------------------
// Controller — owns the windows, the countdown, and the two hold gestures.
// ---------------------------------------------------------------------------
enum HoldAction { case skip, done }

final class Controller: NSObject {
    private var windows: [NSWindow] = []
    private var countdownLabel: NSTextField?
    private let holdBar = HoldBar()
    private var holdStatus: NSTextField?
    private let totalSeconds: Int
    private let holdSeconds: Double
    private var countdownEnd: Date?
    private var countdownTimer: Timer?
    private var holdAction: HoldAction?
    private var holdTimer: Timer?
    private var keyMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var isDismissing = false

    private let skipColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 0.95)
    private let doneColor = NSColor(calibratedRed: 0.45, green: 0.9,  blue: 0.55, alpha: 0.95)

    init(seconds: Int, hold: Double) {
        self.totalSeconds = seconds
        self.holdSeconds = hold
    }

    private func mmss(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat = 1) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = NSColor.white.withAlphaComponent(alpha)
        l.alignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        l.maximumNumberOfLines = 0
        return l
    }

    private func makeContent(size: NSSize) -> NSView {
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        v.wantsLayer = true

        // Centre stack: message (+ subtext) (+ countdown).
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 28
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label(message, size: 76, weight: .bold))
        if let sub = subtext, !sub.isEmpty {
            stack.addArrangedSubview(label(sub, size: 26, weight: .regular, alpha: 0.85))
        }
        if totalSeconds > 0 {
            let cd = label(mmss(totalSeconds), size: 60, weight: .light, alpha: 0.95)
            cd.font = NSFont.monospacedDigitSystemFont(ofSize: 60, weight: .light)
            countdownLabel = cd
            stack.addArrangedSubview(cd)
        }
        v.addSubview(stack)

        // Bottom cluster: live hold status, the smooth bar, then the two hints.
        let status = label("", size: 20, weight: .medium, alpha: 0.95)
        status.isHidden = true
        holdStatus = status

        holdBar.translatesAutoresizingMaskIntoConstraints = false
        holdBar.isHidden = true

        let hintSkip = label("Hold ⌃ Control to skip", size: 17, weight: .regular, alpha: 0.55)
        let hintDone = label("Hold ⏎ Return to mark done", size: 17, weight: .regular, alpha: 0.55)

        let bottom = NSStackView(views: [status, holdBar, hintSkip, hintDone])
        bottom.orientation = .vertical
        bottom.alignment = .centerX
        bottom.spacing = 12
        bottom.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(bottom)

        let m = v.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: v.widthAnchor, multiplier: 0.85),
            holdBar.widthAnchor.constraint(equalToConstant: 360),
            holdBar.heightAnchor.constraint(equalToConstant: 12),
            bottom.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            bottom.bottomAnchor.constraint(equalTo: m.bottomAnchor, constant: -56),
        ])
        return v
    }

    func build() {
        let contentScreen = NSScreen.main ?? NSScreen.screens.first
        var contentWindow: NSWindow?
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame,
                                  styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = true
            w.backgroundColor = background
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.setFrame(screen.frame, display: true)
            w.hidesOnDeactivate = false
            if screen === contentScreen {
                w.contentView = makeContent(size: screen.frame.size)
                contentWindow = w
            }
            w.orderFrontRegardless()
            windows.append(w)
        }
        (contentWindow ?? windows.first)?.makeKeyAndOrderFront(nil)
    }

    func start() {
        if totalSeconds > 0 {
            countdownEnd = Date().addingTimeInterval(Double(totalSeconds))
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let s = self, let end = s.countdownEnd else { return }
                let left = Int(ceil(end.timeIntervalSinceNow))
                if left <= 0 { s.complete(.done); return }   // waited out the break → done
                s.countdownLabel?.stringValue = s.mmss(left)
            }
            if let t = countdownTimer { RunLoop.main.add(t, forMode: .common) }
        }
        // Control fires .flagsChanged (a modifier); Return fires .keyDown/.keyUp.
        // Swallow all ordinary keys so nothing leaks past the overlay.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] ev in
            self?.handle(ev)
            return nil
        }
        // Dismiss and exit when the machine sleeps or the screen locks so the
        // process doesn't accumulate invisibly in memory overnight. System/display
        // sleep arrives on the workspace centre; screen-lock is delivered as a
        // distributed notification ("com.apple.screenIsLocked"), not via NSWorkspace.
        let wsnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            wsnc.addObserver(forName: NSWorkspace.willSleepNotification,
                             object: nil, queue: .main) { [weak self] _ in self?.dismiss() })
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                            object: nil, queue: .main) { [weak self] _ in self?.dismiss() })
    }

    private func handle(_ ev: NSEvent) {
        switch ev.type {
        case .flagsChanged:
            let ctrl = ev.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
            if ctrl { beginHold(.skip) } else if holdAction == .skip { resetHold() }
        case .keyDown:
            if ev.keyCode == 36 { beginHold(.done) }   // Return/Enter
        case .keyUp:
            if ev.keyCode == 36, holdAction == .done { resetHold() }
        default:
            break
        }
    }

    private func beginHold(_ action: HoldAction) {
        guard holdAction == nil else { return }   // one gesture at a time
        holdAction = action
        holdStatus?.stringValue = action == .skip ? "Skipping…" : "Marking done…"
        holdStatus?.textColor = (action == .skip ? skipColor : doneColor)
        holdStatus?.isHidden = false
        holdBar.isHidden = false
        holdBar.begin(duration: holdSeconds, color: action == .skip ? skipColor : doneColor)
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdSeconds, repeats: false) { [weak self] _ in
            self?.complete(action)
        }
    }

    private func resetHold() {
        guard holdAction != nil else { return }
        holdAction = nil
        holdTimer?.invalidate(); holdTimer = nil
        holdBar.cancel()
        holdBar.isHidden = true
        holdStatus?.isHidden = true
    }

    private func complete(_ action: HoldAction) {
        switch action {
        case .skip: setReminderStatus("cancelled")
        case .done: setReminderStatus("done")
        }
        dismiss()
    }

    private func dismiss() {
        // Idempotent: sleep, lock, countdown-end, and the hold gestures can all
        // race to dismiss. Running the teardown twice would call
        // NSEvent.removeMonitor on an already-removed token (undefined behaviour).
        guard !isDismissing else { return }
        isDismissing = true
        countdownTimer?.invalidate()
        holdTimer?.invalidate()
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        let wsnc = NSWorkspace.shared.notificationCenter
        for tok in workspaceObservers { wsnc.removeObserver(tok) }
        workspaceObservers.removeAll()
        let dnc = DistributedNotificationCenter.default()
        for tok in distributedObservers { dnc.removeObserver(tok) }
        distributedObservers.removeAll()
        for w in windows { w.orderOut(nil) }
        NSApp.terminate(nil)
    }
}

// ---------------------------------------------------------------------------
// App wiring.
// ---------------------------------------------------------------------------
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: Controller
    init(_ c: Controller) { controller = c }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.presentationOptions = [
            .hideDock, .hideMenuBar,
            .disableProcessSwitching, .disableForceQuit,
            .disableSessionTermination, .disableHideApplication,
            .disableAppleMenu,
        ]
        NSApp.activate(ignoringOtherApps: true)
        controller.build()
        controller.start()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; still shows windows + takes key events
let controller = Controller(seconds: totalSeconds, hold: holdSeconds)
let delegate = AppDelegate(controller)
app.delegate = delegate
app.run()
