//
//  CanvasManager.swift
//  MacStroke
//
//  Manages the gesture drawing canvas - collects mouse events into strokes,
//  decides whether a right-click should start a gesture (filters), replays
//  right-click events when no gesture matched, and forwards right-clicks to
//  apps that need their native context menu (RightClicksList).
//
//  This is the Swift counterpart of the original's
//  AppDelegate.mouseEventCallback + CanvasWindowController.
//

import Foundation
import AppKit
import GestureEngine

/// Delegate for CanvasManager to notify when a stroke is complete.
public protocol CanvasManagerDelegate: AnyObject {
    /// Called when a gesture stroke is completed and ready for recognition.
    /// - Parameters:
    ///   - manager: The canvas manager
    ///   - stroke: The completed stroke (ready for comparison)
    ///   - bundleID: The bundle ID of the frontmost application (for filtering)
    ///   - Returns: true if a rule matched and the action was handled
    ///             (the right-click is consumed); false if nothing matched
    ///             (the manager will replay the right-click).
    @discardableResult
    func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String) -> Bool
}

/// Manages the gesture drawing canvas.
///
/// Event flow (mirrors the original, with the trigger button widened to
/// middle/side/extra buttons when the user enables them):
/// 1. Trigger-mouse-down → check the button is an allowed trigger and no
///    suppressing modifier is held, then the filters (black/white list, "show UI
///    in any app", app has a suited rule). If allowed, begin capture, show the
///    canvas.
/// 2. Same-button mouse-dragged → record points, draw on canvas.
/// 3. Same-button mouse-up → try rule matching via the delegate. If nothing
///    matched:
///    - Right button, app in RightClicksList, no drag: synthesize a
///      Ctrl+left-click so the app shows its native context menu.
///    - Otherwise replay that button's down/up events so the app sees the click.
public class CanvasManager: EventCaptureDelegate {

    public weak var delegate: CanvasManagerDelegate?

    /// App-layer filter deciding whether a gesture may start in the given app.
    /// Set by the application to combine BlackWhiteFilter, "show UI in any app"
    /// and "app has a suited rule" checks (mirrors the original's
    /// `!shouldHookMouseEventForApp(frontBundle) || !(showUIInWhateverApp || appSuitedRule)` gate).
    public var shouldCaptureGesture: ((String) -> Bool)?

    /// Whether the given app should get its native right-click menu forwarded
    /// when a click (no drag) doesn't match any gesture (RightClicksList check).
    public var needsRightClickMenu: ((String) -> Bool)?

    /// Whether a gesture may start from the given mouse button.
    ///
    /// The original only ever watched the right button. The port has one
    /// configurable trigger button (issue #53) and asks the app layer per
    /// event, so changing it in the preferences applies without restarting or
    /// rebuilding the event tap. Unset means right-button-only, which is
    /// exactly the original's behaviour and also the shipped default.
    public var isTriggerButtonAllowed: ((MouseButton) -> Bool)?

    /// The modifier keys that must not start a gesture (issue #59). Asked per
    /// event, like the trigger-button check, so the preferences apply at once.
    /// Unset or empty means modifiers never interfere — the original's
    /// behaviour, since it never looked at the flags a click arrived with.
    public var suppressedModifiers: (() -> Set<GestureModifier>)?

    /// Whether an unmatched **drawn** gesture should be swallowed instead of
    /// handed back to the front app (issue #73). Asked per event, like the two
    /// closures above, so the preference applies without a restart.
    ///
    /// Unset means "hand it back" — the original's behaviour: it always replayed
    /// the click, so a gesture that failed to match still opened the context
    /// menu. Only strokes that look like a deliberate drawing are affected; a
    /// plain right click is never swallowed, or the menu would vanish for
    /// everyone who turns this on. See `handleTriggerMouseUp`.
    public var shouldSwallowUnmatchedGesture: (() -> Bool)?

    /// Where synthetic mouse/key events are delivered. Production leaves this
    /// nil, which posts at the tap location the call site asks for (session for
    /// replays, mixed for the JetBrains synthetic). Tests install a sink to
    /// count what the front app would have received — without it this whole
    /// branch can only be verified by moving the real pointer.
    var syntheticEventSink: ((CGEvent, CGEventTapLocation) -> Void)?

