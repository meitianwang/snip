import AppKit
import SwiftUI

/// 标注编辑器窗口：顶部工具栏 + 画布。
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let document: AnnotationDocument
    var onClose: (() -> Void)?

    init(document: AnnotationDocument) {
        self.document = document

        let toolbarHeight: CGFloat = 46
        let screenLimit = (NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800))
        let maxCanvas = NSSize(width: screenLimit.width * 0.85, height: screenLimit.height * 0.85 - toolbarHeight)
        let contentSize = NSSize(
            width: max(560, min(document.canvasSize.width, maxCanvas.width)),
            height: min(document.canvasSize.height, maxCanvas.height) + toolbarHeight
        )

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = document.fileURL.lastPathComponent
        window.isReleasedWhenClosed = false

        super.init()
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: EditorRootView(document: document)
        )
        window.setContentSize(contentSize)
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - SwiftUI 根视图

struct EditorRootView: View {
    @ObservedObject var document: AnnotationDocument

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(document: document)
            Divider()
            CanvasContainer(document: document)
        }
    }
}

/// 工具栏：6 工具 + 5 预设色 + 撤销/复制/保存
struct EditorToolbar: View {
    @ObservedObject var document: AnnotationDocument

    var body: some View {
        HStack(spacing: 14) {
            // 工具
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    Button {
                        document.tool = tool
                        document.selectedID = nil
                    } label: {
                        Image(systemName: tool.symbolName)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(document.tool == tool ? Color.accentColor.opacity(0.18) : .clear)
                            )
                            .foregroundStyle(document.tool == tool ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.displayName) (\(String(tool.shortcutKey).uppercased()))")
                }
            }

            Divider().frame(height: 20)

            // 颜色
            HStack(spacing: 6) {
                ForEach(Array(AnnotationDocument.presetColors.enumerated()), id: \.offset) { _, color in
                    Button {
                        document.color = color
                        applyColorToSelection(color)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle().strokeBorder(
                                    document.color == color ? Color.accentColor : Color.primary.opacity(0.15),
                                    lineWidth: document.color == color ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // 操作
            Button {
                document.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .keyboardShortcut("z", modifiers: .command)
            .help("撤销 (⌘Z)")

            Button {
                document.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .keyboardShortcut("z", modifiers: [.shift, .command])
            .help("重做 (⇧⌘Z)")

            Divider().frame(height: 20)

            Button("复制") {
                document.copyToClipboard()
                closeWindow()
            }
            .keyboardShortcut("c", modifiers: .command)
            .help("合成图复制到剪贴板并关闭 (⌘C)")

            Button("保存") {
                document.save()
                closeWindow()
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .help("覆盖保存到文件并关闭 (⌘S)")
        }
        .padding(.horizontal, 12)
        .frame(height: 45)
    }

    private func applyColorToSelection(_ color: NSColor) {
        guard let id = document.selectedID,
              let index = document.elements.firstIndex(where: { $0.id == id }) else { return }
        document.snapshot()
        document.elements[index].color = color
    }

    private func closeWindow() {
        NSApp.keyWindow?.close()
    }
}

/// 画布容器：超出窗口时滚动
struct CanvasContainer: NSViewRepresentable {
    let document: AnnotationDocument

    func makeNSView(context: Context) -> NSScrollView {
        let canvas = AnnotationCanvasView(document: document)
        let scrollView = NSScrollView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        DispatchQueue.main.async {
            canvas.window?.makeFirstResponder(canvas)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
