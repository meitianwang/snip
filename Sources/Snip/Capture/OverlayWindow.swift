import AppKit
import ScreenCaptureKit

/// 覆盖整个屏幕的无边框窗口，承载选区交互。
final class OverlayWindow: NSWindow {
    let selectionView: SelectionView

    init(
        screen: NSScreen,
        frozenImage: CGImage,
        pickableWindows: [(window: SCWindow, rect: NSRect)],
        mode: CaptureMode
    ) {
        selectionView = SelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            frozenImage: frozenImage,
            screenScale: screen.backingScaleFactor,
            pickableWindows: pickableWindows
        )
        selectionView.mode = mode

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
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView = selectionView
        makeFirstResponder(selectionView)
    }

    override var canBecomeKey: Bool { true }
}
