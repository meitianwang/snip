import AppKit
import ScreenCaptureKit

/// 选区交互视图：冻结帧铺底 + 挖洞遮罩 + 放大镜 + 窗口高亮。
/// 两种模式：region(拖拽选区) / window(悬停点选窗口)，Space 切换。
final class SelectionView: NSView {
    var onComplete: ((CGImage, CGFloat) -> Void)?
    var onWindowPick: ((SCWindow) -> Void)?
    var onCancel: (() -> Void)?
    var onModeToggle: (() -> Void)?

    var mode: CaptureMode = .region {
        didSet {
            hoveredWindow = nil
            selectionRect = .zero
            startPoint = nil
            needsDisplay = true
        }
    }

    private let frozenImage: CGImage
    private let screenScale: CGFloat
    /// (窗口, 该窗口在本视图坐标系中的 rect)，按 z 序前置优先
    private let pickableWindows: [(window: SCWindow, rect: NSRect)]

    private var startPoint: NSPoint?
    private var selectionRect: NSRect = .zero
    private var mouseLocation: NSPoint = .zero
    private var hoveredWindow: (window: SCWindow, rect: NSRect)?
    /// 取色后的短暂反馈文案（“已复制 #FF6B35”）
    private var copyFeedback: String?

    init(
        frame: NSRect,
        frozenImage: CGImage,
        screenScale: CGFloat,
        pickableWindows: [(window: SCWindow, rect: NSRect)]
    ) {
        self.frozenImage = frozenImage
        self.screenScale = screenScale
        self.pickableWindows = pickableWindows
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 响应者 / 键盘

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 初始化光标位置，避免鼠标未动时放大镜/取色落在 (0,0)
        if let window {
            mouseLocation = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 49: // Space
            onModeToggle?()
        case 8: // C：复制光标处像素颜色
            copyColorUnderCursor()
        default:
            super.keyDown(with: event)
        }
    }

    /// 取色：光标像素颜色写入剪贴板，屏幕轻提示
    private func copyColorUnderCursor() {
        guard mode == .region else { return }
        let px = Int(floor(mouseLocation.x * screenScale))
        let py = Int(floor((bounds.height - mouseLocation.y) * screenScale))
        guard px >= 0, py >= 0, px < frozenImage.width, py < frozenImage.height else { return }
        let hex = pixelColor(atX: px, y: py)
        guard hex.hasPrefix("#") else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)

