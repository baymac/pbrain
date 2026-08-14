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
// A "Snooze" button appears BOTH on the pre-roll WARNING panel (alongside "Skip")
// AND on the full kiosk overlay: it does NOT resolve the occurrence terminally — it
// pushes this same instance's due_at out by N minutes and clears fired_at, leaving
// it pending, so the poller re-fires it later. (Only shown when --id + --db are
// passed, since with no row to reschedule there is nothing to snooze.)
// The countdown is WALL-CLOCK, so locking the screen OR sleeping the Mac (the Touch
// ID / power button sleeps rather than locks) does not pause or cancel the break —
// stepping away genuinely spends the time. App Nap is disabled so the timer keeps
// firing behind a lock screen; across true system sleep the process is suspended and
// resumes on wake, where the fixed finish line is re-checked. So if the full break
// elapses while you're away it resolves DONE on its own (at wake / unlock); come
// back early and the overlay reappears showing the time that's ACTUALLY left, not
// where it stood when you stepped away. Walking away is a legitimate way to take the
// break, not an escape hatch from it.
// "MISSED" is NOT a full-overlay outcome: it is set only (a) by the poller, for an
// occurrence that was overdue past its grace window and never fired, and (b) if you
// sleep/lock during the short pre-roll WARNING, before the break UI ever appears.
// (The skip gesture is Control ALONE; Control+Command is left alone so the system
// ⌃⌘Q Lock-Screen shortcut still locks instead of being eaten as a skip.)
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
//                  [--warning-seconds 10]   # show a small non-kiosk warning panel first (default 10, 0 = skip)
//                  [--snooze-minutes 5]     # warning-panel "Snooze" button push-out (default 5, 0 = hide; needs --id/--db)
//                  [--chime <path>]         # override the lifecycle chime file (default: bundled Resources/chime.mp3)
//                  [--no-chime]             # mute the notif-start / blocking-start / blocking-end chimes
//                  [--id <instance_id>] [--db <path>]
//
// Build: `swiftc -suppress-warnings pbrain-overlay.swift`

import Cocoa
import QuartzCore
import SQLite3
import CoreGraphics

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
let warningSeconds = max(0, Int(argValue("--warning-seconds") ?? "10") ?? 10)
let snoozeMinutes  = max(0, Int(argValue("--snooze-minutes") ?? "5") ?? 5)   // 0 = no Snooze button

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
// Chime. A short audio cue fires at the three lifecycle moments of a blocking
// reminder: the pre-roll notification panel appearing (NOTIF START), the full
// kiosk overlay appearing (BLOCKING START), and the overlay clearing (BLOCKING
// END). The clip (Conductor's "closing doors" chime) ships with pbrain and is
// copied into this app bundle's Resources at build time, so Bundle.main resolves
// it regardless of the launchd/GUI session it fires from.
//
// Resolution order: --chime <path> (explicit override) → bundled Resources/chime.mp3
// → ~/.config/pbrain/chime.mp3 (the user install). --no-chime mutes it entirely.
// Gating from the shell happens by translating PBRAIN_OVERLAY_CHIME into these
// argv flags (env doesn't survive `open -n`, argv does).
//
// SILENT BY DESIGN (user decision): blocking reminders make NO sound at any
// lifecycle moment. playChime() is an unconditional no-op and the clip is no
// longer copied into the bundle. This is deliberately NOT an env/argv gate —
// a gate is opt-in per invocation, so a stale bundle, a launchd job installed
// before the gate existed, or any un-gated call path would still play audio.
// Killing it at the sink means no caller can resurrect it.
//
// --chime / --no-chime are still ACCEPTED and ignored, so old launchd plists
// and in-flight callers passing them don't break on an unknown-argument path.
// To bring sound back, restore the afplay body here AND re-add the chime copy
// in pbrain_overlay_build (lib/reminders.sh).
func playChime() {
    // Intentionally empty — see the note above.
}

// Authoritative lock-state poll. The lock/unlock distributed notifications are a
// fast path, but macOS can drop them (notably with Touch ID / Apple Watch unlock);
// a dropped screenIsUnlocked would strand the overlay with a frozen countdown. So
// we also ASK every tick — CGSessionCopyCurrentDictionary always reports the truth.
func screenIsCurrentlyLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (dict["CGSSessionScreenIsLocked"] as? Int) == 1
}

