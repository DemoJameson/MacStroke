// 偏好侧栏那一列曾经凭空多出一个蓝框：打开「完全键盘控制」（系统设置 → 键盘 →
// 键盘导航）后，窗口一出现就把第一行「常规」收作键盘焦点，SwiftUI 的 `.plain`
// Button 仍然会画系统 focus ring，于是在整行外面再描一圈蓝色。
//
// 判据取 SwiftUI 自己插进视图树的焦点环视图（类名含 "FocusRing"），不比对像素：
// 环的粗细、颜色随系统强调色与外观变，像素判据会漂；而「有没有这个视图」正是
// 我们要关掉的那个东西。对照组先证明这条探针能看见环，免得哪天 SwiftUI 改了
// 内部结构、用例变成永远通过的空断言。
import XCTest
import AppKit
import SwiftUI
import Storage
@testable import Preferences

final class PreferencesSidebarFocusTests: XCTestCase {
    private static let suiteName = "MacStrokeTests.SidebarFocus"

    override func tearDown() {
        UserDefaults(suiteName: Self.suiteName)?.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    // MARK: - 对照组：探针本身有效

    /// 裸 `.plain` Button 会带出焦点环视图 —— 修复前的侧栏行就是它。
    func testPlainRowStillProducesTheSystemFocusRing() throws {
        let host = try host(AnyView(VStack(spacing: 1) {
            Button(action: {}) { Text("裸行").frame(width: 180, alignment: .leading) }
                .buttonStyle(.plain)
            Spacer()
        }))
        XCTAssertFalse(focusRingViews(in: host).isEmpty,
                       "SwiftUI 不再为 .plain Button 生成焦点环视图，这条探针已失效，需要换判据")
    }

    // MARK: - 修复后：侧栏不再画环

    /// 侧栏 11 行都不该出现焦点环：选中态本来就由 accent 填充表达。
    /// 只数落在侧栏那一列（宽 216pt）里的环 —— 页面里的按钮、开关本来就有自己的焦点环，
    /// 那是系统该有的行为，不在这次修复的范围。
    func testSidebarRowsDoNotDrawAFocusRing() throws {
        let host = try host(AnyView(PreferencesView(viewModel: makePrefs(), initialTab: .general)))
        let sidebarRings = focusRingViews(in: host)
            .map { $0.convert($0.bounds, to: host) }
            .filter { $0.maxX <= SettingsChrome.sidebarWidth + 1 }
        XCTAssertTrue(sidebarRings.isEmpty,
                      "侧栏仍在画系统焦点框：\(sidebarRings)")
    }

    // MARK: - 测量

    /// SwiftUI 给可聚焦控件的焦点环是一个独立子视图，类名带 FocusRing。
    private func focusRingViews(in host: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).contains("FocusRing") { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(host)
        return found
    }

    private func host(_ root: AnyView) throws -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 660)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { window.orderOut(nil) }
        return host
    }

    private func makePrefs() -> UserPreferences {
        UserPreferences(storage: PreferencesStorage(defaults: UserDefaults(suiteName: Self.suiteName)!))
    }
}
