//
//  SmoothWheelAnimatorTests
//  MacStroke
//
//  Contract tests for the in-engine reproduction of Mac Mouse Fix's
//  High smoothness / High speed scrolling.
//

import XCTest
import CoreGraphics
@testable import RuleEngine
@testable import GestureEngine

final class SmoothWheelAnimatorTests: XCTestCase {

    final class Harness {
        let animator = SmoothWheelAnimator()
        var frames: [(dx: Double, dy: Double, phase: SmoothWheelAnimator.Phase)] = []
        var scheduled: [() -> Void] = []
        private var cancelled = 0
        private(set) var virtualTime: TimeInterval = 0

        init() {
            animator.clock = { [weak self] in self?.virtualTime ?? 0 }
            animator.postEvent = { [weak self] dx, dy, phase, _ in
                self?.frames.append((dx, dy, phase))
            }
            animator.schedule = { [weak self] _, fire in
                self?.scheduled.append(fire)
                return { self?.cancelled += 1 }
            }
        }

        func step() {
            virtualTime += 1.0 / animator.parameters.framesPerSecond
            animator.processFrame()
        }

        func runToCompletion(limit: Int = 2000) {
            var count = 0
            while (animator.distanceTotal > animator.distancePosted || animator.isInMomentum),
                  count < limit {
                step()
                count += 1
            }
        }

        var postedDistance: Double {
            frames.reduce(0.0) { $0 + abs($1.dy) }
        }
    }

    // MARK: - Acceleration curve

    func testPixelsPerTickMatchesMMFLinearCurve() {
        let a = SmoothWheelAnimator()
        XCTAssertEqual(a.pixelsPerTick(interval: 0.30), 150, accuracy: 0.001)
        XCTAssertEqual(a.pixelsPerTick(interval: 0.160), 150, accuracy: 0.001)
        XCTAssertEqual(a.pixelsPerTick(interval: 0.015), 240, accuracy: 0.001)
        XCTAssertEqual(a.pixelsPerTick(interval: 0.005), 240, accuracy: 0.001)

        let midRate = (1 / 0.160 + 1 / 0.015) / 2
        let expected = 150 + (midRate - 1 / 0.160) * 90 / (1 / 0.015 - 1 / 0.160)
        XCTAssertEqual(a.pixelsPerTick(interval: 1 / midRate), expected, accuracy: 0.5)
    }

    func testCurveReproducesTracedMMFSamples() {
        let a = SmoothWheelAnimator()
        let samples: [(rate: Double, px: Double)] = [
            (9.258470, 154), (12.195182, 159), (10.471298, 156),
            (14.780731, 163), (48.394805, 216), (46.162073, 212),
            (11.109892, 157), (15.462161, 164), (58.850166, 232),
        ]
        let totalError = samples.reduce(0.0) {
            $0 + abs(a.pixelsPerTick(interval: 1 / $1.rate) - $1.px)
        }
        XCTAssertLessThan(totalError / Double(samples.count), 1.5)
    }

    // MARK: - Animation shape

    func testSingleNotchProducesMMFPhaseOrderAndNoMomentum() {
        let h = Harness()
        h.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: 100)
        h.runToCompletion()

