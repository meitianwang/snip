import SwiftUI

struct MenuContent: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var history = HistoryStore.shared

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
        .keyboardShortcut("0", modifiers: [.shift, .command])

        Button("OCR 取字") {
            AppState.shared.startTextCapture()
        }
        .keyboardShortcut("9", modifiers: [.shift, .command])

        Button("滚动长截图") {
            AppState.shared.startScrollCapture()
        }
        .keyboardShortcut("8", modifiers: [.shift, .command])

        Divider()

        Menu("最近截图") {
            if history.items.isEmpty {
                Text("暂无截图")
            } else {
                ForEach(history.items, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        AppState.shared.openHistoryItem(url)
                    }
                }
                Divider()
                Button("清空历史") {
                    history.clear()
                }
            }
        }

        Divider()

        Toggle("自动复制到剪贴板", isOn: $settings.copyToClipboard)
        Toggle("截取后显示预览", isOn: $settings.showPreview)
        Toggle("窗口截取美化背景", isOn: $settings.beautifyWindowCapture)
        Picker("美化背景风格", selection: $settings.beautifyStyle) {
            ForEach(BeautifyStyle.allCases) { style in
                Text(style.displayName).tag(style)
            }
        }
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
