import AppKit

/// 轻量 HUD 提示：屏幕上短暂浮现一个胶囊文案，自动淡出。
@MainActor
enum Toast {
    private static var panel: NSPanel?

    static func show(_ message: String, near location: NSPoint? = nil) {
        panel?.orderOut(nil)

        let text = message as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let size = NSSize(width: textSize.width + 32, height: textSize.height + 16)

        // 默认光标上方，贴边收敛到屏幕内
        let anchor = location ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y + 24)
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))
        origin.y = min(origin.y, visible.maxY - size.height - 8)

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = ToastView(frame: NSRect(origin: .zero, size: size), text: message)
        panel.orderFrontRegardless()
        Self.panel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard Self.panel === panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if Self.panel === panel { Self.panel = nil }
            })
        }
    }
}

private final class ToastView: NSView {
    private let text: String

    init(frame: NSRect, text: String) {
        self.text = text
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = CGPath(
            roundedRect: bounds,
            cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2,
            transform: nil
        )
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.88))
        ctx.fillPath()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }
}
