import AppKit
import UniformTypeIdentifiers

/// 截取完成后右下角的浮动预览：可拖走、点击打开、5 秒自动消失。
@MainActor
final class FloatingPreview {
    static let shared = FloatingPreview()
    private var panel: NSPanel?

    private init() {}

    func show(image: CGImage, scale: CGFloat, fileURL: URL) {
        dismiss(animated: false)

        // 弹在鼠标所在屏幕（截取发生地），而非固定主屏
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let pointSize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)

        // 等比缩放到最大 300×200
        let maxSize = NSSize(width: 300, height: 200)
        let ratio = min(maxSize.width / pointSize.width, maxSize.height / pointSize.height, 1)
        let thumbSize = NSSize(width: pointSize.width * ratio, height: pointSize.height * ratio)
        let padding: CGFloat = 12 // 阴影留白

        let margin: CGFloat = 24
        let visible = screen.visibleFrame
        let panelSize = NSSize(width: thumbSize.width + padding * 2, height: thumbSize.height + padding * 2)
        let finalRect = NSRect(
            x: visible.maxX - panelSize.width - margin,
            y: visible.minY + margin,
            width: panelSize.width,
            height: panelSize.height
        )
        // 初始位置只向右偏移 16pt（仍在屏内），靠 alpha 淡入 + 轻微滑动
        let startRect = finalRect.offsetBy(dx: 16, dy: 0)

        let panel = NSPanel(
            contentRect: startRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = PreviewThumbView(
            frame: NSRect(origin: .zero, size: startRect.size),
            image: NSImage(cgImage: image, size: pointSize),
            fileURL: fileURL,
            padding: padding
        )
        view.onDismiss = { [weak self] in self?.dismiss(animated: true) }
        view.onOpen = { [weak self] in
            self?.dismiss(animated: false)
            AppState.shared.openEditor(image: image, scale: scale, fileURL: fileURL)
        }
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel

        // 淡入 + 轻微左滑（alphaValue/setFrame 是 NSWindow 官方可动画属性）
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalRect, display: true)
        }
        view.startDismissTimer()
    }

    func dismiss(animated: Bool) {
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 16, dy: 0), display: true)
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

/// 缩略图视图：圆角 + 描边 + 阴影，支持拖拽文件、单击打开。
final class PreviewThumbView: NSView {
    var onDismiss: (() -> Void)?
    var onOpen: (() -> Void)?

    private let image: NSImage
    private let fileURL: URL
    private let padding: CGFloat
    private var dismissTimer: Timer?
    private var mouseDownLocation: NSPoint?

    init(frame: NSRect, image: NSImage, fileURL: URL, padding: CGFloat) {
        self.image = image
        self.fileURL = fileURL
        self.padding = padding
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { dismissTimer?.invalidate() }

    private var thumbRect: NSRect { bounds.insetBy(dx: padding, dy: padding) }

    // MARK: - 自动消失

    func startDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.onDismiss?() }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        dismissTimer?.invalidate() // 悬停时暂停倒计时
    }

    override func mouseExited(with event: NSEvent) {
        startDismissTimer()
    }

    // MARK: - 拖拽 / 点击

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) > 5 else { return }
        mouseDownLocation = nil

        let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        draggingItem.setDraggingFrame(thumbRect, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownLocation != nil else { return }
        mouseDownLocation = nil
        // 单击：进入标注器
        onOpen?()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = thumbRect
        let path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)

        // 阴影
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        // 图片
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGState()

        // 描边
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        ctx.setLineWidth(1.5)
        ctx.strokePath()
    }
}

extension PreviewThumbView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // 拖拽结束（无论成功与否）即完成使命
        DispatchQueue.main.async { [weak self] in self?.onDismiss?() }
    }
}
