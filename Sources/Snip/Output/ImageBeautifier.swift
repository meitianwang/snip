import AppKit
import CoreGraphics

/// 美化背景风格：多段对角渐变 + 径向光晕。
enum BeautifyStyle: String, CaseIterable, Identifiable {
    case indigo    // 蓝紫
    case sunset    // 日落
    case mint      // 薄荷
    case aurora    // 极光
    case graphite  // 深空
    case candy     // 糖果

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .indigo: "蓝紫"
        case .sunset: "日落"
        case .mint: "薄荷"
        case .aurora: "极光"
        case .graphite: "深空"
        case .candy: "糖果"
        }
    }

    /// 对角线性渐变色标（0~1）
    var stops: [(location: CGFloat, color: CGColor)] {
        switch self {
        case .indigo:
            [(0, rgb(0.35, 0.42, 0.94)), (0.55, rgb(0.52, 0.36, 0.86)), (1, rgb(0.68, 0.32, 0.74))]
        case .sunset:
            [(0, rgb(0.98, 0.62, 0.32)), (0.5, rgb(0.94, 0.42, 0.48)), (1, rgb(0.62, 0.32, 0.72))]
        case .mint:
            [(0, rgb(0.22, 0.78, 0.70)), (0.55, rgb(0.24, 0.60, 0.86)), (1, rgb(0.30, 0.42, 0.90))]
        case .aurora:
            [(0, rgb(0.10, 0.75, 0.55)), (0.45, rgb(0.12, 0.50, 0.65)), (1, rgb(0.22, 0.22, 0.55))]
        case .graphite:
            [(0, rgb(0.28, 0.30, 0.36)), (0.6, rgb(0.16, 0.17, 0.22)), (1, rgb(0.08, 0.08, 0.12))]
        case .candy:
            [(0, rgb(0.99, 0.68, 0.78)), (0.5, rgb(0.96, 0.56, 0.66)), (1, rgb(0.72, 0.52, 0.94))]
        }
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: 1)
    }
}

/// 窗口截图美化：渐变背景 + 光晕层次 + 留白 + 柔和投影。
enum ImageBeautifier {
    /// 输入窗口截图（带透明圆角），输出加背景与投影的合成图
    static func beautify(_ image: CGImage, scale: CGFloat, style: BeautifyStyle) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        // 留白：短边的 8%，限制在 32~140pt
        let padding = (min(width, height) * 0.08).clamped(to: 32 * scale...140 * scale)
        let canvasWidth = Int(width + padding * 2)
        let canvasHeight = Int(height + padding * 2)
        let canvasW = CGFloat(canvasWidth)
        let canvasH = CGFloat(canvasHeight)

        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: canvasWidth,
                  height: canvasHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: srgb,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // 1. 对角多段线性渐变
        let stops = style.stops
        if let gradient = CGGradient(
            colorsSpace: srgb,
            colors: stops.map(\.color) as CFArray,
            locations: stops.map(\.location)
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: canvasH),
                end: CGPoint(x: canvasW, y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // 2. 径向光晕：左上亮光 + 右下沉光，打破平面感
        if let glow = CGGradient(
            colorsSpace: srgb,
            colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(
                glow,
                startCenter: CGPoint(x: canvasW * 0.15, y: canvasH * 0.9),
                startRadius: 0,
                endCenter: CGPoint(x: canvasW * 0.15, y: canvasH * 0.9),
                endRadius: max(canvasW, canvasH) * 0.75,
                options: []
            )
        }
        if let shade = CGGradient(
            colorsSpace: srgb,
            colors: [CGColor(gray: 0, alpha: 0.16), CGColor(gray: 0, alpha: 0)] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(
                shade,
                startCenter: CGPoint(x: canvasW * 0.9, y: canvasH * 0.08),
                startRadius: 0,
                endCenter: CGPoint(x: canvasW * 0.9, y: canvasH * 0.08),
                endRadius: max(canvasW, canvasH) * 0.7,
                options: []
            )
        }

        // 3. 柔和投影 + 窗口图
        let imageRect = CGRect(x: padding, y: padding, width: width, height: height)
        ctx.setShadow(
            offset: CGSize(width: 0, height: -10 * scale),
            blur: 36 * scale,
            color: CGColor(gray: 0, alpha: 0.4)
        )
        ctx.draw(image, in: imageRect)

        return ctx.makeImage()
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
