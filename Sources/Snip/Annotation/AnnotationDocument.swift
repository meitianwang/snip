import AppKit
import SwiftUI

/// 标注文档：元素集合 + 快照式撤销 + 导出合成。
@MainActor
final class AnnotationDocument: ObservableObject {
    @Published var elements: [AnnotationElement] = []
    @Published var selectedID: UUID?
    @Published var tool: AnnotationTool = .rect
    @Published var color: NSColor = .systemRed

    let baseImage: CGImage
    let scale: CGFloat
    let fileURL: URL
    let canvasSize: NSSize

    static let presetColors: [NSColor] = [
        .systemRed, .systemOrange, .systemGreen, .systemBlue, .black,
    ]

    private var undoStack: [[AnnotationElement]] = []
    private var redoStack: [[AnnotationElement]] = []

    /// 马赛克底图惰性生成（CIPixellate 全图一次，渲染按需裁剪）
    private(set) lazy var pixellatedImage: CGImage? =
        AnnotationRenderer.makePixellatedImage(from: baseImage, scale: scale)

    init(image: CGImage, scale: CGFloat, fileURL: URL) {
        self.baseImage = image
        self.scale = scale
        self.fileURL = fileURL
        self.canvasSize = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
    }

    // MARK: - 撤销 / 重做

    /// 任何修改前调用，记录当前状态
    func snapshot() {
        undoStack.append(elements)
        redoStack.removeAll()
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(elements)
        elements = last
        selectedID = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(elements)
        elements = next
        selectedID = nil
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        snapshot()
        elements.removeAll { $0.id == id }
        selectedID = nil
    }

    // MARK: - 导出

    /// 原图 + 全部标注合成为全分辨率图像
    func export() -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: baseImage.width,
            height: baseImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
        // 标注坐标是点坐标，放大到像素坐标系
        ctx.scaleBy(x: scale, y: scale)

        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        for element in elements {
            AnnotationRenderer.render(element, in: ctx, pixellatedImage: pixellatedImage, canvasSize: canvasSize)
        }
        NSGraphicsContext.restoreGraphicsState()

        return ctx.makeImage()
    }

    /// 合成结果写入剪贴板
    func copyToClipboard() {
        guard let image = export() else { return }
        let nsImage = NSImage(cgImage: image, size: canvasSize)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    /// 合成结果覆盖保存到原文件；若开启了自动复制，同步刷新剪贴板，保证粘贴与文件一致
    @discardableResult
    func save() -> Bool {
        guard let image = export() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = canvasSize
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: fileURL)
        } catch {
            NSLog("Snip: 标注保存失败 \(error)")
            return false
        }
        if SettingsStore.shared.copyToClipboard {
            let nsImage = NSImage(cgImage: image, size: canvasSize)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
        }
        return true
    }
}
