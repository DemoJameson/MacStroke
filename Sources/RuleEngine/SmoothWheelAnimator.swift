//
//  SmoothWheelAnimator.swift
//  MacStroke
//
//  Reproduction of Mac Mouse Fix's High smoothness / High speed scroll path:
//  ScrollAnalyzer -> LineHybridCurve -> TouchAnimator -> GestureScrollSimulator.
//

import Foundation
import AppKit
import CoreGraphics
import CoreVideo
import GestureEngine

final class SmoothWheelAnimator {

    enum Axis { case vertical, horizontal }

    /// CGEvent/IOHID phase values used by GestureScrollSimulator.
    enum Phase: Int {
        case mayBegin = 128
        case began = 1
        case changed = 2
        case ended = 4
        case cancelled = 8
    }

    struct Parameters {
        // CombinedLinearCurve for Smoothness: High / Speed: High.
        var minPixels: Double = 150
        var maxPixels: Double = 240
        var slowInterval: TimeInterval = 0.160
        var fastInterval: TimeInterval = 0.015

        // MFScrollAnimationCurveParameters for HighInertiaPlusTrackpadSim.
        var baseDuration: TimeInterval = 0.220
        var dragCoefficient: Double = 40
        var dragExponent: Double = 0.7
        var stopSpeed: Double = 30
        var sendGestureScrolls: Bool = true
        var sendMomentumScrolls: Bool = true
        var momentumGestureMinimumTime: TimeInterval = 0.160

        var historyCount: Int = 3
        /// First-frame fallback. CVDisplayLink supplies the actual cadence
        /// afterwards through the wall-clock clock seam.
        var framesPerSecond: Double = 120
    }

    var parameters = Parameters()

    // Test seams.
    var postEvent: ((Double, Double, Phase, CGEventFlags) -> Void)?
    var schedule: ((TimeInterval, @escaping () -> Void) -> () -> Void)?
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var eventSink: ((CGEvent, CGEventTapLocation) -> Void)?

    // Raw CGEvent fields used by MMF's synthetic trackpad events.
    static let gestureEventTypeField = CGEventField(rawValue: 55)!
    static let gestureEventSubtypeField = CGEventField(rawValue: 110)!
    static let gestureDeltaXField = CGEventField(rawValue: 116)!
    static let gestureDeltaYField = CGEventField(rawValue: 119)!
    static let gesturePhaseField = CGEventField(rawValue: 132)!
    static let directionInvertedField = CGEventField(rawValue: 137)!
    static let momentumPhaseField = CGEventField(rawValue: 123)!

    // MARK: - State

    private(set) var activeAxis: Axis?
    private(set) var activeSign: Double = 0
    private(set) var distanceTotal: Double = 0
    private(set) var distancePosted: Double = 0
    private(set) var distanceLeft: Double = 0
    private(set) var baseDistance: Double = 0
    private(set) var dragTargetDistance: Double = 0
    private(set) var lastCommandedPixels: Double = 0
    private(set) var dragTimeToStop: TimeInterval = 0
    private(set) var isInMomentum = false
    private(set) var isPostingMomentum = false
    /// Distance left in the drag subcurve (diagnostic / tests).
    private(set) var momentumLeft: Double = 0
    private(set) var momentumStopTime: TimeInterval = 0

    private var baseCurveDuration: TimeInterval = 0
    private var totalCurveDuration: TimeInterval = 0
    private var dragC: Double = 0
    private var dragK: Double = 0
    private var elapsed: TimeInterval = 0
    private var lastFrameTime: TimeInterval?

    private var intervalSamples: [TimeInterval] = []
    private var lastNotchTime: TimeInterval?
    private var eventFlags: CGEventFlags = []

    private var hasProducedDeltas = false
    private var lastSubCurveWasBase = false
    private var lastPostedHint: MomentumHint?

    private var cancelTimer: (() -> Void)?

    private var pointSubPixelX = SubPixelator()
    private var pointSubPixelY = SubPixelator()
    private var lineSubPixelX = SubPixelator()
    private var lineSubPixelY = SubPixelator()

    private enum MomentumHint { case gesture, momentum }
    private enum SubCurve { case base, drag }