    /// Runs a matched impulse gesture and reports whether it was handled.
    /// The app layer owns this: it looks the gesture up in the rule store and
    /// executes the action, so RuleEngine stays out of EventCapture. Unset
    /// means no impulse rule can match, which leaves the plain wheel/click
    /// behaviour of the trigger button untouched.
    public var impulseHandler: ((ImpulseGesture, String) -> Bool)?

    /// Ignore gesture starts for a moment, while preferences are waiting for
    /// the user to press the button they want to bind. Deliberately separate
    /// from `isEnabled`, which is the master switch the preferences own.
    public var isSuspended = false

    /// Master enable switch (mirrors the original's static `isEnabled`).
    public var isEnabled = true

    /// When true, the next completed gesture is recorded via
    /// `onGestureRecorded` instead of being matched against rules
    /// (the "Draw Gesture" rule-editing flow).
    public var isRecordingGesture = false {
        didSet {
            // CanvasView reads this through UserDefaults: the overlay lives in
            // EventCapture, and prefs writes go through the same channel the
            // view already uses for its other knobs.
            UserDefaults.standard.set(self.isRecordingGesture, forKey: "macStrokeRecordingGesture")
            for window in canvasWindows.values {
                window.canvasView.needsDisplay = true
            }
        }
    }

    /// Called with the recorded gesture points when `isRecordingGesture`
    /// completes. The receiver stores them into the pending rule.
    public var onGestureRecorded: (([GesturePoint]) -> Void)?

    /// Points below this count are treated as a simple click, not a gesture
    /// (the original's DTW comparison requires at least 10 points).
    private let minimumPointsForGesture = 10

    // MARK: - Gesture state

    private var currentPoints: [GesturePoint] = []
    /// Previous drag point, used for the Synergy teleport check.
    private var lastDragPoint: GesturePoint?
    private var isCapturing = false
    private var hasDragged = false
    /// The button that started the current gesture; drags and the matching up
    /// are only accepted for this one.
    private var activeTrigger: MouseButton?
    /// The location (AppKit global coords) where the current gesture started.
    private var downLocation: GesturePoint?
    /// Whether the front app passed the capture filter for the current gesture.
    private var shouldShow = false
    /// App that was frontmost when the trigger went down. Keep using it for
    /// every impulse during this press: showing our transparent canvas can
    /// change NSWorkspace.frontmostApplication, and re-reading it would make
    /// the second wheel notch target MacStroke itself instead of the user app.
    private var capturedBundleID: String?
    /// True once an impulse fired during this trigger press. The press then
    /// belongs to the scroll/click, not the gesture, so releasing the trigger
    /// must not replay it (a synthetic right-click would pop the context menu
    /// on top of the scroll the user just performed).
    private var didFireImpulse = false
    /// CG button numbers whose impulse click-down was consumed, so the matching
    /// up is consumed too instead of reaching the front app as a stray click.
    private var consumedImpulseButtons: Set<Int> = []
    /// Sub-line wheel movement carried between events. A discrete wheel always
    /// moves in whole detents, but a high-resolution wheel reports pixels, so
    /// accumulating them is what keeps "one line = one action" true. Only the
    /// vertical axis accumulates: tilt input has no gesture and passes through.
    private var wheelAccumulatorY: Double = 0

    // MARK: - Canvas windows

    /// The canvas overlay window shown during gesture drawing.
    /// Keyed by screen identifier for multi-screen support.
    private var canvasWindows: [String: CanvasWindow] = [:]

    /// Create a new canvas manager.
    public init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Update canvas window frames when screen layout changes (e.g. display added/removed/resized).
    @objc private func screenParametersDidChange() {
        for (_, window) in canvasWindows {
            let newFrame = window.screen?.frame ?? NSScreen.main?.frame ?? .zero
            if window.frame != newFrame {
                window.setFrame(newFrame, display: false)
                window.canvasView.resize(to: newFrame)
            }
        }
    }

    // MARK: - EventCaptureDelegate