// ---------------------------------------------------------------------------
// SQLite write-back — set this occurrence's terminal status directly. No-op
// unless --id and --db were passed. The `AND status='pending'` guard makes it
// first-writer-wins: whichever of skip / countdown / sleep-lock fires first
// resolves the row, and the rest are inert.
// ---------------------------------------------------------------------------
func isoTime(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: date)
}
func isoNow() -> String { isoTime() }

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

// SNOOZE — push THIS occurrence's due_at out by `minutes` and clear fired_at,
// leaving status='pending' so the poller re-fires the same instance later. Unlike
// setReminderStatus this is NON-terminal: nothing is resolved, the row just moves
// forward in time. Guarded on status='pending' (so it can't revive a row another
// gesture already resolved) and reports whether a row actually moved — a false
// return (no --id/--db, DB error, or a UNIQUE(schedule_id,due_at) clash with an
// already-materialised next occurrence) lets the caller fall back to a plain skip.
func snoozeReminder(minutes: Int) -> Bool {
    guard canWrite, minutes > 0, let db = dbPath, let rid = reminderID else { return false }
    var conn: OpaquePointer?
    guard sqlite3_open(db, &conn) == SQLITE_OK else { return false }
    defer { sqlite3_close(conn) }
    let newDue = isoTime(Date().addingTimeInterval(Double(minutes) * 60))
    let sql = "UPDATE reminders SET due_at=?, fired_at=NULL, resolved_at=NULL WHERE id=? AND status='pending'"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(stmt) }
    var ok = false
    newDue.withCString { d in
        sqlite3_bind_text(stmt, 1, d, -1, nil)
        sqlite3_bind_int(stmt, 2, rid)
        if sqlite3_step(stmt) == SQLITE_DONE {
            ok = sqlite3_changes(conn) > 0
        }
    }
    return ok
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
// GlassButtonView — liquid-glass titled button. Used for the "Mark Done" action
// in --mark-done mode (an alternative to the Option-hold gesture) and for the
// "Snooze" action on the overlay. Uses NSVisualEffectView (withinWindow blending)
// for the frosted backdrop, a thin white border, and a pointer cursor on hover.
// ---------------------------------------------------------------------------
final class GlassButtonView: NSView {
    var action: (() -> Void)?
    private let tintLayer = CALayer()

    init(title: String) {
        super.init(frame: .zero)
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

        let lbl = NSTextField(labelWithString: title)
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
    private var blockingStarted = false   // gates the BLOCKING END chime to a block that actually began

    // Warning phase (shown before the full kiosk overlay)
    private let warningSeconds: Int
    private let snoozeMinutes: Int          // warning-panel "Snooze" push-out (0 = no button)
    private var warningWindow: NSWindow?
    private var warningCountdownLabel: NSTextField?
    private var warningTimer: Timer?
    private var warningEnd: Date?

    // Lock/unlock state — hide the overlay while locked, restore on unlock (the
    // break clock keeps running either way).
    private var isLocked = false
    private var lockPollTimer: Timer?       // polls real lock state every tick (notification-independent)
    private var activityToken: NSObjectProtocol?   // keeps App Nap off so timers fire while hidden

    private let skipColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 0.95)
    private let doneColor = NSColor(calibratedRed: 0.3,  green: 0.85, blue: 0.45, alpha: 0.95)

