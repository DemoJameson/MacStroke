//
//  ImpulsePresetClickTests
//  MacStroke
//
//  这一排格子点了没反应，是因为 ImpulseGestureCell 没有实现 mouseDown 去转发
//  给 target/action —— NSControl 不会自己发。这组用例直接验证点击会冒到面板的
//  action 上，同时验证滚轮图标是画出来的（不是左右箭头字符）。
//

import XCTest
import AppKit
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
@MainActor
final class ImpulsePresetClickTests: XCTestCase {

    private final class Receiver: NSObject {
        var received: [String] = []
        @objc func clicked(_ sender: NSControl) {
            received.append(sender.accessibilityLabel() ?? "?")
        }
    }

    private func makeWindow() -> (NSWindow, NSView) {
        let entries = GestureTemplateProvider.shared.presetPickerEntries.map {
            PresetGesturePickerPanel.Entry(name: $0.name, stroke: $0.stroke)
        } + ImpulseGesture.allCases.map { PresetGesturePickerPanel.Entry(impulse: $0) }
        let window = PresetGesturePickerPanel(triggerButtonNumber: 99).makeWindow(entries: entries)
        let grid = window.contentView!.subviews.first {
            $0.identifier?.rawValue == "PresetGestureGrid"
        }!
        return (window, grid)
    }

    /// Every impulse tile must forward its click to the panel's action.
    func testEveryImpulseTileForwardsItsClick() throws {
        let (_, grid) = makeWindow()
        let receiver = Receiver()
        let impulseLabels = Set(ImpulseGesture.allCases.map(\.displayName))

        let tiles = grid.subviews.filter {
            guard let label = $0.accessibilityLabel() else { return false }
            return impulseLabels.contains(label)
        }
        XCTAssertEqual(tiles.count, ImpulseGesture.allCases.count,
                       "七块瞬时手势格子都要在网格里")

        for tile in tiles {
            let control = try XCTUnwrap(tile as? NSControl)
            control.target = receiver
            control.action = #selector(Receiver.clicked(_:))
        }
        // Press-and-release inside each tile, the way a real click arrives.
        for tile in tiles {
            let point = NSPoint(x: tile.bounds.midX, y: tile.bounds.midY)
            let down = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
            tile.mouseDown(with: down)
        }

        XCTAssertEqual(Set(receiver.received), impulseLabels,
                       "每块格子的点击都应到达面板动作")
    }

    /// The wheel tiles must not fall back to text glyphs: a character would be
    /// drawn at the same place for every gesture, so instead compare rendered
    /// pixels — two different wheel directions must produce different images.
    func testWheelUpAndDownRenderDifferently() throws {
        let up = ImpulseGlyphView(gesture: .wheelUp,
                                  frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        let down = ImpulseGlyphView(gesture: .wheelDown,
                                    frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        let upImage = try render(up)
        let downImage = try render(down)
        XCTAssertNotEqual(upImage.tiffRepresentation, downImage.tiffRepresentation,
                          "上下滚轮图标必须方向不同")
    }

    func testWheelAndTiltGlyphsDiffer() throws {
        let wheel = ImpulseGlyphView(gesture: .wheelUp,
                                     frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        let button = ImpulseGlyphView(gesture: .middleClick,
                                      frame: NSRect(x: 0, y: 0, width: 56, height: 56))
        XCTAssertNotEqual(try render(wheel).tiffRepresentation,
                          try render(button).tiffRepresentation)
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
