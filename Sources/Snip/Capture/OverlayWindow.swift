import AppKit

/// 覆盖整个屏幕的无边框窗口，承载选区交互。
final class OverlayWindow: NSWindow {
    init(
        screen: NSScreen,
        frozenImage: CGImage,
        onComplete: @escaping (CGImage, CGFloat) -> Void,
        onCancel: @escaping () -> Void
    ) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let selectionView = SelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            frozenImage: frozenImage,
            screenScale: screen.backingScaleFactor
        )
        selectionView.onComplete = onComplete
        selectionView.onCancel = onCancel
        contentView = selectionView
        makeFirstResponder(selectionView)
    }

    override var canBecomeKey: Bool { true }
}