    /// Handle a mouse event from EventCapture.
    /// - Returns: true to consume (swallow) the event; false to pass it through.
    @discardableResult
    public func eventCapture(_ capture: EventCapture, didReceive event: MouseEvent) -> Bool {
        switch event.phase {
        case .down:
            // A momentary click on any non-trigger button counts as an impulse
            // while the gesture trigger is held. Outside that window these
            // buttons keep their native behaviour (left click, middle-click
            // paste, back/forward). The trigger button itself must never become
            // an impulse — the Rules page offers "Left/Right Button" gestures
            // for the *other* buttons only.
            if isTriggerAllowed(event.button) {
                return handleTriggerMouseDown(event)
            }
            if handleImpulseClickDown(event) { return true }
            switch event.button {
            case .left:
                // Original AppDelegate.m:431-438 — while a gesture is in
                // progress, left clicks are swallowed to avoid mis-fires.
                return shouldShow && isCapturing
            default:
                return false
            }

        case .moved:
            guard shouldShow, isCapturing, event.button == activeTrigger else { return false }
            // Original AppDelegate.m:332-357 — Synergy hands the pointer to
            // another machine: the point teleports from a screen edge to the
            // screen center. Treat that as gesture cancellation.
            if isSynergyJump(from: lastDragPoint, to: event.point) {
                resetGestureState()
                return true
            }
            hasDragged = true
            lastDragPoint = event.point
            currentPoints.append(event.point)
            addPointToCanvas(event.point)
            return true

        case .up:
            if isCapturing, consumedImpulseButtons.remove(event.button.cgNumber) != nil {
                return true
            }
            guard shouldShow, isCapturing, event.button == activeTrigger else { return false }
            return handleTriggerMouseUp(event)
        }
    }

    /// Handle a scroll-wheel event. The trigger button being held is what turns
    /// a wheel notch into an impulse; otherwise scrolling is untouched.
    /// - Returns: true to consume (swallow) the scroll event.
    @discardableResult
    public func eventCapture(_ capture: EventCapture, didReceiveScroll event: ScrollEvent) -> Bool {
        guard isEnabled, !isSuspended, isCapturing, !isRecordingGesture else { return false }
        // Momentum is the OS replaying a flick after the fingers stopped; it
        // must not fire further impulses, and it must not be swallowed either.
        guard !event.isMomentum else { return false }
        return consumeWheel(event)
    }

    // MARK: - Impulse gestures

    /// Fire the impulse a non-trigger button press stands for (left, right,
    /// middle, side).
    ///
    /// Only the momentum of the press matters here: the matching up is claimed
    /// too (via `consumedImpulseButtons`) so the front app sees neither half of
    /// a click the user aimed at MacStroke.
    /// - Returns: true when an impulse rule handled the press and both halves
    ///   of the click must be swallowed.
    private func handleImpulseClickDown(_ event: MouseEvent) -> Bool {
        guard isEnabled, !isSuspended, isCapturing, !isRecordingGesture else { return false }
        let number = event.button.cgNumber

        let gesture: ImpulseGesture
        switch number {
        case 0: gesture = .leftClick
        case 1: gesture = .rightClick
        case 2: gesture = .middleClick
        case 3: gesture = .button4
        case 4: gesture = .button5
        default: return false
        }
        guard let handled = runImpulse(gesture), handled else { return false }
        consumedImpulseButtons.insert(number)
        return true
    }

    /// Accumulate wheel deltas and fire one impulse per whole line.
    ///
    /// A discrete wheel reports whole detents, so each event crosses the
    /// threshold exactly once. A high-resolution wheel trickles in fractions of
    /// a line: the remainder is kept, and crossing a line fires exactly one
    /// action no matter how the OS split the movement.
    /// - Returns: true to consume the scroll event.
    private func consumeWheel(_ event: ScrollEvent) -> Bool {
        // Shared with the recorder: macOS swaps and flips Shift+vertical
        // scroll, and a tilt-only input has no gesture to fire.
        let delta = WheelDelta(
            x: event.deltaX,
            y: event.deltaY,
            shifted: event.modifiers.contains(.shift)
        )
        let physical = delta.physical
        guard abs(physical.y) > 0, abs(physical.y) >= abs(physical.x) else {
            return false
        }

        var accumulator = wheelAccumulatorY
        accumulator += physical.y
        let steps = accumulator.rounded(.towardZero)
        wheelAccumulatorY = accumulator - steps

        guard abs(steps) >= 1 else { return false }
        // Positive physical delta = rolled toward the user (down).
        let gesture: ImpulseGesture = steps > 0 ? .wheelDown : .wheelUp
        guard let handled = runImpulse(gesture), handled else {
            // Nothing matched: hand the movement back rather than eating it,
            // but drop the accumulation so the front app gets the raw event.
            wheelAccumulatorY = 0
            return false
        }
        return true
    }