    init() {
        postEvent = { [weak self] dx, dy, phase, flags in
            self?.postProduction(dx: dx, dy: dy, phase: phase, flags: flags)
        }
        // MMF's TouchAnimator uses a display link at the panel cadence. The
        // callback advances by the wall-clock delta; coalesced callbacks are
        // not stretched into a fixed 60Hz timer.
        schedule = { _, fire in
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            guard let link else {
                let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in fire() }
                RunLoop.main.add(timer, forMode: .common)
                return { timer.invalidate() }
            }
            CVDisplayLinkSetOutputHandler(link) { _, _, _, _, _ in
                DispatchQueue.main.async { fire() }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            return { CVDisplayLinkStop(link) }
        }
    }

    // MARK: - Sub-pixel rounding

    /// MMF's biased SubPixelator: the first non-zero direction selects ceil or
    /// floor, and the residual carries into later frames.
    struct SubPixelator {
        private var error: Double = 0
        private var positiveRounding: Bool?

        mutating func delta(_ input: Double) -> Double {
            guard input != 0 else { return 0 }
            if positiveRounding == nil { positiveRounding = input > 0 }
            let precise = input + error
            let output = positiveRounding == true ? ceil(precise) : floor(precise)
            error = precise - output
            return output
        }

        mutating func reset() {
            error = 0
            positiveRounding = nil
        }
    }

    // MARK: - Input analysis

    func pixelsPerTick(interval: TimeInterval) -> Double {
        guard interval.isFinite, interval > 0 else { return parameters.minPixels }
        let rate = 1 / interval
        let minRate = 1 / parameters.slowInterval
        let maxRate = 1 / parameters.fastInterval
        if rate <= minRate { return parameters.minPixels }
        if rate >= maxRate { return parameters.maxPixels }
        return parameters.minPixels
            + (rate - minRate) * (parameters.maxPixels - parameters.minPixels)
            / (maxRate - minRate)
    }

    func multiplier(interval: TimeInterval) -> Double {
        pixelsPerTick(interval: interval) / parameters.minPixels
    }

    // MARK: - Notch ingestion

    func addNotch(axis: Axis, sign: Double, flags: CGEventFlags,
                  at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard sign != 0 else { return }

        let wasRunning = cancelTimer != nil
        let directionChanged = axis != activeAxis || sign != activeSign
        if directionChanged {
            cancelActiveAnimation()
            intervalSamples.removeAll()
            lastNotchTime = nil
        }

        // ScrollAnalyzer: a >160ms gap starts a new consecutive sequence. The
        // first tick seeds the RollingAverage with tickMax; the second tick
        // therefore averages the seed and its real gap.
        let isFirstConsecutive = lastNotchTime.map { now - $0 > parameters.slowInterval } ?? true
        if isFirstConsecutive {
            intervalSamples = [parameters.slowInterval]
        } else if let last = lastNotchTime {
            intervalSamples.append(now - last)
            if intervalSamples.count > parameters.historyCount {
                intervalSamples.removeFirst(intervalSamples.count - parameters.historyCount)
            }
        }
        lastNotchTime = now

        let interval: TimeInterval
        if isFirstConsecutive {
            interval = parameters.slowInterval
        } else {
            interval = intervalSamples.reduce(0, +) / Double(intervalSamples.count)
        }
        let pixels = pixelsPerTick(interval: interval)
        lastCommandedPixels = pixels
        eventFlags = flags
        activeAxis = axis
        activeSign = sign

        // Scroll.m computes pxLeftToScroll from the running TouchAnimator and
        // restarts the curve with pxLeft + the newly commanded pixels.
        let remaining = wasRunning ? max(distanceTotal - distancePosted, 0) : 0
        let target = remaining + pixels
        distanceTotal = target
        distancePosted = 0
        distanceLeft = target
        elapsed = 0
        lastFrameTime = wasRunning ? lastFrameTime : nil

        configureLineHybrid(distance: target, minDuration: parameters.baseDuration)

        if !wasRunning {
            hasProducedDeltas = false
            lastSubCurveWasBase = false
            lastPostedHint = nil
            resetSubPixelators()
        }
        isInMomentum = false
        momentumLeft = dragTargetDistance
        momentumStopTime = dragTimeToStop
        ensureRunning()
    }

