//
//  WheelDirectionSemanticsTests
//  MacStroke
//
//  Wheel directions are physical: up is negative, down positive. Shift on a
//  horizontal wheel action still selects the horizontal axis; the animator
//  injects real wheel2 events rather than faking Shift+vertical.
//

import XCTest
import CoreGraphics
@testable import RuleEngine
@testable import GestureEngine

final class WheelDirectionSemanticsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ActionExecutor.wheelAnimator.reset()
    }

    override func tearDown() {
        ActionExecutor.wheelAnimator.reset()
        super.tearDown()
    }

    private func execute(_ direction: WheelDirection, flags: UInt = 0) {
        let executor = ActionExecutor()
        executor.execute(.shortcut(keyCode: MouseShortcutCodec.code(for: .wheel(direction)),
                                   flags: flags))
    }

    func testUpUsesNegativeVerticalAnimatorDirection() {
        execute(.up)
        XCTAssertLessThan(ActionExecutor.wheelAnimator.activeSign, 0)
        XCTAssertEqual(ActionExecutor.wheelAnimator.activeAxis, .vertical)
    }

    func testDownUsesPositiveVerticalAnimatorDirection() {
        execute(.down)
        XCTAssertGreaterThan(ActionExecutor.wheelAnimator.activeSign, 0)
        XCTAssertEqual(ActionExecutor.wheelAnimator.activeAxis, .vertical)
    }

    func testPlainWheelDoesNotPostADirectDiscreteEvent() {
        let executor = ActionExecutor()
        var direct: [CGEvent] = []
        executor.eventSink = { event, _ in direct.append(event) }
        executor.execute(.shortcut(keyCode: MouseShortcutCodec.code(for: .wheel(.up)), flags: 0))
        XCTAssertTrue(direct.isEmpty)
        XCTAssertGreaterThan(ActionExecutor.wheelAnimator.distanceLeft, 0)
    }

    func testShiftUpSelectsHorizontalAxis() {
        execute(.up, flags: 0x20000)
        XCTAssertEqual(ActionExecutor.wheelAnimator.activeAxis, .horizontal)
        XCTAssertLessThan(ActionExecutor.wheelAnimator.activeSign, 0)
    }

    func testShiftDownSelectsHorizontalAxis() {
        execute(.down, flags: 0x20000)
        XCTAssertEqual(ActionExecutor.wheelAnimator.activeAxis, .horizontal)
        XCTAssertGreaterThan(ActionExecutor.wheelAnimator.activeSign, 0)
    }

    func testShiftRightSelectsHorizontalAxis() {
        execute(.right, flags: 0x20000)
        XCTAssertEqual(ActionExecutor.wheelAnimator.activeAxis, .horizontal)
        XCTAssertGreaterThan(ActionExecutor.wheelAnimator.activeSign, 0)
    }

    func testPlainRightStaysVertical() {
        execute(.right)
        XCTAssertEqual(ActionExecutor.wheelAnimator.activeAxis, .vertical)
        XCTAssertGreaterThan(ActionExecutor.wheelAnimator.activeSign, 0)
    }

    func testHorizontalProductionFrameUsesWheel2AndNoShiftFlag() {
        let a = SmoothWheelAnimator()
        var scrolls: [CGEvent] = []
        a.eventSink = { event, _ in
            if event.getIntegerValueField(SmoothWheelAnimator.gestureEventTypeField) == 22 {
                scrolls.append(event)
            }
        }
        a.addNotch(axis: .horizontal, sign: 1, flags: [], at: 0)
        a.processFrame()
        guard let began = scrolls.last else { return XCTFail("no real scroll frame") }
        XCTAssertNotEqual(began.getDoubleValueField(.scrollWheelEventPointDeltaAxis2), 0)
        XCTAssertEqual(began.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), 0)
        XCTAssertFalse(began.flags.contains(.maskShift))
    }

    func testWheelCodesAreStableAcrossRounds() {
        XCTAssertEqual(MouseShortcutCodec.code(for: .wheel(.up)), 2001)
        XCTAssertEqual(MouseShortcutCodec.code(for: .wheel(.down)), 2002)
        XCTAssertEqual(MouseShortcutCodec.code(for: .wheel(.left)), 2003)
        XCTAssertEqual(MouseShortcutCodec.code(for: .wheel(.right)), 2004)
    }
}
