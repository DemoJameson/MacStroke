//
//  ImpulseRuleTests
//  MacStroke
//
//  瞬时手势在规则层的行为：精确匹配、遵守启用/黑白名单/应用过滤、与轨迹规则
//  互不干扰；以及 rules.json 的向后兼容（旧文件没有 "impulse" 键）和水平滚动
//  动作的持久化。
//

import XCTest
@testable import RuleEngine
@testable import GestureEngine

final class ImpulseRuleTests: XCTestCase {

    private func impulseRule(
        _ gesture: ImpulseGesture,
        name: String? = nil,
        action: RuleAction = .keyPress("space"),
        filter: String = "*",
        filterType: String = "wildcard",
        isEnabled: Bool = true
    ) -> Rule {
        Rule(
            name: name ?? gesture.displayName,
            description: "",
            template: GestureTemplate(points: [], name: gesture.displayName),
            impulse: gesture,
            action: action,
            isEnabled: isEnabled,
            filter: filter,
            filterType: filterType
        )
    }

    private func strokeRule(filter: String = "*") -> Rule {
        Rule(
            name: "S Shape",
            description: "",
            template: GestureTemplate(
                points: (0..<20).map { GesturePoint(x: Double($0), y: Double($0) * 2) },
                name: "S Shape"
            ),
            action: .keyPress("space"),
            filter: filter
        )
    }

    // MARK: - Matching

    func testMatchesEachImpulseExactly() {
        for gesture in ImpulseGesture.allCases {
            let engine = RuleEngine()
            engine.add(contentsOf: ImpulseGesture.allCases.map { impulseRule($0) })

            XCTAssertEqual(engine.match(impulse: gesture, bundleID: "com.apple.Safari")?.impulse,
                           gesture)
        }
    }

    func testDisabledImpulseRuleDoesNotMatch() {
        let engine = RuleEngine()
        engine.add(impulseRule(.wheelUp, isEnabled: false))
        XCTAssertNil(engine.match(impulse: .wheelUp, bundleID: "com.apple.Safari"))
    }

    func testImpulseRuleRespectsBundleFilter() {
        let engine = RuleEngine()
        engine.add(impulseRule(.wheelUp, filter: "com.apple.Safari"))

        XCTAssertNotNil(engine.match(impulse: .wheelUp, bundleID: "com.apple.Safari"))
        XCTAssertNil(engine.match(impulse: .wheelUp, bundleID: "com.google.Chrome"))
    }

    func testStrokeRulesNeverMatchImpulses() {
        let engine = RuleEngine()
        engine.add(strokeRule())
        for gesture in ImpulseGesture.allCases {
            XCTAssertNil(engine.match(impulse: gesture, bundleID: "com.apple.Safari"))
        }
    }

    func testImpulseRulesNeverMatchStrokes() {
        let engine = RuleEngine()
        engine.add(contentsOf: ImpulseGesture.allCases.map { impulseRule($0) })

        var stroke = Stroke(capacity: 20)
        for i in 0..<20 { stroke.addPoint(GesturePoint(x: Double(i), y: Double(i) * 2)) }
        XCTAssertNil(engine.match(stroke: stroke, bundleID: "com.apple.Safari"))
    }

