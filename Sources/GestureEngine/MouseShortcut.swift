//
//  MouseShortcut.swift
//  GestureEngine
//
//  The Hot Key action can also carry a mouse input: a wheel notch or a
//  momentary click on the middle / side buttons. Those live in the same
//  `shortcut_code` slot a keyboard shortcut uses, so the recorder, the rule
//  table and `rules.json` keep one representation instead of growing a second
//  action type.
//
//  Real macOS virtual key codes stop below 128, so everything at or above
//  `buttonBase` is unambiguously a mouse input. Old rules only ever contain
//  keyboard codes and decode unchanged.
//

import Foundation

/// A wheel direction, named from the user's point of view: `.up` is the
/// direction content moves, which is what "scroll up" means everywhere else in
/// the app.
public enum WheelDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case up, down, left, right

    /// The digit stored in the shortcut code (`wheelBase + offset`).
    public var offset: UInt16 {
        switch self {
        case .up: return 1
        case .down: return 2
        case .left: return 3
        case .right: return 4
        }
    }

    public init?(offset: UInt16) {
        switch offset {
        case 1: self = .up
        case 2: self = .down
        case 3: self = .left
        case 4: self = .right
        default: return nil
        }
    }
}

/// A mouse input that can stand in for a keyboard shortcut.
public enum MouseShortcut: Equatable {
    /// Middle button (2) or a side button (3, 4, …).
    case button(Int)
    case wheel(WheelDirection)
}

public enum MouseShortcutCodec {
    /// First code reserved for mouse buttons. `wheelBase` follows, leaving room
    /// for plenty of side buttons before the two ranges meet.
    public static let buttonBase: UInt16 = 1000
    public static let wheelBase: UInt16 = 2000

    public static func code(for input: MouseShortcut) -> UInt16 {
        switch input {
        case .button(let number):
            return buttonBase + UInt16(max(0, min(999, number)))
        case .wheel(let direction):
            return wheelBase + direction.offset
        }
    }

    public static func input(forKeyCode code: UInt16) -> MouseShortcut? {
        if code >= wheelBase {
            return WheelDirection(offset: code - wheelBase).map(MouseShortcut.wheel)
        }
        if code >= buttonBase {
            return .button(Int(code - buttonBase))
        }
        return nil
    }
}
