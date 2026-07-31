import AppKit
import CoreGraphics

// ===== E2E v3: 周期性内容 + 快滚/回滚 + 分栏布局（固定侧边栏）场景 =====

let viewportW = 1200, viewportH = 1600, tallH = 9000

func makeTallImage(width: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: tallH, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: tallH))
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    let titleAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.black]
    let markerAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 24), .foregroundColor: NSColor.red]
    let bodyAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.darkGray]
    var y = 40
    var i = 1
    while y < tallH - 220 {
        ("Section \(i)" as NSString).draw(at: NSPoint(x: 60, y: CGFloat(tallH - y - 36)), withAttributes: titleAttr)
        ctx.setFillColor(CGColor(red: 0.55, green: 0.55, blue: 0.75, alpha: 1))
        ctx.fill(CGRect(x: 60, y: tallH - y - 48, width: width - 120, height: 2))
        (String(format: "MARKER-%03d", i) as NSString).draw(at: NSPoint(x: 60, y: CGFloat(tallH - y - 90)), withAttributes: markerAttr)
        ("这是第 \(i) 段测试内容。The quick brown fox jumps over the lazy dog. 验证滚动拼接。" as NSString)
            .draw(at: NSPoint(x: 60, y: CGFloat(tallH - y - 130)), withAttributes: bodyAttr)
        y += 190
        i += 1
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

func frame(at offset: Double, of tall: CGImage, width: Int, height: Int, scrollbar: Bool = false, hoverY: Double? = nil) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let drawY = -(Double(tallH) - Double(height) - offset)
    ctx.draw(tall, in: CGRect(x: 0, y: drawY, width: Double(width), height: Double(tallH)))
    if let hoverY {
        // 模拟悬停高亮：44px 半透明蓝色行条
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.95, alpha: 0.25))
        ctx.fill(CGRect(x: 0, y: Double(height) - hoverY - 44, width: Double(width), height: 44))
    }
    if scrollbar {
        // 模拟 macOS 悬浮滚动条：右侧 12px 轨道 + 随 offset 移动的滑块
        let trackX = Double(width) - 14
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        ctx.fill(CGRect(x: trackX, y: 0, width: 12, height: Double(height)))
        let thumbH = 120.0
        let progress = offset / Double(tallH - height)
        let thumbTop = progress * (Double(height) - thumbH)
        ctx.setFillColor(CGColor(gray: 0.45, alpha: 1))
        ctx.fill(CGRect(x: trackX + 2, y: Double(height) - thumbTop - thumbH, width: 8, height: thumbH))
    }
    return ctx.makeImage()!
}

func contentMismatch(_ final: CGImage, ref: CGImage, checkH: Int) -> Double {
    let cols = 64
    let refSig = Stitcher.rowSignatures(of: ref.cropping(to: CGRect(x: 0, y: 0, width: ref.width, height: checkH))!)
    let outSig = Stitcher.rowSignatures(of: final.cropping(to: CGRect(x: 0, y: 0, width: final.width, height: checkH))!)
    var bad = 0, totalRows = 0
    for y in stride(from: 1, to: checkH - 1, by: 3) {
        var best = Int.max
        for dy in -1...1 {
            var diff = 0
            for c in 0..<(cols-3) { diff += abs(Int(refSig[(y+dy)*cols+c]) - Int(outSig[y*cols+c])) }
            best = min(best, diff)
        }
        if best > cols * 12 { bad += 1 }
        totalRows += 1
    }
    return Double(bad) / Double(totalRows)
}

