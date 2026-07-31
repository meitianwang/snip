import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerHotkeys()
    }

    private func registerHotkeys() {
        let cmdShift = UInt32(cmdKey | shiftKey)
        HotkeyManager.shared.register(keyCode: UInt32(kVK_ANSI_1), modifiers: cmdShift) {
            Task { @MainActor in AppState.shared.startRegionCapture() }
        }
        HotkeyManager.shared.register(keyCode: UInt32(kVK_ANSI_2), modifiers: cmdShift) {
            Task { @MainActor in AppState.shared.startWindowCapture() }
        }
        // 全屏用 ⇧⌘0：⇧⌘3 是系统截屏快捷键，不能冲突
        HotkeyManager.shared.register(keyCode: UInt32(kVK_ANSI_0), modifiers: cmdShift) {
            Task { @MainActor in AppState.shared.captureFullScreen() }
        }
        // OCR 取字
        HotkeyManager.shared.register(keyCode: UInt32(kVK_ANSI_9), modifiers: cmdShift) {
            Task { @MainActor in AppState.shared.startTextCapture() }
        }
        // 滚动长截图
        HotkeyManager.shared.register(keyCode: UInt32(kVK_ANSI_8), modifiers: cmdShift) {
            Task { @MainActor in AppState.shared.startScrollCapture() }
        }
    }
}
