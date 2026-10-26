//
//  RulesTableControlAlignmentTests
//  MacStroke
//
//  用户截图反馈：规则页 Type / Action 两格没有和 Gesture / Filter / Description
//  三个输入框垂直对齐。原因是一行里五种控件各用了一套 frame —— 文本框 25pt@30、
//  Type 下拉框 27pt@25、Action 录制框 25pt@27 —— 中心相差最多 4pt。这里钉住
//  「同一行所有控件同一高度、同一中线」，防止以后再各调各的。
//

import XCTest
import AppKit
import RuleEngine
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
@MainActor
final class RulesTableControlAlignmentTests: XCTestCase {

    private func makeCoordinator(action: RuleAction) -> RulesTable.Coordinator {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstroke-align-\(UUID().uuidString).json")
        let store = RuleStore(storageURL: url)
        for existing in store.rules { store.remove(named: existing.name) }
        store.add(Rule(
            name: "Next Tab",
            description: "Next Tab",
            template: GestureTemplate(points: [], name: "Next Tab"),
            impulse: nil,
            action: action,
            filter: "*"
        ))
        let coordinator = RulesTable.Coordinator(store: store, onDrawGesture: { _ in })
        let table = NSTableView()
        table.rowHeight = 84
        RulesTable.Coordinator.makeColumns().forEach(table.addTableColumn)
        coordinator.table = table
        return coordinator
    }

    private func column(_ identifier: String) -> NSTableColumn {
        RulesTable.Coordinator.makeColumns().first { $0.identifier.rawValue == identifier }!
    }

    private func cell(_ coordinator: RulesTable.Coordinator,
                      _ identifier: String) throws -> NSView {
        let view = try XCTUnwrap(
            coordinator.tableView(NSTableView(), viewFor: column(identifier), row: 0),
            "\(identifier) 列应生成单元格"
        )
        view.frame = NSRect(x: 0, y: 0, width: column(identifier).width, height: 84)
        return view
    }

    private func onlySubview(_ cell: NSView, as type: AnyClass) throws -> NSView {
        try XCTUnwrap(cell.subviews.first { $0.isKind(of: type) },
                      "单元格里应有 \(type)")
    }

    /// 84pt 行里五个控件共用同一个 25pt 高、29.5pt 起始的框。
    func testEveryRowControlSharesTheSameFrame() throws {
        let coordinator = makeCoordinator(action: .shortcut(keyCode: 48, flags: 0))
        var frames: [String: NSRect] = [:]

        for identifier in ["Gesture", "Filter", "Note"] {
            let field = try onlySubview(try cell(coordinator, identifier), as: NSTextField.self)
            frames[identifier] = field.frame
        }
        frames["Type"] = try onlySubview(try cell(coordinator, "Type"), as: NSComboBox.self).frame
        frames["Action"] = try onlySubview(try cell(coordinator, "Action"),
                                           as: ShortcutRecorderView.self).frame

        for (identifier, frame) in frames {
            XCTAssertEqual(frame.height, 25, accuracy: 0.01,
                           "\(identifier) 的高度必须和文本框一致（25pt）")
            XCTAssertEqual(frame.midY, 42, accuracy: 0.01,
                           "\(identifier) 的中线必须落在 84pt 行的中心（42pt），实际 \(frame.midY)")
        }
    }

