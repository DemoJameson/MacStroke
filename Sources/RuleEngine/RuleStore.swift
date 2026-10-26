//
//  RuleStore.swift
//  MacStroke
//
//  Persistent storage for gesture matching rules.
//  Supports CRUD operations, filter matching, and JSON serialization.
//

import Foundation
import GestureEngine
import RuleEngine

/// A rule store that manages gesture rules with persistence.
@available(macOS 13.0, *)
public final class RuleStore: ObservableObject {
    /// Process-wide store (original: `[RulesList sharedRulesList]`) so rule
    /// edits made in the preferences window are picked up by gesture matching
    /// immediately instead of only at the next launch.
    public static let shared = RuleStore()

    /// All loaded rules.
    @Published public var rules: [Rule] = []

    /// The file URL for persistent storage.
    private let storageURL: URL

    /// Create a new rule store.
    /// - Parameter storageURL: Path to the JSON rules file (defaults to ~/Library/Application Support/MacStroke/rules.json)
    public init(storageURL: URL? = nil) {
        let url: URL
        if let storageURL = storageURL {
            self.storageURL = storageURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.storageURL = appSupport.appendingPathComponent("MacStroke/rules.json")
        }
        self.rules = []
        load()
    }

    /// All rules.
    public var allRules: [Rule] {
        rules
    }

    /// Enabled rules only.
    public var enabledRules: [Rule] {
        rules.filter { $0.isEnabled }
    }

    /// The number of enabled rules.
    public var enabledRuleCount: Int {
        rules.filter { $0.isEnabled }.count
    }

    /// Get a rule by name.
    public func rule(named name: String) -> Rule? {
        rules.first { $0.name == name }
    }

    /// Add a rule.
    /// - Parameter rule: The rule to add.
    public func add(_ rule: Rule) {
        rules.insert(rule, at: 0)   // original: insertObject:atIndex:0
        save()
    }

    /// Update a rule.
    /// - Parameter rule: The rule to update (must have a name).
    /// - Returns: The updated rule, or nil if not found.
    @discardableResult
    public func update(_ rule: Rule) -> Rule? {
        if let index = rules.firstIndex(where: { $0.name == rule.name }) {
            rules[index] = rule
            save()
            return rules[index]
        }
        return nil
    }

    /// Replace the rule currently stored under `oldName` with `rule`, which may
    /// carry a different name. The rules list is positional (original: rows are
    /// addressed by index), so renaming has to be explicit here or the edit
    /// would silently drop the new values.
    /// - Returns: true when the rule was found and replaced.
    @discardableResult
    public func replace(named oldName: String, with rule: Rule) -> Bool {
        guard let index = rules.firstIndex(where: { $0.name == oldName }) else { return false }
        rules[index] = rule
        save()
        return true
    }

    /// Replace a rule by its position.
    ///
    /// Rules created from the "+" button all start out named "Double click
    /// Modify", so names are not unique and a name-based lookup can silently
    /// edit the wrong row. Callers that already know the row use this instead.
    /// - Returns: true when the index was in range.
    @discardableResult
    public func replace(at index: Int, with rule: Rule) -> Bool {
        guard rules.indices.contains(index) else { return false }
        rules[index] = rule
        save()
        return true
    }

    /// Remove a rule by name.
    /// - Parameter name: The rule name to remove.
    /// - Returns: The removed rule, or nil if not found.
    @discardableResult
    public func remove(named name: String) -> Rule? {
        if let index = rules.firstIndex(where: { $0.name == name }) {
            let removed = rules.remove(at: index)
            save()
            return removed
        }
        return nil
    }

    /// Match a stroke against rules, filtered by the frontmost bundle ID.
    /// - Parameters:
    ///   - stroke: The stroke to test
    ///   - bundleID: The frontmost application's bundle ID ("" when it has none)
    /// - Returns: The matching rule and its similarity score, or nil if no match.
    public func match(stroke: Stroke, bundleID: String) -> (rule: Rule, score: Double)? {
        // Use RuleEngine's match method
        // Create a temporary rule engine with our rules
        let engine = RuleEngine()
        engine.add(contentsOf: rules)
        return engine.match(stroke: stroke, bundleID: bundleID)
    }

