//
//  AppTerminatePolicy.swift
//  WindowManager
//
//  状态栏常驻应用的 terminate 决策：只有用户从菜单发起的退出才终止。
//  关掉最后一个窗口（绘制手势面板 / 偏好窗）后 LaunchServices 会经 TAL 下发
//  Quit AppleEvent，这类请求必须取消，否则托盘 app 静默退出。
//

import AppKit

public enum AppTerminatePolicy {
    /// terminate 放行决策：userInitiated 仅指菜单 Quit；其余一律取消。
    public static func reply(userInitiated: Bool) -> NSApplication.TerminateReply {
        userInitiated ? .terminateNow : .terminateCancel
    }
}
