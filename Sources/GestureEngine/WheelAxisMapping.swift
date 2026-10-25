//
//  WheelAxisMapping.swift
//  GestureEngine
//
//  macOS rewrites Shift+vertical-scroll before any tap sees it: the event moves
//  to the horizontal axis AND its sign flips. Measured on this machine —
//
//      roll up,   no Shift : deltaY = -1
//      roll up,   Shift    : deltaX = +1
//      roll down, no Shift : deltaY = +1
//
//  So "undo the swap" is swap-then-negate, not a plain swap. Recorder, trigger
//  matcher and executor all go through this one type so the three can never
//  disagree about what a physical roll means.
//

import Foundation

/// A scroll delta in the coordinate space the app actually delivers.
public struct WheelDelta: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// Whether Shift was held, which is what triggered macOS's rewrite.
    public var shifted: Bool

    public init(x: Double, y: Double, shifted: Bool) {
        self.x = x
        self.y = y
        self.shifted = shifted
    }

    /// Undo macOS's Shift rewrite: swap the axes, then flip the sign.
    public var physical: (x: Double, y: Double) {
        guard shifted else { return (x, y) }
        return (-y, -x)
    }

    /// The direction the user physically rolled, or nil when nothing moved.
    public var direction: WheelDirection? {
        let (px, py) = physical
        // Vertical wins ties: a mouse wheel is a vertical input, and a
        // trackpad's sideways swipe is not one of the gestures we offer.
        guard abs(py) > 0, abs(py) >= abs(px) else { return nil }
        // Positive vertical = rolled toward the user (down).
        return py > 0 ? .down : .up
    }

    /// The event to post so the system ends up scrolling in `direction`.
    ///
    /// With Shift held the OS will swap-and-flip what we post, so pre-apply the
    /// same transformation to land back on the intended direction.
    public func postable(for direction: WheelDirection) -> WheelDelta {
        let y: Double = direction == .down ? 1 : -1
        guard shifted else {
            return WheelDelta(x: 0, y: y, shifted: false)
        }
        // Inverse of `physical`: swap-and-flip is its own inverse here.
        return WheelDelta(x: -y, y: 0, shifted: true)
    }
}

/// Marks events MacStroke injected itself, so its own capture tap can pass
/// them through instead of treating them as fresh user gestures.
///
/// Lives in GestureEngine because both the executor (RuleEngine) and the
/// capture tap (EventCapture) need the same value, and this is the only module
/// they both depend on.
public enum InjectedEvent {
    public static let tag: Int64 = 0x4D53_5452_4F4B_45 // "MSTROKE"
}