    /// Whether any enabled rule's filter matches the given bundle ID
    /// (original: `appSuitedRule:` — gates whether the gesture UI is shown).
    /// Match an impulse gesture exactly against enabled, filter-matching rules.
    ///
    /// 滚轮刻度是高频路径，这里直接遍历本 store 的规则，复用 RuleEngine 的
    /// filter 语义，不再每次调用都全量复制规则建引擎。
    public func match(impulse: ImpulseGesture, bundleID: String) -> Rule? {
        guard isAppAllowed(bundleID) else { return nil }
        return rules.first {
            $0.isEnabled && $0.impulse == impulse
                && engineStub.matchesFilter(filter: $0.filter, type: $0.filterType, bundleID: bundleID)
        }
    }

    /// 黑白名单判据。默认就是 App 共享的那一份；留成属性是为了让「指针那家被排除时
    /// 不许拿前台规则往它身上投」这条能在单测里钉住，而不去动真实的用户名单。
    public var isAppAllowed: (String) -> Bool = {
        BlackWhiteFilter.shared.shouldHookMouseEventForApp($0)
    }

    /// 这一家有没有「按指针落地」的瞬时手势规则（滚轮 / 中键 / 侧键回放）。
    ///
    /// 用来决定「指针停在这扇后台窗上时，要不要为它开一次手势窗口」。门槛与真正匹配时
    /// 一致，所以不会出现「窗口开了、滚轮却一条都匹配不上」的空转：
    /// - 只配了轨迹规则的后台窗不开（轨迹动作仍按前台匹配）；
    /// - 只有键盘动作的也不开（键只进活跃 App，见 `RuleAction.routesByPointerWindow`）。
    public func hasPointerRoutedImpulseRule(bundleID: String) -> Bool {
        guard isAppAllowed(bundleID) else { return false }
        return rules.contains {
            $0.isEnabled && $0.impulse != nil && $0.action.routesByPointerWindow
                && engineStub.matchesFilter(filter: $0.filter, type: $0.filterType, bundleID: bundleID)
        }
    }

    /// 匹配一次瞬时手势，同时拿到「指针下那家」和「前台那家」。
    ///
    /// 指针停在后台窗口上滚轮时，用户要滚的是那扇窗；可键盘动作只进活跃 App。
    /// 所以先按指针下那家找，只有「按指针落地」的动作才采纳它（见
    /// `RuleAction.routesByPointerWindow`），否则退回前台那家 —— 与改动前同一口径。
    /// 指针下没有可归属的窗口时也退回前台。
    public func match(impulse: ImpulseGesture,
                      pointerBundleID: String?,
                      frontBundleID: String) -> Rule? {
        let pointerIsFront = pointerBundleID == nil || pointerBundleID == frontBundleID
        if !pointerIsFront, let pointerBundleID, isAppAllowed(pointerBundleID),
           let pointerRule = firstImpulseRule(gesture: impulse, bundleID: pointerBundleID,
                                              where: { $0.action.routesByPointerWindow }) {
            return pointerRule
        }

        guard let frontRule = match(impulse: impulse, bundleID: frontBundleID) else { return nil }
        // 指针停在一家被黑白名单排除的 App 上、而挑中的又是「按指针落地」的动作：
        // 这一下谁都不动。投出去等于往用户明确排除的家里塞事件，与黑名单语义相反；
        // 返回 nil 让调用方放行原始滚轮，那扇窗照系统行为自己滚。
        //
        // 只否这一档。键盘动作打的是前台，与指针下那扇窗无关 —— 因为指针恰好停在一个
        // 被排除的 App 上就把「按住触发键切标签页」整发吞掉，是另一回事（那是失灵，不是保护）。
        if !pointerIsFront, let pointerBundleID, !isAppAllowed(pointerBundleID),
           frontRule.action.routesByPointerWindow {
            return nil
        }
        return frontRule
    }