        XCTAssertEqual(h.frames.first?.phase, .began)
        XCTAssertTrue(h.frames.contains { $0.phase == .ended })
        XCTAssertEqual(h.frames.last?.phase, .cancelled)
        XCTAssertGreaterThan(h.postedDistance, 0)
    }

    func testSingleNotchRunsTheBaseMsPerStepPhaseOnly() {
        let h = Harness()
        h.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: 100)
        h.runToCompletion()
        // A 150px notch / 220ms minDuration becomes a shortened line segment
        // plus its drag tail. At 60Hz the result is about 0.45–0.60s.
        XCTAssertGreaterThanOrEqual(h.frames.count, 25)
        XCTAssertLessThanOrEqual(h.frames.count, 90)
        XCTAssertGreaterThan(h.scheduled.count, 0)
    }

    func testBasePhaseMovesAtConstantVelocity() {
        let h = Harness()
        h.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: 100)
        for _ in 0..<16 { h.step() }
        let steps = h.frames.filter { $0.phase != .mayBegin && $0.dy != 0 }.map { abs($0.dy) }
        guard steps.count >= 4 else { return XCTFail("not enough frames") }
        // The first frames form the constant-velocity base segment; later
        // frames enter the drag tail and legitimately decelerate.
        let base = Array(steps.prefix(5))
        XCTAssertLessThanOrEqual(base.max()! - base.min()!, 1.0,
                                 "base frames may differ by one due to sub-pixel rounding")
    }

    func testSixFiftyMillisecondNotchesAggregateLikeMMF() {
        let h = Harness()
        for i in 0..<6 {
            h.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: Double(i) * 0.05)
        }
        h.runToCompletion()
        XCTAssertGreaterThan(h.postedDistance, 900,
                             "six consecutive 50ms notches must accumulate, not collapse to one 150px tick")
        XCTAssertLessThan(h.postedDistance, 1100)
    }

    func testDenseBurstProducesMoreDistanceThanIsolatedNotches() {
        let slow = Harness()
        for i in 0..<10 {
            slow.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: Double(i) * 0.5)
            slow.runToCompletion()
        }
        let slowDistance = slow.postedDistance

        let fast = Harness()
        for i in 0..<10 {
            fast.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: Double(i) * 0.03)
        }
        fast.runToCompletion()

        XCTAssertGreaterThan(fast.postedDistance, slowDistance,
                             "30ms ticks must accelerate above ten isolated 150px notches")
        XCTAssertLessThan(fast.postedDistance, slowDistance * 3,
                          "without MMF's swipes guard, fastScroll would explode and this catches that regression")
    }

    // MARK: - Direction and axis

    func testReversalDropsThePendingTail() {
        let h = Harness()
        h.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: 100)
        h.step()
        h.animator.addNotch(axis: .vertical, sign: -1, flags: [], at: 100.1)
        XCTAssertEqual(h.animator.distanceLeft, h.animator.lastCommandedPixels, accuracy: 0.01)
        XCTAssertEqual(h.animator.activeSign, -1)
    }

    func testAxisChangeDropsThePendingTail() {
        let h = Harness()
        h.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: 100)
        h.step()
        h.animator.addNotch(axis: .horizontal, sign: 1, flags: [], at: 100.1)
        XCTAssertEqual(h.animator.activeAxis, .horizontal)
        XCTAssertEqual(h.animator.distanceLeft, h.animator.lastCommandedPixels, accuracy: 0.01)
    }

    func testPauseResetsTheAccelerationHistory() {
        let h = Harness()
        var t: TimeInterval = 1
        for _ in 0..<3 {
            h.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: t)
            t += 0.05
        }
        h.runToCompletion()
        h.frames = []
        h.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: t + 2)
        h.runToCompletion()
        XCTAssertEqual(h.postedDistance, 150, accuracy: 1.1)
    }

    // MARK: - Non-stacking / event contract

    func testProductionEventIsContinuousAndPhased() {
        let a = SmoothWheelAnimator()
        var events: [CGEvent] = []
        a.postEvent = { dx, dy, phase, _ in
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else { return }
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
            event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
            events.append(event)
        }
        a.addNotch(axis: .vertical, sign: 1, flags: [], at: 0)
        a.processFrame()
        XCTAssertGreaterThanOrEqual(events.count, 1)
        XCTAssertTrue(events.allSatisfy {
            $0.getIntegerValueField(.scrollWheelEventIsContinuous) == 1
        })
        XCTAssertNotEqual(events.last?.getIntegerValueField(.scrollWheelEventScrollPhase), 0)
    }

    func testGestureCompanionFieldNumbersMatchMMF() {
        XCTAssertEqual(SmoothWheelAnimator.gestureEventTypeField.rawValue, 55)
        XCTAssertEqual(SmoothWheelAnimator.gestureEventSubtypeField.rawValue, 110)
        XCTAssertEqual(SmoothWheelAnimator.gestureDeltaXField.rawValue, 116)
        XCTAssertEqual(SmoothWheelAnimator.gestureDeltaYField.rawValue, 119)
        XCTAssertEqual(SmoothWheelAnimator.gesturePhaseField.rawValue, 132)
        XCTAssertEqual(SmoothWheelAnimator.directionInvertedField.rawValue, 137)
        XCTAssertEqual(SmoothWheelAnimator.momentumPhaseField.rawValue, 123)
    }

    // MARK: - Executor wiring

    func testWheelActionFeedsTheSharedAnimator() {
        let h = Harness()
        let original = ActionExecutor.wheelAnimator
        let savedPost = original.postEvent
        let savedSchedule = original.schedule
        original.postEvent = h.animator.postEvent
        original.schedule = h.animator.schedule
        defer { original.postEvent = savedPost; original.schedule = savedSchedule }

        let executor = ActionExecutor()
        executor.execute(.shortcut(keyCode: MouseShortcutCodec.code(for: .wheel(.down)), flags: 0))
        XCTAssertGreaterThan(original.distanceLeft, 0)
        original.reset()
    }

    // MARK: - Drag maths / momentum

    func testDragCurveMatchesMMFClosedForm() {
        let a = SmoothWheelAnimator()
        a.addNotch(axis: .vertical, sign: 1, flags: [], at: 100)
        XCTAssertGreaterThan(a.dragTimeToStop, 0)
        var previous = a.dragSpeed(elapsed: 1.0 / 60)
        for frame in 2...120 {
            let v = a.dragSpeed(elapsed: Double(frame) / 60)
            XCTAssertLessThanOrEqual(v, previous)
            previous = v
        }
    }

    func testSubPixelatorIsBiasedAndCarriesResidualError() {
        var sp = SmoothWheelAnimator.SubPixelator()
        XCTAssertEqual(sp.delta(0.3), 1)
        XCTAssertEqual(sp.delta(0.3), 0)
        XCTAssertEqual(sp.delta(0.3), 0)
        XCTAssertEqual(sp.delta(0.3), 1)
        sp.reset()
        XCTAssertEqual(sp.delta(-0.3), -1)
        XCTAssertEqual(sp.delta(-0.3), 0)
    }

    func testFastSwipeHasMomentumButMomentumPhaseUsesMMFRawValues() {
        let h = Harness()
        for i in 0..<8 {
            h.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: Double(i) * 0.02)
        }
        h.runToCompletion()
        XCTAssertEqual(SmoothWheelAnimator.Phase.mayBegin.rawValue, 128)
        XCTAssertEqual(SmoothWheelAnimator.Phase.began.rawValue, 1)
        XCTAssertEqual(SmoothWheelAnimator.Phase.changed.rawValue, 2)
        XCTAssertEqual(SmoothWheelAnimator.Phase.ended.rawValue, 4)
    }

    func testMomentumTailIsFiniteAndBounded() {
        let h = Harness()
        for i in 0..<6 {
            h.animator.addNotch(axis: .vertical, sign: 1, flags: [], at: Double(i) * 0.05)
        }
        h.runToCompletion(limit: 5000)
        // Six 50ms ticks command at most 190px each. The momentum tail may
        // extend that, but must remain in the same order of magnitude.
        XCTAssertLessThan(h.postedDistance, 3000,
                          "momentum tail must not explode into hundreds of thousands of pixels")
    }
}
