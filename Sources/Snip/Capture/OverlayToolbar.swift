import SwiftUI

/// 选区旁就地工具条的状态模型。
@MainActor
final class OverlayToolbarModel: ObservableObject {
    /// nil = 未选工具（不进入绘制）
    @Published var tool: AnnotationTool?
    @Published var color: NSColor = .systemRed
    /// 吸管取色模式：点击屏幕像素复制色值
    @Published var isPickingColor = false

    var onUndo: () -> Void = {}
    var onCancel: () -> Void = {}
    var onConfirm: () -> Void = {}
}

/// 框选完成后出现在选区旁的工具条：标注工具 + 颜色 + 撤销 + ✕/✓。
struct OverlayToolbar: View {
    @ObservedObject var model: OverlayToolbarModel

    var body: some View {
        HStack(spacing: 10) {
            // 标注工具（再点一次取消选择）
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    Button {
                        model.tool = model.tool == tool ? nil : tool
                        model.isPickingColor = false
                    } label: {
                        Image(systemName: tool.symbolName)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(model.tool == tool ? Color.accentColor : .clear)
                            )
                            .foregroundStyle(model.tool == tool ? .white : .white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.displayName) (\(String(tool.shortcutKey).uppercased()))")
                }
            }

            Divider().frame(height: 16).overlay(.white.opacity(0.3))

            // 颜色
            HStack(spacing: 5) {
                ForEach(Array(AnnotationDocument.presetColors.enumerated()), id: \.offset) { _, color in
                    Button {
                        model.color = color
                    } label: {
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 14, height: 14)
                            .overlay(
                                Circle().strokeBorder(
                                    model.color == color ? .white : .white.opacity(0.25),
                                    lineWidth: model.color == color ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().frame(height: 16).overlay(.white.opacity(0.3))

            // 吸管取色：点击后在选区内外任意像素取色
            Button {
                model.isPickingColor.toggle()
                if model.isPickingColor { model.tool = nil }
            } label: {
                Image(systemName: "eyedropper")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(model.isPickingColor ? Color.accentColor : .clear)
                    )
                    .foregroundStyle(model.isPickingColor ? .white : .white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("取色 (C)：点击像素复制色值")

            Divider().frame(height: 16).overlay(.white.opacity(0.3))

            Button {
                model.onUndo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("撤销 (⌘Z)")

            Button {
                model.onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("取消 (Esc)")

            Button {
                model.onConfirm()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.green))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("完成 (回车)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.black.opacity(0.78))
        )
        .fixedSize()
    }
}