    /// MMF LineHybridCurve._lineInit. The 220ms value is minDuration; the
    /// actual straight segment is shortened to transitionDistance / distance.
    private func configureLineHybrid(distance: Double, minDuration: TimeInterval) {
        let exitSpeed = distance / minDuration
        baseDistance = 0
        baseCurveDuration = 0
        dragTargetDistance = 0
        dragC = 0
        dragK = 0
        dragTimeToStop = 0

        guard exitSpeed > parameters.stopSpeed else {
            baseDistance = distance
            baseCurveDuration = minDuration
            totalCurveDuration = minDuration
            return
        }

        let drag = makeDragParameters(
            coefficient: parameters.dragCoefficient,
            exponent: parameters.dragExponent,
            stopSpeed: parameters.stopSpeed,
            initialSpeed: exitSpeed
        )
        if distance - drag.distance < 0 {
            // MMF fallback: discard the line and solve a distance-initialised
            // DragCurve for the full target.
            dragTargetDistance = distance
            solveDragCurve(distance: distance)
        } else {
            baseDistance = distance - drag.distance
            baseCurveDuration = minDuration * (baseDistance / distance)
            dragTargetDistance = drag.distance
            dragC = drag.c
            dragK = drag.k
            dragTimeToStop = drag.time
        }
        totalCurveDuration = baseCurveDuration + dragTimeToStop
    }

    // MARK: - Frame production

    func processFrame() {
        guard activeAxis != nil, distanceTotal > 0 else {
            stop()
            return
        }

        let now = clock()
        let fallback = 1 / parameters.framesPerSecond
        let dt = lastFrameTime.map { max(0, now - $0) } ?? fallback
        lastFrameTime = now
        elapsed += dt

        let isFinal = elapsed >= totalCurveDuration - 1e-9
        if isFinal { elapsed = totalCurveDuration }

        let travelled = curveDistance(at: elapsed, total: distanceTotal)
        let rawStep = max(travelled - distancePosted, 0)
        distancePosted = travelled
        distanceLeft = max(distanceTotal - distancePosted, 0)
        momentumLeft = max(dragTargetDistance - max(travelled - baseDistance, 0), 0)

        let subCurve: SubCurve = elapsed <= baseCurveDuration ? .base : .drag
        var hint = momentumHint(elapsed: elapsed, subCurve: subCurve)
        // MMF only switches to drag when the whole frame comes from drag.
        if lastSubCurveWasBase { hint = .gesture }
        lastSubCurveWasBase = subCurve == .base

        let (dx, dy) = integerDelta(amount: isFinal ? 0 : rawStep)
        let hasIntegerDelta = dx != 0 || dy != 0

        if !isFinal && !hasIntegerDelta {
            return
        }
        if isFinal && !hasProducedDeltas && !hasIntegerDelta {
            // MMF maps this to stoppedBeforeStart, which Scroll.m discards.
            resetAfterAnimation()
            stop()
            return
        }

        let callbackPhase: Phase = isFinal
            ? .ended
            : (hasProducedDeltas ? .changed : .began)
        postFrame(dx: dx, dy: dy, phase: callbackPhase, hint: hint, isFinal: isFinal)
        hasProducedDeltas = true

        if isFinal {
            resetAfterAnimation()
            stop()
        }
    }

    private func curveDistance(at time: TimeInterval, total: Double) -> Double {
        guard time > 0 else { return 0 }
        if time <= baseCurveDuration {
            guard baseCurveDuration > 0 else { return 0 }
            return min(baseDistance * (time / baseCurveDuration), total)
        }
        let dragElapsed = time - baseCurveDuration
        let dragTravelled = dragDistance(elapsed: dragElapsed)
        return min(baseDistance + dragTravelled, total)
    }

    private func momentumHint(elapsed: TimeInterval, subCurve: SubCurve) -> MomentumHint {
        guard parameters.sendMomentumScrolls else { return .gesture }
        if elapsed < parameters.momentumGestureMinimumTime { return .gesture }
        return subCurve == .drag ? .momentum : .gesture
    }

