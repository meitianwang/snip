import AppKit
import ScreenCaptureKit
import SwiftUI

/// 全局状态与截取流程协调器。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var isCapturing = false

    private var overlayWindows: [OverlayWindow] = []

    private init() {}

    // MARK: - 设置

    var saveDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: "saveDirectory") {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - 区域 / 窗口截取

    func startRegionCapture() { startInteractiveCapture(mode: .region) }
    func startWindowCapture() { startInteractiveCapture(mode: .window) }

    private var currentMode: CaptureMode = .region

    private func startInteractiveCapture(mode: CaptureMode) {
        guard !isCapturing else { return }
        guard CaptureEngine.ensurePermission() else { return }
        isCapturing = true
        currentMode = mode

        Task {
            do {
                let content = try await CaptureEngine.shareableContent()
                let pickable = CaptureEngine.pickableWindows(from: content)
                var windows: [OverlayWindow] = []
                // 每个屏幕先冻结一帧，选取过程画面不再变动
                for screen in NSScreen.screens {
                    let frozen = try await CaptureEngine.captureImage(of: screen, content: content)
                    let windowRects = pickable.compactMap { window -> (SCWindow, NSRect)? in
                        let rect = Self.viewRect(for: window, on: screen)
                        return rect.intersects(NSRect(origin: .zero, size: screen.frame.size)) ? (window, rect) : nil
                    }
                    let overlay = OverlayWindow(
                        screen: screen,
                        frozenImage: frozen,
                        pickableWindows: windowRects,
                        mode: mode
                    )
                    configureCallbacks(for: overlay)
                    windows.append(overlay)
                }
                overlayWindows = windows
                windows.forEach { $0.orderFrontRegardless() }
                NSApp.activate(ignoringOtherApps: true)
                let mouse = NSEvent.mouseLocation
                let keyWindow = windows.first { $0.screen?.frame.contains(mouse) ?? false } ?? windows.first
                keyWindow?.makeKeyAndOrderFront(nil)
            } catch {
                NSLog("Snip: 冻结屏幕失败 \(error)")
                isCapturing = false
            }
        }
    }

    private func configureCallbacks(for overlay: OverlayWindow) {
        overlay.selectionView.onComplete = { [weak self] image, scale in
            Task { @MainActor in self?.finishRegionCapture(image, scale: scale) }
        }
        overlay.selectionView.onWindowPick = { [weak self] window in
            Task { @MainActor in self?.finishWindowCapture(window) }
        }
        overlay.selectionView.onCancel = { [weak self] in
            Task { @MainActor in self?.dismissOverlays() }
        }
        overlay.selectionView.onModeToggle = { [weak self] in
            Task { @MainActor in self?.toggleMode() }
        }
    }

    private func toggleMode() {
        currentMode = currentMode == .region ? .window : .region
        overlayWindows.forEach { $0.selectionView.mode = currentMode }
    }

    /// SCWindow 全局 CG 坐标(原点左上) -> 指定屏幕视图坐标(原点左下)
    private static func viewRect(for window: SCWindow, on screen: NSScreen) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = window.frame
        let cocoaGlobal = NSRect(
            x: frame.origin.x,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        return NSRect(
            x: cocoaGlobal.minX - screen.frame.minX,
            y: cocoaGlobal.minY - screen.frame.minY,
            width: cocoaGlobal.width,
            height: cocoaGlobal.height
        )
    }

    private func finishRegionCapture(_ image: CGImage, scale: CGFloat) {
        dismissOverlays()
        deliverWithPreview(image, scale: scale)
    }

    private func finishWindowCapture(_ window: SCWindow) {
        // 先找到窗口所在屏幕的 scale，再关闭覆盖层、活体截取
        let scale = overlayWindows
            .first { $0.selectionView.mode == .window }?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        dismissOverlays()
        Task {
            do {
                let image = try await CaptureEngine.captureWindow(window, scale: scale)
                deliverWithPreview(image, scale: scale)
            } catch {
                NSLog("Snip: 窗口截取失败 \(error)")
            }
        }
    }

    /// 统一输出：剪贴板 + 保存 + 浮动预览
    private func deliverWithPreview(_ image: CGImage, scale: CGFloat) {
        if let url = OutputService.deliver(image, scale: scale, saveTo: saveDirectory) {
            FloatingPreview.shared.show(image: image, scale: scale, fileURL: url)
        }
    }

    private func dismissOverlays() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        isCapturing = false
    }

    // MARK: - 全屏截取

    func captureFullScreen() {
        guard !isCapturing else { return }
        guard CaptureEngine.ensurePermission() else { return }

        Task {
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
            do {
                let image = try await CaptureEngine.captureImage(of: screen)
                deliverWithPreview(image, scale: screen.backingScaleFactor)
            } catch {
                NSLog("Snip: 全屏截取失败 \(error)")
            }
        }
    }
}
