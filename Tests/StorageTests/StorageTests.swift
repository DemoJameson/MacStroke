//
//  StorageTests
//  MacStroke
//

import XCTest
@testable import Storage
import EventCapture

final class StorageTests: XCTestCase {

    func getTestDatabasePath() -> String {
        // Create a unique temporary database path for each test
        let tempDir = NSTemporaryDirectory()
        let uuid = UUID().uuidString
        return "\(tempDir)clipboard_test_\(uuid).db"
    }

    /// Regression: raw UserDefaults readers (HistoryClipboardManager) must see
    /// the registered defaults on a fresh install, otherwise the clipboard
    /// monitor never starts (enableHistoryClipboard / clipoardStroageLocal
    /// read as false).
    func testRegisterUserDefaultsDefaults() {
        registerUserDefaultsDefaults()

        let defaults = UserDefaults.standard
        XCTAssertTrue(defaults.bool(forKey: "enableHistoryClipboard"))
        XCTAssertTrue(defaults.bool(forKey: "clipoardStroageLocal"))
        XCTAssertTrue(defaults.bool(forKey: "showGestureNote"))
        XCTAssertTrue(defaults.bool(forKey: "enableLimitTop"))
        XCTAssertEqual(defaults.integer(forKey: "limitTop"), 15)
        XCTAssertEqual(defaults.integer(forKey: "limitSaveDays"), 7)
        XCTAssertEqual(defaults.double(forKey: "minScore"), 85.0)
        XCTAssertEqual(defaults.string(forKey: "userTerminal"), "Terminal")
        XCTAssertEqual(defaults.string(forKey: "historyCilpboardListShortcut"), "keyCode=9, flags=1572864")
    }

    /// 自动检查更新默认关（2026-10-26）。这条判据取 `object(forKey:)` 而不是
    /// `bool(forKey:)`：后者在键不存在时也返回 false，注册域漏写照样能过。
    /// 同时钉住 build_app.sh 的 Info.plist 那一份 —— 两处一起改才生效。
    func testAutomaticUpdateChecksAreOffByDefault() throws {
        registerUserDefaultsDefaults()

        XCTAssertFalse(StorageDefaults.autoCheckUpdates, "默认值必须是关")
        let registered = try XCTUnwrap(UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool,
                                       "SUEnableAutomaticChecks 没进注册域，关于页开关会读成未设置")
        XCTAssertFalse(registered, "注册域里仍是开，默认值没生效")

        // Info.plist 由 build_app.sh 生成，脚本里那份必须和这里一致。
        // 路径从本文件推上去，不依赖 swift test 的当前目录。
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // StorageTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let script = try String(contentsOf: repoRoot.appendingPathComponent("build_app.sh"),
                                encoding: .utf8)
        let key = script.range(of: "<key>SUEnableAutomaticChecks</key>")
        XCTAssertNotNil(key, "build_app.sh 里找不到 SUEnableAutomaticChecks")
        if let key {
            let tail = script[key.upperBound...].prefix(120)
            XCTAssertTrue(tail.contains("<false/>"),
                          "build_app.sh 的 Info.plist 仍写着开：\(tail)")
        }
    }

    /// The default clipboard shortcut parses to ⌘⌥V (original SRShortcut:
    /// keyCode 9, modifierFlags 1572864).
    func testDefaultClipboardShortcutParses() {
        let parsed = ShortcutMonitor.parseShortcut(StorageDefaults.historyCilpboardListShortcut)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.0, 9)      // kVK_ANSI_V
        XCTAssertEqual(parsed?.1, 1572864) // command (0x100000) + option (0x80000)
    }

}