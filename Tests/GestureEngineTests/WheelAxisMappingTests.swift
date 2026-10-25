//
//  WheelAxisMappingTests
//  GestureEngine
//
//  macOS rewrites Shift+vertical-scroll: axis swaps AND sign flips. Measured:
//      up,   no Shift -> deltaY = -1
//      up,   Shift    -> deltaX = +1
//  Undo is therefore swap-then-negate. These cases lock that in, because getting
//  it wrong makes "Wheel Up" record as "Wheel Down".
//

import XCTest
@testable import GestureEngine

final class WheelAxisMappingTests: XCTestCase {

    // MARK: - The measured facts

    func testPlainRollUpIsNegativeY() {
        XCTAssertEqual(WheelDelta(x: 0, y: -1, shifted: false).direction, .up)
    }

    func testPlainRollDownIsPositiveY() {
        XCTAssertEqual(WheelDelta(x: 0, y: 1, shifted: false).direction, .down)
    }

    /// This is the exact event shape that was recorded as "down" by mistake.
    func testShiftRollUpArrivesAsPositiveX() {
        XCTAssertEqual(WheelDelta(x: 1, y: 0, shifted: true).direction, .up,
                       "Shift+上滚在系统里是 deltaX=+1，必须还原成 up")
    }

    func testShiftRollDownArrivesAsNegativeX() {
        XCTAssertEqual(WheelDelta(x: -1, y: 0, shifted: true).direction, .down)
    }

    // MARK: - The transformation

    func testPhysicalSwapsAndNegatesUnderShift() {
        let delta = WheelDelta(x: 3, y: 4, shifted: true)
        XCTAssertEqual(delta.physical.x, -4)
        XCTAssertEqual(delta.physical.y, -3)
    }

    func testPhysicalIsIdentityWithoutShift() {
        let delta = WheelDelta(x: 3, y: 4, shifted: false)
        XCTAssertEqual(delta.physical.x, 3)
        XCTAssertEqual(delta.physical.y, 4)
    }

    func testTiltOnlyHasNoDirection() {
        // Sideways-only input is not one of our gestures.
        XCTAssertNil(WheelDelta(x: 2, y: 0, shifted: false).direction)
        XCTAssertNil(WheelDelta(x: 0, y: 0, shifted: false).direction)
    }

    // MARK: - Replay round-trips

    /// Whatever we post, the system's own rewrite must land on the intended
    /// physical direction. This is the property that keeps record and replay
    /// in agreement.
    func testPostableRoundTripsThroughTheSystemRewrite() {
        for direction: WheelDirection in [.up, .down] {
            for shifted in [false, true] {
                let posted = WheelDelta(x: 0, y: 0, shifted: shifted)
                    .postable(for: direction)
                XCTAssertEqual(posted.direction, direction,
                               "\(direction) shifted=\(shifted) 回放后方向必须一致")
            }
        }
    }

    func testUnshiftedUpPostsNegativeY() {
        let posted = WheelDelta(x: 0, y: 0, shifted: false).postable(for: .up)
        XCTAssertEqual(posted.y, -1)
        XCTAssertEqual(posted.x, 0)
    }

    func testShiftedUpPostsPositiveX() {
        // The inverse of the system's rewrite: post on X with the flipped sign.
        let posted = WheelDelta(x: 0, y: 0, shifted: true).postable(for: .up)
        XCTAssertEqual(posted.x, 1)
        XCTAssertEqual(posted.y, 0)
    }
}
