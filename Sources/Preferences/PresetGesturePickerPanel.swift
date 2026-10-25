//
//  PresetGesturePickerPanel.swift
//  MacStroke
//
//  The "Draw Gesture!" dialog: every preset gesture the original picker offers
//  (8 arrows + 4 box corners and 26 letters, each with a reversed twin = 68)
//  laid out as a one-page grid of thumbnails, so the shape is visible before
//  it is chosen. A single click applies it, hovering replays the drawing order.
//  Drawing on the live overlay still works, which is what the hint text has to
//  spell out.
//

import AppKit
import GestureEngine
import Storage

final class PresetGesturePickerPanel: NSObject, NSWindowDelegate {
    /// What the user clicked, or `nil` when the dialog was dismissed.
    private struct Choice {
        let name: String
        let stroke: Stroke?
        let impulse: ImpulseGesture?
    }

    /// A picker entry: a drawn preset or one of the impulse gestures that fire
    /// while the trigger button is held (button + wheel / momentary buttons).
    struct Entry {
        let name: String
        /// Only drawn presets have a trajectory. `Stroke` traps on an empty
        /// point array, so impulse entries carry nil instead of a blank stroke.
        let stroke: Stroke?
        let impulse: ImpulseGesture?
        /// 仅测试构造用：run() 已在数据源层过滤触发键自身，不渲染禁用格。
        let disabled: Bool

        init(name: String, stroke: Stroke) {
            self.name = name
            self.stroke = stroke
            self.impulse = nil
            self.disabled = false
        }

        init(impulse: ImpulseGesture, disabled: Bool = false) {
            // Localise the caption so the picker reads "Wheel Down" / "Middle
            // Button" like every other label instead of a truncated raw name.
            self.name = L(impulse.displayName)
            self.stroke = nil
            self.impulse = impulse
            self.disabled = disabled
        }
    }

    /// Sized so all 68 presets fit on one page — the grid never scrolls.
    private static let columns = 10
    private static let cellSide: CGFloat = 56
    /// The mouse-input row sits below the drawn presets. Its five labels are
    /// wider than a square stroke tile ("Middle Button" is the longest), so its
    /// cells span the whole grid width equally instead of sharing the square
    /// grid columns.
    private static let impulseCellHeight: CGFloat = 56
    /// Trigger buttons + wheel notches fit one row; the remaining button
    /// clicks wrap onto the next.
    private static let impulseRowCapacity = 4
    private static let gridPadding: CGFloat = 8

    private var window: NSWindow!
    private var cells: [PresetGestureCell] = []
    private var choice: Choice?

    /// Show the grid modally. Returns the preset the user clicked; `nil` when the
    /// dialog was closed or cancelled. A gesture drawn on the live overlay saves
    /// itself, so the caller only has to tell "drew one" apart from "cancelled".
    /// - Parameter triggerButtonNumber: CG number of the current gesture trigger
    ///   button; the matching "… Button" gesture tile is excluded entirely,
    ///   because the trigger press itself can never be the fired input.
    static func pick(triggerButtonNumber: Int) -> (name: String, stroke: Stroke?, impulse: ImpulseGesture?)? {
        let panel = PresetGesturePickerPanel(triggerButtonNumber: triggerButtonNumber)
        guard let choice = panel.run() else { return nil }
        return (choice.name, choice.stroke, choice.impulse)
    }

    private let triggerButtonNumber: Int

    init(triggerButtonNumber: Int = 1) {
        self.triggerButtonNumber = triggerButtonNumber
    }

    private func run() -> Choice? {
        var entries = GestureTemplateProvider.shared.presetPickerEntries.map {
            Entry(name: $0.name, stroke: $0.stroke)
        }
        // 触发键自己的格子直接不进面板：隐藏而不是禁用（禁用会留下空位）。
        entries += ImpulseGesture.allCases
            .filter { $0.cgButtonNumber != triggerButtonNumber }
            .map { Entry(impulse: $0) }
        window = makeWindow(entries: entries)

        // The overlay saves a drawn gesture itself and posts this; close so the
        // caller can tell "drew one" apart from "cancelled".
        let drawnObserver = NotificationCenter.default.addObserver(
            forName: .macStrokeGestureDidRecord, object: nil, queue: .main
        ) { [weak self] _ in
            self?.close()
        }
        defer { NotificationCenter.default.removeObserver(drawnObserver) }

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        _ = NSApp.runModal(for: window)
        // A cell hovered when the dialog closed would otherwise keep replaying.
        cells.forEach { $0.stopReplay() }
        window.orderOut(nil)
        window = nil
        cells = []
        return choice
    }