    func testImpulseNameIsStableAndUnique() {
        let names = ImpulseGesture.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "预设名必须唯一，避免插入时互相覆盖")
    }

    // MARK: - 指针归属

    /// 指针停在后台窗口上滚轮：那扇窗的专用规则要能被挑中。
    /// 前台那家没有这条手势的规则时，老口径会一条都不中、滚轮白白交回前台。
    func testPointerWindowRuleWinsForScrollActions() {
        let store = RuleStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-pointer-\(UUID().uuidString).json"))
        store.add(impulseRule(.wheelUp, name: "Front", action: .keyPress("space"),
                              filter: "com.apple.Safari"))
        store.add(impulseRule(.wheelUp, name: "Pointer", action: .shortcut(
            keyCode: MouseShortcutCodec.code(for: .wheel(.left)), flags: 0),
            filter: "tv.rexnow.app"))

        let rule = store.match(impulse: .wheelUp, pointerBundleID: "tv.rexnow.app",
                               frontBundleID: "com.apple.Safari")
        XCTAssertEqual(rule?.name, "Pointer", "滚轮动作按指针位置落地，规则就该按指针下那家挑")
    }

    /// 行序不该决定胜负：一条 `*` 的全局键盘规则排在前面，也不能顶掉指针下那家的滚轮动作。
    func testCatchAllKeyboardRuleDoesNotShadowThePointerAppsWheelRule() {
        let store = RuleStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-pointer-\(UUID().uuidString).json"))
        store.add(impulseRule(.wheelUp, name: "Global Tabs", action: .shortcut(keyCode: 33,
                                                                              flags: 0x10_0000),
                              filter: "*"))
        store.add(impulseRule(.wheelUp, name: "Scroll Left", action: .shortcut(
            keyCode: MouseShortcutCodec.code(for: .wheel(.left)), flags: 0),
            filter: "tv.rexnow.app"))

        let rule = store.match(impulse: .wheelUp, pointerBundleID: "tv.rexnow.app",
                               frontBundleID: "com.apple.finder")
        XCTAssertEqual(rule?.name, "Scroll Left",
                       "键盘动作进不了后台窗口，不该把指针下那家的滚轮动作顶掉")
    }

    /// 指针那家只有键盘动作的规则时，仍退回前台 —— 键只会打进活跃 App。
    func testPointerKeyboardRuleFallsBackToFront() {
        let store = RuleStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-pointer-\(UUID().uuidString).json"))
        store.add(impulseRule(.wheelUp, name: "Pointer Keys", action: .keyPress("space"),
                              filter: "tv.rexnow.app"))
        store.add(impulseRule(.wheelUp, name: "Front Keys", action: .keyPress("space"),
                              filter: "com.apple.finder"))

        let rule = store.match(impulse: .wheelUp, pointerBundleID: "tv.rexnow.app",
                               frontBundleID: "com.apple.finder")
        XCTAssertEqual(rule?.name, "Front Keys")
    }

    /// 键盘动作只进活跃 App：指针下那家的专用快捷键不能抢前台那家的规则。
    func testPointerWindowRuleIsIgnoredForKeyboardActions() {
        let store = RuleStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-pointer-\(UUID().uuidString).json"))
        store.add(impulseRule(.wheelUp, name: "Front", action: .keyPress("space"),
                              filter: "com.apple.Safari"))
        store.add(impulseRule(.wheelUp, name: "Pointer", action: .keyPress("space"),
                              filter: "tv.rexnow.app"))

        let rule = store.match(impulse: .wheelUp, pointerBundleID: "tv.rexnow.app",
                               frontBundleID: "com.apple.Safari")
        XCTAssertEqual(rule?.name, "Front",
                       "键只进活跃 App；按指针那家挑规则，键却打进前台，等于挑错了规则")
    }

    func testFallsBackToFrontWhenPointerAppHasNoRule() {
        let store = RuleStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-pointer-\(UUID().uuidString).json"))
        store.add(impulseRule(.wheelDown, name: "Front", action: .keyPress("space"), filter: "*"))

        let rule = store.match(impulse: .wheelDown, pointerBundleID: "com.example.Other",
                               frontBundleID: "com.apple.Safari")
        XCTAssertEqual(rule?.name, "Front")
    }

    func testFallsBackToFrontWhenPointerIsUnknown() {
        let store = RuleStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-pointer-\(UUID().uuidString).json"))
        store.add(impulseRule(.wheelDown, name: "Front", action: .keyPress("space"), filter: "*"))

        let rule = store.match(impulse: .wheelDown, pointerBundleID: nil,
                               frontBundleID: "com.apple.Safari")
        XCTAssertEqual(rule?.name, "Front")
    }

    /// 指针那家就是前台那家时不该走两条路各问一遍。
    func testSameAppUsesTheFrontLookup() {
        let store = RuleStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-pointer-\(UUID().uuidString).json"))
        store.add(impulseRule(.wheelUp, name: "Only", action: .keyPress("space"),
                              filter: "com.apple.Safari"))

        let rule = store.match(impulse: .wheelUp, pointerBundleID: "com.apple.Safari",
                               frontBundleID: "com.apple.Safari")
        XCTAssertEqual(rule?.name, "Only")
    }

    /// 指针停在被黑名单排除的 App 上、挑中的是「按指针落地」的动作：谁都不动，
    /// 绝不拿前台的滚轮规则往那家里投。
    func testBlacklistedPointerAppSuppressesTheImpulse() {
        let store = RuleStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-pointer-\(UUID().uuidString).json"))
        store.isAppAllowed = { $0 != "com.example.Blocked" }
        store.add(impulseRule(.wheelUp, name: "Front", action: .shortcut(
            keyCode: MouseShortcutCodec.code(for: .wheel(.left)), flags: 0),
            filter: "com.example.Front"))

        XCTAssertNil(store.match(impulse: .wheelUp, pointerBundleID: "com.example.Blocked",
                                 frontBundleID: "com.example.Front"),
                     "黑名单那家的指针位置不许借前台的规则投动作")
    }

    /// 指针停在被排除的 App 上、但挑中的是键盘动作：照常打前台。
    /// 键只进活跃 App，与指针下那扇窗无关；因为指针恰好压在一个黑名单窗口上就把
    /// 「按住触发键切标签页」整发吞掉，是失灵不是保护。
    func testBlacklistedPointerAppStillAllowsKeyboardActions() {
        let store = RuleStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-pointer-\(UUID().uuidString).json"))
        store.isAppAllowed = { $0 != "com.example.Blocked" }
        store.add(impulseRule(.wheelUp, name: "Front Tabs", action: .shortcut(keyCode: 33,
                                                                             flags: 0x10_0000),
                              filter: "com.example.Front"))

        XCTAssertEqual(store.match(impulse: .wheelUp, pointerBundleID: "com.example.Blocked",
                                   frontBundleID: "com.example.Front")?.name, "Front Tabs")
    }

    /// 指针那家过了名单、只是没有这条手势的规则：才退回前台。
    func testAllowedPointerAppWithoutRuleFallsBackToFront() {
        let store = RuleStore(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("impulse-pointer-\(UUID().uuidString).json"))
        store.isAppAllowed = { _ in true }
        store.add(impulseRule(.wheelUp, name: "Front", action: .keyPress("space"),
                              filter: "com.example.Front"))

        XCTAssertEqual(store.match(impulse: .wheelUp, pointerBundleID: "com.example.Other",
                                   frontBundleID: "com.example.Front")?.name, "Front")
    }

    func testWheelAndCoordinateActionsRouteByPointer() {
        XCTAssertTrue(RuleAction.shortcut(
            keyCode: MouseShortcutCodec.code(for: .wheel(.left)), flags: 0).routesByPointerWindow)
        XCTAssertTrue(RuleAction.shortcut(
            keyCode: MouseShortcutCodec.code(for: .button(4)), flags: 0).routesByPointerWindow)
        XCTAssertTrue(RuleAction.mouseClick(x: 10, y: 10).routesByPointerWindow)
        XCTAssertFalse(RuleAction.keyPress("space").routesByPointerWindow)
        XCTAssertFalse(RuleAction.shortcut(keyCode: 33, flags: 0).routesByPointerWindow)
        XCTAssertFalse(RuleAction.text("hello").routesByPointerWindow)
        XCTAssertFalse(RuleAction.copyToClipboard("x").routesByPointerWindow)
        XCTAssertFalse(RuleAction.screenshot.routesByPointerWindow)
        XCTAssertFalse(RuleAction.none.routesByPointerWindow)
    }

    // MARK: - Persistence

    func testLegacyRuleWithoutImpulseKeyDecodesAsStrokeRule() throws {
        // 3.1.9 写出的规则形状：没有 impulse 键。
        let json = """
        [{
          "direction": "↑",
          "data": [{"x": 0, "y": 0}, {"x": 0, "y": 10}],
          "filter": "*",
          "filterType": 0,
          "actionType": 0,
          "text": "",
          "password": "",
          "shortcut_code": 49,
          "shortcut_flag": 0,
          "note": ""
        }]
        """.data(using: .utf8)!

        let rules = try JSONDecoder().decode([Rule].self, from: json)
        XCTAssertEqual(rules.count, 1)
        XCTAssertNil(rules[0].impulse, "旧规则必须仍按轨迹手势解码")
        XCTAssertEqual(rules[0].name, "↑")
    }

    func testImpulseRuleRoundTrips() throws {
        let original = impulseRule(.button5, action: .keyPress("space"))
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([Rule].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].impulse, .button5)
        XCTAssertEqual(decoded[0].name, "Button 5")
        XCTAssertTrue(decoded[0].template.points.isEmpty)
    }
}
