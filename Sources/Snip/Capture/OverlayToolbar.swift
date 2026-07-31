import SwiftUI

/// 选区旁就地工具条的状态模型。
@MainActor
final class OverlayToolbarModel: ObservableObject {
    /// nil = 未选工具（不进入绘制）
    @Published var tool: AnnotationTool?
    @Published var color: NSColor = .systemRed
    /// 吸管取色模式：点击屏幕像素复制色值
    @Published var isPickingColor = false
    /// 线宽（对齐钉钉 DTSCBrushSizeControlView：细/中/粗三档）
    @Published var lineWidth: CGFloat = 3

    var onUndo: () -> Void = {}
    var onCancel: () -> Void = {}
    var onConfirm: () -> Void = {}
    var onOCR: () -> Void = {}
    var onScroll: () -> Void = {}
    var onSave: () -> Void = {}
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

            // 线宽三档（钉钉 DTSCBrushSizeControlView 同款）
            HStack(spacing: 4) {
                ForEach([CGFloat(2), 4, 7], id: \.self) { w in
                    Button {
                        model.lineWidth = w
                    } label: {
                        Circle()
                            .fill(.white.opacity(model.lineWidth == w ? 1 : 0.5))
                            .frame(width: 3 + w, height: 3 + w)
                            .frame(width: 18, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(model.lineWidth == w ? Color.accentColor.opacity(0.9) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("线宽 \(Int(w))")
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

            // OCR：识别选区内文字，弹窗展示结果
            Button {
                model.onOCR()
            } label: {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 24)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("识别选区文字 (OCR)")

            // 长截图：对当前选区启动滚动拼接（钉钉同款）
            Button {
                model.onScroll()
            } label: {
                Image(systemName: "rectangle.portrait.arrowtriangle.2.outward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 24)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("长截图：在选区内滚动拼接")

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

            // 保存到指定位置
            Button {
                model.onSave()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("另存为… (⌘S)")

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
