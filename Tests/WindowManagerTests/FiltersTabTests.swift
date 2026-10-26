//
//  FiltersTabTests.swift
//
//  过滤页的两条老毛病（2026-10-26）：
//  ① 两个 NSTextView 只把文字留在自己身上，没有 delegate 回传，@State 永远是空的 ——
//     点「应用规则」就把空串写回 UserDefaults，黑白名单看着像「存不上」。
//  ② 激活那一栏被硬编码成 NSColor.white，深色模式下是一整块白板，和旁边那栏不一致。
//  判据不读实现里的常量：文字走真 delegate 通知，颜色从渲染位图里取，两栏互相比。
//

import AppKit
import SwiftUI
import XCTest
import RuleEngine
import Storage

@testable import Preferences

final class FiltersTabTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.FiltersTab"

    override func setUp() {
        super.setUp()
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func isolatedFilter() -> BlackWhiteFilter {
        BlackWhiteFilter(defaults: UserDefaults(suiteName: Self.suiteName)!)
    }

    private func makePrefs() -> UserPreferences {
        UserPreferences(storage: PreferencesStorage(defaults: UserDefaults(suiteName: Self.suiteName)!))
    }

    // MARK: - 输入必须回到草稿

    /// 在左边那栏真敲一行字：delegate 没接上的话草稿还是空串，「应用规则」就会拿空串覆盖。
    func testTypingIntoTheBlackListEditorReachesTheDraft() throws {
        let filter = isolatedFilter()
        let draft = FiltersDraft(filter: filter)
        let host = try hostFilters(filter: filter, draft: draft, scheme: .light)

        let editors = collectTextViews(in: host)
        XCTAssertEqual(editors.count, 2, "过滤页该有黑名单、白名单两个编辑框")
        let blackEditor = try XCTUnwrap(editors.first)

        blackEditor.string = "com.example.blocked"
        blackEditor.didChangeText()
        spin()

        XCTAssertEqual(draft.blackListText, "com.example.blocked",
                       "编辑框里的字没有回传到草稿，应用规则会把它清掉")
        XCTAssertEqual(draft.whiteListText, "", "白名单那栏不该被带着改")
    }

    /// 应用规则：逐行 trim、丢空行，然后回读持久层 —— 与原版 filterViewApplyClicked: 一致。
    func testApplyPersistsTrimmedLinesAndDropsBlankOnes() throws {
        let filter = isolatedFilter()
        let draft = FiltersDraft(filter: filter)
        draft.blackListText = "  com.example.blocked  \n\ncom.example.*\n   \n"
        draft.whiteListText = "com.example.allowed\n"

        draft.apply(to: filter)

        XCTAssertEqual(draft.blackListText, "com.example.blocked\ncom.example.*",
                       "草稿该回读成落盘后的样子")
        XCTAssertEqual(draft.whiteListText, "com.example.allowed")

        // 换一个实例、同一个 defaults 域读回来，证明真的写进了持久层。
        let reread = isolatedFilter()
        XCTAssertEqual(reread.blackListText, "com.example.blocked\ncom.example.*")
        XCTAssertEqual(reread.whiteListText, "com.example.allowed")
        XCTAssertFalse(reread.shouldHookMouseEventForApp("com.example.blocked"),
                       "写进去的黑名单没生效，匹配侧读的仍是旧值")
    }

    /// 用户在页面上打完字再点应用，整条链路（编辑框 → 草稿 → 持久层）都要通。
    func testTypedTextSurvivesApply() throws {
        let filter = isolatedFilter()
        let draft = FiltersDraft(filter: filter)
        let host = try hostFilters(filter: filter, draft: draft, scheme: .light)

        let editor = try XCTUnwrap(collectTextViews(in: host).first)
        editor.string = "com.example.blocked"
        editor.didChangeText()
        spin()
        draft.apply(to: filter)

        XCTAssertEqual(isolatedFilter().blackListText, "com.example.blocked")
    }

    /// 用户打了字但还没点「应用规则」，切到别的页再回来，字要还在 ——
    /// 原版的两个文本框是常驻的，切页不会丢草稿。
    func testUnappliedEditsSurviveLeavingAndReturningToTheTab() throws {
        let filter = isolatedFilter()
        let prefs = makePrefs()
        let draft = FiltersDraft(filter: filter)
        let host = NSHostingView(rootView: PreferencesView(viewModel: prefs,
                                                          initialTab: .filters,
                                                          filter: filter,
                                                          draft: draft))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 660)
        host.layoutSubtreeIfNeeded()
        spin()

        let editor = try XCTUnwrap(collectTextViews(in: host).first)
        editor.string = "com.example.blocked"
        editor.didChangeText()
        spin()

        NotificationCenter.default.post(name: .macStrokeShowPreferencesTab,
                                        object: PreferencesTab.general.rawValue)
        spin()
        NotificationCenter.default.post(name: .macStrokeShowPreferencesTab,
                                        object: PreferencesTab.filters.rawValue)
        spin()
        host.layoutSubtreeIfNeeded()

        let reopened = try XCTUnwrap(collectTextViews(in: host).first)
        XCTAssertEqual(reopened.string, "com.example.blocked",
                       "切页回来草稿被丢了")
        XCTAssertEqual(filter.blackListText, "", "还没点应用就写盘了")

        draft.apply(to: filter)
        XCTAssertEqual(isolatedFilter().blackListText, "com.example.blocked",
                       "应用后没落到持久层")
    }

    /// 页面重新出现时：没动过就回读持久层（导入配置后能看见新值），
    /// 动过但没应用就保住草稿（原版文本框不会自己清空）。
    func testReappearingPagePicksUpStoredChangesOnlyWhenClean() {
        let filter = isolatedFilter()
        let draft = FiltersDraft(filter: filter)

        filter.blackListText = "com.example.fromImport"
        draft.reloadIfClean(from: filter)
        XCTAssertEqual(draft.blackListText, "com.example.fromImport",
                       "没改过的草稿该跟着持久层走")

        draft.blackListText = "com.example.typed"
        filter.blackListText = "com.example.anotherImport"
        draft.reloadIfClean(from: filter)
        XCTAssertEqual(draft.blackListText, "com.example.typed",
                       "未应用的编辑被外部改动覆盖了")
    }

    // MARK: - 两栏底色必须一致

    /// 深色页面：两栏都跟着页面走，谁也不是那块白板。
    func testBothEditorsShareTheDarkPageBackground() throws {
        let filter = isolatedFilter()
        let host = try hostFilters(filter: filter, draft: FiltersDraft(filter: filter), scheme: .dark)
        let colors = try sampledEditorBackgrounds(in: host)

        XCTAssertEqual(colors.count, 2)
        assertEditorsResolveAppearance(.darkAqua, in: host)
        assertSameColor(colors[0], colors[1], "黑白名单两栏底色不一致")
        XCTAssertLessThan(colors[0].redComponent, 0.5, "深色页面上的编辑框仍是浅底：\(colors[0])")
        XCTAssertLessThan(colors[0].greenComponent, 0.5)
        XCTAssertLessThan(colors[0].blueComponent, 0.5)
    }

    /// 浅色页面反向半边：证明取的是动态色，而不是把深色写死。
    func testBothEditorsShareTheLightPageBackground() throws {
        let filter = isolatedFilter()
        let host = try hostFilters(filter: filter, draft: FiltersDraft(filter: filter), scheme: .light)
        let colors = try sampledEditorBackgrounds(in: host)

        assertSameColor(colors[0], colors[1], "黑白名单两栏底色不一致")
        assertEditorsResolveAppearance(.aqua, in: host)
        XCTAssertGreaterThan(colors[0].redComponent, 0.8, "浅色页面上的编辑框发黑：\(colors[0])")
        XCTAssertGreaterThan(colors[0].greenComponent, 0.8)
        XCTAssertGreaterThan(colors[0].blueComponent, 0.8)
    }

    /// 选中哪一栏只由单选决定：切模式不改变任何一栏的底色。
    func testSwitchingModeDoesNotRepaintEitherEditor() throws {
        let filter = isolatedFilter()
        let prefs = makePrefs()
        let host = try hostFilters(filter: filter, draft: FiltersDraft(filter: filter),
                                   scheme: .dark, viewModel: prefs)
        let before = try sampledEditorBackgrounds(in: host)

        prefs.whiteListMode = true
        spin()
        host.layoutSubtreeIfNeeded()
        let after = try sampledEditorBackgrounds(in: host)

        assertSameColor(before[0], after[0], "切换模式后黑名单栏被重新上色")
        assertSameColor(before[1], after[1], "切换模式后白名单栏被重新上色")
    }

    // MARK: - 取证工具

    private func hostFilters(filter: BlackWhiteFilter,
                             draft: FiltersDraft,
                             scheme: ColorScheme,
                             viewModel: UserPreferences? = nil) throws -> NSHostingView<AnyView> {
        let view = FiltersTabView(viewModel: viewModel ?? makePrefs(), draft: draft, filter: filter)
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        // 窗口外观设成页面配色的反面：即便 SwiftUI 没把页面配色传给代表视图，
        // 编辑框也不该跟着窗口走。实测本机 SwiftUI 会传，所以这条不会因为删掉
        // 页面里的 appearance 固定而变红；它守的是用户能看见的结果（编辑框跟页面，
        // 不跟系统/窗口），而不是某一行实现。
        window.appearance = NSAppearance(named: scheme == .dark ? .aqua : .darkAqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 660)
        host.layoutSubtreeIfNeeded()
        spin()
        return host
    }

    /// 两个编辑框解析出的外观必须是页面的配色，而不是宿主窗口的那一套。
    private func assertEditorsResolveAppearance(_ expected: NSAppearance.Name,
                                               in host: NSView,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        let editors = collectTextViews(in: host)
        XCTAssertEqual(editors.count, 2, "过滤页该有黑名单、白名单两个编辑框", file: file, line: line)
        for editor in editors {
            XCTAssertEqual(editor.effectiveAppearance.name, expected,
                           "编辑框跟着宿主外观走了，没有按页面配色解析", file: file, line: line)
        }
    }

    private func collectTextViews(in view: NSView) -> [NSTextView] {
        var found: [NSTextView] = []
        for sub in view.subviews {
            if let text = sub as? NSTextView { found.append(text) }
            found.append(contentsOf: collectTextViews(in: sub))
        }
        return found
    }

    /// 从渲染位图取每一栏中部的底色。位图是 Retina 像素，按比例换算坐标。
    private func sampledEditorBackgrounds(in host: NSView) throws -> [NSColor] {
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / host.bounds.height

        return try collectTextViews(in: host).map { textView in
            let frame = textView.convert(textView.bounds, to: host)
            // 中部偏左一点，避开滚动条与文字光标。
            let point = CGPoint(x: frame.minX + frame.width * 0.25,
                                y: frame.midY)
            let color = try XCTUnwrap(rep.colorAt(x: Int(point.x * scaleX),
                                                y: Int((host.bounds.height - point.y) * scaleY)),
                                      "取不到编辑框里的像素")
            return try XCTUnwrap(color.usingColorSpace(.sRGB))
        }
    }

    private func assertSameColor(_ a: NSColor, _ b: NSColor, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let delta = abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
        XCTAssertLessThan(delta, 0.06, "\(message)：\(a) vs \(b)", file: file, line: line)
    }

    private func spin() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }
}
