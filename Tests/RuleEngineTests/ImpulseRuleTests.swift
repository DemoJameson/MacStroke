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
