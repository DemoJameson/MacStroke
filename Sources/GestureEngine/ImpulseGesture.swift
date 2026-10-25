//
//  ImpulseGesture.swift
//  GestureEngine
//
//  Non-drawing gestures: a momentary input that fires once per occurrence
//  while the gesture trigger button is held (wheel notches / tilt, and clicks
//  on the middle and side buttons).
//
//  Lives in GestureEngine — the dependency-free bottom layer — because the
//  event-capture layer names these gestures when it reports them, and
//  RuleEngine names them when it persists and matches rules. Putting the enum
//  above either of them would force a dependency cycle.
//

import Foundation

/// A non-drawing gesture that fires while the trigger button is held:
/// wheel notches / tilt and momentary clicks on other mouse buttons.
public enum ImpulseGesture: String, Codable, CaseIterable, Equatable, Sendable {
    case leftClick
    case rightClick
    case wheelUp
    case wheelDown
    case middleClick
    case button4
    case button5

    /// Display name for the picker and the rules table.
    ///
    /// Deliberately names only the input, not the trigger button: the trigger is
    /// configurable, so "Right + ..." would be wrong for anyone who rebound it.
    public var displayName: String {
        switch self {
        case .leftClick: return "Left Button"
        case .rightClick: return "Right Button"
        case .wheelUp: return "Wheel Up"
        case .wheelDown: return "Wheel Down"
        case .middleClick: return "Middle Button"
        case .button4: return "Button 4"
        case .button5: return "Button 5"
        }
    }

    /// Whether the glyph is a filled circle (dot / digit in a ring). These read
    /// visually heavier than the wheel capsule at the same box size, so views
    /// that lay both types side by side give them a smaller box.
    public var isClickGlyph: Bool {
        cgButtonNumber != nil
    }

    /// CG button number for click impulses; nil for wheel impulses.
    public var cgButtonNumber: Int? {
        switch self {
        case .leftClick: return 0
        case .rightClick: return 1
        case .middleClick: return 2
        case .button4: return 3
        case .button5: return 4
        default: return nil
        }
    }
}