    private func integerDelta(amount: Double) -> (Double, Double) {
        guard let axis = activeAxis, amount != 0 else { return (0, 0) }
        let signed = activeSign * amount
        switch axis {
        case .vertical:
            return (0, pointSubPixelY.delta(signed))
        case .horizontal:
            return (pointSubPixelX.delta(signed), 0)
        }
    }

    // MARK: - Posting / phase transitions

    private func postFrame(dx: Double, dy: Double, phase: Phase,
                           hint: MomentumHint, isFinal: Bool) {
        switch hint {
        case .gesture:
            if lastPostedHint == .momentum {
                postMomentum(dx: 0, dy: 0, phase: .ended)
            }
            let eventPhase = (lastPostedHint == .momentum && !isFinal) ? Phase.began : phase
            postGesture(dx: dx, dy: dy, phase: eventPhase)

        case .momentum:
            if lastPostedHint == .gesture {
                postGesture(dx: 0, dy: 0, phase: .ended)
                postMomentum(dx: dx, dy: dy, phase: .began)
            } else {
                postMomentum(dx: dx, dy: dy, phase: phase)
            }
            if isFinal {
                postGesture(dx: 0, dy: 0, phase: .mayBegin)
                postGesture(dx: 0, dy: 0, phase: .cancelled)
            }
        }

        lastPostedHint = hint
        isInMomentum = hint == .momentum
    }

    private func postGesture(dx: Double, dy: Double, phase: Phase) {
        isPostingMomentum = false
        postEvent?(dx, dy, phase, eventFlags)
    }

    private func postMomentum(dx: Double, dy: Double, phase: Phase) {
        isPostingMomentum = true
        postEvent?(dx, dy, phase, eventFlags)
        isPostingMomentum = false
    }

    private func cancelActiveAnimation() {
        guard cancelTimer != nil else { return }
        if let hint = lastPostedHint {
            if hint == .momentum {
                postMomentum(dx: 0, dy: 0, phase: .ended)
            } else {
                postGesture(dx: 0, dy: 0, phase: .ended)
            }
        }
        resetAfterAnimation()
        stop()
    }

    // MARK: - Drag maths

    private struct DragParameters {
        var c: Double = 0
        var k: Double = 0
        var time: TimeInterval = 0
        var distance: Double = 0
    }

    private func makeDragParameters(coefficient a: Double, exponent b: Double,
                                    stopSpeed vs: Double, initialSpeed v0: Double) -> DragParameters {
        var result = DragParameters()
        let c = -pow(v0, 1 - b) / ((b - 1) * a)
        let time = pow(vs, 1 - b) / ((b - 1) * a) + c
        let exponent = 1 / (1 - b) + 1

        func raw(_ t: TimeInterval) -> Double {
            let inner = a * (b - 1) * (t - c)
            guard inner > 0 else { return 0 }
            return pow(inner, exponent) / (a * (b - 2))
        }
        let start = raw(0)
        let end = raw(time)
        result.c = c
        result.k = -start
        result.time = time
        result.distance = end - start
        return result
    }

    func dragSpeed(elapsed: TimeInterval) -> Double {
        let b = parameters.dragExponent
        let a = parameters.dragCoefficient
        let raw = (b - 1) * (a * (elapsed - dragC))
        guard raw > 0 else { return 0 }
        return pow(raw, 1 / (1 - b))
    }

    private func dragDistance(elapsed: TimeInterval) -> Double {
        guard dragTargetDistance > 0 else { return 0 }
        let a = parameters.dragCoefficient
        let b = parameters.dragExponent
        let inner = a * (b - 1) * (elapsed - dragC)
        guard inner > 0 else { return 0 }
        return pow(inner, 1 / (1 - b) + 1) / (a * (b - 2)) + dragK
    }

    private func solveDragCurve(distance: Double) {
        let a = parameters.dragCoefficient
        let b = parameters.dragExponent
        let vs = parameters.stopSpeed
        let tS0 = pow(vs, 1 - b) / ((b - 1) * a)
        let d0 = pow(a * (b - 1) * tS0, 1 / (1 - b) + 1) / (a * (b - 2))
        dragK = -(d0 - distance)
        let exponent = 1 / (1 - b) + 1
        let numerator = -dragK * a * (b - 2)
        let inner = pow(numerator, 1 / exponent)
        dragC = -(inner / (a * (b - 1)))
        dragTimeToStop = tS0 + dragC
        baseCurveDuration = 0
        baseDistance = 0
        dragTargetDistance = distance
    }

