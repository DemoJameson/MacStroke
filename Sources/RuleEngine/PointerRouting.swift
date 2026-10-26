//
//  PointerRouting.swift
//  MacStroke
//
//  「这一发动作落在哪扇窗上」。
//
//  滚轮手势在按住触发键时可能落在指针下那扇**后台**窗口上：macOS 自己就是把真实滚轮
//  按指针位置派发的（Scroll inactive windows）。但键盘事件只认活跃 App —— 往一个没有
//  焦点的窗口投 ⌘⇧[ 打进去的是前台那一家。所以匹配规则时不能一律按指针下那家挑：
//  动作落在哪，规则就按哪家挑。
//

import Foundation
import GestureEngine

public extension RuleAction {
    /// 这一发动作是否按「指针下那扇窗」落地。
    ///
    /// - 滚轮 / 中键侧键回放：窗口服务按指针位置与坐标派发，与谁有焦点无关 → 是。
    /// - 坐标点击：按坐标打，点下去那一下自己就会把目标变前台 → 是。
    /// - 键盘（快捷键 / 单键 / 文本 / 密码 / AppleScript）：只进活跃 App → 否。
    /// - 粘贴板 / 截图 / 无动作：与窗口无关，用哪家匹配都一样 → 否（按前台，保持老口径）。
    var routesByPointerWindow: Bool {
        switch self {
        case .mouseClick:
            return true
        case .shortcut(let keyCode, _):
            return MouseShortcutCodec.input(forKeyCode: keyCode) != nil
        case .keyPress, .text, .password, .applescript, .copyToClipboard, .screenshot, .none:
            return false
        }
    }
}
