//
//  ImpulseGestureTests
//  MacStroke
//
//  按住触发键（默认右键）期间的瞬时手势：滚轮每满一行触发一次，中键/按键4/5
//  按下触发并且连 up 一起吞掉。反向对照同样重要：没接线、没按住触发键、没匹配
//  到规则时，这些事件必须原样交回前台应用，中键粘贴与普通滚动不受影响。
//

import XCTest
import CoreGraphics
@testable import EventCapture
@testable import GestureEngine

final class ImpulseGestureTests: XCTestCase {

    private final class RecordingDelegate: CanvasManagerDelegate {
        var matchResult = false
        @discardableResult
        func canvasManager(_ manager: CanvasManager, didCompleteStroke stroke: Stroke, bundleID: String) -> Bool {
            matchResult
        }
    }

    private let delegate = RecordingDelegate()
    private lazy var manager = CanvasManager()
    private lazy var capture = EventCapture()

    private var fired: [ImpulseGesture] = []
    private var firedTargets: [CanvasManager.ImpulseTarget] = []
    private var handled: Set<ImpulseGesture> = []
    private var replayed: [CGEventType] = []

    override func setUp() {
        super.setUp()
        manager.delegate = delegate
        capture.delegate = manager
        fired = []
        firedTargets = []
        handled = []
        replayed = []
        manager.impulseHandler = { [weak self] gesture, target in
            self?.fired.append(gesture)
            self?.firedTargets.append(target)
            return self?.handled.contains(gesture) ?? false
        }
        manager.syntheticEventSink = { [weak self] event, _ in
            self?.replayed.append(event.type)
        }
    }