    // MARK: Window

    func makeWindow(entries: [Entry]) -> NSWindow {
        // The mouse inputs get one dedicated row at the bottom, separate from
        // the square stroke grid above, so they are never split across two
        // partial rows.
        let drawnEntries = entries.filter { $0.impulse == nil }
        let impulseEntries = entries.filter { $0.impulse != nil }
        let drawnRows = (drawnEntries.count + Self.columns - 1) / Self.columns
        let gridWidth = Self.cellSide * CGFloat(Self.columns) + Self.gridPadding * 2
        var gridHeight = Self.cellSide * CGFloat(drawnRows) + Self.gridPadding * 2
        if !impulseEntries.isEmpty {
            let impulseRowCount = (impulseEntries.count + Self.impulseRowCapacity - 1)
                / Self.impulseRowCapacity
            gridHeight += Self.impulseCellHeight * CGFloat(impulseRowCount)
        }
        let contentWidth = gridWidth + 20
        let hintHeight: CGFloat = 84
        let contentHeight = gridHeight + hintHeight + 46

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        // The close button must end the modal session, or the loop never returns.
        window.delegate = self
        // ✕ 关闭时窗口不能被立刻释放：panel.window 强引用 + runModal 返回后还要
        // orderOut/读 choice。默认 isReleasedWhenClosed=true 会把窗口在 close 当场
        // 释放，panel 的强引用变成悬垂指针 —— 点 ✕ 必现 EXC_BAD_ACCESS。
        window.isReleasedWhenClosed = false
        window.title = L("Draw Gesture!")

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))

        let title = NSTextField(labelWithString: L("Draw Gesture!"))
        title.font = .boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 18, y: contentHeight - 30, width: contentWidth - 36, height: 20)

        let hint = NSTextField(labelWithString: L("You can draw a gesture anywhere on the screen, or select the preset gesture below."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 18, y: contentHeight - 50, width: contentWidth - 36, height: 16)

        let clickHint = NSTextField(labelWithString: L("Click a preset gesture to apply it at once"))
        clickHint.font = .systemFont(ofSize: 11)
        clickHint.textColor = .secondaryLabelColor
        clickHint.frame = NSRect(x: 18, y: contentHeight - 66, width: contentWidth - 36, height: 16)

        let header = NSTextField(labelWithString: LFormat("Preset Gestures (%d)", entries.count))
        header.font = .systemFont(ofSize: 11, weight: .medium)
        header.frame = NSRect(x: 18, y: contentHeight - 82, width: 150, height: 14)

        // Without the replay there is no way to tell a preset from its reversed twin.
        let hoverHint = NSTextField(labelWithString: L("Hover a preset to replay how it is drawn"))
        hoverHint.font = .systemFont(ofSize: 11)
        hoverHint.textColor = .secondaryLabelColor
        hoverHint.alignment = .right
        hoverHint.frame = NSRect(x: 174, y: contentHeight - 82,
                                 width: contentWidth - 192, height: 14)

        let grid = FlippedGrid(frame: NSRect(x: 10, y: 46, width: gridWidth, height: gridHeight))
        grid.identifier = NSUserInterfaceItemIdentifier("PresetGestureGrid")
        grid.wantsLayer = true
        grid.layer?.borderColor = NSColor.separatorColor.cgColor
        grid.layer?.borderWidth = 1
        grid.layer?.cornerRadius = 6
        for (index, entry) in drawnEntries.enumerated() {
            let column = index % Self.columns
            let row = index / Self.columns
            let frame = NSRect(x: Self.gridPadding + CGFloat(column) * Self.cellSide,
                               y: Self.gridPadding + CGFloat(row) * Self.cellSide,
                               width: Self.cellSide, height: Self.cellSide)
            guard let stroke = entry.stroke else { continue }
            let cell = PresetGestureCell(stroke: stroke, title: entry.name, frame: frame)
            cell.target = self
            cell.action = #selector(cellClicked(_:))
            grid.addSubview(cell)
            cells.append(cell)
        }

        if !impulseEntries.isEmpty {
            // Impulse tiles live in their own band below the square grid: the
            // two trigger buttons and the wheel notches fill the first row
            // (four tiles), the remaining button clicks wrap onto the next.
            // Cells butt against each other with no extra spacing — each tile
            // insets itself 3pt per side, giving the same 6pt visual gap as
            // the square grid above.
            let rowCapacity = Self.impulseRowCapacity
            let rows = stride(from: 0, to: impulseEntries.count, by: rowCapacity).map {
                Array(impulseEntries[$0..<min($0 + rowCapacity, impulseEntries.count)])
            }
            for (rowIndex, rowEntries) in rows.enumerated() {
                let rowY = Self.gridPadding + Self.cellSide * CGFloat(drawnRows)
                    + Self.impulseCellHeight * CGFloat(rowIndex)
                let cellWidth = (gridWidth - Self.gridPadding * 2) / CGFloat(rowCapacity)
                for (column, entry) in rowEntries.enumerated() {
                    guard let impulse = entry.impulse else { continue }
                    let frame = NSRect(x: Self.gridPadding + CGFloat(column) * cellWidth,
                                       y: rowY, width: cellWidth, height: Self.impulseCellHeight)
                    let cell = ImpulseGestureCell(gesture: impulse, title: entry.name, frame: frame)
                    cell.target = self
                    cell.action = #selector(impulseCellClicked(_:))
                    grid.addSubview(cell)
                }
            }
        }

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: contentWidth - 96, y: 10, width: 86, height: 28)

        [title, hint, clickHint, header, hoverHint, grid, cancel].forEach(content.addSubview)
        window.contentView = content
        return window
    }

    @objc private func cellClicked(_ sender: PresetGestureCell) {
        choice = Choice(name: sender.gestureName, stroke: sender.stroke, impulse: nil)
        close()
    }

    @objc private func impulseCellClicked(_ sender: ImpulseGestureCell) {
        choice = Choice(name: sender.title, stroke: nil, impulse: sender.gesture)
        close()
    }

    /// 测试探针：构造一块 action 指向自身的格子，供禁用反馈用例观测转发。
    static func makeDisabledFeedbackProbe() -> NSControl & ImpulseCellTestProbe {
        let cell = ImpulseGestureCell(
            gesture: .rightClick, title: "Right Button",
            frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        cell.target = cell
        cell.action = #selector(ImpulseGestureCell.probeAction)
        return cell
    }

    @objc private func cancelClicked() {
        choice = nil
        close()
    }

    func windowWillClose(_ notification: Notification) {
        guard choice == nil else { return }
        close()
    }

    private func close() {
        NSApp.stopModal(withCode: choice == nil ? .cancel : .OK)
    }

    private final class FlippedGrid: NSView {
        override var isFlipped: Bool { true }
    }
}

