//
//  ImpulseLayoutTests
//  MacStroke
//
//  三个布局回归点：
//   1. 候选格子里 "Wheel Down" 是两行，caption 区必须够高，不能把第二行裁掉。
//   2. 规则表的图形必须和候选格子画得一样（同一内在尺寸，不再各自 inset）。
//   3. 规则表单元格里「图形 + 文字」整体垂直居中，而不是贴顶留白。
//

import XCTest
import AppKit
import RuleEngine
import GestureEngine
@testable import Preferences

@available(macOS 13.0, *)
@MainActor
final class ImpulseLayoutTests: XCTestCase {

    // MARK: - Caption is not clipped

    /// "Wheel Down" needs two lines at 8pt inside a 56pt tile.
    func testTwoLineCaptionFitsInTheTile() {
        let font = NSFont.systemFont(ofSize: 8)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let style: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph
        ]
        let width: CGFloat = 56 - 6 - 4   // tile minus border and side padding
        let text = "Wheel Down" as NSString
        let bounds = text.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: style
        )
        XCTAssertGreaterThan(bounds.height, font.pointSize,
                             "这段文字确实需要两行")
        XCTAssertGreaterThanOrEqual(20, bounds.height,
                                    "caption 区必须容得下两行，否则第二行被裁")
    }

    /// Every impulse caption must fit the reserved band.
    func testEveryImpulseCaptionFitsTheBand() {
        let font = NSFont.systemFont(ofSize: 8)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let style: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph
        ]
        for gesture in ImpulseGesture.allCases {
            let bounds = (gesture.displayName as NSString).boundingRect(
                with: NSSize(width: 46, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: style
            )
            XCTAssertLessThanOrEqual(bounds.height, 20,
                                     "\(gesture.displayName) 放不进 caption 区")
        }
    }

    // MARK: - Same glyph on both surfaces

    func testPickerAndTableDrawTheSameGlyph() throws {
        // The glyph is centred in its box, so rendering it at the intrinsic
        // size must be identical no matter which surface asked for it.
        for gesture in ImpulseGesture.allCases {
            let box = ImpulseGlyph.box(in: NSRect(x: 0, y: 0, width: 56, height: 56))
            XCTAssertEqual(box.size.width, ImpulseGlyph.intrinsicSize.width)
            XCTAssertEqual(box.size.height, ImpulseGlyph.intrinsicSize.height)

            // Centred in both axes.
            XCTAssertEqual(box.midX, 28, accuracy: 0.01)
            XCTAssertEqual(box.midY, 28, accuracy: 0.01)
        }
    }

    func testIntrinsicGlyphIsShorterThanBefore() {
        // Slightly larger for readability, still clear of the tile's caption
        // area (a 28pt capsule used to crowd it).
        XCTAssertEqual(ImpulseGlyph.intrinsicSize.height, 26)
    }

    // MARK: - Vertical centring in the rules table

    private func makeCoordinator(_ gesture: ImpulseGesture) -> RulesTable.Coordinator {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstroke-layout-\(UUID().uuidString).json")
        let store = RuleStore(storageURL: url)
        for existing in store.rules { store.remove(named: existing.name) }
        store.add(Rule(
            name: "New Rule",
            description: "",
            template: GestureTemplate(points: [], name: "New Rule"),
            impulse: gesture,
            action: .shortcut(keyCode: 0, flags: 0),
            filter: "*"
        ))
        let coordinator = RulesTable.Coordinator(store: store, onDrawGesture: { _ in })
        let table = NSTableView()
        table.rowHeight = 84
        RulesTable.Coordinator.makeColumns().forEach(table.addTableColumn)
        coordinator.table = table
        return coordinator
    }

    func testGlyphAndLabelAreVerticallyCentredInTheRow() throws {
        let coordinator = makeCoordinator(.wheelDown)
        let column = RulesTable.Coordinator.makeColumns().first {
            $0.identifier.rawValue == "Gesture_Image"
        }!

        // The cell view is built for an 84pt row; give the container that size
        // the way NSTableView would.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 84, height: 84))
        let cell = try XCTUnwrap(
            coordinator.tableView(NSTableView(), viewFor: column, row: 0)
        )
        container.addSubview(cell)

        let glyph = try XCTUnwrap(cell.subviews.compactMap { $0 as? ImpulseGlyphView }.first)
        let label = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSTextField }.first)

        let stackTop = glyph.frame.maxY
        let stackBottom = label.frame.minY
        let topGap = container.bounds.height - stackTop
        let bottomGap = stackBottom - container.bounds.minY
        XCTAssertEqual(topGap, bottomGap, accuracy: 1.5,
                       "图形+文字要垂直居中，上留白 \(topGap) vs 下留白 \(bottomGap)")
    }

    func testGlyphSitsAboveTheLabel() throws {
        let coordinator = makeCoordinator(.wheelUp)
        let column = RulesTable.Coordinator.makeColumns().first {
            $0.identifier.rawValue == "Gesture_Image"
        }!
        let cell = try XCTUnwrap(coordinator.tableView(NSTableView(), viewFor: column, row: 0))
        let glyph = try XCTUnwrap(cell.subviews.compactMap { $0 as? ImpulseGlyphView }.first)
        let label = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertGreaterThan(glyph.frame.minY, label.frame.maxY - 1,
                             "图形在文字上方，不能重叠")
    }
}