    /// Ask the app layer to run the impulse for the front app.
    private func runImpulse(_ gesture: ImpulseGesture) -> Bool? {
        guard let impulseHandler else { return nil }
        let bundleID = capturedBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard impulseHandler(gesture, bundleID) else { return nil }
        didFireImpulse = true
        return true
    }

    /// Whether the given button may start a gesture. The app layer owns the
    /// single configured trigger button; without its answer nothing is allowed,
    /// which leaves the right button as the only trigger.
    private func isTriggerAllowed(_ button: MouseButton) -> Bool {
        guard let isTriggerButtonAllowed else { return button == .right }
        return isTriggerButtonAllowed(button)
    }

    /// Whether any modifier that must suppress gestures is currently held.
    /// Holding one of several configured modifiers is enough — the request was
    /// for "certain modifiers, or combinations of them", and a combination
    /// always includes at least one single modifier.
    private func isSuppressedByModifiers(_ modifiers: Set<GestureModifier>) -> Bool {
        guard let suppressed = suppressedModifiers else { return false }
        return !suppressed().isDisjoint(with: modifiers)
    }

    // MARK: - Gesture trigger handling

    private func handleTriggerMouseDown(_ event: MouseEvent) -> Bool {
        guard isEnabled, !isSuspended else {
            shouldShow = false
            return false
        }

        // A suppressed modifier held at mouse-down hands the whole click-drag
        // back to the front app untouched (issue #59). Only the down phase is
        // checked: pressing a modifier mid-stroke stays as it always was.
        if isSuppressedByModifiers(event.modifiers) {
            shouldShow = false
            return false
        }

        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        // Filter gate: black/white list + "show UI in whatever app" / suited rule.
        if let shouldCapture = shouldCaptureGesture, !shouldCapture(frontBundle) {
            shouldShow = false
            return false
        }

        shouldShow = true

        // If a previous gesture was interrupted (down without up, e.g. the tap
        // was disabled by timeout), finish it off so the app sees its click.
        if isCapturing {
            finishInterruptedGesture()
        }

        currentPoints = [event.point]
        lastDragPoint = event.point
        downLocation = event.point
        hasDragged = false
        isCapturing = true
        activeTrigger = event.button

        showCanvasWindow(for: event.point)
        addPointToCanvas(event.point)

        return true
    }

    private func handleTriggerMouseUp(_ event: MouseEvent) -> Bool {
        currentPoints.append(event.point)
        addPointToCanvas(event.point)

        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let consumed: Bool

        // Rule-recording mode ("Draw Gesture" from preferences).
        if isRecordingGesture {
            isRecordingGesture = false
            onGestureRecorded?(currentPoints)
            consumed = true
        } else if currentPoints.count >= minimumPointsForGesture,
                  let stroke = completedStroke(),
                  let delegate = delegate,
                  delegate.canvasManager(self, didCompleteStroke: stroke, bundleID: frontBundle) {
            // A rule matched and its action was executed.
            consumed = true
        } else if shouldSwallowUnmatchedGesture?() == true, drewADeliberateStroke {
            // 用户随手画一条不存在的轨迹来「取消」这次手势（issue #73）。这时候把右键
            // 交回前台应用，就是凭空弹出他刚刚明确不想要的那个菜单 —— 什么都不投，
            // 整段吞掉。判据只看「这一下是不是真的画了一条」：纯单击仍走下面的回放。
            NSLog("%@", "[CanvasManager] Unmatched gesture swallowed (no click replay)")
            consumed = true
        } else if didFireImpulse {
            // The press was consumed as an impulse (scrolling or a momentary
            // click), so the trigger button itself was never meant to click.
            // Replaying it now would pop a context menu on top of the scroll
            // the user just performed — regardless of whether a partial drag
            // happened to accompany the scrolling.
            NSLog("%@", "[CanvasManager] Trigger press belonged to an impulse (no click replay)")
            consumed = true
        } else {
            // No gesture matched: give the click back to the app so the button
            // still does whatever it normally does.
            let trigger = activeTrigger ?? .right
            if trigger == .right,
               let needsRightClickMenu = needsRightClickMenu,
               needsRightClickMenu(frontBundle), !hasDragged {
                // Apps like JetBrains IDEs: synthesize Ctrl+left-click so the
                // native context menu appears (original: threadRightClick).
                // Only meaningful for the right button — that is the click
                // whose job is opening a context menu.
                if let down = downLocation {
                    performSyntheticRightClick(at: down)
                }
            } else if let down = downLocation {
                // Replay the trigger button's down + up so the app sees the click.
                replayClick(button: trigger, down: down, up: event.point)
            }
            consumed = true
        }

        resetGestureState()
        return consumed
    }

