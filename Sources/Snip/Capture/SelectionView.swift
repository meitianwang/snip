import AppKit

/// 选区交互视图：冻结帧铺底 + 挖洞遮罩 + 蚂蚁线边框 + 尺寸标签。
final class SelectionView: NSView {
    var onComplete: ((CGImage, CGFloat) -> Void)?
    var onCancel: (() -> Void)?

    private let frozenImage: CGImage
    private let screenScale: CGFloat

    private var startPoint: NSPoint?
    private var selectionRect: NSRect = .zero
    private var antPhase: CGFloat = 0
    private var antTimer: Timer?

    init(frame: NSRect, frozenImage: CGImage, screenScale: CGFloat) {
        self.frozenImage = frozenImage
        self.screenScale = screenScale
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { antTimer?.invalidate() }

    // MARK: - 响应者

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selectionRect = .zero
        startAntAnimation()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint = nil
            stopAntAnimation()
        }
        guard selectionRect.width >= 2, selectionRect.height >= 2 else {
            // 单击不构成选区，重置继续等待
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

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 冻结帧铺底
        ctx.draw(frozenImage, in: bounds)

        // 2. 暗色遮罩（even-odd 挖洞）
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        ctx.addRect(bounds)
        if !selectionRect.isEmpty {
            ctx.addRect(selectionRect)
        }
        ctx.fillPath(using: .evenOdd)

        guard !selectionRect.isEmpty else { return }

        // 3. 蚂蚁线边框
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: antPhase, lengths: [5, 4])
        ctx.stroke(selectionRect.insetBy(dx: -0.5, dy: -0.5))
        ctx.setLineDash(phase: 0, lengths: [])

        // 4. 尺寸标签（像素尺寸）
        drawSizeLabel(in: ctx)
    }

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
        var labelOrigin = NSPoint(
            x: selectionRect.minX,
            y: selectionRect.maxY + 6
        )
        // 贴近屏幕顶端时移到选区内部
        if labelOrigin.y + textSize.height + padding * 2 > bounds.maxY {
            labelOrigin.y = selectionRect.maxY - textSize.height - padding * 2 - 6
        }
        let labelRect = NSRect(
            x: labelOrigin.x,
            y: labelOrigin.y,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        let path = CGPath(roundedRect: labelRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
        ctx.fillPath()
        text.draw(
            at: NSPoint(x: labelRect.minX + padding, y: labelRect.minY + padding),
            withAttributes: attributes
        )
    }

    // MARK: - 蚂蚁线动画

    private func startAntAnimation() {
        antTimer?.invalidate()
        antTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.antPhase += 1
            if !self.selectionRect.isEmpty { self.needsDisplay = true }
        }
    }

    private func stopAntAnimation() {
        antTimer?.invalidate()
        antTimer = nil
    }
}
