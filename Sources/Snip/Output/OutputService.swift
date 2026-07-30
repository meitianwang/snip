import AppKit

/// 输出：剪贴板 + 磁盘保存。
enum OutputService {
    /// 返回保存后的文件 URL（失败时 nil）
    @discardableResult
    static func deliver(
        _ image: CGImage,
        scale: CGFloat,
        saveTo directory: URL,
        copyToClipboard: Bool = true
    ) -> URL? {
        // Retina: 像素尺寸 / scale = 点尺寸，保证粘贴时大小正确
        let pointSize = NSSize(
            width: CGFloat(image.width) / scale,
            height: CGFloat(image.height) / scale
        )
        let nsImage = NSImage(cgImage: image, size: pointSize)

        // 1. 剪贴板（可关）
        if copyToClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
        }

        // 2. 保存 PNG
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize // 写入 DPI 信息
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("Snip: PNG 编码失败")
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let filename = "Snip \(formatter.string(from: Date())).png"
        let url = directory.appendingPathComponent(filename)
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("Snip: 保存失败 \(error)")
            return nil
        }
    }
}
