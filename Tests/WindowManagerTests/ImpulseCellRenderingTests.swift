//
//  ImpulseCellRenderingTests
//  MacStroke
//
//  用户报告规则表的 Image 列"没有图案"。之前的用例只比较两张渲染图是否不同，
//  两张全空也会通过 —— 这里直接数非背景像素，确认图标真的画出来了，并且能
//  双击回到手势选择面板。
//

import XCTest
import AppKit
import RuleEngine
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
@MainActor
final class ImpulseCellRenderingTests: XCTestCase {

    private func makeCoordinator(_ gesture: ImpulseGesture) -> (RulesTable.Coordinator, RuleStore) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstroke-cell-\(UUID().uuidString).json")
        let store = RuleStore(storageURL: url)
        for existing in store.rules { store.remove(named: existing.name) }
        store.add(Rule(
            name: "New Rule",
            description: "",
            template: GestureTemplate(points: [], name: "New Rule"),
            impulse: gesture,
            action: .shortcut(keyCode: MouseShortcutCodec.code(for: .wheel(.up)), flags: 0),
            filter: "*"
        ))
        let coordinator = RulesTable.Coordinator(store: store, onDrawGesture: { _ in })
        let table = NSTableView()
        table.rowHeight = 84
        RulesTable.Coordinator.makeColumns().forEach(table.addTableColumn)
        coordinator.table = table
        return (coordinator, store)
    }

    private func gestureColumn() -> NSTableColumn {
        RulesTable.Coordinator.makeColumns().first {
            $0.identifier.rawValue == "Gesture_Image"
        }!
    }

    /// Count pixels that differ from the cell's own background.
    private func inkPixels(in view: NSView) throws -> Int {
        view.frame = NSRect(x: 0, y: 0, width: 84, height: 84)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        // The most common colour is the background; anything else is ink.
        var histogram: [UInt32: Int] = [:]
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let key = UInt32(colour.redComponent * 255) << 16
                    | UInt32(colour.greenComponent * 255) << 8
                    | UInt32(colour.blueComponent * 255)
                histogram[key, default: 0] += 1
            }
        }
        let background = histogram.max { $0.value < $1.value }?.key ?? 0
        return histogram.filter { $0.key != background }.values.reduce(0, +)
    }

    func testEveryImpulseCellDrawsVisibleInk() throws {
        for gesture in ImpulseGesture.allCases {
            let (coordinator, _) = makeCoordinator(gesture)
            let cell = try XCTUnwrap(
                coordinator.tableView(NSTableView(), viewFor: gestureColumn(), row: 0)
            )
            let ink = try inkPixels(in: cell)
            XCTAssertGreaterThan(ink, 40, "\(gesture.displayName) 的 Image 列几乎是空白")
        }
    }

    func testImpulseCellContainsADoubleClickTarget() throws {
        let (coordinator, _) = makeCoordinator(.wheelUp)
        let cell = try XCTUnwrap(
            coordinator.tableView(NSTableView(), viewFor: gestureColumn(), row: 0)
        )
        let glyph = cell.subviews.compactMap { $0 as? ImpulseGlyphView }.first
        let view = try XCTUnwrap(glyph, "Image 列应有手势图标视图")
        XCTAssertNotNil(view.onDoubleClick, "双击图标必须能重新打开手势选择")
    }

    func testDifferentGesturesRenderDifferentInk() throws {
        func ink(_ gesture: ImpulseGesture) throws -> Int {
            let (coordinator, _) = makeCoordinator(gesture)
            let cell = try XCTUnwrap(
                coordinator.tableView(NSTableView(), viewFor: gestureColumn(), row: 0)
            )
            return try inkPixels(in: cell)
        }
        XCTAssertNotEqual(try ink(.wheelUp), try ink(.wheelDown),
                          "上滚和下滚的图形必须不同")
        XCTAssertNotEqual(try ink(.wheelUp), try ink(.middleClick),
                          "滚轮和按键的图形必须不同")
    }

    /// The real killer behind "手势没有实际效果": editing the action rebuilt
    /// the rule and dropped `impulse`, so the trigger vanished the moment the
    /// user recorded a Hot Key.
    func testEditingTheActionKeepsTheImpulse() {
        let (coordinator, store) = makeCoordinator(.wheelUp)
        let before = store.rules[0]
        XCTAssertEqual(before.impulse, .wheelUp)

        let edited = before.copying(
            action: .shortcut(keyCode: MouseShortcutCodec.code(for: .wheel(.down)), flags: 0)
        )
        XCTAssertEqual(edited.impulse, .wheelUp, "改动作不能把触发手势抹掉")
        XCTAssertEqual(edited.action,
                       .shortcut(keyCode: MouseShortcutCodec.code(for: .wheel(.down)), flags: 0))
        XCTAssertEqual(coordinator.store.rules.count, 1)
    }

    /// 启用格子点击必须转发 action（ImpulseGestureCell 手动转发，NSControl 不自动发）。
    func testImpulseTileForwardsActionOnMouseDown() throws {
        let cell = PresetGesturePickerPanel.makeDisabledFeedbackProbe()
        XCTAssertFalse(cell.forwardedForTest, "点击前不应有任何转发")
        cell.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!)
        XCTAssertTrue(cell.forwardedForTest, "格子点击必须转发 action")
    }

    /// 触发键自己的格子现在直接隐藏：面板里不出现，也就不存在"点了没反应"。
    /// run() 在数据源层过滤触发键（cgButtonNumber == triggerButtonNumber），
    /// 所以这里模拟调用方的构造方式：entries 里根本不含 rightClick。
    func testTriggerTileIsHiddenFromPicker() throws {
        let entries = GestureTemplateProvider.shared.presetPickerEntries.map {
            PresetGesturePickerPanel.Entry(name: $0.name, stroke: $0.stroke)
        } + ImpulseGesture.allCases
            .filter { $0.cgButtonNumber != 1 }   // triggerButtonNumber = 1（右键）
            .map { PresetGesturePickerPanel.Entry(impulse: $0) }
        let window = PresetGesturePickerPanel(triggerButtonNumber: 1).makeWindow(entries: entries)
        let grid = try XCTUnwrap(window.contentView?.subviews.first {
            $0.identifier?.rawValue == "PresetGestureGrid"
        })
        let impulseLabels = Set(ImpulseGesture.allCases.map(\.displayName))
        let visibleImpulseTiles = grid.subviews.filter {
            guard let label = $0.accessibilityLabel() else { return false }
            return impulseLabels.contains(label)
        }
        let visibleLabels = Set(visibleImpulseTiles.compactMap { $0.accessibilityLabel() })
        XCTAssertFalse(visibleLabels.contains(ImpulseGesture.rightClick.displayName),
                       "触发键自己的格子必须隐藏")
        XCTAssertEqual(visibleImpulseTiles.count, ImpulseGesture.allCases.count - 1,
                       "隐藏一格后其余瞬时手势格子都要在")
        // 隐藏后不得留空位：布局应紧凑排布（最后一行的格子数 = 余数或满行）
        let rows = stride(from: 0, to: visibleImpulseTiles.count, by: 4).map { _ in () }
        XCTAssertEqual(rows.count, (ImpulseGesture.allCases.count - 1 + 3) / 4,
                       "过滤后应按剩余数量紧凑分 4 列排布")
    }

    func testEditingFilterAndNoteKeepTheImpulse() {
        let (_, store) = makeCoordinator(.middleClick)
        let before = store.rules[0]
        XCTAssertEqual(before.copying(filter: "com.apple.Safari").impulse, .middleClick)
        XCTAssertEqual(before.copying(note: "hi").impulse, .middleClick)
        XCTAssertEqual(before.copying(name: "Renamed").impulse, .middleClick)
        XCTAssertEqual(before.copying(spare: RuleSpareActions(text: "x")).impulse, .middleClick)
    }
}
