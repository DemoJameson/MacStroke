//
//  ImpulseSelectionTests
//  MacStroke
//
//  「选一个瞬时手势」只该改触发条件。之前它把规则名也改成手势名，再按新名
//  update —— RuleStore 找不到旧名，静默什么都没写，用户看到的就是"点了没反应"。
//  这组用例盯住那个回归。
//

import XCTest
@testable import RuleEngine
@testable import GestureEngine

final class ImpulseSelectionTests: XCTestCase {

    private var url: URL!
    private var store: RuleStore!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macstroke-impulse-\(UUID().uuidString).json")
        store = RuleStore(storageURL: url)
        // 新 store 会播种出厂默认规则；这几条用例只关心自己加的那一条。
        for rule in store.rules { store.remove(named: rule.name) }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func addPendingRule() -> String {
        let name = "New Rule"
        store.add(Rule(
            name: name,
            description: "",
            template: GestureTemplate(points: [], name: name),
            action: .shortcut(keyCode: 49, flags: 0),
            filter: "*"
        ))
        return name
    }

    /// The fix: replacing by the *old* name lands the impulse on the rule.
    func testReplacingByNameCarriesTheImpulseOntoTheRule() {
        let name = addPendingRule()
        let old = store.rules[0]
        let updated = Rule(
            name: old.name,
            description: old.description,
            template: GestureTemplate(points: [], name: old.name),
            impulse: .wheelUp,
            action: old.action,
            filter: old.filter
        )

        XCTAssertTrue(store.replace(named: name, with: updated))
        XCTAssertEqual(store.rules.count, 1, "不能因为改名多出一条规则")
        XCTAssertEqual(store.rules[0].impulse, .wheelUp)
        XCTAssertEqual(store.rules[0].name, "New Rule", "名称不该被手势名顶掉")
        XCTAssertEqual(store.rules[0].action, .shortcut(keyCode: 49, flags: 0),
                       "动作要保持原样")
    }

    /// The bug that was actually shipped: update() keyed on the new name.
    func testUpdateWithNewNameFindsNothing() {
        _ = addPendingRule()
        let ghost = Rule(
            name: "Wheel Up",
            description: "",
            template: GestureTemplate(points: [], name: "x"),
            impulse: .wheelUp,
            action: .shortcut(keyCode: 49, flags: 0),
            filter: "*"
        )
        XCTAssertNil(store.update(ghost), "按新名 update 必然找不到，这正是当初静默失败的根因")
        XCTAssertNil(store.rules[0].impulse)
    }

    func testImpulseRuleMatchesAfterSelection() throws {
        let name = addPendingRule()
        let old = store.rules[0]
        XCTAssertTrue(store.replace(named: name, with: Rule(
            name: old.name,
            description: "",
            template: GestureTemplate(points: [], name: old.name),
            impulse: .wheelDown,
            action: old.action,
            filter: "*"
        )))
        XCTAssertNotNil(store.match(impulse: .wheelDown, bundleID: "com.apple.Safari"))
        XCTAssertNil(store.match(impulse: .wheelUp, bundleID: "com.apple.Safari"))
    }

    func testSelectionSurvivesAReloadFromDisk() throws {
        let name = addPendingRule()
        let old = store.rules[0]
        _ = store.replace(named: name, with: Rule(
            name: old.name,
            description: "",
            template: GestureTemplate(points: [], name: old.name),
            impulse: .button4,
            action: old.action,
            filter: "*"
        ))

        let reloaded = RuleStore(storageURL: url)
        XCTAssertEqual(reloaded.rules[0].impulse, .button4, "必须真的落盘")
    }

    /// 两条同名占位规则（"Double click Modify"）必须各自独立：按行号写入，
    /// 不会因为名字相同而互相覆盖，也不会写到别人身上。
    func testDuplicatePlaceholderNamesStayIndependent() {
        let first = addPendingRule()
        store.add(Rule(
            name: first,   // same placeholder name on purpose
            description: "",
            template: GestureTemplate(points: [], name: first),
            action: .shortcut(keyCode: 0, flags: 0),
            filter: "*"
        ))
        XCTAssertEqual(store.rules.count, 2)
        XCTAssertEqual(store.rules.filter { $0.name == first }.count, 2,
                       "两条规则同名是既有行为，正是不能按名定位的原因")

        // Write only to index 1, through the positional API.
        let target = store.rules[1]
        XCTAssertTrue(store.replace(at: 1, with: Rule(
            name: target.name,
            description: "",
            template: GestureTemplate(points: [], name: target.name),
            impulse: .wheelDown,
            action: target.action,
            filter: target.filter
        )))
        XCTAssertNil(store.rules[0].impulse, "第 0 行不该被动到")
        XCTAssertEqual(store.rules[1].impulse, .wheelDown)
        XCTAssertEqual(store.rules[1].name, first, "占位名保持原样")
    }
}
