import SwiftUI

struct MenuContent: View {
    var body: some View {
        Button("区域截取") {
            AppState.shared.startRegionCapture()
        }
        .keyboardShortcut("1", modifiers: [.shift, .command])

        Button("全屏截取") {
            AppState.shared.captureFullScreen()
        }
        .keyboardShortcut("3", modifiers: [.shift, .command])

        Divider()

        Button("打开保存目录") {
            NSWorkspace.shared.open(AppState.shared.saveDirectory)
        }

        Divider()

        Button("退出 Snip") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