    init(seconds: Int, hold: Double, markDone: Bool, warning: Int, snooze: Int) {
        self.totalSeconds = seconds
        self.holdSeconds = hold
        self.markDone = markDone
        self.warningSeconds = warning
        self.snoozeMinutes = snooze
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

        // Snooze is offered on the overlay (not just the warning panel) whenever
        // there's an occurrence row to reschedule. A single click — snooze isn't an
        // escape, it just defers the same break by a few minutes.
        let showSnooze = canWrite && snoozeMinutes > 0
        var bottomViews: [NSView] = [status, holdBar]
        if markDone {
            let doneBtn = GlassButtonView(title: "Mark Done")
            doneBtn.action = { [weak self] in self?.resolve("done") }
            bottomViews.append(doneBtn)
            bottomViews.append(label("Hold ⌥ Option to mark done", size: 17, weight: .regular, alpha: 0.55))
        }
        if showSnooze {
            let snoozeBtn = GlassButtonView(title: "Snooze \(snoozeMinutes)m")
            snoozeBtn.action = { [weak self] in self?.snoozeFromOverlay() }
            bottomViews.append(snoozeBtn)
        }
        bottomViews.append(hintSkip)
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
        // BLOCKING START — the full kiosk overlay is now live. Reached from both the
        // warning→overlay transition and the no-warning direct path, exactly once.
        if !blockingStarted {
            blockingStarted = true
            playChime()
        }
        // Disable App Nap so the countdown / lock-poll timers keep firing while the
        // overlay is hidden behind a lock screen. We still ALLOW idle system sleep —
        // sleeping mid-break is fine: the process is suspended and resumes on wake,
        // where the fixed wall-clock finish line is re-checked (handleWake).
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "blocking break overlay")
        if totalSeconds > 0 {
            countdownEnd = Date().addingTimeInterval(Double(totalSeconds))
            startCountdownTimer()
        }
        // Control fires .flagsChanged (a modifier); Return fires .keyDown/.keyUp.
        // Swallow all ordinary keys so nothing leaks past the overlay.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] ev in
            self?.handle(ev)
            return nil
        }
        // Sleeping the Mac (e.g. the Touch ID / power button SLEEPS rather than
        // locks) does NOT cancel the break — the wall-clock countdown keeps its
        // finish line across sleep, so on wake it either resolves DONE (the break
        // elapsed while away) or shows the real time left. Screen lock is the same:
        // hide while locked, restore on unlock. Neither resolves "missed" — that's
        // only the poller's outcome for an occurrence that never fired at all.
        let wsnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            wsnc.addObserver(forName: NSWorkspace.didWakeNotification,
                             object: nil, queue: .main) { [weak self] _ in self?.handleWake() })
        // The lock/unlock notifications are the FAST path; pollLockState() is the
        // safety net for when macOS drops one. Both funnel through the same
        // idempotent handlers, so a double-fire is harmless.
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                            object: nil, queue: .main) { [weak self] _ in self?.handleLock() })
        distributedObservers.append(
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                            object: nil, queue: .main) { [weak self] _ in self?.handleUnlock() })
        // Always-on poll: catches a lock/unlock even if its notification never
        // arrives, for both countdown and mark-done modes.
        let pt = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollLockState()
        }
        RunLoop.main.add(pt, forMode: .common)
        lockPollTimer = pt
    }

    private func pollLockState() {
        guard !isDismissing else { return }
        let locked = screenIsCurrentlyLocked()
        if locked && !isLocked { handleLock() }
        else if !locked && isLocked { handleUnlock() }
    }

    // Woke from system sleep. The countdown was frozen while asleep but its finish
    // line is fixed wall-clock, so if the break elapsed during sleep, resolve DONE
    // immediately; otherwise re-sync lock state (wake usually lands on the login
    // screen) and let the live timer carry the remaining time. The repeating timers
    // resume on their own — this just makes the resolution instant instead of
    // waiting for the next tick.
    private func handleWake() {
        guard !isDismissing else { return }
        if totalSeconds > 0, let end = countdownEnd, end.timeIntervalSinceNow <= 0 {
            resolve("done"); return
        }
        pollLockState()
    }

    private func handle(_ ev: NSEvent) {
        // Modifier keys (Control, Option) arrive as .flagsChanged. Every other key
        // is swallowed (the monitor returns nil) so nothing leaks past the overlay.
        // Control = skip (always). Option = mark done (only in mark-done mode).
        // The two gestures are mutually exclusive: starting one cancels the other.
        if ev.type == .flagsChanged {
            let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Control ALONE = skip. Control+Command must NOT trigger skip, so the
            // system Lock-Screen shortcut (⌃⌘Q) can lock instead of being captured
            // as a skip-hold. Adding Command mid-hold cancels the skip (via the
            // !ctrl branch below) and the keystroke passes through to lock.
            let ctrl  = flags.contains(.control) && !flags.contains(.command)
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

    // Snooze from the live overlay: reschedule this occurrence forward and tear
    // down WITHOUT resolving it (it stays pending for the poller to re-fire). Same
    // reschedule the warning-panel button uses. If it didn't take (no DB row, or a
    // UNIQUE clash with an already-materialised next occurrence), fall back to a
    // skip so the screen still clears instead of hanging.
    private func snoozeFromOverlay() {
        if snoozeReminder(minutes: snoozeMinutes) {
            dismiss()
        } else {
            resolve("skipped")
        }
    }

    private func dismiss() {
        // Idempotent: sleep, lock, countdown-end, and the skip gesture can all
        // race to dismiss. Running the teardown twice would call
        // NSEvent.removeMonitor on an already-removed token (undefined behaviour).
        guard !isDismissing else { return }
        isDismissing = true
        // BLOCKING END — only when the full overlay actually ran. A skip/snooze/miss
        // during the warning phase never started a block, so it gets no end cue.
        if blockingStarted { playChime() }
        warningTimer?.invalidate(); warningTimer = nil
        warningWindow?.close(); warningWindow = nil
        countdownTimer?.invalidate()
        lockPollTimer?.invalidate(); lockPollTimer = nil
        holdTimer?.invalidate()
        doneHoldTimer?.invalidate()
        if let tok = activityToken { ProcessInfo.processInfo.endActivity(tok); activityToken = nil }
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

    // The countdown timer runs for the overlay's whole life — it is NEVER torn down
    // on lock. The countdown is pure WALL-CLOCK (driven by the fixed countdownEnd),
    // so it keeps elapsing while the screen is locked; App Nap is disabled so the
    // timer keeps firing behind the lock screen. If the break runs out while locked
    // it resolves DONE then and there; if the user unlocks first, the very next tick
    // shows the correctly-decremented time. Locking is taking the break, not pausing it.
    private func startCountdownTimer() {
        guard totalSeconds > 0, countdownTimer == nil else { return }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let s = self, let end = s.countdownEnd else { return }
            let left = Int(ceil(end.timeIntervalSinceNow))
            if left <= 0 { s.resolve("done"); return }
            s.countdownLabel?.stringValue = s.mmss(left)
        }
        if let t = countdownTimer { RunLoop.main.add(t, forMode: .common) }
    }

    // Hide windows on lock (don't resolve — the break clock keeps running behind the
    // lock screen; see startCountdownTimer). Cosmetic only: the lock screen already
    // covers everything, so this just avoids a flash on the unlock transition.
    private func handleLock() {
        guard !isLocked, !isDismissing else { return }
        isLocked = true
        for w in windows { w.orderOut(nil) }
    }

    // Restore windows after unlock. The countdown was never paused, so there's no
    // time to credit back and nothing to restart — the live timer already reflects
    // the real time remaining.
    private func handleUnlock() {
        guard isLocked, !isDismissing else { return }
        isLocked = false
        for w in windows { w.orderFrontRegardless() }
        (windows.first(where: { $0.contentView != nil }) ?? windows.first)?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Show a small non-kiosk warning panel before the full overlay fires.
    // On Skip → resolve("skipped"). On timer end → enterFullOverlay().
    func startWarning() {
        guard !isDismissing else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            enterFullOverlay(); return
        }
        playChime()   // NOTIF START — the pre-roll panel is appearing
        // Snooze sits next to Skip; only offered when there's a row to reschedule.
        let showSnooze = canWrite && snoozeMinutes > 0
        let ww: CGFloat = showSnooze ? 560 : 460, wh: CGFloat = 64
        let ox = screen.visibleFrame.maxX - ww - 24
        let oy = screen.visibleFrame.maxY - wh - 24
        let wnd = NSPanel(
            contentRect: NSRect(x: ox, y: oy, width: ww, height: wh),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        wnd.level = .statusBar
        wnd.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.90)
        wnd.isOpaque = false
        wnd.hasShadow = true
        wnd.collectionBehavior = [.canJoinAllSpaces, .stationary]
        wnd.alphaValue = 0.0

        let v = NSView(frame: NSRect(origin: .zero, size: CGSize(width: ww, height: wh)))
        v.wantsLayer = true

        let iconLbl = NSTextField(labelWithString: "⏱")
        iconLbl.font = NSFont.systemFont(ofSize: 18)
        iconLbl.textColor = .white
        iconLbl.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(iconLbl)

        let msgLbl = NSTextField(labelWithString: message)
        msgLbl.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        msgLbl.textColor = .white
        msgLbl.lineBreakMode = .byTruncatingTail
        msgLbl.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(msgLbl)

        let inLbl = NSTextField(labelWithString: "in")
        inLbl.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        inLbl.textColor = NSColor.white.withAlphaComponent(0.60)
        inLbl.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(inLbl)

        let cdLbl = NSTextField(labelWithString: mmss(warningSeconds))
        cdLbl.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        cdLbl.textColor = NSColor.white.withAlphaComponent(0.90)
        cdLbl.translatesAutoresizingMaskIntoConstraints = false
        warningCountdownLabel = cdLbl
        v.addSubview(cdLbl)

        let skipBtn = NSButton(title: "Skip", target: self, action: #selector(skipWarning))
        skipBtn.bezelStyle = .rounded
        skipBtn.font = NSFont.systemFont(ofSize: 13)
        skipBtn.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(skipBtn)

        NSLayoutConstraint.activate([
            iconLbl.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            iconLbl.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            msgLbl.leadingAnchor.constraint(equalTo: iconLbl.trailingAnchor, constant: 8),
            msgLbl.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            msgLbl.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            inLbl.leadingAnchor.constraint(equalTo: msgLbl.trailingAnchor, constant: 8),
            inLbl.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            cdLbl.leadingAnchor.constraint(equalTo: inLbl.trailingAnchor, constant: 6),
            cdLbl.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            skipBtn.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
            skipBtn.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])

        // Snooze button — sits just left of Skip, pushes this occurrence out N min.
        if showSnooze {
            let snoozeBtn = NSButton(title: "Snooze \(snoozeMinutes)m", target: self, action: #selector(snoozeWarning))
            snoozeBtn.bezelStyle = .rounded
            snoozeBtn.font = NSFont.systemFont(ofSize: 13)
            snoozeBtn.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(snoozeBtn)
            NSLayoutConstraint.activate([
                snoozeBtn.trailingAnchor.constraint(equalTo: skipBtn.leadingAnchor, constant: -8),
                snoozeBtn.centerYAnchor.constraint(equalTo: v.centerYAnchor),
                snoozeBtn.leadingAnchor.constraint(greaterThanOrEqualTo: cdLbl.trailingAnchor, constant: 12),
            ])
        }
        wnd.contentView = v

        wnd.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            wnd.animator().alphaValue = 1.0
        })
        warningWindow = wnd

        // During warning phase: sleep or lock → missed (full overlay never fired yet)
        let wsnc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            wsnc.addObserver(forName: NSWorkspace.willSleepNotification,
                             object: nil, queue: .main) { [weak self] _ in self?.resolve("missed") })
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(
            dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                            object: nil, queue: .main) { [weak self] _ in self?.resolve("missed") })

        warningEnd = Date().addingTimeInterval(Double(warningSeconds))
        warningTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let s = self, let end = s.warningEnd else { return }
            let left = Int(ceil(end.timeIntervalSinceNow))
            if left <= 0 {
                s.warningTimer?.invalidate(); s.warningTimer = nil
                s.enterFullOverlay()
                return
            }
            s.warningCountdownLabel?.stringValue = s.mmss(left)
        }
        if let t = warningTimer { RunLoop.main.add(t, forMode: .common) }
    }

    @objc private func skipWarning() { resolve("skipped") }

    // Warning-panel Snooze button (target/action needs @objc) — same behaviour as
    // the overlay's Snooze: reschedule forward and dismiss without resolving.
    @objc private func snoozeWarning() { snoozeFromOverlay() }

    // Transition from warning phase to full kiosk overlay.
    func enterFullOverlay() {
        guard !isDismissing else { return }
        // Clear warning-phase observers before registering full-overlay ones in start()
        let wsnc = NSWorkspace.shared.notificationCenter
        for tok in workspaceObservers { wsnc.removeObserver(tok) }
        workspaceObservers.removeAll()
        let dnc = DistributedNotificationCenter.default()
        for tok in distributedObservers { dnc.removeObserver(tok) }
        distributedObservers.removeAll()
        warningTimer?.invalidate(); warningTimer = nil
        warningWindow?.close(); warningWindow = nil
        NSApp.presentationOptions = [
            .hideDock, .hideMenuBar,
            .disableProcessSwitching, .disableForceQuit,
            .disableSessionTermination, .disableHideApplication,
            .disableAppleMenu,
        ]
        NSApp.activate(ignoringOtherApps: true)
        build()
        start()
    }
}

// ---------------------------------------------------------------------------
// App wiring.
// ---------------------------------------------------------------------------
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: Controller
    init(_ c: Controller) { controller = c }

    func applicationDidFinishLaunching(_ note: Notification) {
        if warningSeconds > 0 {
            controller.startWarning()
        } else {
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
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon; still shows windows + takes key events
let controller = Controller(seconds: totalSeconds, hold: holdSeconds, markDone: markDone, warning: warningSeconds, snooze: snoozeMinutes)
let delegate = AppDelegate(controller)
app.delegate = delegate
app.run()