// MARK: - Thumbnail cell

private final class PresetGestureCell: NSControl {
    let gestureName: String
    let stroke: Stroke
    private let points: [CGPoint]
    private lazy var replay = GestureReplayAnimator(view: self)
    private var trackingArea: NSTrackingArea?

    init(stroke: Stroke, title: String, frame: NSRect) {
        self.stroke = stroke
        self.gestureName = title
        self.points = stroke.points.map { CGPoint(x: $0.x, y: $0.y) }
        super.init(frame: frame)
        toolTip = title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let tile = bounds.insetBy(dx: 3, dy: 3)
        let background = NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6)
        background.lineWidth = 1
        let replaying = replay.progress < 1
        if replaying {
            NSColor.selectedControlColor.withAlphaComponent(0.3).setFill()
            background.fill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        background.stroke()

        guard let scaled = scaledPoints(fit: tile.insetBy(dx: 11, dy: 11)) else { return }
        GestureStrokeRenderer.draw(scaled, progress: replay.progress)
    }

    /// Fit the stroke's bounding box into `rect`, keeping its aspect and centring
    /// it — the table cell offsets by 12pt instead because its row is taller.
    private func scaledPoints(fit rect: NSRect) -> [CGPoint]? {
        guard points.count > 1 else { return nil }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let width = abs((xs.max() ?? 0) - (xs.min() ?? 0))
        let height = abs((ys.max() ?? 0) - (ys.min() ?? 0))
        let span = max(width, height)
        guard span > 0 else { return nil }
        let zoom = min(rect.width, rect.height) / span
        let offsetX = rect.midX - (width * zoom) / 2
        let offsetY = rect.midY - (height * zoom) / 2
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return points.map {
            CGPoint(x: ($0.x - minX) * zoom + offsetX, y: ($0.y - minY) * zoom + offsetY)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        replay.start()
    }

    override func mouseExited(with event: NSEvent) {
        replay.stop()
    }

    /// Called when the dialog closes while the pointer still rests on the cell.
    func stopReplay() {
        replay.stop()
    }
}

/// 只为测试暴露 private ImpulseGestureCell 的转发状态（见 ImpulseCellRenderingTests）。
protocol ImpulseCellTestProbe: AnyObject {
    var forwardedForTest: Bool { get set }
}

// MARK: - Impulse cell

/// A picker tile for a gesture that has no trajectory to draw: a button +
/// wheel notch, or a momentary click on the middle / side buttons. It shows a
/// glyph and a two-line caption instead of replaying a stroke.
private final class ImpulseGestureCell: NSControl, ImpulseCellTestProbe {
    let gesture: ImpulseGesture
    let title: String

