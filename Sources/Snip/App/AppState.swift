import AppKit
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

    // MARK: - 区域截取

    func startRegionCapture() {
        guard !isCapturing else { return }
        guard CaptureEngine.ensurePermission() else { return }
        isCapturing = true

        Task {
            do {
                var windows: [OverlayWindow] = []
                // 每个屏幕先冻结一帧，选取过程画面不再变动
                for screen in NSScreen.screens {
                    let frozen = try await CaptureEngine.captureImage(of: screen)
                    let window = OverlayWindow(
                        screen: screen,
                        frozenImage: frozen,
                        onComplete: { [weak self] image, scale in
                            Task { @MainActor in self?.finishRegionCapture(image, scale: scale) }
                        },
                        onCancel: { [weak self] in
                            Task { @MainActor in self?.dismissOverlays() }
                        }
                    )
                    windows.append(window)
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

    private func finishRegionCapture(_ image: CGImage, scale: CGFloat) {
        dismissOverlays()
        OutputService.deliver(image, scale: scale, saveTo: saveDirectory)
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
                OutputService.deliver(image, scale: screen.backingScaleFactor, saveTo: saveDirectory)
            } catch {
                NSLog("Snip: 全屏截取失败 \(error)")
            }
        }
    }
}
