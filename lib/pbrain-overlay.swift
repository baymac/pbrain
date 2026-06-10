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
// RESOLVING THE OCCURRENCE
// ------------------------
// The overlay resolves the OCCURRENCE (instance row) it represents, so the user
// doesn't have to mark it off afterwards. The outcome is whichever of three
// things ends the overlay:
//   • Hold CONTROL   → SKIPPED (a deliberate hold, so it can't be hit by accident)
//   • Countdown ends → DONE    (you waited out the full break)
//   • Sleep / lock   → MISSED  (you never engaged with it; it self-dismisses)
// There is deliberately NO "mark done" gesture: `done` means only that the
// allotted time elapsed. The status write happens here via the SQLite3 C API,
// enabled by passing --id and --db. Every occurrence is its OWN row (the recurring
// series lives in reminder_schedules), so writing this row's outcome never
// touches the series — the tick has already scheduled the next occurrence.
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
//                  [--hold 3]               # seconds of hold required to act (skip AND done)
//                  [--background "#1e3a5f"] # solid bg colour (hex); default slate
//                  [--subtext "..."]        # optional smaller line under the message
//                  [--mark-done]            # enable Option-hold + "Mark Done" button (no countdown)
//                  [--id <instance_id>] [--db <path>]
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
let holdSeconds  = max(0.5, Double(argValue("--hold") ?? "3") ?? 3.0)
let markDone     = CommandLine.arguments.contains("--mark-done")

let reminderID: Int32?   = argValue("--id").flatMap { Int32($0) }
let dbPath: String?      = { let p = argValue("--db"); return (p?.isEmpty == false) ? p : nil }()
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
// SQLite write-back — set this occurrence's terminal status directly. No-op
// unless --id and --db were passed. The `AND status='pending'` guard makes it
// first-writer-wins: whichever of skip / countdown / sleep-lock fires first
// resolves the row, and the rest are inert.
// ---------------------------------------------------------------------------
func isoNow() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date())
}

func setReminderStatus(_ status: String) {
    guard canWrite, let db = dbPath, let rid = reminderID else { return }
    var conn: OpaquePointer?
    guard sqlite3_open(db, &conn) == SQLITE_OK else { return }
    defer { sqlite3_close(conn) }
    let sql = "UPDATE reminders SET status=?, resolved_at=? WHERE id=? AND status='pending'"
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
// DoneButtonView — liquid-glass "Mark Done" button shown in --mark-done mode
// as an alternative to the Option-hold gesture. Uses NSVisualEffectView
// (withinWindow blending) for the frosted backdrop, a thin white border, and
// a pointer cursor on hover.
// ---------------------------------------------------------------------------
final class DoneButtonView: NSView {
    var action: (() -> Void)?
    private let tintLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.40).cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        // Frosted-glass backdrop — blurs the overlay background behind the button
        let vfx = NSVisualEffectView()
        vfx.material = .hudWindow
        vfx.blendingMode = .withinWindow
        vfx.state = .active
        vfx.appearance = NSAppearance(named: .darkAqua)
        vfx.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vfx)

        // White tint over the blur; brightens slightly on hover
        tintLayer.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.addSublayer(tintLayer)

        let lbl = NSTextField(labelWithString: "Mark Done")
        lbl.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        lbl.textColor = .white
        lbl.alignment = .center
        lbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lbl)

        NSLayoutConstraint.activate([
            vfx.leadingAnchor.constraint(equalTo: leadingAnchor),
            vfx.trailingAnchor.constraint(equalTo: trailingAnchor),
            vfx.topAnchor.constraint(equalTo: topAnchor),
            vfx.bottomAnchor.constraint(equalTo: bottomAnchor),
            lbl.centerXAnchor.constraint(equalTo: centerXAnchor),
            lbl.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 48),
            widthAnchor.constraint(equalToConstant: 180),
        ])

        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        CATransaction.commit()
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) {
        tintLayer.backgroundColor = NSColor.white.withAlphaComponent(0.20).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        tintLayer.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
    }
    override func mouseDown(with event: NSEvent) { action?() }
}

// ---------------------------------------------------------------------------
// Controller — owns the windows, the countdown, and the hold gestures.
//
// Two modes:
//   mark-done  (--mark-done flag): Option-hold or "Mark Done" button → done,
//              Control-hold → skip. No countdown; stays until a gesture/button.
//   duration   (default):          countdown elapses → done, Control-hold → skip.
//              The only path to "done" is waiting out the timer.
// ---------------------------------------------------------------------------
final class Controller: NSObject {
    private var windows: [NSWindow] = []
    private var countdownLabel: NSTextField?
    private let holdBar = HoldBar()
    private var holdStatus: NSTextField?
    private let totalSeconds: Int
    private let holdSeconds: Double
    private let markDone: Bool
    private var countdownEnd: Date?
    private var countdownTimer: Timer?
    private var holding = false
    private var holdTimer: Timer?
    private var holdingDone = false
    private var doneHoldTimer: Timer?
    private var keyMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var isDismissing = false