    /// Type 列要能完整显示最长的两个选项，否则下拉框会被系统按钮挤成
    /// "Screens…" / "Apple Scr…"（回归实测）。
    func testTypeColumnFitsEveryOptionTitle() {
        let column = column("Type")
        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: column.width, height: 25))
        combo.font = .systemFont(ofSize: NSFont.systemFontSize)
        let available = combo.cell!.titleRect(forBounds: combo.bounds).width
        for title in RulesTable.Coordinator.typeTitles {
            let needed = (title as NSString).size(
                withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
            ).width
            XCTAssertGreaterThanOrEqual(available, needed,
                                        "Type 列宽 \(column.width) 放不下「\(title)」")
        }
    }

    /// Action 格的另外三种形态（AppleScript 下拉框、Text/Password 输入框、
    /// Screenshot 说明文字）也要落在同一条中线上。
    func testActionVariantsShareTheSameBaseline() throws {
        let scriptCoordinator = makeCoordinator(action: .applescript(""))
        let scriptCombo = try onlySubview(try cell(scriptCoordinator, "Action"),
                                          as: NSComboBox.self)
        XCTAssertEqual(scriptCombo.frame.height, 25, accuracy: 0.01)
        XCTAssertEqual(scriptCombo.frame.midY, 42, accuracy: 0.01)

        let textCoordinator = makeCoordinator(action: .text("hello"))
        let textField = try onlySubview(try cell(textCoordinator, "Action"), as: NSTextField.self)
        XCTAssertEqual(textField.frame.midY, 42, accuracy: 0.01)

        let screenshotCoordinator = makeCoordinator(action: .screenshot)
        let label = try XCTUnwrap(onlySubview(try cell(screenshotCoordinator, "Action"),
                                              as: NSTextField.self) as? NSTextField)
        XCTAssertEqual(label.frame.midY, 42, accuracy: 0.01)
        XCTAssertTrue(label.cell is VerticallyCenteredLabelCell,
                      "Screenshot 说明文字要按框中心绘制，AppKit label 默认贴顶")
    }

    /// 密码列必须继续用 `NSSecureTextFieldCell` 这一支：换成普通 text cell 后
    /// 静态绘制会按明文画出来（回归实测渲染出 "hunter2"）。同时它的几何要和
    /// 其余列一致。
    func testPasswordColumnKeepsSecureCellAndAlignment() throws {
        let coordinator = makeCoordinator(action: .password("hunter2"))
        let field = try XCTUnwrap(
            onlySubview(try cell(coordinator, "Action"), as: NSTextField.self) as? NSTextField
        )
        XCTAssertTrue(field is NSSecureTextField, "Password 动作必须用 NSSecureTextField")
        XCTAssertTrue(field.cell is NSSecureTextFieldCell,
                      "Password 列必须是 NSSecureTextFieldCell，普通 cell 会明文显示")
        XCTAssertTrue(field.cell is VerticallyCenteredSecureTextFieldCell,
                      "Password 列仍要走垂直居中的安全 cell")
        XCTAssertEqual(field.frame.height, 25, accuracy: 0.01)
        XCTAssertEqual(field.frame.midY, 42, accuracy: 0.01)
    }

    /// Action 列里 Text / Password 两种输入框和录制框同宽，右边不会短一截。
    func testTextAndPasswordActionFieldsMatchRecorderWidth() throws {
        let recorder = try onlySubview(
            try cell(makeCoordinator(action: .shortcut(keyCode: 48, flags: 0)), "Action"),
            as: ShortcutRecorderView.self
        )
        for action in [RuleAction.text("hello"), .password("hunter2")] {
            let field = try onlySubview(
                try cell(makeCoordinator(action: action), "Action"), as: NSTextField.self
            )
            XCTAssertEqual(field.frame.width, recorder.frame.width, accuracy: 0.01,
                           "\(action) 的输入框宽度要和录制框一致")
        }
    }

    /// 渲染验证：Type 下拉框、Action 录制框与 Gesture 文本框的文字墨迹中线相差
    /// 不超过 1.5pt。Filter 列的内容是「*」，墨迹天然偏上，不能拿来当基线。
    func testRenderedInkIsOnOneLine() throws {
        let coordinator = makeCoordinator(action: .shortcut(keyCode: 48, flags: 0))
        var centers: [String: Double] = [:]

        for identifier in ["Gesture", "Type", "Action"] {
            let view = try cell(coordinator, identifier)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = Double(rep.pixelsHigh) / Double(view.bounds.height)
            var rows: [Int] = []
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y) else { continue }
                    if color.brightnessComponent > 0.6 {
                        rows.append(y)
                        break
                    }
                }
            }
            let first = try XCTUnwrap(rows.first, "\(identifier) 应有文字墨迹")
            let last = try XCTUnwrap(rows.last)
            // 位图左上为原点，按实际缩放换算成「距框顶的 pt」。
            centers[identifier] = (Double(first) + Double(last)) / 2 / scale
        }

        let reference = try XCTUnwrap(centers["Gesture"])
        for (identifier, center) in centers where identifier != "Gesture" {
            XCTAssertEqual(center, reference, accuracy: 1.5,
                           "\(identifier) 的文字中线 \(center) 与 Gesture \(reference) 不在同一行")
        }
    }
}