    override func tearDown() {
        manager.impulseHandler = nil
        manager.syntheticEventSink = nil
        capture.stop()
        manager.cancelStroke()
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func holdTrigger(_ button: MouseButton = .right) -> Bool {
        manager.eventCapture(capture, didReceive: MouseEvent(
            point: GesturePoint(x: 0, y: 0), button: button, phase: .down))
    }

    @discardableResult
    private func releaseTrigger(_ button: MouseButton = .right) -> Bool {
        manager.eventCapture(capture, didReceive: MouseEvent(
            point: GesturePoint(x: 0, y: 0), button: button, phase: .up))
    }

    @discardableResult
    private func scroll(dx: Double = 0, dy: Double = 0, continuous: Bool = false,
                        momentum: Bool = false) -> Bool {
        manager.eventCapture(capture, didReceiveScroll: ScrollEvent(
            deltaX: dx, deltaY: dy, isContinuous: continuous, isMomentum: momentum))
    }

    @discardableResult
    private func click(_ button: MouseButton, phase: MousePhase) -> Bool {
        manager.eventCapture(capture, didReceive: MouseEvent(
            point: GesturePoint(x: 0, y: 0), button: button, phase: phase))
    }

    // MARK: - Wheel impulses

    func testWheelUpAndDownFireWhileTriggerHeld() {
        handled = [.wheelUp, .wheelDown]
        holdTrigger()

        // Positive delta = rolled down (measured convention).
        XCTAssertTrue(scroll(dy: -1), "匹配到规则的滚轮事件必须被吞掉")
        XCTAssertTrue(scroll(dy: 1))
        XCTAssertEqual(fired, [.wheelUp, .wheelDown])
    }

    func testEachWheelNotchFiresOnce() {
        handled = [.wheelUp]
        holdTrigger()

        XCTAssertTrue(scroll(dy: -1))
        XCTAssertTrue(scroll(dy: -1))
        XCTAssertTrue(scroll(dy: -1))
        XCTAssertEqual(fired, [.wheelUp, .wheelUp, .wheelUp], "连滚三格应触发三次")
    }

    func testAllNotchesUseTheFrontAppCapturedAtTriggerDown() {
        handled = [.wheelDown]
        holdTrigger()
        XCTAssertTrue(scroll(dy: 1))
        XCTAssertTrue(scroll(dy: 1))
        XCTAssertTrue(scroll(dy: 1))
        XCTAssertEqual(fired, [.wheelDown, .wheelDown, .wheelDown])
        XCTAssertEqual(firedTargets.count, 3)
        XCTAssertEqual(Set(firedTargets.map(\.frontBundleID)).count, 1,
                       "all notches in one held gesture must keep the front app captured at mouse-down")
        XCTAssertTrue(firedTargets.allSatisfy { $0.pointerBundleID == nil },
                      "no pointer probe installed: nothing to attribute to the window under the pointer")
    }

    func testHighResolutionWheelAccumulatesToWholeLines() {
        handled = [.wheelDown]
        holdTrigger()

        // ScrollEvent is already in lines (EventCapture divides pixel deltas
        // by the measured 10 points-per-line). Three 0.4-line steps cross one
        // line exactly, and the leftover 0.2 is carried into the next step.
        XCTAssertFalse(scroll(dy: 0.4, continuous: true))
        XCTAssertFalse(scroll(dy: 0.4, continuous: true))
        XCTAssertTrue(fired.isEmpty, "0.8 line is not a whole notch yet")

        XCTAssertTrue(scroll(dy: 0.4, continuous: true))
        XCTAssertEqual(fired, [.wheelDown], "1.2 lines fire once, 0.2 carried over")

        XCTAssertTrue(scroll(dy: 0.8, continuous: true))
        XCTAssertEqual(fired, [.wheelDown, .wheelDown], "carried 0.2 + 0.8 = the next notch")
    }

    func testMomentumNeverFiresImpulses() {
        handled = Set(ImpulseGesture.allCases)
        holdTrigger()

        XCTAssertFalse(scroll(dy: 10, momentum: true), "惯性事件不能触发，也不能被吞")
        XCTAssertTrue(fired.isEmpty)
    }

    // MARK: - Pointer attribution

    private func pointerRecord(_ bundle: String, pid: pid_t = 900) -> CursorWindowRecord {
        CursorWindowRecord(windowNumber: 12, pid: pid, bundleID: bundle, ownerName: "Owner",
                           layer: 0, alpha: 1)
    }

    func testWheelUsesTheAppUnderThePointer() {
        manager.cursorWindowResolver = { [weak self] _ in self?.pointerRecord("tv.rexnow.app") }
        handled = [.wheelUp]
        holdTrigger()

        // 真实滚轮事件自带坐标；这里给一个落点，模拟指针停在后台那扇窗上。
        XCTAssertTrue(manager.eventCapture(capture, didReceiveScroll: ScrollEvent(
            deltaX: 0, deltaY: -1, isContinuous: false, isMomentum: false,
            location: CGPoint(x: 640, y: 400))))
        XCTAssertEqual(firedTargets.last?.pointerBundleID, "tv.rexnow.app",
                       "滚轮要归给指针下那一家，规则才挑得中它的专用动作")
    }

    func testWheelPrefersTheScrollLocationOverTriggerDown() {
        manager.cursorWindowResolver = { point in
            point.x < 50 ? self.pointerRecord("com.example.Start")
                         : self.pointerRecord("com.example.Moved")
        }
        handled = [.wheelDown]
        holdTrigger()

        XCTAssertTrue(manager.eventCapture(capture, didReceiveScroll: ScrollEvent(
            deltaX: 0, deltaY: 1, isContinuous: false, isMomentum: false,
            location: CGPoint(x: 300, y: 200))))
        XCTAssertEqual(firedTargets.last?.pointerBundleID, "com.example.Moved",
                       "按住期间指针挪过，滚轮归的是这一发滚轮的落点")
    }

    /// 事件没带位置（手搓的事件、或系统不给坐标）时没有指针目标，交给 App 层退回前台那家。
    /// 不能拿「按下触发键那一刻」那扇窗来冒充：指针在这期间可能已经挪走了。
    func testWheelWithoutLocationHasNoPointerTarget() {
        manager.cursorWindowResolver = { _ in self.pointerRecord("com.example.Start") }
        handled = [.wheelDown]
        holdTrigger()

        XCTAssertTrue(scroll(dy: 1))
        XCTAssertNil(firedTargets.last?.pointerBundleID)
        XCTAssertNotNil(firedTargets.last?.frontBundleID)
    }

    func testClickImpulseUsesTheAppUnderThePointerAtTriggerDown() {
        manager.cursorWindowResolver = { _ in self.pointerRecord("com.example.Start") }
        handled = [.middleClick]
        holdTrigger()

        XCTAssertTrue(click(.middle, phase: .down))
        XCTAssertEqual(firedTargets.last?.pointerBundleID, "com.example.Start")
    }

    func testNoPointerWindowFallsBackToFrontApp() {
        handled = [.wheelUp]
        holdTrigger()
        XCTAssertTrue(scroll(dy: -1))
        XCTAssertNil(firedTargets.last?.pointerBundleID)
        XCTAssertNotNil(firedTargets.last)
    }

    // MARK: - Click impulses

    func testMiddleClickFiresAndSwallowsBothHalves() {
        handled = [.middleClick]
        holdTrigger()

        XCTAssertTrue(click(.middle, phase: .down), "匹配到规则的中键按下必须被吞掉")
        XCTAssertTrue(click(.middle, phase: .up), "配对的抬起也要吞，否则前台收到半次点击")
        XCTAssertEqual(fired, [.middleClick])
    }

    func testSideButtonsFireMatchingImpulses() {
        handled = [.button4, .button5]
        holdTrigger()

        XCTAssertTrue(click(.extra(3), phase: .down))
        XCTAssertTrue(click(.extra(3), phase: .up))
        XCTAssertTrue(click(.extra(4), phase: .down))
        XCTAssertTrue(click(.extra(4), phase: .up))
        XCTAssertEqual(fired, [.button4, .button5])
    }

    func testUnmappedSideButtonPassesThrough() {
        handled = [.button4]
        holdTrigger()

        XCTAssertFalse(click(.extra(5), phase: .down), "没规则时侧键必须原样放行")
        XCTAssertFalse(click(.extra(5), phase: .up))
        XCTAssertTrue(fired.isEmpty)
    }

    // MARK: - Reverse controls

    func testWheelPassesThroughWhenTriggerNotHeld() {
        handled = Set(ImpulseGesture.allCases)

        XCTAssertFalse(scroll(dy: 1), "没按住触发键时滚轮必须原样放行")
        XCTAssertTrue(fired.isEmpty)
    }

    func testMiddleClickPassesThroughWhenTriggerNotHeld() {
        handled = Set(ImpulseGesture.allCases)

        XCTAssertFalse(click(.middle, phase: .down), "没按住触发键时中键保持原生行为")
        XCTAssertFalse(click(.middle, phase: .up))
        XCTAssertTrue(fired.isEmpty)
    }

    func testNoHandlerLeavesEverythingUntouched() {
        manager.impulseHandler = nil
        holdTrigger()

        XCTAssertFalse(scroll(dy: 1))
        XCTAssertFalse(click(.middle, phase: .down))
        XCTAssertTrue(fired.isEmpty)
    }

    func testUnmatchedWheelPassesThrough() {
        // 没有规则命中时，滚动必须照常交给前台应用。
        holdTrigger()
        XCTAssertFalse(scroll(dy: 1))
        XCTAssertFalse(scroll(dy: -1))
    }

    // MARK: - Trigger release after an impulse

    func testReleasingTriggerAfterImpulseDoesNotReplayClick() {
        handled = [.wheelUp]
        holdTrigger()
        XCTAssertTrue(scroll(dy: -1))  // negative = rolled up

        releaseTrigger()

        XCTAssertTrue(replayed.isEmpty, "滚动过的这一下不能再补一发右键/合成菜单")
    }

    func testPlainTriggerReleaseStillReplays() {
        holdTrigger()
        releaseTrigger()

        XCTAssertEqual(replayed, [.rightMouseDown, .rightMouseUp],
                       "纯右键单击（没触发瞬时手势）仍要回放，菜单照常弹")
    }

    func testImpulseDoesNotSwallowOtherSideButton() {
        // 中键触发后，未绑定的侧键仍走自己的原生路径，不会被顺带吞掉。
        handled = [.middleClick]
        holdTrigger()
        XCTAssertTrue(click(.middle, phase: .down))
        XCTAssertTrue(click(.middle, phase: .up))
        XCTAssertFalse(click(.extra(4), phase: .down), "按键5 不属于这次瞬时手势")
    }

    /// Shift makes macOS deliver a vertical roll as a horizontal delta. The
    /// trigger side must undo that, or "wheel up" fires the left-tilt gesture.
    func testShiftVerticalRollStillFiresWheelUp() {
        handled = [.wheelUp]
        holdTrigger()

        // Measured shape: Shift+上滚 arrives as deltaX = +1 (swap-and-flip).
        manager.eventCapture(capture, didReceiveScroll: ScrollEvent(
            deltaX: 1, deltaY: 0, isContinuous: false, isMomentum: false,
            modifiers: [.shift]))

        XCTAssertEqual(fired, [.wheelUp], "Shift+上滚必须还是上滚")
    }

    func testShiftVerticalRollDownStillFiresWheelDown() {
        handled = [.wheelDown]
        holdTrigger()

        manager.eventCapture(capture, didReceiveScroll: ScrollEvent(
            deltaX: -1, deltaY: 0, isContinuous: false, isMomentum: false,
            modifiers: [.shift]))

        XCTAssertEqual(fired, [.wheelDown])
    }

    /// The action posts to the HID tap so Mac Mouse Fix can smooth it — which
    /// also means our own tap sees it again. The tag must make it pass through
    /// instead of firing the gesture a second time.
    func testInjectedScrollDoesNotRefireTheGesture() {
        handled = Set(ImpulseGesture.allCases)
        holdTrigger()

        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                            wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0)!
        // The executor's tag and the capture layer's must be the same value,
        // otherwise the guard never matches in production.
        event.setIntegerValueField(.eventSourceUserData, value: InjectedEvent.tag)
        XCTAssertTrue(EventCapture.isInjectedScroll(event), "注入事件必须被识别")

        // A plain event must NOT be mistaken for an injected one.
        let plain = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                            wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0)!
        XCTAssertFalse(EventCapture.isInjectedScroll(plain))
    }
}