    /// 在这一家的规则里找第一条满足 `where` 的瞬时手势。
    ///
    /// 与 `match(impulse:bundleID:)` 的差别只有一处：可以先按动作筛。指针那一路要用它 ——
    /// 一条 `*` 的全局键盘规则（比如「按住右键滚 = 切标签页」）也匹配所有 bundle，
    /// 先按文件名顺序撞上它就会把指针下那家真正想要的滚轮动作顶掉。键盘动作本来也进不了
    /// 后台窗口，筛掉它既不改老语义，也让「App 专用规则」不必靠 rules.json 的行序取胜。
    private func firstImpulseRule(gesture: ImpulseGesture, bundleID: String,
                                  where predicate: (Rule) -> Bool) -> Rule? {
        guard isAppAllowed(bundleID) else { return nil }
        return rules.first {
            $0.isEnabled && $0.impulse == gesture
                && engineStub.matchesFilter(filter: $0.filter, type: $0.filterType, bundleID: bundleID)
                && predicate($0)
        }
    }

    /// matchesFilter 无状态，共享一个空引擎只为复用它的过滤实现。
    private let engineStub = RuleEngine()

    public func appSuitedRule(bundleID: String) -> Bool {
        let engine = RuleEngine()
        engine.add(contentsOf: rules)
        return engine.appSuitedRule(bundleID: bundleID)
    }

    /// Save rules to disk.
    public func save() {
        do {
            let data = try JSONEncoder().encode(rules)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("%@", "[RuleStore] Failed to save rules: \(error)")
        }
    }

    /// The rules in the same JSON form `rules.json` holds, so a configuration
    /// backup can carry them (issue #69).
    public func configurationJSON() throws -> Data {
        try JSONEncoder().encode(rules)
    }

    /// Replace the rules with a backed-up set. A payload that does not parse
    /// throws before anything is written, so a failed import leaves the working
    /// rules alone.
    public func restoreConfiguration(from data: Data) throws {
        rules = try JSONDecoder().decode([Rule].self, from: data)
        save()
    }

