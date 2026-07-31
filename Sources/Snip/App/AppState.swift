import AppKit
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// 全局状态与截取流程协调器。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var isCapturing = false

    private var overlayWindows: [OverlayWindow] = []
    private var editors: [EditorWindowController] = []
    private var ocrWindows: [OCRResultWindowController] = []

    private init() {}

    // MARK: - 设置

    var saveDirectory: URL { SettingsStore.shared.saveDirectory }

    /// 权限检查，未授权时引导去系统设置
    private func ensurePermissionWithGuidance() -> Bool {
        if CaptureEngine.ensurePermission() { return true }
        let alert = NSAlert()
        alert.messageText = "Snip 需要屏幕录制权限"
        alert.informativeText = "请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 Snip，然后重新打开应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: - 区域 / 窗口截取

    func startRegionCapture() { startInteractiveCapture(mode: .region) }
    func startWindowCapture() { startInteractiveCapture(mode: .window) }
    /// OCR 取字：框选 → 识别 → 文字进剪贴板
    func startTextCapture() { startInteractiveCapture(mode: .region, purpose: .text) }
    /// 滚动长截图（钉钉模式）：框选区域 → 用户手动滚动 → ✓ 完成；再按一次 ⇧⌘8 也可完成
    func startScrollCapture() {
        if let session = scrollSession {
            session.finish()
            return
        }
        startInteractiveCapture(mode: .region, purpose: .scroll)
    }

    private var scrollSession: ScrollCaptureSession?

    private var currentMode: CaptureMode = .region
    private var currentPurpose: CapturePurpose = .image

    private func startInteractiveCapture(mode: CaptureMode, purpose: CapturePurpose = .image) {
        guard !isCapturing else { return }
        guard ensurePermissionWithGuidance() else { return }
        isCapturing = true
        currentMode = mode
        currentPurpose = purpose

        Task {
            do {
                // 等菜单栏菜单收起，避免冻结帧拍到菜单
                try? await Task.sleep(nanoseconds: 180_000_000)
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
                        mode: mode,
                        purpose: purpose
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
        overlay.selectionView.onColorPicked = { [weak self] hex in
            Task { @MainActor in
                self?.dismissOverlays()
                Toast.show("已复制 \(hex)")
            }
        }
        overlay.selectionView.onRecognizeText = { [weak self] image in
            Task { @MainActor in
                // 保留覆盖层：结果窗口浮在选区之上，方便对照原文校对
                self?.recognizeAndShowResult(from: image)
            }
        }
        overlay.selectionView.onScrollRegionPicked = { [weak self, weak overlay] pixelRect in
            Task { @MainActor in
                guard let self, let screen = overlay?.screen else { return }
                self.dismissOverlays()
                self.performScrollCapture(region: pixelRect, on: screen)
            }
        }
        overlay.selectionView.onSaveRequested = { [weak self] image, scale in
            Task { @MainActor in
                self?.dismissOverlays()
                self?.saveWithPanel(image, scale: scale)
            }
        }
    }

    /// 另存为：原生保存面板（钉钉「下载」同款）
    private func saveWithPanel(_ image: CGImage, scale: CGFloat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "Snip \(formatter.string(from: Date())).png"
        panel.directoryURL = saveDirectory
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: url)
            HistoryStore.shared.add(url)
            Toast.show("已保存")
        } catch {
            NSLog("Snip: 另存为失败 \(error)")
            Toast.show("保存失败")
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
        if currentPurpose == .text {
            // OCR：不关覆盖层，弹窗悬浮在选区上方供校对，Esc 退出
            recognizeAndShowResult(from: image)
        } else {
            dismissOverlays()
            deliverWithPreview(image, scale: scale)
        }
    }

    /// OCR：识别后弹窗展示，可编辑/选择/一键复制
    private func recognizeAndShowResult(from image: CGImage) {
        Task {
            do {
                let text = try await TextRecognizer.recognize(image)
                guard !text.isEmpty else {
                    Toast.show("未识别到文字")
                    return
                }
                openOCRResult(text: text)
            } catch {
                NSLog("Snip: OCR 失败 \(error)")
                Toast.show("文字识别失败")
            }
        }
    }

    private func openOCRResult(text: String) {
        let controller = OCRResultWindowController(text: text)
        controller.onClose = { [weak self, weak controller] in
            guard let controller else { return }
            self?.ocrWindows.removeAll { $0 === controller }
        }
        // 覆盖层还在时抬到其上，否则普通层级
        controller.setFloatsAboveCapture(!overlayWindows.isEmpty)
        ocrWindows.append(controller)
        controller.show()
    }

    private func finishWindowCapture(_ window: SCWindow) {
        // 点击刚发生在鼠标所在屏幕，用它的 scale
        let mouse = NSEvent.mouseLocation
        let scale = NSScreen.screens.first { $0.frame.contains(mouse) }?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
        dismissOverlays()
        Task {
            do {
                var image = try await CaptureEngine.captureWindow(window, scale: scale)
                // 美化：渐变背景 + 留白 + 投影（可在菜单关闭）
                if SettingsStore.shared.beautifyWindowCapture,
                   let beautified = ImageBeautifier.beautify(image, scale: scale, style: SettingsStore.shared.beautifyStyle) {
                    image = beautified
                }
                deliverWithPreview(image, scale: scale)
            } catch {
                NSLog("Snip: 窗口截取失败 \(error)")
            }
        }
    }

    /// 滚动长截图：启动会话，用户在框选区域内手动滚动，HUD 控制完成/取消
    private func performScrollCapture(region: CGRect, on screen: NSScreen) {
        let session = ScrollCaptureSession(pixelRegion: region, screen: screen) { [weak self] image in
            guard let self else { return }
            self.scrollSession = nil
            if let image {
                self.deliverWithPreview(image, scale: screen.backingScaleFactor)
            }
        }
        session.onSave = { [weak self] image in
            self?.saveWithPanel(image, scale: screen.backingScaleFactor)
        }
        scrollSession = session
        session.start()
    }

    /// 统一输出：剪贴板 + 保存 + 浮动预览（按设置开关）
    private func deliverWithPreview(_ image: CGImage, scale: CGFloat) {
        let settings = SettingsStore.shared
        if let url = OutputService.deliver(
            image, scale: scale,
            saveTo: saveDirectory,
            copyToClipboard: settings.copyToClipboard
        ), settings.showPreview {
            FloatingPreview.shared.show(image: image, scale: scale, fileURL: url)
        }
    }

    private func dismissOverlays() {
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        isCapturing = false
        // 覆盖层没了，OCR 结果窗口降回普通层级
        ocrWindows.forEach { $0.setFloatsAboveCapture(false) }
    }

    // MARK: - 标注器 / 历史

    func openHistoryItem(_ url: URL) {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Toast.show("文件已不存在")
            return
        }
        let scale = nsImage.size.width > 0 ? CGFloat(cgImage.width) / nsImage.size.width : 2
        openEditor(image: cgImage, scale: scale, fileURL: url)
    }

    func openEditor(image: CGImage, scale: CGFloat, fileURL: URL) {
        let document = AnnotationDocument(image: image, scale: scale, fileURL: fileURL)
        let editor = EditorWindowController(document: document)
        editor.onClose = { [weak self, weak editor] in
            guard let editor else { return }
            self?.editors.removeAll { $0 === editor }
        }
        editors.append(editor)
        editor.show()
    }

    // MARK: - 全屏截取

    func captureFullScreen() {
        guard !isCapturing else { return }
        guard ensurePermissionWithGuidance() else { return }

        Task {
            // 等菜单栏菜单收起
            try? await Task.sleep(nanoseconds: 180_000_000)
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
