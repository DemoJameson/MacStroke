//
//  SmoothWheelEventShapeTests
//  MacStroke
//
//  The production CGEvent sink must carry MMF's exact scroll fields.
//

import XCTest
import CoreGraphics
@testable import RuleEngine
@testable import GestureEngine

final class SmoothWheelEventShapeTests: XCTestCase {

    func testHorizontalWheelUsesAnimatorWithoutSyntheticShift() {
        ActionExecutor.wheelAnimator.reset()
        let executor = ActionExecutor()
        var directEvents: [CGEvent] = []
        executor.eventSink = { event, _ in directEvents.append(event) }
        executor.execute(.shortcut(keyCode: MouseShortcutCodec.code(for: .wheel(.right)), flags: 0))
        XCTAssertGreaterThan(ActionExecutor.wheelAnimator.distanceLeft, 0)
        XCTAssertTrue(directEvents.isEmpty,
                      "wheel actions belong to the animator; no fake Shift+wheel may be posted directly")
        ActionExecutor.wheelAnimator.reset()
    }

    func testProductionFramesCarryMMFFields() {
        let a = SmoothWheelAnimator()
        var frames: [(event: CGEvent, tap: CGEventTapLocation)] = []
        a.eventSink = { event, tap in frames.append((event, tap)) }
        a.addNotch(axis: .vertical, sign: -1, flags: [], at: 0)
        a.processFrame()

        XCTAssertGreaterThanOrEqual(frames.count, 2)
        let scroll = frames.filter {
            $0.event.getIntegerValueField(SmoothWheelAnimator.gestureEventTypeField) == 22
        }
        let gestures = frames.filter {
            $0.event.getIntegerValueField(SmoothWheelAnimator.gestureEventTypeField) == 29
        }
        XCTAssertGreaterThanOrEqual(scroll.count, 1)
        XCTAssertEqual(scroll.count, gestures.count)
        let first = scroll[0].event
        XCTAssertEqual(first.getIntegerValueField(.scrollWheelEventScrollPhase), 1)
        XCTAssertEqual(first.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
        XCTAssertEqual(first.getIntegerValueField(SmoothWheelAnimator.directionInvertedField), 1)
        XCTAssertLessThan(first.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), 0)
        XCTAssertTrue(scroll.allSatisfy { $0.tap == .cgSessionEventTap })
        XCTAssertEqual(gestures[0].event.getIntegerValueField(SmoothWheelAnimator.gestureEventSubtypeField), 6)
        XCTAssertEqual(gestures[0].event.getIntegerValueField(SmoothWheelAnimator.gesturePhaseField), 1)
    }

    func testHorizontalFrameUsesWheel2AndNoShiftFlag() {
        let a = SmoothWheelAnimator()
        var scrollEvents: [CGEvent] = []
        a.eventSink = { event, _ in
            if event.getIntegerValueField(SmoothWheelAnimator.gestureEventTypeField) == 22 {
                scrollEvents.append(event)
            }
        }
        a.addNotch(axis: .horizontal, sign: 1, flags: [], at: 0)
        a.processFrame()
        guard let began = scrollEvents.last else { return XCTFail("no began event") }
        XCTAssertNotEqual(began.getDoubleValueField(.scrollWheelEventPointDeltaAxis2), 0)
        XCTAssertEqual(began.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), 0)
        XCTAssertFalse(began.flags.contains(.maskShift))
    }

    func testPhaseRawValuesMatchIOSHID() {
        XCTAssertEqual(SmoothWheelAnimator.Phase.mayBegin.rawValue, 128)
        XCTAssertEqual(SmoothWheelAnimator.Phase.began.rawValue, 1)
        XCTAssertEqual(SmoothWheelAnimator.Phase.changed.rawValue, 2)
        XCTAssertEqual(SmoothWheelAnimator.Phase.ended.rawValue, 4)
    }
}
