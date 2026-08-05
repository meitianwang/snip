import AppKit

/// 对角调整光标。
/// 钉钉截图助手用的是自定义光标 `dt_resizeNorthWestSouthEastCursor` /
/// `dt_resizeNorthEastSouthWestCursor`（AppKit 未公开斜向 resize 光标），
/// 这里同样自绘：白描边黑箭头的双向斜箭头，Retina 清晰、深浅背景都可见。
extension NSCursor {
    static let snipResizeNWSE: NSCursor = makeDiagonalResize(flipped: false)
    static let snipResizeNESW: NSCursor = makeDiagonalResize(flipped: true)

    /// flipped=false → ↖↘（左上-右下）；true → ↗↙（右上-左下）
    private static func makeDiagonalResize(flipped: Bool) -> NSCursor {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.saveGState()
            if flipped {
                // 沿垂直中线镜像，得到另一条对角
                ctx.translateBy(x: side, y: 0)
                ctx.scaleBy(x: -1, y: 1)
            }

            let inset: CGFloat = 4
            let head: CGFloat = 6
            // 主轴：左下 → 右上（镜像后即为另一对角）
            let p1 = CGPoint(x: inset, y: inset)
            let p2 = CGPoint(x: side - inset, y: side - inset)

            let path = CGMutablePath()
            path.move(to: p1)
            path.addLine(to: p2)
            // 两端箭头
            path.move(to: p2)
            path.addLine(to: CGPoint(x: p2.x - head, y: p2.y))
            path.move(to: p2)
            path.addLine(to: CGPoint(x: p2.x, y: p2.y - head))
            path.move(to: p1)
            path.addLine(to: CGPoint(x: p1.x + head, y: p1.y))
            path.move(to: p1)
            path.addLine(to: CGPoint(x: p1.x, y: p1.y + head))

            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            // 白色描边打底，保证深色背景上也清晰
            ctx.setStrokeColor(.white)
            ctx.setLineWidth(4.5)
            ctx.addPath(path)
            ctx.strokePath()
            // 黑色主体
            ctx.setStrokeColor(.black)
            ctx.setLineWidth(2)
            ctx.addPath(path)
            ctx.strokePath()

            ctx.restoreGState()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}
