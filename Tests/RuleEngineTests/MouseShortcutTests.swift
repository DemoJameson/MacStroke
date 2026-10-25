//
//  MouseShortcutTests
//  MacStroke
//
//  Hot Key 现在也能录鼠标输入。编码必须落在键盘虚拟键码范围之外，旧规则里
//  只有键盘码，解码结果不变；执行端要把这些码还原成真正的滚轮/鼠标事件，
//  而不是去按一个不存在的虚拟键。
//

import XCTest
import CoreGraphics
@testable import RuleEngine
@testable import GestureEngine

final class MouseShortcutTests: XCTestCase {

    // MARK: - Codec

    func testMouseCodesNeverCollideWithKeyboardCodes() {
        // Real macOS virtual key codes stay below 128.
        for input: MouseShortcut in [.button(2), .button(3), .button(4),
                                     .wheel(.up), .wheel(.down),
                                     .wheel(.left), .wheel(.right)] {
            XCTAssertGreaterThanOrEqual(MouseShortcutCodec.code(for: input),
                                        MouseShortcutCodec.buttonBase,
                                        "\(input) 的编码不能落进键盘键码区间")
        }
    }

    func testRoundTripsEveryMouseInput() {
        for input: MouseShortcut in [.button(2), .button(3), .button(4), .button(9),
                                     .wheel(.up), .wheel(.down),
                                     .wheel(.left), .wheel(.right)] {
            let code = MouseShortcutCodec.code(for: input)
            XCTAssertEqual(MouseShortcutCodec.input(forKeyCode: code), input)
        }
    }

    func testKeyboardCodesDecodeAsNoMouseInput() {
        for code: UInt16 in [0, 1, 12, 49, 123, 126, 127] {
            XCTAssertNil(MouseShortcutCodec.input(forKeyCode: code),
                         "键码 \(code) 仍应按键盘处理")
        }
    }

    func testButtonAndWheelRangesAreDisjoint() {
        XCTAssertEqual(MouseShortcutCodec.input(forKeyCode: MouseShortcutCodec.buttonBase),
                       .button(0))
        XCTAssertEqual(MouseShortcutCodec.input(forKeyCode: MouseShortcutCodec.wheelBase),
                       nil, "wheelBase 本身不是有效方向")
        XCTAssertEqual(MouseShortcutCodec.input(forKeyCode: MouseShortcutCodec.wheelBase + 1),
                       .wheel(.up))
    }

    // MARK: - Execution

    private struct Delivery {
        let type: CGEventType
        let buttonNumber: Int64
        let wheel1: Int64
        let wheel2: Int64
        let flags: CGEventFlags
    }

    private var deliveries: [Delivery] = []

    private func execute(_ input: MouseShortcut, flags: UInt = 0) {
        let executor = ActionExecutor()
        executor.eventSink = { [weak self] event, _ in
            self?.deliveries.append(Delivery(
                type: event.type,
                buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
                wheel1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                wheel2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                flags: event.flags
            ))
        }
        executor.execute(.shortcut(keyCode: MouseShortcutCodec.code(for: input), flags: flags))
    }

    override func setUp() {
        super.setUp()
        deliveries = []
    }

    func testMiddleClickPostsDownAndUpWithButtonNumber() {
        execute(.button(2))
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(deliveries[0].type, .otherMouseDown)
        XCTAssertEqual(deliveries[1].type, .otherMouseUp)
        XCTAssertEqual(deliveries[0].buttonNumber, 2)
        XCTAssertEqual(deliveries[1].buttonNumber, 2)
    }

    func testSideButtonKeepsItsRealNumber() {
        execute(.button(4))
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(deliveries[0].buttonNumber, 4)
        XCTAssertEqual(deliveries[1].buttonNumber, 4)
    }

    func testRecordedModifiersAreReplayed() {
        execute(.button(2), flags: 0x80000) // option
        XCTAssertTrue(deliveries.allSatisfy { $0.flags.contains(.maskAlternate) })
    }

    func testKeyboardShortcutStillPostsKeyEvents() {
        // 反向对照：普通键码不能被当成鼠标输入。
        let executor = ActionExecutor()
        var types: [CGEventType] = []
        executor.eventSink = { event, _ in types.append(event.type) }
        executor.execute(.shortcut(keyCode: 49, flags: 0)) // space
        XCTAssertEqual(types, [.keyDown, .keyUp])
    }
}