    /// 这一下是不是「真的画了一条」：拖过、而且点数够 DTW 起步（不足 10 点在原版语义里
    /// 就是单击）。只有够格的轨迹才可能被吞 —— 用户抱怨的是「画一个不存在的手势来取消」，
    /// 不是「右键不能弹菜单」。必须在 `resetGestureState()` 之前问，之后这两样都被清了。
    private var drewADeliberateStroke: Bool {
        hasDragged && currentPoints.count >= minimumPointsForGesture
    }

    /// Build the completed stroke from the recorded points.
    private func completedStroke() -> Stroke? {
        guard currentPoints.count >= 2 else { return nil }
        var stroke = Stroke(capacity: currentPoints.count)
        for p in currentPoints {
            stroke.addPoint(p)
        }
        return stroke
    }

    /// Reset gesture state and clear the drawn path right away.
    ///
    /// The original does the same: `reinitWindow` (AppDelegate.m:392) swaps in a
    /// fresh empty CanvasView synchronously at the end of the mouseUp branch, so
    /// the path never outlives the release. Lingering it for 300ms makes every
    /// gesture look like the action arrived half a beat late (issue #68).
    private func resetGestureState() {
        currentPoints = []
        lastDragPoint = nil
        isCapturing = false
        hasDragged = false
        activeTrigger = nil
        downLocation = nil
        shouldShow = false
        capturedBundleID = nil
        didFireImpulse = false
        consumedImpulseButtons.removeAll()
        wheelAccumulatorY = 0

        hideAllCanvasWindows()
    }

    /// Original AppDelegate.m:332-357 — previous drag point near a primary
    /// screen edge and the new point near the screen center means Synergy
    /// teleported the pointer to another machine.
    private func isSynergyJump(from previous: GesturePoint?, to current: GesturePoint) -> Bool {
        guard let previous, let screen = NSScreen.main else { return false }
        let f = screen.frame
        let threshold: Double = 30
        let nearEdge = abs(previous.x - f.minX) < threshold
            || abs(previous.x - f.maxX) < threshold
            || abs(previous.y - f.minY) < threshold
            || abs(previous.y - f.maxY) < threshold
        let nearCenter = abs(current.x - (f.minX + f.width / 2)) < threshold
            && abs(current.y - (f.minY + f.height / 2)) < threshold
        return nearEdge && nearCenter
    }

    /// Replay the pending down + a synthetic up for an interrupted gesture.
    private func finishInterruptedGesture() {
        if let down = downLocation {
            replayClick(
                button: activeTrigger ?? .right,
                down: down,
                up: currentPoints.last ?? down
            )
        }
        resetGestureState()
    }

    // MARK: - Event replay / synthesis

    /// Replay a down/up pair for the button that started the gesture, so the
    /// frontmost application receives the click normally (a middle click still
    /// opens links, a side click still navigates back).
    private func replayClick(button: MouseButton, down: GesturePoint, up: GesturePoint) {
        let number = button.cgNumber
        postSyntheticMouseEvent(number: number, pressed: true, at: down)
        postSyntheticMouseEvent(number: number, pressed: false, at: up)
    }

    private func postSyntheticMouseEvent(number: Int, pressed: Bool, at point: GesturePoint) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch number {
        case 0:
            type = pressed ? .leftMouseDown : .leftMouseUp
            cgButton = .left
        case 1:
            type = pressed ? .rightMouseDown : .rightMouseUp
            cgButton = .right
        default:
            // Every non-left/right button, and the real number is written into
            // the payload below (CG only names left/right/center).
            type = pressed ? .otherMouseDown : .otherMouseUp
            cgButton = .center
        }

