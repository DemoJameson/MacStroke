//
//  BlackWhiteFilterTests.swift
//
//  过滤页「应用规则」最后落到这两个 setter 上。之前它们直接写 UserDefaults.standard，
//  测试没法隔离，也看不出「应用」是否真的把整段文本落盘；现在注入一个 defaults 域，
//  这里钉住落盘、trim/丢空行、以及匹配侧立刻读到新值。
//

import XCTest
@testable import RuleEngine

final class BlackWhiteFilterTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.BlackWhiteFilter"

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func makeFilter() -> BlackWhiteFilter {
        BlackWhiteFilter(defaults: UserDefaults(suiteName: Self.suiteName)!)
    }

    func testTextRoundTripsThroughTheInjectedDomain() {
        let filter = makeFilter()
        filter.blackListText = "com.example.one\ncom.example.two"
        filter.whiteListText = "com.example.allowed"

        let reread = makeFilter()
        XCTAssertEqual(reread.blackListText, "com.example.one\ncom.example.two")
        XCTAssertEqual(reread.whiteListText, "com.example.allowed")
    }

    func testApplyNormalisesLinesLikeTheOriginal() {
        let filter = makeFilter()
        filter.blackListText = "  com.example.one  \n\n   \ncom.example.two\n"
        XCTAssertEqual(filter.blackListText, "com.example.one\ncom.example.two")
    }

    /// 写空串就是「清空」，不是「保持原样」—— 用户删光再应用要真的删掉。
    func testEmptyTextClearsTheStoredList() {
        let filter = makeFilter()
        filter.blackListText = "com.example.one"
        filter.blackListText = ""
        XCTAssertEqual(filter.blackListText, "")
        XCTAssertEqual(makeFilter().blackListText, "")
    }

    func testMatchingUsesTheFreshlyAppliedList() {
        let filter = makeFilter()
        filter.blackListText = "com.example.blocked"
        XCTAssertFalse(filter.shouldHookMouseEventForApp("com.example.blocked"))
        XCTAssertTrue(filter.shouldHookMouseEventForApp("com.example.other"))

        filter.whiteListText = "com.example.allowed"
        UserDefaults(suiteName: Self.suiteName)!.set(true, forKey: "filterIsInWhiteMode")
        XCTAssertTrue(filter.shouldHookMouseEventForApp("com.example.allowed"))
        XCTAssertFalse(filter.shouldHookMouseEventForApp("com.example.other"))
    }

    /// 旧版 blockFilter 迁移走的是同一个 defaults 域，测试里不会碰到真实偏好。
    func testLegacyBlockFilterMigrationUsesTheInjectedDomain() {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.set("com.a|com.b", forKey: "blockFilter")

        let filter = makeFilter()
        filter.compatibleProcedureWithPreviousVersion()

        XCTAssertEqual(filter.blackListText, "com.a\ncom.b")
        XCTAssertNil(defaults.object(forKey: "blockFilter"))
    }
}
