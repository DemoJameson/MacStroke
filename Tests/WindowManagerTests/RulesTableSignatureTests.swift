//
//  RulesTableSignatureTests
//  MacStroke
//
//  规则表只在签名变化时 reload。选中瞬时手势后 Image 列没跟着变，正是因为
//  impulse 不在签名里 —— 新规则与旧规则签名相同，表就不重绘。
//

import XCTest
import RuleEngine
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
@MainActor
final class RulesTableSignatureTests: XCTestCase {

    private func makeStore() -> RuleStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstroke-sig-\(UUID().uuidString).json")
        return RuleStore(storageURL: url)
    }

    private func rule(_ impulse: ImpulseGesture?) -> Rule {
        Rule(
            name: "New Rule",
            description: "",
            template: GestureTemplate(points: [], name: "New Rule"),
            impulse: impulse,
            action: .shortcut(keyCode: 49, flags: 0),
            filter: "*"
        )
    }

    func testSignatureChangesWhenAnImpulseIsSet() {
        let store = makeStore()
        for existing in store.rules { store.remove(named: existing.name) }
        store.add(rule(nil))
        let table = RulesTable.Coordinator(store: store, onDrawGesture: { _ in })

        let before = table.currentSignature()
        store.replace(named: "New Rule", with: rule(.wheelUp))
        let after = table.currentSignature()

        XCTAssertNotEqual(before, after, "设置了瞬时手势后签名必须变化，否则 Image 不会刷新")
    }

    func testSignatureChangesWhenTheRecordedShortcutChanges() {
        let store = makeStore()
        for existing in store.rules { store.remove(named: existing.name) }
        store.add(rule(nil))
        let table = RulesTable.Coordinator(store: store, onDrawGesture: { _ in })

        let before = table.currentSignature()
        store.replace(named: "New Rule", with: Rule(
            name: "New Rule",
            description: "",
            template: GestureTemplate(points: [], name: "New Rule"),
            action: .shortcut(keyCode: MouseShortcutCodec.code(for: .wheel(.up)), flags: 0),
            filter: "*"
        ))
        let after = table.currentSignature()

        XCTAssertNotEqual(before, after, "录了新的快捷键（含鼠标码）后签名必须变化，否则行不重载")
    }

    /// 三个文本列（名称 / 过滤器 / 备注）必须单行垂直居中：AppKit 的 text cell
    /// 从顶部排版（实测 20pt 框里 ink 中心 16 而不是 20），只有把绘制/编辑区
    /// 下移的自定义 cell 才能真居中（截图反馈的回归）。
    func testTextColumnsRenderSingleLineVerticallyCentered() {
        let store = makeStore()
        let table = RulesTable.Coordinator(store: store, onDrawGesture: { _ in })

        for identifier in ["Gesture", "Filter", "Note"] {
            let field = table.makeField(identifier: identifier, value: "Next Tab", row: 0, width: 100)
            XCTAssertTrue(field.cell is VerticallyCenteredTextFieldCell,
                          "\(identifier) 列必须用垂直居中 cell（录制框样式）")
            XCTAssertTrue(field.usesSingleLineMode,
                          "\(identifier) 列必须单行模式")
            XCTAssertNotEqual(field.cell?.wraps, true,
                              "\(identifier) 列不能开 wrap，wrap 从顶部排版")
            XCTAssertEqual(field.bounds.height, 25,
                           "\(identifier) 列高度对齐录制框（25pt）")
            // 右边缘溢出回归：addTextCell 传入的宽度就是列宽本身（Gesture 98、
            // Filter 138.85、Note 221），不再写死 100/160/400 超出列宽；
            // 文字的左右留白在 cell 内部（horizontalPadding）。
            XCTAssertLessThanOrEqual(Double(field.bounds.width), 100,
                                     "\(identifier) 列宽度不得再写死 160/400 超出列宽")

            // 渲染验证：文字墨迹中心必须落在框中心 ±2px 内
            let rep = field.bitmapImageRepForCachingDisplay(in: field.bounds)!
            field.cacheDisplay(in: field.bounds, to: rep)
            let bg = rep.colorAt(x: 1, y: 1)!
            var rows: [Int] = []
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    if let c = rep.colorAt(x: x, y: y),
                       abs(c.redComponent - bg.redComponent) > 0.03
                        || abs(c.greenComponent - bg.greenComponent) > 0.03
                        || abs(c.blueComponent - bg.blueComponent) > 0.03 {
                        rows.append(y); break
                    }
                }
            }
            if let first = rows.first, let last = rows.last {
                let center = Double(first + last) / 2
                let target = Double(rep.pixelsHigh) / 2
                XCTAssertLessThan(abs(center - target), 4,
                                  "\(identifier) 列文字中心 \(center) 偏离框中心 \(target) 太远")
            }
        }
    }

    /// 有焦点（field editor）与无焦点（静态绘制）的文字位置必须一致：
    /// 静态自绘走 textRect，编辑态 editor 也走同一 textRect。
    func testEditingTextMatchesStaticTextPosition() throws {
        let table = RulesTable.Coordinator(store: makeStore(), onDrawGesture: { _ in })
        let field = table.makeField(identifier: "Gesture", value: "Paste", row: 0, width: 98)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        field.layoutSubtreeIfNeeded()

        // 静态墨迹
        let staticRep = field.bitmapImageRepForCachingDisplay(in: field.bounds)!
        field.cacheDisplay(in: field.bounds, to: staticRep)
        var sMinX = Int.max, sMinY = Int.max, sMaxY = -1
        for y in 4..<(staticRep.pixelsHigh - 4) {
            for x in 4..<(staticRep.pixelsWide - 4) {
                if let c = staticRep.colorAt(x: x, y: y), c.brightnessComponent > 0.6 {
                    sMinX = min(sMinX, x); sMinY = min(sMinY, y); sMaxY = max(sMaxY, y)
                }
            }
        }
        XCTAssertTrue(sMinX < Int.max, "静态态应有文字墨迹")
        let staticLeftPt = Double(sMinX) / 2
        let staticCenterY = Double(sMinY + sMaxY) / 4

        // 编辑态墨迹（field editor 的 layoutManager）
        window.makeFirstResponder(field)
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let lm = editor.layoutManager!
        let range = NSRange(location: 0, length: (editor.string as NSString).length)
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let ink = lm.boundingRect(forGlyphRange: glyphRange, in: editor.textContainer!)
        let editingInField = editor.convert(ink, to: field)

        XCTAssertEqual(editingInField.minX, staticLeftPt, accuracy: 2.0,
                       "编辑态与静态文字左缘必须对齐（误差 ≤2pt）")
        XCTAssertEqual(editingInField.midY, staticCenterY, accuracy: 2.0,
                       "编辑态与静态文字垂直中心必须对齐（误差 ≤2pt）")
    }

    func testSignatureDistinguishesEachImpulse() {
        let store = makeStore()
        for existing in store.rules { store.remove(named: existing.name) }
        store.add(rule(.wheelUp))
        let table = RulesTable.Coordinator(store: store, onDrawGesture: { _ in })

        var seen = Set([table.currentSignature()])
        for gesture in [ImpulseGesture.wheelDown, .middleClick, .button4, .button5] {
            store.replace(named: "New Rule", with: rule(gesture))
            let signature = table.currentSignature()
            XCTAssertTrue(seen.insert(signature).inserted,
                          "\(gesture) 的签名与之前某一条撞了")
        }
    }
}