// —— 场景 1~3：全窗滚动，直接驱动 Stitcher.analyze ——
func runSession(offsets: [Double], tall: CGImage, scrollbar: Bool = false) -> (ok: Bool, detail: String) {
    var strips: [CGImage] = []
    var anchorSig: FrameSig? = nil
    var totalHeight = 0
    var outcomes: [String] = []
    var maxStitchedOffset = 0.0
    for (i, off) in offsets.enumerated() {
        let f = frame(at: off, of: tall, width: viewportW, height: viewportH, scrollbar: scrollbar && off > 0)
        let sig = Stitcher.signature(of: f)
        if i == 0 {
            strips = [f]; totalHeight = f.height; anchorSig = sig
            maxStitchedOffset = off
            continue
        }
        switch Stitcher.analyze(prev: anchorSig ?? sig, next: sig) {
        case .matched(let d):
            if let strip = f.cropping(to: CGRect(x: 0, y: f.height - d, width: f.width, height: d)) {
                strips.append(strip); totalHeight += d; anchorSig = sig
                maxStitchedOffset = off
                outcomes.append("+\(d)")
            }
        case .noChange: outcomes.append("=")
        case .noOverlap: outcomes.append("x")
        }
    }
    let final = Stitcher.compose(strips: strips, totalHeight: totalHeight)!
    let expected = viewportH + Int(maxStitchedOffset.rounded())
    let heightOK = abs(final.height - expected) <= 4
    let badRatio = contentMismatch(final, ref: tall, checkH: min(final.height, tallH))
    let ok = heightOK && badRatio < 0.02
    return (ok, "outcomes=\(outcomes.joined(separator: " ")) | h=\(final.height)/\(expected) | mismatch=\(String(format: "%.1f%%", badRatio*100))")
}

// —— 场景 4：分栏布局（左侧 300px 固定边栏 + 右侧滚动），模拟应用的区域锁定逻辑 ——
func runSidebarSession(offsets: [Double], tallRight: CGImage) -> (ok: Bool, detail: String) {
    let sidebarW = 300
    let rightW = viewportW - sidebarW

    func composeFrame(at off: Double) -> CGImage {
        let ctx = CGContext(data: nil, width: viewportW, height: viewportH, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // 固定侧边栏：灰底 + 菜单行
        ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: sidebarW, height: viewportH))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let menuAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.black]
        for m in 0..<18 {
            ("菜单项 Item \(m)" as NSString).draw(at: NSPoint(x: 24, y: CGFloat(viewportH - 60 - m * 80)), withAttributes: menuAttr)
        }
        NSGraphicsContext.restoreGraphicsState()
        // 右侧滚动内容
        let right = frame(at: off, of: tallRight, width: rightW, height: viewportH)
        ctx.draw(right, in: CGRect(x: sidebarW, y: 0, width: rightW, height: viewportH))
        return ctx.makeImage()!
    }

    let first = composeFrame(at: offsets[0])
    let baseSig = Stitcher.rowSignatures(of: first)
    var strips = [first]
    var totalHeight = first.height
    var anchorSig = Stitcher.signature(of: first)
    var locked = false
    var activeRect: CGRect?
    var outcomes: [String] = []
    var maxStitchedOffset = offsets[0]

    for off in offsets.dropFirst() {
        let full = composeFrame(at: off)
        if !locked {
            let sigFull = Stitcher.rowSignatures(of: full)
            guard let rect = Stitcher.changedRect(baseSig: baseSig, newSig: sigFull, pixelWidth: full.width, pixelHeight: full.height),
                  rect.height >= 150 else { outcomes.append("·"); continue }
            locked = true
            if rect.width < CGFloat(full.width) * 0.9 || rect.height < CGFloat(full.height) * 0.85 {
                activeRect = rect
                let base = first.cropping(to: rect) ?? first
                strips = [base]
                totalHeight = base.height
                anchorSig = Stitcher.signature(of: base)
                outcomes.append("LOCK(\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height)))")
            }
        }
        let f: CGImage
        if let rect = activeRect, let cropped = full.cropping(to: rect) { f = cropped } else { f = full }
        let sig = Stitcher.signature(of: f)
        switch Stitcher.analyze(prev: anchorSig ?? sig, next: sig) {
        case .matched(let d):
            if let strip = f.cropping(to: CGRect(x: 0, y: f.height - d, width: f.width, height: d)) {
                strips.append(strip); totalHeight += d; anchorSig = sig
                maxStitchedOffset = off
                outcomes.append("+\(d)")
            }
        case .noChange: outcomes.append("=")
        case .noOverlap: outcomes.append("x")
        }
    }

    let final = Stitcher.compose(strips: strips, totalHeight: totalHeight)!
    guard let rect = activeRect else {
        return (false, "未锁定滚动区域 | outcomes=\(outcomes.joined(separator: " "))")
    }
    // 宽度必须只含右侧滚动区（侧边栏被剔除）
    let widthOK = Int(rect.minX) >= sidebarW - 20 && Int(rect.minX) <= sidebarW + 160 && abs(final.width - Int(rect.width)) <= 2
    // 内容与右侧原图对齐（从 rect.minY 对应行开始）
    let refTop = Int(rect.minY)
    let checkH = min(final.height, tallH - refTop)
    let refX = max(0, Int(rect.minX) - sidebarW)
    let ref = tallRight.cropping(to: CGRect(x: refX, y: refTop, width: rightW - refX, height: checkH))!
    // final 宽度 = rect.width（可能与 rightW 差一点列对齐），裁到共同宽度比较
    let commonW = min(final.width, rightW - refX)
    let finalC = final.cropping(to: CGRect(x: 0, y: 0, width: commonW, height: min(final.height, checkH)))!
    let refC = ref.cropping(to: CGRect(x: 0, y: 0, width: commonW, height: min(final.height, checkH)))!
    let badRatio = contentMismatch(finalC, ref: refC, checkH: min(final.height, checkH))
    let expectedH = Int(rect.height) + Int((maxStitchedOffset - offsets[0]).rounded())
    let heightOK = abs(final.height - expectedH) <= 6
    let ok = widthOK && heightOK && badRatio < 0.02
    return (ok, "outcomes=\(outcomes.joined(separator: " ")) | w=\(final.width) h=\(final.height)/\(expectedH) | mismatch=\(String(format: "%.1f%%", badRatio*100))")
}