    // MARK: - Lifecycle

    private func resetAfterAnimation() {
        distanceTotal = 0
        distancePosted = 0
        distanceLeft = 0
        baseDistance = 0
        baseCurveDuration = 0
        totalCurveDuration = 0
        dragTargetDistance = 0
        dragTimeToStop = 0
        elapsed = 0
        lastFrameTime = nil
        dragC = 0
        dragK = 0
        momentumLeft = 0
        momentumStopTime = 0
        isInMomentum = false
        hasProducedDeltas = false
        lastSubCurveWasBase = false
        lastPostedHint = nil
        resetSubPixelators()
    }

    func reset() {
        cancelTimer?()
        cancelTimer = nil
        resetAfterAnimation()
        activeAxis = nil
        activeSign = 0
        intervalSamples.removeAll()
        lastNotchTime = nil
        eventFlags = []
    }

    private func resetSubPixelators() {
        pointSubPixelX.reset()
        pointSubPixelY.reset()
        lineSubPixelX.reset()
        lineSubPixelY.reset()
    }

    private func ensureRunning() {
        guard cancelTimer == nil else { return }
        cancelTimer = schedule?(1 / parameters.framesPerSecond) { [weak self] in
            self?.processFrame()
        }
    }

    private func stop() {
        cancelTimer?()
        cancelTimer = nil
    }

    // MARK: - Production events

    private func postProduction(dx: Double, dy: Double, phase: Phase, flags: CGEventFlags) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0
        ) else { return }

        let lineDX = Int64(lineSubPixelX.delta(dx / 10))
        let lineDY = Int64(lineSubPixelY.delta(dy / 10))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lineDY)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lineDX)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1,
                                   value: Int64((Double(lineDY) * 65_536).rounded()))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2,
                                   value: Int64((Double(lineDX) * 65_536).rounded()))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(Self.directionInvertedField, value: 1)

        if isPostingMomentum {
            let momentumPhase: Int64
            switch phase {
            case .mayBegin: momentumPhase = 0
            case .began: momentumPhase = 1
            case .changed: momentumPhase = 2
            case .ended: momentumPhase = 3
            case .cancelled: momentumPhase = 3
            }
            event.setIntegerValueField(Self.momentumPhaseField, value: momentumPhase)
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        } else {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }

        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: InjectedEvent.tag)
        // 落点保持「当前指针」：滚动按指针底下的窗口路由，事件里的 location 只填字段、
        // 不决定路由（同 ScreenshotScrollCapture 那条注释）。所以「指针停在后台窗口上滚」
        // 天然落到那扇窗，不需要也不该把坐标钉到别处。
        event.location = CGEvent(source: nil)?.location ?? event.location
        let timestamp = event.timestamp
        if let eventSink { eventSink(event, .cgSessionEventTap) } else { event.post(tap: .cgSessionEventTap) }

        // GestureScrollSimulator posts the type-29 companion only for gesture
        // events. Momentum events have scrollPhase=0 and no companion.
        guard !isPostingMomentum else { return }
        guard let gesture = CGEvent(source: nil) else { return }
        gesture.setIntegerValueField(Self.gestureEventTypeField, value: 29)
        gesture.setIntegerValueField(Self.gestureEventSubtypeField, value: 6)
        gesture.setDoubleValueField(Self.gestureDeltaXField, value: dx == 0 ? -0.0 : dx * 1.67)
        gesture.setDoubleValueField(Self.gestureDeltaYField, value: dy == 0 ? -0.0 : dy * 1.67)
        gesture.setIntegerValueField(Self.gesturePhaseField, value: Int64(phase.rawValue))
        gesture.timestamp = timestamp
        gesture.setIntegerValueField(.eventSourceUserData, value: InjectedEvent.tag)
        if let eventSink { eventSink(gesture, .cgSessionEventTap) } else { gesture.post(tap: .cgSessionEventTap) }
    }
}
