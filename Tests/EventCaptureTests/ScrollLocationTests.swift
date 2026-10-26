//
//  ScrollLocationTests
//  MacStroke
//
//  滚轮事件的落点换算：CG（主屏左上原点、y 向下）→ AppKit（主屏左下原点、y 向上）。
//
//  这一手写坏时界面上看不出来 —— 症状只是「滚轮归属悄悄退回前台」，日志里全是
//  `指针下 无`，与「指针本来就在桌面上」长得一模一样。所以用字面数字钉住。
//

import XCTest
import CoreGraphics
import AppKit
@testable import EventCapture

final class ScrollLocationTests: XCTestCase {

    /// 字面数字：主屏高 1296 时，CG y=40（屏幕上方）应翻成 AppKit y=1256（屏幕上方）。
    /// 写成 `H + y` 或忘了翻，这里会直接红。
    func testFlipsYAgainstThePrimaryHeight() {
        let flipped = EventCapture.appKitLocation(CGPoint(x: 100, y: 40), primaryHeight: 1296)
        XCTAssertEqual(flipped.x, 100, accuracy: 0.001)
        XCTAssertEqual(flipped.y, 1256, accuracy: 0.001)
    }

    /// 副屏挂在主屏上方时，CG y 是负数；翻过来必须是比主屏还高的正数。
    /// 这条挡住「顺手用 NSScreen.main 的 frame 做基准」那类改法。
    func testNegativeYOnAScreenAboveThePrimary() {
        let flipped = EventCapture.appKitLocation(CGPoint(x: 20, y: -500), primaryHeight: 1296)
        XCTAssertEqual(flipped.x, 20, accuracy: 0.001)
        XCTAssertEqual(flipped.y, 1796, accuracy: 0.001)
    }

    func testOriginMapsToTheTopOfThePrimaryScreen() {
        let flipped = EventCapture.appKitLocation(.zero, primaryHeight: 1296)
        XCTAssertEqual(flipped, CGPoint(x: 0, y: 1296),
                       "CG 原点在主屏左上角，翻成 AppKit 就是主屏左下原点上方的那个角")
    }

    /// 端到端：`scrollEvent(from:)` 必须把事件自带的落点带出来（x 原样、y 翻转）。
    /// 用事件**自己报回来的**坐标做基准，所以这里验的是「翻没翻对」，不是复述实现。
    func testScrollEventCarriesTheFlippedLocation() {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: 0, wheel2: 0, wheel3: 0) else {
            return XCTFail("could not build a scroll event")
        }
        event.location = CGPoint(x: 100, y: 40)
        let reported = event.location
        let height = Double(NSScreen.screens.first?.frame.height ?? 0)

        let scroll = EventCapture.scrollEvent(from: event)
        guard let location = scroll.location else { return XCTFail("scroll event lost its location") }
        XCTAssertEqual(location.x, reported.x, accuracy: 0.001)
        XCTAssertEqual(location.y, height - Double(reported.y), accuracy: 0.001,
                       "y 必须相对主屏高度翻转；漏翻或加号翻都会在这里红")
    }
}
