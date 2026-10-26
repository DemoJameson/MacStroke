//
//  CursorWindowProbe.swift
//  MacStroke
//
//  「光标底下那扇窗是谁的」。
//
//  滚轮手势要落在光标下那一家，而不是按下触发键时的前台：用户把指针停在后台窗口上滚，
//  期望滚的是那扇窗。macOS 自己就是这么派发真实滚轮的（Scroll inactive windows），
//  所以这一层只回答「是谁」，既不挪焦点、也不挪指针，更不产生任何副作用。
//
//  画轨迹那条路不走这里：它投的是键盘事件，键盘只认活跃 App，换家就得挪焦点、会闪窗。
//  两条路的差别写在 `CanvasManager.handleTriggerMouseDown`。
//
//  取窗口用的是 `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` —— 与
//  Mac Mouse Fix 同一个原语：它按「鼠标按下会命中谁」做真实命中测试，只需要辅助功能授权。
//
//  为什么不改成「枚举一遍全屏窗口再自己筛」：`CGWindowListCopyWindowInfo` 的产出随授权
//  而变 —— 没有「屏幕录制」时，`kCGWindowName` 这类字段会被抹掉，某些受限进程（沙箱里跑的
//  命令行工具实测）甚至一条都拿不到。命中测试先把「是哪一扇」定下来，再对那一扇做单窗查询，
//  只读 ownerPID / ownerName / layer / alpha，不碰需要屏幕录制的字段，授权面最小。
//

import AppKit
import CoreGraphics

/// 屏上一扇窗的归属。字段全部取自窗口服务与应用列表，可离线构造（单测就是这么用的）。
public struct CursorWindowRecord: Equatable {
    /// 窗口号（`kCGWindowNumber`）。用于诊断与「继续往下找」。
    public let windowNumber: Int
    public let pid: pid_t
    public let bundleID: String
    public let ownerName: String
    /// 0 = 普通应用窗；菜单栏 24/25、程序坞 20、桌面 -2147483623 这些都在 0 之外。
    public let layer: Int
    public let alpha: Double

    public init(windowNumber: Int, pid: pid_t, bundleID: String, ownerName: String,
                layer: Int, alpha: Double) {
        self.windowNumber = windowNumber
        self.pid = pid
        self.bundleID = bundleID
        self.ownerName = ownerName
        self.layer = layer
        self.alpha = alpha
    }
}

public enum CursorWindowProbe {

    /// 这一扇窗能不能当「光标下的目标」。
    ///
    /// 三条门槛，缺一不可：
    /// - 不是我们自己的窗：画布、提示、偏好窗都压在最上面，抢过来等于把滚轮喂给自己；
    /// - 层 0：菜单栏 / 程序坞 / 通知中心不是「一扇能滚的窗」；
    /// - 有 bundleID：没有 bundleID 的进程（单文件可执行、部分游戏）匹配不了规则。
    ///
    /// 不要求 `.regular`：后台的 accessory / 没有 Dock 图标的 App 照样能被滚轮滚到，
    /// 那是系统行为，与「能不能把焦点挪过去」无关。
    public static func accepts(_ record: CursorWindowRecord, ownPID: pid_t) -> Bool {
        guard record.pid != ownPID else { return false }
        guard record.layer == 0 else { return false }
        guard record.alpha > 0.01 else { return false }
        guard !record.bundleID.isEmpty else { return false }
        return true
    }

    /// 光标下那扇窗。点在自家窗上、或那扇窗不够格时，继续往下一层找。
    ///
    /// - Parameter point: AppKit 全局坐标（主屏左下原点）—— 与 `MouseEvent.point` 同一把尺，
    ///   也是 `windowNumber(at:)` 要的那套。**不要**传 `kCGWindowBounds` 那套左上原点的值。
    /// - Parameters:
    ///   - windowAt: 命中测试接缝。默认问窗口服务；单测换成字面表，才能钉住
    ///     「自家窗要跳过、继续往下」这条顺序。
    ///   - record: 窗口号 → 记录。同样可注入。
    public static func target(at point: CGPoint,
                              ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
                              windowAt: (CGPoint, Int) -> Int = { point, below in
                                  NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: below)
                              },
                              record: (Int) -> CursorWindowRecord? = CursorWindowProbe.record(forWindowNumber:))
        -> CursorWindowRecord? {
        var below = 0
        // 深度上限只是防呆：每往下走一层都会排除一整段窗口，真实桌面两三层就到底。
        for _ in 0..<16 {
            let number = windowAt(point, below)
            guard number > 0 else { return nil }
            guard let candidate = record(number) else { return nil }
            if accepts(candidate, ownPID: ownPID) { return candidate }
            below = number
        }
        return nil
    }

    /// 把窗口号翻译成一条记录。窗口号来自命中测试，所以这里只需一次单窗查询。
    public static func record(forWindowNumber number: Int) -> CursorWindowRecord? {
        let infos = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number))
            as? [[String: Any]]) ?? []
        guard let info = infos.first else { return nil }
        guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return CursorWindowRecord(
            windowNumber: number,
            pid: pid,
            bundleID: app?.bundleIdentifier ?? "",
            ownerName: (info[kCGWindowOwnerName as String] as? String) ?? app?.localizedName ?? "",
            layer: (info[kCGWindowLayer as String] as? Int) ?? 0,
            alpha: (info[kCGWindowAlpha as String] as? Double) ?? 1
        )
    }
}
