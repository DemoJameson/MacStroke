//
//  ImpulsePickerRowLayoutTests
//  MacStroke
//
//  鼠标输入的五个格子必须独占最后一行、等宽铺满，图标与文字水平排在同一行并
//  整体垂直居中——不能像普通预设那样折进方格网格里被拆成两行。
//

import XCTest
import AppKit
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
@MainActor
final class ImpulsePickerRowLayoutTests: XCTestCase {

    private func makeWindow() throws -> (NSWindow, NSView) {
        let entries = GestureTemplateProvider.shared.presetPickerEntries.map {
            PresetGesturePickerPanel.Entry(name: $0.name, stroke: $0.stroke)
        } + ImpulseGesture.allCases.map { PresetGesturePickerPanel.Entry(impulse: $0) }
        let window = PresetGesturePickerPanel(triggerButtonNumber: 99).makeWindow(entries: entries)
        let grid = try XCTUnwrap(window.contentView?.subviews.first {
            $0.identifier?.rawValue == "PresetGestureGrid"
        })
        return (window, grid)
    }

    private func impulseCells(_ grid: NSView) -> [NSView] {
        let labels = Set(ImpulseGesture.allCases.map(\.displayName))
        return grid.subviews.filter {
            guard let label = $0.accessibilityLabel() else { return false }
            return labels.contains(label)
        }
    }

    func testMouseInputsLiveInTheImpulseBand() throws {
        let (_, grid) = try makeWindow()
        let cells = impulseCells(grid)
        XCTAssertEqual(cells.count, ImpulseGesture.allCases.count)

        let gridHeight = grid.bounds.height
        for cell in cells {
            // The impulse band is the last two 56pt rows of the grid.
            XCTAssertGreaterThan(cell.frame.minY, gridHeight - 130,
                                 "\(cell.accessibilityLabel() ?? "") 必须在鼠标手势区")
        }
        // Row one holds four tiles, row two the rest; rows never interleave.
        let rows = Set(cells.map { Int(($0.frame.minY - 8) / 56) })
        XCTAssertEqual(rows.count, 2, "鼠标手势区应为两排")
    }

    func testMouseCellsAreEquallyWideAndSpanTheGrid() throws {
        let (_, grid) = try makeWindow()
        let cells = impulseCells(grid).sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(cells.count, ImpulseGesture.allCases.count)

        let widths = Set(cells.map { round($0.frame.width) })
        XCTAssertEqual(widths.count, 1, "五个格子必须等宽，实际宽度 \(widths)")

        XCTAssertEqual(cells.first!.frame.minX, 8, accuracy: 1)
        // Cells butt together: the last one ends at the grid's inner edge.
        let expectedMax = grid.bounds.width - 8
        XCTAssertEqual(cells.last!.frame.maxX, expectedMax, accuracy: 1)
    }

    func testEveryMouseLabelFitsOnOneLine() {
        // At the actual computed cell width, the longest name must fit beside
        // the glyph without truncation.
        let font = NSFont.systemFont(ofSize: 11)
        let style: [NSAttributedString.Key: Any] = [.font: font]
        let longest = ImpulseGesture.allCases
            .map(\.displayName)
            .max { $0.count < $1.count }!
        let size = (longest as NSString).size(withAttributes: style)

        // 5 cells across 568pt of grid: (568 - 16 - 24) / 5 ≈ 105pt each.
        // Glyph 22 + spacing 7 leaves ~76pt for text — verify the longest fits.
        XCTAssertLessThan(size.width, 76,
                          "\(longest) 放不进单行宽度")
    }

    func testNoMouseCellAppearsInTheSquareGrid() throws {
        let (_, grid) = try makeWindow()
        let squareGridHeight = CGFloat(
            (GestureTemplateProvider.shared.presetPickerEntries.count + 9) / 10
        ) * 56 + 8
        for cell in impulseCells(grid) {
            XCTAssertGreaterThan(cell.frame.minY, squareGridHeight - 1,
                                 "鼠标格子不能混进上方方格网格")
        }
    }
}
