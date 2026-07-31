import AppKit
import CoreImage

/// 标注工具集，对齐钉钉截图助手 DTSCDrawingTools
/// （逆向可见其工具名：rect / ellipse / line / arrow / brush / text / mosaic / highlight / step）
enum AnnotationTool: CaseIterable {
    case rect, ellipse, line, arrow, pen, highlight, step, text, mosaic

    var symbolName: String {
        switch self {
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .pen: "scribble"
        case .highlight: "highlighter"
        case .step: "1.circle.fill"
        case .text: "textformat"
        case .mosaic: "square.grid.3x3.square"
        }
    }

    var displayName: String {
        switch self {
        case .rect: "矩形"
        case .ellipse: "椭圆"
        case .line: "直线"
        case .arrow: "箭头"
        case .pen: "画笔"
        case .highlight: "荧光笔"
        case .step: "序号"
        case .text: "文字"
        case .mosaic: "马赛克"
        }
    }

    /// 工具切换快捷键
    var shortcutKey: Character {
        switch self {
        case .rect: "r"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .pen: "p"
        case .highlight: "h"
        case .step: "n"
        case .text: "t"
        case .mosaic: "m"
        }
    }

    /// 拖拽类工具（rect/ellipse/mosaic 用 rect，其余用 points）
    var usesRect: Bool {
        switch self {
        case .rect, .ellipse, .mosaic, .highlight: true
        default: false
        }
    }
}

/// 一条矢量标注。坐标统一为画布点坐标（原点左下）。
struct AnnotationElement: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var rect: NSRect = .zero        // rect / ellipse / mosaic / text
    var points: [NSPoint] = []      // arrow(2 点) / pen(多点)
    var text: String = ""
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    var fontSize: CGFloat = 18
    /// 序号标注的编号（step 工具）
    var stepIndex: Int = 1

    /// 命中测试用的包围盒
    var boundingBox: NSRect {
        switch tool {
        case .rect, .ellipse, .mosaic, .text, .highlight:
            return rect.insetBy(dx: -6, dy: -6)
        case .step:
            return rect.insetBy(dx: -stepRadius - 2, dy: -stepRadius - 2)
        case .line, .arrow, .pen:
            guard let first = points.first else { return .zero }
            var box = NSRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                box = box.union(NSRect(origin: point, size: .zero))
            }
            return box.insetBy(dx: -8, dy: -8)
        }
    }

    /// 整体平移
    mutating func translate(by delta: NSPoint) {
        rect.origin.x += delta.x
        rect.origin.y += delta.y
        points = points.map { NSPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }

    /// 序号圆点半径（随线宽略微变化）
    var stepRadius: CGFloat { 11 + lineWidth }

    var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
        ]
    }
}

/// 标注渲染器：画布实时显示与最终导出共用。
enum AnnotationRenderer {
    /// 在当前 CGContext(点坐标、原点左下) 中渲染一条标注
    static func render(
        _ element: AnnotationElement,
        in ctx: CGContext,
        pixellatedImage: CGImage?,
        canvasSize: NSSize
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(element.color.cgColor)
        ctx.setFillColor(element.color.cgColor)
        ctx.setLineWidth(element.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch element.tool {
        case .rect:
            ctx.stroke(element.rect)

        case .ellipse:
            ctx.strokeEllipse(in: element.rect)

        case .line:
            guard element.points.count >= 2 else { return }
            ctx.move(to: element.points[0])
            ctx.addLine(to: element.points[1])
            ctx.strokePath()

        case .arrow:
            guard element.points.count >= 2 else { return }
            renderArrow(from: element.points[0], to: element.points[1], in: ctx, lineWidth: element.lineWidth)

        case .highlight:
            // 荧光笔：半透明色块叠加（钉钉 highlight 同款）
            ctx.setFillColor(element.color.withAlphaComponent(0.35).cgColor)
            ctx.fill(element.rect)

        case .step:
            // 序号：实心圆 + 居中白字（钉钉 step 同款）
            let r = element.stepRadius
            let center = element.rect.origin
            let circle = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(element.color.cgColor)
            ctx.fillEllipse(in: circle)
            let label = "\(element.stepIndex)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(
                at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                withAttributes: attrs
            )

        case .pen:
            guard element.points.count >= 2 else { return }
            ctx.move(to: element.points[0])
            for point in element.points.dropFirst() {
                ctx.addLine(to: point)
            }
            ctx.strokePath()

        case .text:
            guard !element.text.isEmpty else { return }
            (element.text as NSString).draw(at: element.rect.origin, withAttributes: element.textAttributes)

        case .mosaic:
            guard let pixellated = pixellatedImage else { return }
            ctx.clip(to: element.rect)
            ctx.draw(pixellated, in: NSRect(origin: .zero, size: canvasSize))
        }
    }

    private static func renderArrow(from start: NSPoint, to end: NSPoint, in ctx: CGContext, lineWidth: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(12, lineWidth * 4.5)
        let headAngle: CGFloat = .pi / 7

        // 箭杆止于箭头底部，避免露出圆头
        let shaftEnd = NSPoint(
            x: end.x - headLength * 0.7 * cos(angle),
            y: end.y - headLength * 0.7 * sin(angle)
        )
        ctx.move(to: start)
        ctx.addLine(to: shaftEnd)
        ctx.strokePath()

        // 实心箭头
        let wing1 = NSPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let wing2 = NSPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )
        ctx.move(to: end)
        ctx.addLine(to: wing1)
        ctx.addLine(to: wing2)
        ctx.closePath()
        ctx.fillPath()
    }

    /// 生成马赛克底图（对整张原图做像素化，渲染时按需裁剪）
    static func makePixellatedImage(from image: CGImage, scale: CGFloat) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(10 * scale, forKey: kCIInputScaleKey)
        guard let output = filter.outputImage?.cropped(to: ciImage.extent) else { return nil }
        return CIContext().createCGImage(output, from: ciImage.extent)
    }
}