let tall = makeTallImage(width: viewportW)
let s1 = runSession(offsets: [0, 0, 310.4, 622.9, 623.1, 934.6, 1247.2, 1100.0, 1247.2, 1558.7, 1871.3, 2183.9, 2495.4], tall: tall)
print("场景1 正常滚动: \(s1.ok ? "✅" : "❌") \(s1.detail)")
let s2 = runSession(offsets: [0, 420.3, 840.7, 2900.5, 2000.2, 2400.6, 2800.1, 3200.8], tall: tall)
print("场景2 快滚回接: \(s2.ok ? "✅" : "❌") \(s2.detail)")
let s3 = runSession(offsets: [0, 190.2, 380.5, 570.9, 761.3, 951.8], tall: tall)
print("场景3 周期陷阱: \(s3.ok ? "✅" : "❌") \(s3.detail)")
let tallRight = makeTallImage(width: viewportW - 300)
let s4 = runSidebarSession(offsets: [0, 0, 310.4, 622.9, 934.6, 1247.2, 1558.7, 1871.3], tallRight: tallRight)
print("场景4 固定侧边栏: \(s4.ok ? "✅" : "❌") \(s4.detail)")
let s5 = runSession(offsets: [0, 0, 180.4, 362.9, 545.6, 726.2, 908.7, 1090.3], tall: tall, scrollbar: true)
print("场景5 悬浮滚动条: \(s5.ok ? "✅" : "❌") \(s5.detail)")
// 场景6：静止画面 + 悬停高亮移动/光标闪烁，绝不能报 noOverlap
var s6ok = true
var s6outcomes: [String] = []
do {
    let hovers: [Double?] = [nil, 300, 620, nil, 940, 300, nil, 620]
    var anchor: FrameSig? = nil
    for (i, h) in hovers.enumerated() {
        let f = frame(at: 500.0, of: tall, width: viewportW, height: viewportH, scrollbar: false, hoverY: h)
        let sig = Stitcher.signature(of: f)
        if i == 0 { anchor = sig; continue }
        switch Stitcher.analyze(prev: anchor ?? sig, next: sig) {
        case .noChange: s6outcomes.append("=")
        case .matched(let d): s6outcomes.append("+\(d)"); s6ok = false
        case .noOverlap: s6outcomes.append("x"); s6ok = false
        }
    }
}
print("场景6 静止+悬停动态: \(s6ok ? "✅" : "❌") outcomes=\(s6outcomes.joined(separator: " "))")
print((s1.ok && s2.ok && s3.ok && s4.ok && s5.ok && s6ok) ? "ALL PASS" : "HAS FAIL")
