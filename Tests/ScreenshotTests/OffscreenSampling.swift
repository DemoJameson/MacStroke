//
//  OffscreenSampling.swift
//
//  离屏取证位图的取点换算。
//
//  `bitmapImageRepForCachingDisplay(in:)` 给回来的位图跟着屏的 backing scale 走：
//  Retina 上 800×500 点的视图拿到的是 1600×1000 像素，而 `colorAt(x:y:)` 吃的是
//  **像素**坐标。用例里写的坐标全是视图点坐标（和 flipped 视图同向、同单位），
//  直接喂给 `colorAt` 就整体错位一倍 —— 取到的是别的格子，断言要么假失败、要么
//  在纯色区域上空转通过。
//
//  这里按位图自己报的点尺寸换算，非 Retina（1 点 = 1 像素）时是恒等变换，
//  `NSBitmapImageRep(cgImage:)` 造出来的位图（点尺寸 == 像素尺寸）同样不受影响。
//

import AppKit

extension NSBitmapImageRep {
    /// 一个视图点对应多少位图像素。
    var pointScale: CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return CGFloat(pixelsWide) / size.width
    }

    /// 按**视图点坐标**取色；落在位图外返回 nil。
    func color(atPoint point: CGPoint) -> NSColor? {
        let scale = pointScale
        let x = Int((point.x * scale).rounded(.down))
        let y = Int((point.y * scale).rounded(.down))
        guard x >= 0, y >= 0, x < pixelsWide, y < pixelsHigh else { return nil }
        return colorAt(x: x, y: y)
    }

    /// 按视图点坐标取色，并转到 sRGB。
    func srgbColor(atPoint point: CGPoint) -> NSColor? {
        color(atPoint: point)?.usingColorSpace(.sRGB)
    }
}

extension NSBitmapImageRep {
    /// 造一张 1 点 = 1 像素的离屏位图。
    ///
    /// `bitmapImageRepForCachingDisplay(in:)` 的像素尺寸跟着屏的 backing scale 走，
    /// Retina 上会翻倍；而取证用例的坐标与阈值都是按「1 点 = 1 像素」写死并实测标定的。
    /// 这里自己给位图，`cacheDisplay` 照样把视图画进去，比例就钉死成 1:1。
    static func oneToOne(width: Int, height: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil,
                         pixelsWide: max(1, width), pixelsHigh: max(1, height),
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                         isPlanar: false, colorSpaceName: .deviceRGB,
                         bytesPerRow: 0, bitsPerPixel: 0)
    }
}

extension NSView {
    /// 把视图画进一张 1:1 位图（见 `NSBitmapImageRep.oneToOne`）。
    func renderOneToOne() -> NSBitmapImageRep? {
        needsDisplay = true
        layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep.oneToOne(width: Int(bounds.width.rounded()),
                                                     height: Int(bounds.height.rounded())) else {
            return nil
        }
        cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }
}

extension NSBitmapImageRep {
    /// 把一张按 backing scale 渲染出来的成品（如 `ScreenshotComposer` 的 CGImage）画进
    /// 1 点 = 1 像素的位图，让「按点写死」的断言在 Retina 上照样能取点。
    ///
    /// 不直接裁原图：成品是 2x，像素坐标和视图点坐标差一倍，照点取点会取到别的格子。
    static func oneToOne(from image: CGImage, pointSize: NSSize) -> NSBitmapImageRep? {
        guard let bitmap = oneToOne(width: Int(pointSize.width.rounded()),
                                    height: Int(pointSize.height.rounded())),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSImage(cgImage: image, size: pointSize).draw(in: NSRect(origin: .zero, size: pointSize))
        NSGraphicsContext.current = previous
        return bitmap
    }
}
