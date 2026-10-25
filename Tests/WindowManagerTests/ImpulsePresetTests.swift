//
//  ImpulsePresetTests
//  MacStroke
//
//  瞬时手势在预设面板里的呈现与落库：七块新格子排在既有 68 个绘制预设之后，
//  各自带自己的名字；滚轮上/下必须画成上下方向的滚轮符号，而不是左右箭头
//  （后者会被读成"翻页/横移"）。
//

import XCTest
import AppKit
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
final class ImpulsePresetTests: XCTestCase {

    @MainActor
    func testImpulseTilesFollowTheDrawnPresets() throws {
        let drawn = GestureTemplateProvider.shared.presetPickerEntries
        let entries = drawn.map { PresetGesturePickerPanel.Entry(name: $0.name, stroke: $0.stroke) }
            + ImpulseGesture.allCases.map { PresetGesturePickerPanel.Entry(impulse: $0) }

        XCTAssertEqual(entries.count, drawn.count + ImpulseGesture.allCases.count)

        let window = PresetGesturePickerPanel(triggerButtonNumber: 99).makeWindow(entries: entries)
        let content = try XCTUnwrap(window.contentView)
        let grid = try XCTUnwrap(content.subviews.first {
            $0.identifier?.rawValue == "PresetGestureGrid"
        })
        XCTAssertEqual(grid.subviews.count, entries.count)

        let labels = Set(grid.subviews.compactMap { $0.accessibilityLabel() })
        for gesture in ImpulseGesture.allCases {
            XCTAssertTrue(labels.contains(gesture.displayName),
                          "缺了 \(gesture.displayName) 的格子")
        }
    }

    @MainActor
    func testImpulseTileWindowStillFitsContent() throws {
        let entries = GestureTemplateProvider.shared.presetPickerEntries.map {
            PresetGesturePickerPanel.Entry(name: $0.name, stroke: $0.stroke)
        } + ImpulseGesture.allCases.map { PresetGesturePickerPanel.Entry(impulse: $0) }
        let window = PresetGesturePickerPanel(triggerButtonNumber: 99).makeWindow(entries: entries)
        let content = try XCTUnwrap(window.contentView)
        let grid = try XCTUnwrap(content.subviews.first {
            $0.identifier?.rawValue == "PresetGestureGrid"
        })
        XCTAssertTrue(content.bounds.contains(grid.frame),
                      "grid \(grid.frame) 放不进 content \(content.bounds)")
    }

    /// 候选：左右键、上下滚、中键、按键4、按键5。
    func testAllSevenMouseGesturesAreOffered() {
        XCTAssertEqual(ImpulseGesture.allCases.map(\.displayName),
                       ["Left Button", "Right Button", "Wheel Up", "Wheel Down",
                        "Middle Button", "Button 4", "Button 5"])
    }
}
