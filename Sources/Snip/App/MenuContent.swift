import SwiftUI

struct MenuContent: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Button("区域截取") {
            AppState.shared.startRegionCapture()
        }
        .keyboardShortcut("1", modifiers: [.shift, .command])

        Button("窗口截取") {
            AppState.shared.startWindowCapture()
        }
        .keyboardShortcut("2", modifiers: [.shift, .command])

        Button("全屏截取") {
            AppState.shared.captureFullScreen()
        }
        .keyboardShortcut("3", modifiers: [.shift, .command])

        Divider()

        Toggle("自动复制到剪贴板", isOn: $settings.copyToClipboard)
        Toggle("截取后显示预览", isOn: $settings.showPreview)
        Toggle("开机自动启动", isOn: $settings.launchAtLogin)

        Divider()

        Button("保存目录：\(settings.saveDirectory.lastPathComponent)…") {
            settings.chooseSaveDirectory()
        }

        Button("打开保存目录") {
            NSWorkspace.shared.open(settings.saveDirectory)
        }

        Divider()

        Button("退出 Snip") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