        // Convert back from AppKit (bottom-left) to CG (top-left) global coords.
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: cgPoint,
            mouseButton: cgButton
        ) else { return }
        if number >= 2 {
            // `otherMouse*` covers every non-left/right button, so the payload
            // has to carry which one this actually was.
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
        }
        // Original: CGEventPost(kCGSessionEventTap, …) — session level is
        // downstream of our HID tap, so the replay is not re-captured
        // (posting at HID would loop: capture → replay → capture …).
        deliver(event, at: .cgSessionEventTap)
    }

    /// 把合成事件投出去。生产环境没有 sink，就是原来的 `post(tap:)`；单测挂上 sink
    /// 才能数出「前台应用到底收到了几发」——否则这条判定只能靠动真鼠标取证。
    private func deliver(_ event: CGEvent, at location: CGEventTapLocation) {
        if let syntheticEventSink = syntheticEventSink {
            syntheticEventSink(event, location)
        } else {
            event.post(tap: location)
        }
    }

    /// Synthesize Ctrl+left-click at the given point on a background thread,
    /// mirroring the original's `threadRightClick:` (used for apps whose
    /// context menus need a synthetic click, e.g. JetBrains IDEs).
    private func performSyntheticRightClick(at point: GesturePoint) {
        let primaryHeight = Double(NSScreen.screens.first?.frame.height ?? 0)
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)

        Thread.detachNewThread { [weak self] in
            // Original taps: control keys at session, left clicks at HID.
            guard let self else { return }
            let controlDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x3B, keyDown: true)
            if let controlDown { self.deliver(controlDown, at: .cgSessionEventTap) }
            usleep(25_000) // improve reliability (matches original)

            let leftDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            )
            if let leftDown { self.deliver(leftDown, at: .cghidEventTap) }
            usleep(15_000) // improve reliability (matches original)

            let leftUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left
            )
            if let leftUp { self.deliver(leftUp, at: .cghidEventTap) }

            let controlUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x3B, keyDown: false)
            if let controlUp { self.deliver(controlUp, at: .cgSessionEventTap) }
        }
    }

    // MARK: - Public helpers

    /// Cancel the current stroke without notifying the delegate.
    public func cancelStroke() {
        resetGestureState()
        hideAllCanvasWindows()
    }

    /// Whether currently capturing a gesture.
    public var capturing: Bool { isCapturing }

    // MARK: - Canvas Window Management

    /// Adds a point to all visible canvas windows for visual feedback.
    private func addPointToCanvas(_ point: GesturePoint) {
        for window in canvasWindows.values {
            let viewPoint = convertPointToView(point, for: window)
            window.canvasView.addPoint(viewPoint)
        }
    }

    /// Shows a canvas window covering the screen that contains the given point.
    private func showCanvasWindow(for point: GesturePoint) {
        hideAllCanvasWindows()

        let screen = screenContainingPoint(point)
        let screenKey = String(describing: screen.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber ?? NSNumber(value: 0))
        let screenFrame = screen.frame

        let window: CanvasWindow
        if let existing = canvasWindows[screenKey] {
            existing.setEnable(true)
            if existing.frame != screenFrame {
                existing.setFrame(screenFrame, display: false)
                existing.canvasView.resize(to: screenFrame)
            }
            window = existing
        } else {
            window = CanvasWindow(screenFrame: screenFrame)
            canvasWindows[screenKey] = window
        }

        window.canvasView.updateColorFromDefaults()
        window.show()
    }

    /// Hides all canvas windows and clears their drawing.
    private func hideAllCanvasWindows() {
        for (_, window) in canvasWindows {
            window.hide()
            window.canvasView.clear()
        }
    }

    /// Returns the screen that contains the given point.
    private func screenContainingPoint(_ point: GesturePoint) -> NSScreen {
        let location = CGPoint(x: point.x, y: point.y)
        for screen in NSScreen.screens {
            if NSPointInRect(location, screen.frame) {
                return screen
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Converts a GesturePoint (in AppKit global coordinates) to the local
    /// coordinate system of the given screen-covering canvas window.
    private func convertPointToView(_ point: GesturePoint, for window: CanvasWindow) -> CGPoint {
        let screenFrame = window.screen?.frame ?? NSScreen.main?.frame ?? .zero
        return CGPoint(
            x: point.x - screenFrame.origin.x,
            y: point.y - screenFrame.origin.y
        )
    }
}
