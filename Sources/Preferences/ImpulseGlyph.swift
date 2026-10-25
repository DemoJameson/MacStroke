//
//  ImpulseGlyph.swift
//  MacStroke
//
//  The picker tile and the rules-table thumbnail both need the same picture for
//  an impulse gesture. Drawn instead of typed as characters: a scroll wheel is
//  a capsule with a direction arrow inside it, which reads as "roll the wheel
//  up/down" — plain ↑/↓ characters read as page navigation instead.
//

import AppKit
import GestureEngine

enum ImpulseGlyph {
    private enum GlyphSide { case left, right }

    /// The glyph's intrinsic size. Every surface draws at exactly this size so
    /// the picker tile and the rules-table thumbnail are visually identical;
    /// callers centre this box inside whatever space they have.
    static let intrinsicSize = NSSize(width: 26, height: 26)

    /// The box the glyph occupies inside `rect`, centred both ways.
    static func box(in rect: NSRect) -> NSRect {
        NSRect(x: rect.midX - intrinsicSize.width / 2,
               y: rect.midY - intrinsicSize.height / 2,
               width: intrinsicSize.width,
               height: intrinsicSize.height)
    }

    /// Draw the gesture's symbol inside `rect`, centred at intrinsic size.
    static func draw(_ gesture: ImpulseGesture, in rect: NSRect) {
        draw(gesture, inBox: box(in: rect))
    }

    private static func draw(_ gesture: ImpulseGesture, inBox rect: NSRect) {
        switch gesture {
        case .leftClick: drawTriggerButton(.left, in: rect)
        case .rightClick: drawTriggerButton(.right, in: rect)
        case .wheelUp: drawWheel(.up, in: rect)
        case .wheelDown: drawWheel(.down, in: rect)
        case .middleClick: drawButton(2, in: rect)
        case .button4: drawButton(4, in: rect)
        case .button5: drawButton(5, in: rect)
        }
    }

    // MARK: - Trigger buttons

    /// A mouse outline with the pressed button shaded, so "Left Button" and
    /// "Right Button" read as physical buttons rather than abstract circles.
    private static func drawTriggerButton(_ side: GlyphSide, in rect: NSRect) {
        let width: CGFloat = 16
        let height: CGFloat = min(22, rect.height)
        let body = NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                          width: width, height: height)

        let outline = NSBezierPath(roundedRect: body,
                                   xRadius: width / 2, yRadius: width / 2)
        outline.lineWidth = 1.4
        NSColor.secondaryLabelColor.setStroke()
        outline.stroke()

        // Split line between the two halves.
        let split = NSBezierPath()
        split.move(to: NSPoint(x: body.midX, y: body.maxY))
        split.line(to: NSPoint(x: body.midX, y: body.midY - height * 0.18))
        split.lineWidth = 1
        NSColor.tertiaryLabelColor.setStroke()
        split.stroke()

        // Shade the pressed half.
        let pressed = NSRect(x: side == .left ? body.minX + 1 : body.midX,
                             y: body.minY + 1,
                             width: width / 2 - 1, height: height - 2)
        let pressedPath = NSBezierPath(roundedRect: pressed,
                                       xRadius: width / 4, yRadius: width / 4)
        NSColor.labelColor.withAlphaComponent(0.35).setFill()
        pressedPath.fill()

        // Re-stroke the outline above the shading.
        outline.lineWidth = 1.4
        NSColor.secondaryLabelColor.setStroke()
        outline.stroke()
    }

    // MARK: - Wheel

    /// A vertical scroll wheel with the roll direction inside it. Small ticks
    /// on the rim keep it from reading as a plain arrow in a rounded box.
    private static func drawWheel(_ direction: WheelDirection, in rect: NSRect) {
        // Shorter than the box is tall: the capsule needs to leave room for the
        // caption underneath without crowding it.
        let width: CGFloat = 15
        let height: CGFloat = min(24, rect.height)
        let wheel = NSRect(x: rect.midX - width / 2, y: rect.midY - height / 2,
                           width: width, height: height)

        let capsule = NSBezierPath(roundedRect: wheel,
                                   xRadius: width / 2, yRadius: width / 2)
        capsule.lineWidth = 1.4
        NSColor.secondaryLabelColor.setStroke()
        capsule.stroke()

        // Rim ticks: three short marks per side, like the ridges on a wheel.
        let ticks = NSBezierPath()
        for offset in [-0.28, 0.0, 0.28] as [CGFloat] {
            let y = wheel.midY + height * 0.30 * offset
            ticks.move(to: NSPoint(x: wheel.minX + 1.5, y: y))
            ticks.line(to: NSPoint(x: wheel.minX + 4.0, y: y))
            ticks.move(to: NSPoint(x: wheel.maxX - 4.0, y: y))
            ticks.line(to: NSPoint(x: wheel.maxX - 1.5, y: y))
        }
        ticks.lineWidth = 1
        NSColor.tertiaryLabelColor.setStroke()
        ticks.stroke()

        let sign: CGFloat = direction == .up ? 1 : -1
        let center = NSPoint(x: wheel.midX, y: wheel.midY)
        let tip = NSPoint(x: center.x, y: center.y + sign * height * 0.26)
        let tail = NSPoint(x: center.x, y: center.y - sign * height * 0.26)

        let arrow = NSBezierPath()
        arrow.move(to: tail)
        arrow.line(to: tip)
        arrow.move(to: NSPoint(x: tip.x - 3.4, y: tip.y - sign * 3.6))
        arrow.line(to: tip)
        arrow.line(to: NSPoint(x: tip.x + 3.4, y: tip.y - sign * 3.6))
        arrow.lineWidth = 1.7
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        NSColor.labelColor.setStroke()
        arrow.stroke()
    }

    // MARK: - Buttons

    /// Circled button number: a solid dot for the middle button, a digit for
    /// the side buttons. The ring is deliberately smaller than the wheel
    /// capsule: a filled circle at the same box reads visually heavier.
    private static func drawButton(_ number: Int, in rect: NSRect) {
        let side = min(20, min(rect.width, rect.height))
        let circle = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                            width: side, height: side)

        let ring = NSBezierPath(ovalIn: circle)
        ring.lineWidth = 1.5
        NSColor.secondaryLabelColor.setStroke()
        ring.stroke()

        if number == 2 {
            let dot = NSBezierPath(ovalIn: circle.insetBy(dx: side * 0.33, dy: side * 0.33))
            NSColor.labelColor.setFill()
            dot.fill()
            return
        }

        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: side * 0.52, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let text = "\(number)" as NSString
        let size = text.size(withAttributes: style)
        text.draw(at: NSPoint(x: circle.midX - size.width / 2,
                              y: circle.midY - size.height / 2),
                  withAttributes: style)
    }
}

/// A small view that renders one impulse glyph; the rules table uses it where a
/// drawn gesture would show its stroke thumbnail.
final class ImpulseGlyphView: NSView {
    let gesture: ImpulseGesture

    /// Double-click reopens the gesture picker, matching the drawn-gesture
    /// thumbnail next to it.
    var onDoubleClick: (() -> Void)?

    init(gesture: ImpulseGesture, frame: NSRect) {
        self.gesture = gesture
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(gesture.displayName)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        (window?.effectiveAppearance ?? effectiveAppearance).performAsCurrentDrawingAppearance {
            ImpulseGlyph.draw(gesture, in: bounds)
        }
    }
}