    init(gesture: ImpulseGesture, title: String, frame: NSRect) {
        self.gesture = gesture
        self.title = title
        super.init(frame: frame)
        toolTip = title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    /// The gesture's own name; the trigger button is not part of it.
    private var caption: String { title }

    override func draw(_ dirtyRect: NSRect) {
        let tile = bounds.insetBy(dx: 3, dy: 3)
        let background = NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6)
        background.lineWidth = 1
        // 与字母手势格（PresetGestureCell）同款描边，两排格子边框观感一致。
        NSColor.separatorColor.setStroke()
        background.stroke()

        // Horizontal layout: glyph on the left, label beside it on one line.
        // The pair is centred vertically as a unit — with a wide cell there is
        // no caption band to reserve, so stacking would leave both elements
        // off-centre.
        let font = NSFont.systemFont(ofSize: 11)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let textSize = (caption as NSString).size(withAttributes: attributes)
        // The circled dot/number glyphs read larger than the wheel capsule at
        // the same box size, so the circle ones get a smaller box; that keeps
        // the five glyphs visually even. Spacing stays tight — 6pt between the
        // glyph box and the label.
        let glyphSide: CGFloat = gesture.isClickGlyph ? 21 : ImpulseGlyph.intrinsicSize.height
        let spacing: CGFloat = 6
        let totalWidth = glyphSide + spacing + textSize.width
        let originX = tile.midX - totalWidth / 2

        let glyphRect = NSRect(x: originX,
                               y: tile.midY - glyphSide / 2,
                               width: glyphSide, height: glyphSide)
        ImpulseGlyph.draw(gesture, in: glyphRect)

        // AppKit text draws from the baseline; centre the box instead. The
        // width is the measured text size, never clipped to the leftover tile
        // space — clipping made NSString.draw wrap and the single-line-height
        // rect then hid the second line, showing only "Wheel" / "Middle".
        let textRect = NSRect(x: glyphRect.maxX + spacing,
                              y: tile.midY - textSize.height / 2,
                              width: textSize.width + 1,
                              height: textSize.height)
        (caption as NSString).draw(at: textRect.origin, withAttributes: attributes)
    }

    /// Forward the click like the drawn-preset cell does. Without this the
    /// control never calls its target, which made every tile in this row inert.
    override func mouseDown(with event: NSEvent) {
        guard let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    // MARK: Test hooks（ImpulseGestureCell 是 private，测试经由文件底部协议访问）

    @objc func probeAction() {
        forwardedForTest = true
    }

    var forwardedForTest: Bool {
        get { objc_getAssociatedObject(self, &Self.forwardedKey) != nil }
        set { objc_setAssociatedObject(self, &Self.forwardedKey, newValue ? NSNumber(value: true) : nil, .OBJC_ASSOCIATION_RETAIN) }
    }
    private static var forwardedKey: UInt8 = 0

    /// Tracking area so the tile can show a hover outline, matching the drawn
    /// cells' affordance.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingArea?.forEach(removeTrackingArea)
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = [area]
    }

    private var trackingArea: [NSTrackingArea]?
}
