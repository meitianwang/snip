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
        HotkeyManager.shared.register(keyCode: UInt32(kVK_ANSI_3), modifiers: cmdShift) {
            Task { @MainActor in AppState.shared.captureFullScreen() }
        }
    }
}
