//
//  CanvasWindowTests.swift
//  MacStroke
//
//  画布窗口对抓屏 API 必须隐身。截图的第一帧是在抬手那一刻同步抓的，而 `orderOut`
//  要等 CoreAnimation 事务提交才从窗口服务的合成里消失（实测：同一轮 runloop 里
//  hide 之后立刻 `CGDisplayCreateImage`，轨迹线一个像素都没少），所以靠先后顺序追不上，
//  只能让画布压根不参与采集。
//

import AppKit
import XCTest
@testable import EventCapture

final class CanvasWindowTests: XCTestCase {

    func testGestureCanvasIsInvisibleToScreenCapture() {
        _ = NSApplication.shared
        let window = CanvasWindow(screenFrame: NSRect(x: 0, y: 0, width: 320, height: 240))

        XCTAssertEqual(window.sharingType, .none,
                       "轨迹画布一旦被抓屏拍到，就会被冻进截图的第一帧")
    }

    /// disableMousePath 关掉后正常手势不画；但「画新触发器」的录制态必须无视
    /// 这个开关 —— 录制时看不见轨迹等于盲画。
    func testMousePathToggleStillShowsThePathWhileRecording() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let originalToggle = defaults.object(forKey: "disableMousePath")
        let originalRecording = defaults.object(forKey: "macStrokeRecordingGesture")
        defer {
            if let originalToggle { defaults.set(originalToggle, forKey: "disableMousePath") }
            else { defaults.removeObject(forKey: "disableMousePath") }
            if let originalRecording { defaults.set(originalRecording, forKey: "macStrokeRecordingGesture") }
            else { defaults.removeObject(forKey: "macStrokeRecordingGesture") }
        }

        let manager = CanvasManager()
        defer { manager.cancelStroke() }

        defaults.set(true, forKey: "disableMousePath")

        // 录制态：窗口可见时必须画。
        manager.isRecordingGesture = true
        let recordingWindow = CanvasWindow(screenFrame: NSRect(x: 0, y: 0, width: 320, height: 240))
        recordingWindow.show()
        recordingWindow.canvasView.updateColorFromDefaults()
        recordingWindow.canvasView.addPoint(CGPoint(x: 10, y: 10))
        recordingWindow.canvasView.addPoint(CGPoint(x: 200, y: 100))
        recordingWindow.canvasView.displayIfNeeded()
        let recordingImage = snapshot(recordingWindow)
        XCTAssertGreaterThan(recordingImage, 0.005,
                             "录制手势时即使关了鼠标路径，轨迹也必须画出来")

        // 普通手势：同一开关下不画。
        manager.isRecordingGesture = false
        let normalWindow = CanvasWindow(screenFrame: NSRect(x: 0, y: 0, width: 320, height: 240))
        normalWindow.show()
        normalWindow.canvasView.updateColorFromDefaults()
        normalWindow.canvasView.addPoint(CGPoint(x: 10, y: 10))
        normalWindow.canvasView.addPoint(CGPoint(x: 200, y: 100))
        normalWindow.canvasView.displayIfNeeded()
        let normalImage = snapshot(normalWindow)
        XCTAssertLessThan(normalImage, 0.005,
                          "关闭鼠标路径后，普通手势不得再画轨迹")
    }

    /// 轨迹像素占整窗白色背景的比例：画布是透明窗，数非透明像素即可。
    private func snapshot(_ window: CanvasWindow) -> Double {
        guard let contentView = window.contentView else { return 0 }
        let size = contentView.bounds.size
        guard size.width > 0, size.height > 0 else { return 0 }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        contentView.layer?.render(in: NSGraphicsContext.current!.cgContext)
        NSGraphicsContext.restoreGraphicsState()

        var opaque = 0
        var total = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                total += 1
                if color.alphaComponent > 0.01 { opaque += 1 }
            }
        }
        return total == 0 ? 0 : Double(opaque) / Double(total)
    }
}
