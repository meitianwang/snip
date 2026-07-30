import AppKit
import SwiftUI

/// OCR 识别结果窗口：毛玻璃质感、可编辑、可选择、一键复制。
@MainActor
final class OCRResultWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    var onClose: (() -> Void)?

    init(text: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 260)

        super.init()
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: OCRResultView(text: text) { [weak self] in
                self?.window.close()
            }
        )
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 截取覆盖层存在时抬到其上层，覆盖层关闭后降回普通层级
    func setFloatsAboveCapture(_ floats: Bool) {
        window.level = floats
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            : .normal
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

struct OCRResultView: View {
    @State var text: String
    let onDone: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            // 头部（左侧给红绿灯留位）
            HStack(spacing: 7) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("识别结果")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(text.count) 字 · \(lineCount) 行")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.leading, 76)
            .padding(.trailing, 16)
            .padding(.top, 13)
            .padding(.bottom, 10)

            // 文本卡片
            TextEditor(text: $text)
                .font(.system(size: 13))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
                )
                .padding(.horizontal, 14)

            // 底部操作
            HStack(spacing: 10) {
                Text("可直接编辑、选中部分复制")
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)

                Spacer()

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        onDone()
                    }
                } label: {
                    Label(copied ? "已复制" : "复制全部", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .frame(minWidth: 76)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(copied ? .green : .accentColor)
                .keyboardShortcut(.defaultAction)
                .help("复制全部文字并关闭 (回车)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    private var lineCount: Int {
        text.components(separatedBy: "\n").count
    }
}

/// 原生毛玻璃背景
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