        copyFeedback = "已复制 \(hex)"
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyFeedback = nil
            self?.needsDisplay = true
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
            owner: self
        ))
    }

    // MARK: - 鼠标

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if mode == .window {
            hoveredWindow = pickableWindows.first { $0.rect.contains(mouseLocation) }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .region else { return }
        startPoint = convert(event.locationInWindow, from: nil)
        selectionRect = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region, let start = startPoint else { return }
        mouseLocation = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(
            x: min(start.x, mouseLocation.x),
            y: min(start.y, mouseLocation.y),
            width: abs(mouseLocation.x - start.x),
            height: abs(mouseLocation.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .window:
            if let hovered = hoveredWindow {
                onWindowPick?(hovered.window)
            }
        case .region:
            defer { startPoint = nil }
            guard selectionRect.width >= 2, selectionRect.height >= 2 else {
                selectionRect = .zero
                needsDisplay = true
                return
            }
            // 视图坐标(原点左下) -> 图像像素坐标(原点左上)
            let pixelRect = CGRect(
                x: selectionRect.minX * screenScale,
                y: (bounds.height - selectionRect.maxY) * screenScale,
                width: selectionRect.width * screenScale,
                height: selectionRect.height * screenScale
            ).integral
            if let cropped = frozenImage.cropping(to: pixelRect) {
                onComplete?(cropped, screenScale)
            } else {
                onCancel?()
            }
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 冻结帧铺底
        ctx.draw(frozenImage, in: bounds)

        switch mode {
        case .region: drawRegionMode(in: ctx)
        case .window: drawWindowMode(in: ctx)
        }

        drawHint(in: ctx)
        drawCopyFeedback(in: ctx)
    }

    private func drawRegionMode(in ctx: CGContext) {
        // 暗色遮罩（even-odd 挖洞）
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        ctx.addRect(bounds)
        if !selectionRect.isEmpty { ctx.addRect(selectionRect) }
        ctx.fillPath(using: .evenOdd)

        if !selectionRect.isEmpty {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(1)
            ctx.stroke(selectionRect.insetBy(dx: -0.5, dy: -0.5))
            drawSizeLabel(in: ctx)
        }

        drawMagnifier(in: ctx)
    }

    private func drawWindowMode(in ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        if let hovered = hoveredWindow {
            let rect = hovered.rect.intersection(bounds)
            // 遮罩挖洞 + 强调色描边
            ctx.addRect(bounds)
            ctx.addRect(rect)
            ctx.fillPath(using: .evenOdd)

            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(3)
            let path = CGPath(
                roundedRect: rect.insetBy(dx: 1.5, dy: 1.5),
                cornerWidth: 8, cornerHeight: 8, transform: nil
            )
            ctx.addPath(path)
            ctx.strokePath()
        } else {
            ctx.fill(bounds)
        }
    }

    // MARK: - 放大镜

    private func drawMagnifier(in ctx: CGContext) {
        let gridCount = 11           // 11×11 像素
        let cell: CGFloat = 10       // 每像素放大到 10pt
        let loupeSize = CGFloat(gridCount) * cell
        let labelHeight: CGFloat = 34

        // 光标对应的图像像素（原点左上）
        let px = floor(mouseLocation.x * screenScale)
        let py = floor((bounds.height - mouseLocation.y) * screenScale)
        guard px >= 0, py >= 0, px < CGFloat(frozenImage.width), py < CGFloat(frozenImage.height) else { return }

        // 放大镜位置：默认光标右下，贴边时翻转
        var origin = NSPoint(x: mouseLocation.x + 20, y: mouseLocation.y - 20 - loupeSize - labelHeight)
        if origin.x + loupeSize > bounds.maxX { origin.x = mouseLocation.x - 20 - loupeSize }
        if origin.y < bounds.minY { origin.y = mouseLocation.y + 20 }
        let loupeRect = NSRect(x: origin.x, y: origin.y + labelHeight, width: loupeSize, height: loupeSize)

        // 源区域裁剪（越界部分留黑）
        let half = CGFloat(gridCount / 2)
        let srcRect = CGRect(x: px - half, y: py - half, width: CGFloat(gridCount), height: CGFloat(gridCount))

        ctx.saveGState()
        let clipPath = CGPath(roundedRect: loupeRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(loupeRect)
        if let cropped = frozenImage.cropping(to: srcRect.intersection(
            CGRect(x: 0, y: 0, width: frozenImage.width, height: frozenImage.height)
        )) {
            // 越界裁剪后需要按偏移对齐绘制
            let clamped = srcRect.intersection(CGRect(x: 0, y: 0, width: frozenImage.width, height: frozenImage.height))
            let offsetX = (clamped.minX - srcRect.minX) * cell
            let offsetYTop = (clamped.minY - srcRect.minY) * cell
            let drawRect = NSRect(
                x: loupeRect.minX + offsetX,
                y: loupeRect.maxY - offsetYTop - clamped.height * cell,
                width: clamped.width * cell,
                height: clamped.height * cell
            )
            ctx.interpolationQuality = .none
            ctx.draw(cropped, in: drawRect)
            ctx.interpolationQuality = .default
        }
        ctx.restoreGState()

        // 中心像素十字标记
        let centerCell = NSRect(
            x: loupeRect.minX + half * cell,
            y: loupeRect.minY + half * cell,
            width: cell, height: cell
        )
        ctx.setStrokeColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1))
        ctx.setLineWidth(1.5)
        ctx.stroke(centerCell)

        // 边框
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
        ctx.setLineWidth(1)
        ctx.addPath(clipPath)
        ctx.strokePath()

        // 坐标 + 颜色标签
        let rgb = pixelColor(atX: Int(px), y: Int(py))
        let text = String(format: "(%d, %d)  %@", Int(px), Int(py), rgb) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let labelRect = NSRect(x: loupeRect.minX, y: origin.y, width: loupeSize, height: labelHeight - 6)
        let labelPath = CGPath(roundedRect: labelRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(labelPath)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.75))
        ctx.fillPath()
        text.draw(
            at: NSPoint(
                x: labelRect.midX - textSize.width / 2,
                y: labelRect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    /// 读取冻结帧单个像素的十六进制颜色
    private func pixelColor(atX x: Int, y: Int) -> String {
        guard let cropped = frozenImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return "—" }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "—" }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }

    // MARK: - 标签

    private func drawSizeLabel(in ctx: CGContext) {
        let w = Int(selectionRect.width * screenScale)
        let h = Int(selectionRect.height * screenScale)
        let text = "\(w) × \(h)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding: CGFloat = 5
        var labelOrigin = NSPoint(x: selectionRect.minX, y: selectionRect.maxY + 6)
        if labelOrigin.y + textSize.height + padding * 2 > bounds.maxY {
            labelOrigin.y = selectionRect.maxY - textSize.height - padding * 2 - 6
        }
        let labelRect = NSRect(
            x: labelOrigin.x, y: labelOrigin.y,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        let path = CGPath(roundedRect: labelRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
        ctx.fillPath()
        text.draw(at: NSPoint(x: labelRect.minX + padding, y: labelRect.minY + padding), withAttributes: attributes)
    }

    private func drawHint(in ctx: CGContext) {
        // 拖拽过程中不显示提示，减少干扰
        guard startPoint == nil else { return }
        let text = (mode == .region ? "拖拽选取区域  ·  C 取色" : "点击选取窗口") + "  ·  Space 切换  ·  Esc 取消" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let textSize = text.size(withAttributes: attributes)
        let labelRect = NSRect(
            x: bounds.midX - textSize.width / 2 - 14,
            y: bounds.maxY - 80,
            width: textSize.width + 28,
            height: textSize.height + 14
        )
        let path = CGPath(
            roundedRect: labelRect,
            cornerWidth: labelRect.height / 2, cornerHeight: labelRect.height / 2,
            transform: nil
        )
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath()
        text.draw(
            at: NSPoint(x: labelRect.midX - textSize.width / 2, y: labelRect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }

    /// 取色成功的轻提示（光标上方胶囊）
    private func drawCopyFeedback(in ctx: CGContext) {
        guard let feedback = copyFeedback else { return }
        let text = feedback as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        var labelRect = NSRect(
            x: mouseLocation.x - textSize.width / 2 - 12,
            y: mouseLocation.y + 28,
            width: textSize.width + 24,
            height: textSize.height + 12
        )
        // 贴边修正
        labelRect.origin.x = max(bounds.minX + 8, min(labelRect.origin.x, bounds.maxX - labelRect.width - 8))
        labelRect.origin.y = min(labelRect.origin.y, bounds.maxY - labelRect.height - 8)

        let path = CGPath(
            roundedRect: labelRect,
            cornerWidth: labelRect.height / 2, cornerHeight: labelRect.height / 2,
            transform: nil
        )
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.15, green: 0.55, blue: 0.25, alpha: 0.92))
        ctx.fillPath()
        text.draw(
            at: NSPoint(x: labelRect.midX - textSize.width / 2, y: labelRect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }
}