    /// Load rules from disk.
    public func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            rules = RuleStore.defaultRules()
            save()
            return
        }
        do {
            let data = try Data(contentsOf: storageURL)
            rules = try JSONDecoder().decode([Rule].self, from: data)
        } catch {
            // The original `reInit` + save replaced an unreadable archive without
            // a second thought; Swift decodes all-or-nothing, so one malformed
            // entry would wipe every hand-written rule. Keep the file instead.
            NSLog("%@", "[RuleStore] Rules file could not be decoded, backed it up and loaded default rules: \(error)")
            backUpUnreadableRules()
            rules = RuleStore.defaultRules()
            save()
            return
        }
        if rules.isEmpty {
            NSLog("%@", "[RuleStore] Existing rules file is empty, loading default rules")
            rules = RuleStore.defaultRules()
            save()
        }
    }

    private func backUpUnreadableRules() {
        let backupURL = storageURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: storageURL, to: backupURL)
    }

    /// Default rules matching the original MacStroke preset configuration
    /// (RulesList.m `reInit`). Shortcut key codes are Carbon virtual key codes;
    /// modifier flags are CGEventFlags raw values.
    public static func defaultRules() -> [Rule] {
        let gestures = GestureTemplateProvider.shared.allTemplatesIncludingReversed()
        let templateByName = Dictionary(uniqueKeysWithValues: gestures.map { ($0.name, $0.stroke) })

        // CGEventFlags raw values for keyboard modifiers.
        let cmd: UInt = 0x100000
        let shift: UInt = 0x20000
        let control: UInt = 0x40000
        let option: UInt = 0x80000
        // Carbon virtual key codes.
        let keyLeftArrow: UInt16 = 123
        let keyRightArrow: UInt16 = 124
        let keyPageUp: UInt16 = 116
        let keyPageDown: UInt16 = 121
        let keyM: UInt16 = 46
        let keyF: UInt16 = 3
        let keyQ: UInt16 = 12
        let keyW: UInt16 = 13
        let keyV: UInt16 = 9
        let keyA: UInt16 = 0
        let keyLeftBracket: UInt16 = 33
        let keyRightBracket: UInt16 = 30

        func rule(
            name: String,
            gesture: String,
            action: RuleAction,
            note: String,
            filter: String = "*",
            filterType: String = "wildcard"
        ) -> Rule {
            let stroke = templateByName[gesture] ?? templateByName["A Shape"]!
            return Rule(
                name: name,
                // Original rules have no separate description: the note doubles
                // as it.
                description: note,
                template: GestureTemplate(from: stroke, name: gesture),
                minSimilarityScore: 30.0,
                action: action,
                note: note,
                isEnabled: true,
                triggerOnEveryMatch: false,
                filter: filter,
                filterType: filterType
            )
        }

        // Original reInit inserts each rule at index 0, so the stored list is
        // the reverse of the declaration order (NextTab first … password last).
        // 截图手势声明在最前面，反转后落在最后一行：原版的 15 条位置不动。
        let list: [Rule] = [
            screenshotRule(),
            rule(
                // Original stores the direction lower-case: "password".
                name: "password",
                gesture: "P Shape Revered",
                action: .password("12345678"),
                note: "input password"
            ),
            rule(
                name: "Email",
                gesture: "M Shape",
                action: .text("mtjo.net@gmail.com"),
                note: "input e-mail"
            ),
            rule(
                name: "Back",
                gesture: "\u{2190}",
                action: .shortcut(keyCode: keyLeftArrow, flags: cmd),
                note: "Back"
            ),
            rule(
                name: "Next",
                gesture: "\u{2192}",
                action: .shortcut(keyCode: keyRightArrow, flags: cmd),
                note: "Next"
            ),
            rule(
                name: "MinSizeAll",
                gesture: "\u{2198}",
                action: .shortcut(keyCode: keyM, flags: cmd | option),
                note: "Min Size All Windows"
            ),
            rule(
                name: "MinSize",
                gesture: "\u{2199}",
                action: .shortcut(keyCode: keyM, flags: cmd),
                note: "Min Size Windows"
            ),
            rule(
                name: "FullScreen",
                gesture: "\u{2197}",
                action: .shortcut(keyCode: keyF, flags: cmd | control),
                note: "Full screen"
            ),
            rule(
                name: "Exit",
                gesture: "L Shape Revered",
                action: .shortcut(keyCode: keyQ, flags: cmd),
                note: "Exit App"
            ),
            rule(
                name: "CloseTab",
                gesture: "L Shape",
                action: .shortcut(keyCode: keyW, flags: cmd),
                note: "Close Tab"
            ),
            rule(
                name: "Paste",
                gesture: "V Shape",
                action: .shortcut(keyCode: keyV, flags: cmd),
                note: "Paste"
            ),
            rule(
                name: "SelectAll",
                gesture: "A Shape",
                action: .shortcut(keyCode: keyA, flags: cmd),
                note: "SelectALL"
            ),
            rule(
                name: "PageUp",
                gesture: "I Shape Revered",
                // Original quirk: RulesList.m passes kVK_PageUp as the flag.
                action: .shortcut(keyCode: keyPageUp, flags: UInt(keyPageUp)),
                note: "PageUp"
            ),
            rule(
                name: "PageDown",
                gesture: "I Shape",
                action: .shortcut(keyCode: keyPageDown, flags: UInt(keyPageDown)),
                note: "PageDown"
            ),
            rule(
                name: "PrevTab",
                gesture: "T Shape Revered",
                action: .shortcut(keyCode: keyLeftBracket, flags: shift | cmd),
                note: "Prev Tab"
            ),
            rule(
                name: "NextTab",
                gesture: "F Shape Revered",
                action: .shortcut(keyCode: keyRightBracket, flags: shift | cmd),
                note: "Next Tab"
            ),
        ]
        return list.reversed()
    }

    /// Check if a rule name already exists.
    /// - Parameters:
    ///   - name: The rule name to check.
    ///   - oldName: A name to ignore, so editing a rule without renaming it
    ///     does not collide with itself (rule names are the UI's row identity).
    /// - Returns: true if another rule already uses this name.
    public func exists(named name: String, excluding oldName: String = "") -> Bool {
        rules.contains { $0.name == name && $0.name != oldName }
    }
}