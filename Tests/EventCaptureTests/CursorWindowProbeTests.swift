//
//  CursorWindowProbeTests
//  MacStroke
//
//  滚轮手势归给「光标下那扇窗」的判定：自家画布要跳过、菜单栏/程序坞不算、
//  没 bundleID 的不算；以及按下触发键那一刻的过滤闸门要看指针下那一家。
//

import XCTest
@testable import EventCapture
@testable import GestureEngine

final class CursorWindowProbeTests: XCTestCase {

    private func record(_ number: Int, pid: pid_t = 42, bundle: String = "com.example.Target",
                        layer: Int = 0, alpha: Double = 1) -> CursorWindowRecord {
        CursorWindowRecord(windowNumber: number, pid: pid, bundleID: bundle,
                           ownerName: "Target", layer: layer, alpha: alpha)
    }

    func testAcceptsOrdinaryWindowOfAnotherApp() {
        XCTAssertTrue(CursorWindowProbe.accepts(record(7), ownPID: 1))
    }

    func testRejectsOwnWindow() {
        XCTAssertFalse(CursorWindowProbe.accepts(record(7, pid: 1), ownPID: 1),
                       "我们自己的画布压在指针上，抢过来等于把滚轮喂给自己")
    }

    func testRejectsNonZeroLayer() {
        XCTAssertFalse(CursorWindowProbe.accepts(record(7, layer: 24), ownPID: 1))
        XCTAssertFalse(CursorWindowProbe.accepts(record(7, layer: 20), ownPID: 1))
    }

    func testRejectsInvisibleWindow() {
        XCTAssertFalse(CursorWindowProbe.accepts(record(7, alpha: 0), ownPID: 1))
    }

    func testRejectsWindowWithoutBundleID() {
        XCTAssertFalse(CursorWindowProbe.accepts(record(7, bundle: ""), ownPID: 1),
                       "没有 bundleID 的进程匹配不了规则")
    }

    // MARK: - 命中顺序

    func testSkipsOwnWindowAndKeepsWalkingDown() {
        // 最上面是我们自己的画布，下面才是用户那扇窗 —— 真实桌面就是这个形状。
        let table: [Int: CursorWindowRecord] = [
            100: record(100, pid: 1, bundle: "com.demojameson.MacStroke"),
            90: record(90, pid: 42, bundle: "tv.rexnow.app"),
        ]
        var asked: [Int] = []
        let hit = CursorWindowProbe.target(
            at: CGPoint(x: 10, y: 10), ownPID: 1,
            windowAt: { _, below in
                asked.append(below)
                switch below {
                case 0: return 100
                case 100: return 90
                default: return 0
                }
            },
            record: { table[$0] }
        )
        XCTAssertEqual(hit?.bundleID, "tv.rexnow.app")
        XCTAssertEqual(asked, [0, 100], "要按窗口号往下走，而不是只看最上面那一扇")
    }

    func testReturnsNilWhenOnlyOurWindowsRemain() {
        let table: [Int: CursorWindowRecord] = [
            100: record(100, pid: 1, bundle: "com.demojameson.MacStroke"),
        ]
        let hit = CursorWindowProbe.target(
            at: .zero, ownPID: 1,
            windowAt: { _, below in below == 0 ? 100 : 0 },
            record: { table[$0] }
        )
        XCTAssertNil(hit)
    }

    func testStopsAtFirstAcceptableWindow() {
        let table: [Int: CursorWindowRecord] = [
            100: record(100, pid: 42, bundle: "com.example.Top"),
            90: record(90, pid: 43, bundle: "com.example.Below"),
        ]
        let hit = CursorWindowProbe.target(
            at: .zero, ownPID: 1,
            windowAt: { _, _ in 100 },
            record: { table[$0] }
        )
        XCTAssertEqual(hit?.bundleID, "com.example.Top", "第一个够格的窗就是答案，不继续往下翻")
    }
}
