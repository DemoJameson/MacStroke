//
//  AppDelegateTerminateGuardTests
//  MacStroke
//
//  关掉最后一个窗口（绘制手势面板 / 偏好窗）后 macOS 会经 TAL 下发 Quit AppleEvent。
//  只有菜单 Quit 是用户主动退出；其余 terminate 请求必须被取消，否则托盘 app 静默退出。
//

import XCTest
import WindowManager

final class AppDelegateTerminateGuardTests: XCTestCase {
    func testMenuQuitTerminates() {
        XCTAssertEqual(AppTerminatePolicy.reply(userInitiated: true), .terminateNow)
    }

    func testWindowClosePathCancelsTerminate() {
        XCTAssertEqual(AppTerminatePolicy.reply(userInitiated: false), .terminateCancel)
    }
}