    private let skipColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 0.95)
    private let doneColor = NSColor(calibratedRed: 0.3,  green: 0.85, blue: 0.45, alpha: 0.95)

    init(seconds: Int, hold: Double, markDone: Bool) {
        self.totalSeconds = seconds
        self.holdSeconds = hold
        self.markDone = markDone
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

        let bottomViews: [NSView]
        if markDone {
            let doneBtn = DoneButtonView()
            doneBtn.action = { [weak self] in self?.resolve("done") }
            let hintDone = label("Hold ⌥ Option to mark done", size: 17, weight: .regular, alpha: 0.55)
            bottomViews = [status, holdBar, doneBtn, hintDone, hintSkip]
        } else {
            bottomViews = [status, holdBar, hintSkip]
        }
        let bottom = NSStackView(views: bottomViews)
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
                if left <= 0 { s.resolve("done"); return }   // waited out the break → done
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
                             object: nil, queue: .main) { [weak self] _ in self?.resolve("missed") })
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                            object: nil, queue: .main) { [weak self] _ in self?.resolve("missed") })
        // Re-grab focus after an unlock so keyboard shortcuts work without
        // requiring a click first. The overlay window is at maximumWindow level
        // but the OS returns key-app status to Finder (or the previous app) after
        // unlocking, which breaks the local key monitor.
        distributedObservers.append(
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                            object: nil, queue: .main) { [weak self] _ in
                NSApp.activate(ignoringOtherApps: true)
                self?.windows.forEach { $0.makeKeyAndOrderFront(nil) }
            })
    }

    private func handle(_ ev: NSEvent) {
        // Modifier keys (Control, Option) arrive as .flagsChanged. Every other key
        // is swallowed (the monitor returns nil) so nothing leaks past the overlay.
        // Control = skip (always). Option = mark done (only in mark-done mode).
        // The two gestures are mutually exclusive: starting one cancels the other.
        if ev.type == .flagsChanged {
            let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let ctrl  = flags.contains(.control)
            let opt   = flags.contains(.option) && markDone

            if ctrl && !holding {
                if holdingDone { resetDoneHold() }
                beginHold()
            } else if !ctrl && holding {
                resetHold()
            }

            if opt && !holdingDone {
                if holding { resetHold() }
                beginDoneHold()
            } else if !opt && holdingDone {
                resetDoneHold()
            }
        }
    }

    private func beginHold() {
        guard !holding else { return }
        holding = true
        holdStatus?.stringValue = "Skipping…"
        holdStatus?.textColor = skipColor
        holdStatus?.isHidden = false
        holdBar.isHidden = false
        holdBar.begin(duration: holdSeconds, color: skipColor)
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdSeconds, repeats: false) { [weak self] _ in
            self?.resolve("skipped")
        }
    }

    private func resetHold() {
        guard holding else { return }
        holding = false
        holdTimer?.invalidate(); holdTimer = nil
        holdBar.cancel()
        holdBar.isHidden = true
        holdStatus?.isHidden = true
    }

    private func beginDoneHold() {
        guard !holdingDone else { return }
        holdingDone = true
        holdStatus?.stringValue = "Marking done…"
        holdStatus?.textColor = doneColor
        holdStatus?.isHidden = false
        holdBar.isHidden = false
        holdBar.begin(duration: holdSeconds, color: doneColor)
        doneHoldTimer = Timer.scheduledTimer(withTimeInterval: holdSeconds, repeats: false) { [weak self] _ in
            self?.resolve("done")
        }
    }

    private func resetDoneHold() {
        guard holdingDone else { return }
        holdingDone = false
        doneHoldTimer?.invalidate(); doneHoldTimer = nil
        holdBar.cancel()
        holdBar.isHidden = true
        holdStatus?.isHidden = true
    }

    // Write the occurrence's outcome, then tear down. setReminderStatus is
    // first-writer-wins (guarded on status='pending'), so the earliest of
    // skip / countdown / sleep-lock decides and later calls are inert.
    private func resolve(_ status: String) {
        setReminderStatus(status)
        dismiss()
    }

    private func dismiss() {
        // Idempotent: sleep, lock, countdown-end, and the skip gesture can all
        // race to dismiss. Running the teardown twice would call
        // NSEvent.removeMonitor on an already-removed token (undefined behaviour).
        guard !isDismissing else { return }
        isDismissing = true
        countdownTimer?.invalidate()
        holdTimer?.invalidate()
        doneHoldTimer?.invalidate()
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
let controller = Controller(seconds: totalSeconds, hold: holdSeconds, markDone: markDone)
let delegate = AppDelegate(controller)
app.delegate = delegate
app.run()
