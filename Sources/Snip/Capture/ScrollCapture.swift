import AppKit
import ScreenCaptureKit
import SwiftUI

/// 滚动长截图会话（对齐钉钉 DTSCScrollScreenshotManager 机制）：
/// - 用户框选区域，在里面手动滚动；
/// - 【关键】用 addGlobalMonitorForEvents(.scrollWheel) 监听真实滚轮事件判定
///   “是否正在滚动”，而不是靠图像比较去猜 —— 因此静止时永不可能误报；
/// - 滚轮停止后防抖延时才抓帧（避开弹性动画未稳的中间帧）；
/// - “太快”提示来自单次滚轮位移过大（钉钉 scroll_toofast_tip 同策略）。
/// 无需任何额外权限。
@MainActor
final class ScrollCaptureSession: ObservableObject {
    /// 已拼接高度（pt），供 HUD 展示
    @Published private(set) var capturedPoints: Int = 0
    /// 单次滚动幅度过大，提示放慢（对齐钉钉：只看滚轮速度，不看拼接结果）
    @Published private(set) var scrollTooFast = false

    /// 用户框选区域（显示器像素坐标，顶部原点）
    private let pixelRegion: CGRect
    private let screen: NSScreen
    private let scale: CGFloat
    private let onFinish: (CGImage?) -> Void
    /// 保存回调（HUD 保存按钮）
    var onSave: ((CGImage) -> Void)?

    private var strips: [CGImage] = []
    private var anchorSig: FrameSig?
    private var totalHeight = 0
    private var hud: NSPanel?
    private var regionFrame: NSPanel?
    private var finished = false

    /// 滚轮事件监听（钉钉：add/remove scroll event monitor）
    private var scrollMonitor: Any?
    /// 持续抓帧循环（钉钉：start/stop manually scroll timer）
    private var loopTask: Task<Void, Never>?
    /// 最后一次滚轮事件时间，用于自适应抓帧频率
    private var lastScrollAt: Date?
    /// 捕帧器（只建一次，已排除 Snip 自身窗口）
    private var capturer: (filter: SCContentFilter, config: SCStreamConfiguration)?
    private var grabbing = false

    init(pixelRegion: CGRect, screen: NSScreen, onFinish: @escaping (CGImage?) -> Void) {
        self.pixelRegion = pixelRegion
        self.screen = screen
        self.scale = screen.backingScaleFactor
        self.onFinish = onFinish
    }

    func start() {
        showRegionFrame()
        showHUD()
        Task { [weak self] in
            await self?.prepareAndGrabFirst()
        }
    }

    /// ✓ 完成：合成交付
    func finish() {
        guard !finished else { return }
        finished = true
        teardown()
        let image = Stitcher.compose(strips: strips, totalHeight: totalHeight)
        onFinish(image)
    }

    /// 保存：合成当前已拼接结果并交给外部另存（钉钉 saveButton 同款）
    func saveNow() {
        guard !finished, let image = Stitcher.compose(strips: strips, totalHeight: totalHeight) else { return }
        onSave?(image)
    }

    /// ✕ 取消：丢弃
    func cancel() {
        guard !finished else { return }
        finished = true
        teardown()
        onFinish(nil)
    }

    private func teardown() {
        loopTask?.cancel()
        loopTask = nil
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        dismissHUD()
    }

    // MARK: - 抓帧（仅在滚轮停稳后触发）

    private func prepareAndGrabFirst() async {
        do {
            capturer = try await CaptureEngine.displayCapturer(for: screen)
            guard let first = try await grab() else {
                cancel()
                return
            }
            strips = [first]
            totalHeight = first.height
            anchorSig = Stitcher.signature(of: first)
            capturedPoints = Int(CGFloat(totalHeight) / scale)
            installScrollMonitor()
        } catch {
            NSLog("Snip: 长截图初始帧失败 \(error)")
            cancel()
        }
    }

    private func grab() async throws -> CGImage? {
        guard let capturer else { return nil }
        let full = try await SCScreenshotManager.captureImage(
            contentFilter: capturer.filter,
            configuration: capturer.config
        )
        return full.cropping(to: pixelRegion)
    }

    /// 对齐钉钉 DTSCScrollScreenshotManager：
    /// - addScrollEventMonitor：滚轮事件只用于“开始/保活”定时器与“太快”判定；
    /// - startScrollManuallyTimer：逆向可见其间隔为 0.5s，每次 tick 都
    ///   captureImageNeedStitch: —— 即“持续定时抓帧”，而非停手才抓。
    ///   本实现滚动中用更密的 0.25s（保证连续快滚也有重叠），
    ///   空闲时降为 0.5s；静止帧由 meanAbsDiff 忽略，不产生副作用。
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handleScroll(event) }
        }
        startCaptureTimer()
    }

    private func handleScroll(_ event: NSEvent) {
        guard !finished else { return }
        lastScrollAt = Date()
        // 单次位移过大提示放慢（钉钉 manually scroll TOO FAST!! 同策略）
        let step = abs(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10)
        if step > CGFloat(pixelRegion.height) / scale * 0.8 {
            scrollTooFast = true
        }
    }

    /// 持续定时抓帧（钉钉 scrollManuallyTimer 同构）
    private func startCaptureTimer() {
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled, await !self.finished {
                let scrolling = await self.isRecentlyScrolling
                try? await Task.sleep(nanoseconds: scrolling ? 250_000_000 : 500_000_000)
                guard !Task.isCancelled else { return }
                await self.stitchCurrentFrame()
            }
        }
    }

    private var isRecentlyScrolling: Bool {
        guard let last = lastScrollAt else { return false }
        return Date().timeIntervalSince(last) < 1.0
    }

    private func stitchCurrentFrame() async {
        guard !finished, !grabbing else { return }
        grabbing = true
        defer { grabbing = false }
        do {
            guard let frame = try await grab() else { return }
            let sig = Stitcher.signature(of: frame)
            if case .matched(let delta) = Stitcher.analyze(prev: anchorSig ?? sig, next: sig),
               let strip = frame.cropping(to: CGRect(
                   x: 0, y: frame.height - delta,
                   width: frame.width, height: delta
               )) {
                strips.append(strip)
                totalHeight += delta
                anchorSig = sig
                capturedPoints = Int(CGFloat(totalHeight) / scale)
                scrollTooFast = false
            }
            if totalHeight >= 60000 { finish() }
        } catch {
            NSLog("Snip: 长截图抓帧失败 \(error)")
        }
    }

    // MARK: - 控制 HUD / 选区边框

    /// 框选区域像素坐标(顶部原点) -> Cocoa 屏幕坐标
    private var regionPointRect: NSRect {
        NSRect(
            x: screen.frame.minX + pixelRegion.minX / scale,
            y: screen.frame.maxY - (pixelRegion.maxY / scale),
            width: pixelRegion.width / scale,
            height: pixelRegion.height / scale
        )
    }

    /// 滚动期间选区边框常驻（钉钉同款）：穿透鼠标，不入镜
    private func showRegionFrame() {
        let rect = regionPointRect.insetBy(dx: -3, dy: -3)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = RegionFrameView(frame: NSRect(origin: .zero, size: rect.size))
        panel.orderFrontRegardless()
        regionFrame = panel
    }

    private func showHUD() {
        let view = ScrollCaptureHUD(session: self)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize

        // 优先放在框选区域正下方，放不下则区域上方，再不行屏幕底部
        let visible = screen.visibleFrame
        let regionPt = regionPointRect
        var origin = NSPoint(x: regionPt.midX - size.width / 2, y: regionPt.minY - size.height - 12)
        if origin.y < visible.minY + 8 {
            origin.y = regionPt.maxY + 12
        }
        if origin.y + size.height > visible.maxY - 8 {
            origin.y = visible.minY + 40
        }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - size.width - 8))

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.orderFrontRegardless()
        hud = panel
    }

    private func dismissHUD() {
        hud?.orderOut(nil)
        hud = nil
        regionFrame?.orderOut(nil)
        regionFrame = nil
    }
}

/// 长截图选区边框：强调色描边 + 四角提示。
/// 光标对齐钉钉（grabbing_cursor / onScrollScreenshotCaptureAreaGrabStatusDidChange:）：
/// 区域内提示"可抓取滚动"的手型。边框浮层穿透鼠标，故用 NSCursor.set 主动设置。
private final class RegionFrameView: NSView {
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(rect)

        // 四角加粗提示（钉钉同款角标）
        let len: CGFloat = 16
        ctx.setLineWidth(4)
        for (cx, cy, dx, dy) in [
            (rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1.0, 1.0),
            (rect.minX, rect.maxY, 1.0, -1.0), (rect.maxX, rect.maxY, -1.0, -1.0),
        ] {
            ctx.move(to: CGPoint(x: cx, y: cy + CGFloat(dy) * len))
            ctx.addLine(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: cx + CGFloat(dx) * len, y: cy))
            ctx.strokePath()
        }
    }
}

/// 长截图控制条：进度 + ✕/✓
struct ScrollCaptureHUD: View {
    @ObservedObject var session: ScrollCaptureSession

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(session.scrollTooFast ? Color.orange : .red)
                .frame(width: 7, height: 7)

            Text(session.scrollTooFast ? "滚得太快了，请放慢" : "长截图中 · 在框选区域内滚动")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(session.scrollTooFast ? .orange : .white.opacity(0.9))

            Text("\(session.capturedPoints) pt")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)

            Divider().frame(height: 14).overlay(.white.opacity(0.3))

            Button {
                session.saveNow()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("保存长图")

            Button {
                session.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 24)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("取消")

            Button {
                session.finish()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.green))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("完成 (再按一次 ⇧⌘8 也可)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.8)))
        .fixedSize()
    }
}

/// 帧对齐结果
enum StitchOutcome {
    case noChange           // 画面没动
    case matched(Int)       // 拼上了，新增像素高度
    case noOverlap          // 画面变了但无法衔接（滚太快/回滚）
}

/// 单帧双分辨率签名：低分辨找候选，高分辨验真
struct FrameSig {
    let lo: [UInt8]   // 64 列，对齐搜索
    let hi: [UInt8]   // 256 列，候选验证（分辨出周期性版式里的编号差异）
    let height: Int
}

/// 帧对齐与拼接算法。
/// 关键设计：
/// 1. 模糊容差匹配（而非精确哈希）——平滑滚动是亚像素级的；
/// 2. 只用「特征行」打分 —— 避免空白区域假匹配；
/// 3. 低分辨候选 + 高分辨滑窗验真 —— 周期性版式（重复的列表项/段落，
///    仅编号不同）下幽灵对齐的平均差极小，但编号所在的局部窗口差很大，
///    高分辨滑窗能精确拒绝它。
enum Stitcher {
    static let loCols = 64
    static let hiCols = 256
    /// 比对时排除末尾列（右侧 ~3%）：macOS 悬浮滚动条在滚动时淡入，
    /// 会污染右边缘导致真匹配被误拒
    private static func usable(_ cols: Int) -> Int { cols - max(2, cols / 32) }

    static func signature(of image: CGImage) -> FrameSig {
        FrameSig(
            lo: sample(image, cols: loCols),
            hi: sample(image, cols: hiCols),
            height: image.height
        )
    }

    /// 兼容旧接口：仅低分辨签名（changedRect 用）
    static func rowSignatures(of image: CGImage) -> [UInt8] {
        sample(image, cols: loCols)
    }

    private static func sample(_ image: CGImage, cols: Int) -> [UInt8] {
        let height = image.height
        guard height > 0, let ctx = CGContext(
            data: nil,
            width: cols,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: cols,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: height))
        guard let data = ctx.data else { return [] }
        let buffer = data.bindMemory(to: UInt8.self, capacity: cols * height)
        return Array(UnsafeBufferPointer(start: buffer, count: cols * height))
    }

    /// 分析两帧关系：没动 / 拼接成功(新增高度) / 断开
    static func analyze(prev: FrameSig, next: FrameSig) -> StitchOutcome {
        let cols = loCols
        let height = min(prev.height, next.height)
        guard height > 120 else { return .noChange }

        // 1. 静止判定（对齐钉钉 IsImageSimilar:withLastImage:inThreshold:）：
        // 灰度+模糊后整幅平均结构差 ≤ 2/255 即视为同一画面。
        // 局部动态（光标闪烁/悬停高亮/正在输入）对全幅均值影响极小，
        // 因此天然免疫；而任何真滚动都会使均值差远超阈值。
        if meanAbsDiff(prev.lo, next.lo, cols: cols, height: height) <= 2.0 {
            return .noChange
        }

        // 2. 取 next 的「特征行」：与上一行差异明显的行（文字/边缘），
        //    空白均匀行不参与打分；跳过顶部 1/5（吸顶导航）
        var distinctive: [Int] = []
        let useLo = usable(cols)
        for y in stride(from: max(1, height / 5), to: height, by: 2) {
            var diff = 0
            let base = y * cols
            let prevBase = (y - 1) * cols
            for c in 0..<useLo {
                diff += abs(Int(next.lo[base + c]) - Int(next.lo[prevBase + c]))
            }
            if diff > useLo * 6 { distinctive.append(y) }
        }
        // 内容太素无法可靠对齐：按静止处理，宁不拼接也不误报断开
        guard distinctive.count >= 12 else { return .noChange }
        if distinctive.count > 60 {
            let step = distinctive.count / 60
            distinctive = stride(from: 0, to: distinctive.count, by: step).map { distinctive[$0] }
        }

        // 2.5 保底：大多数特征行原位就能对上（平移不到 2px），同样当静止
        let avgThreshold = Double(cols) * 12
        if staticMatchRatio(prev.lo, next.lo, cols: cols, rows: distinctive, height: height) >= 0.9 {
            return .noChange
        }

        // 3. 低分辨收集达标候选（按平均差升序）
        let maxDelta = height - 60
        var candidates: [(delta: Int, diff: Double)] = []
        for delta in stride(from: 2, to: maxDelta, by: 3) {
            let diff = avgDiff(prev.lo, next.lo, cols: cols, delta: delta, rows: distinctive, height: height)
            if diff <= avgThreshold { candidates.append((delta, diff)) }
        }
        candidates.sort { $0.diff < $1.diff }

        // 4. 对每个候选：低分辨精搜 + 高分辨 spike 评分，选 spike 最小者。
        //    真解的 spike 接近 0（仅亚像素模糊），幽灵周期解因编号/文字差异
        //    必有局部尖峰；取最小而非首个达标，保证真解在场时永远胜出
        var tried: [Int] = []
        var bestPick: (delta: Int, spike: Double, diff: Double)?
        for candidate in candidates {
            if tried.contains(where: { abs($0 - candidate.delta) < 12 }) { continue }
            tried.append(candidate.delta)
            if tried.count > 6 { break }

            var refined = candidate.delta
            var refinedDiff = candidate.diff
            for d in max(1, candidate.delta - 4)...min(maxDelta, candidate.delta + 4) where d != candidate.delta {
                let dd = avgDiff(prev.lo, next.lo, cols: cols, delta: d, rows: distinctive, height: height)
                if dd < refinedDiff {
                    refinedDiff = dd
                    refined = d
                }
            }
            let spike = hiResSpikeRatio(prev.hi, next.hi, delta: refined, rows: distinctive, height: height)
            NSLog("Snip[scroll]: cand=%d avgDiff=%.1f spike=%.2f", refined, refinedDiff, spike)
            if bestPick == nil || spike < bestPick!.spike - 0.001
                || (abs(spike - bestPick!.spike) <= 0.001 && refinedDiff < bestPick!.diff) {
                bestPick = (refined, spike, refinedDiff)
            }
        }
        // E2E 实测：合成页真匹配 spike ≤ 0.13；真实 Retina 文字边缘更锐利、
        // 悬停高亮等局部动态会押高，放宽到 0.22；幽灵解（错周期）仍 ≥ 0.3
        guard let pick = bestPick, pick.spike <= 0.22 else { return .noOverlap }
        return .matched(roundedDelta(prev.lo, next.lo, cols: cols, delta: pick.delta, rows: distinctive, height: height))
    }

    /// 整幅平均结构差（对齐钉钉 IsImageSimilar：gray + blur + subtract + mean）。
    /// 签名本身已是降采样灰度（等效模糊），此处逐行取与邻行的最小差，
    /// 吸收 ±1px 亚像素抖动后再求均值。
    private static func meanAbsDiff(
        _ prevSig: [UInt8], _ nextSig: [UInt8], cols: Int, height: Int
    ) -> Double {
        let use = usable(cols)
        guard height > 2, use > 0 else { return 0 }
        var sum = 0.0
        var count = 0
        for y in stride(from: 1, to: height - 1, by: 2) {
            let nb = y * cols
            for c in stride(from: 0, to: use, by: 2) {
                let n = Int(nextSig[nb + c])
                let d = min(
                    abs(n - Int(prevSig[nb + c])),
                    min(abs(n - Int(prevSig[(y - 1) * cols + c])),
                        abs(n - Int(prevSig[(y + 1) * cols + c])))
                )
                sum += Double(d)
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return sum / Double(count)
    }

    /// 静止判定：特征行在原位（含 ±1px 容差）匹配的占比
    private static func staticMatchRatio(
        _ prevSig: [UInt8], _ nextSig: [UInt8], cols: Int,
        rows: [Int], height: Int
    ) -> Double {
        let use = usable(cols)
        var matched = 0
        var total = 0
        for y in rows {
            guard y >= 1, y < height - 1 else { continue }
            var dSame = 0
            var dUp = 0
            var dDown = 0
            let nb = y * cols
            for c in 0..<use {
                let n = Int(nextSig[nb + c])
                dSame += abs(n - Int(prevSig[nb + c]))
                dUp += abs(n - Int(prevSig[(y - 1) * cols + c]))
                dDown += abs(n - Int(prevSig[(y + 1) * cols + c]))
            }
            total += 1
            if min(dSame, dUp, dDown) <= use * 10 { matched += 1 }
        }
        guard total >= 8 else { return 1 } // 样本不足视为静止，宁静勿误报
        return Double(matched) / Double(total)
    }

    /// 高分辨验真：统计尖峰行占比。
    /// 亚像素模糊是全行均匀小差；编号/文字不同是局部集中大差，
    /// 6 列滑窗极值超限即计为尖峰行。
    private static func hiResSpikeRatio(
        _ prevHi: [UInt8], _ nextHi: [UInt8],
        delta: Int, rows: [Int], height: Int
    ) -> Double {
        let cols = hiCols
        let use = usable(cols)
        let overlap = height - delta
        var spikes = 0
        var total = 0
        var buf = [Int](repeating: 0, count: cols)
        let win = 6
        let winLimit = win * 45

        for y in rows {
            guard y < overlap - 1 else { continue }
            var dA = 0
            var dB = 0
            var dM = 0
            let nb = y * cols
            let pa = (y + delta) * cols
            let pb = (y + delta + 1) * cols
            for c in 0..<use {
                let n = Int(nextHi[nb + c])
                let a = Int(prevHi[pa + c])
                let b = Int(prevHi[pb + c])
                dA += abs(n - a)
                dB += abs(n - b)
                dM += abs(n - (a + b) / 2)
            }
            let best = min(dA, dB, dM)
            for c in 0..<use {
                let n = Int(nextHi[nb + c])
                let a = Int(prevHi[pa + c])
                let b = Int(prevHi[pb + c])
                buf[c] = best == dA ? abs(n - a) : (best == dB ? abs(n - b) : abs(n - (a + b) / 2))
            }
            var window = 0
            for c in 0..<win { window += buf[c] }
            var windowMax = window
            for c in win..<use {
                window += buf[c] - buf[c - win]
                if window > windowMax { windowMax = window }
            }
            total += 1
            if windowMax > winLimit { spikes += 1 }
        }
        guard total >= 8 else { return 1 }
        return Double(spikes) / Double(total)
    }

    /// 给定 delta 下特征行平均差（三变体 d/d+1/50%混合取最小）
    private static func avgDiff(
        _ prevSig: [UInt8], _ nextSig: [UInt8], cols: Int,
        delta: Int, rows: [Int], height: Int
    ) -> Double {
        let overlap = height - delta
        let use = usable(cols)
        var sum = 0.0
        var total = 0
        for y in rows {
            guard y < overlap - 1 else { continue }
            var dA = 0
            var dB = 0
            var dM = 0
            let nb = y * cols
            let pa = (y + delta) * cols
            let pb = (y + delta + 1) * cols
            for c in 0..<use {
                let n = Int(nextSig[nb + c])
                let a = Int(prevSig[pa + c])
                let b = Int(prevSig[pb + c])
                dA += abs(n - a)
                dB += abs(n - b)
                dM += abs(n - (a + b) / 2)
            }
            sum += Double(min(dA, dB, dM))
            total += 1
        }
        guard total >= 8 else { return .greatestFiniteMagnitude }
        return sum / Double(total)
    }

    /// 两帧差异的包围盒（像素坐标，顶部原点）：用于锁定分栏布局的实际滚动区域
    static func changedRect(
        baseSig: [UInt8], newSig: [UInt8],
        pixelWidth: Int, pixelHeight: Int
    ) -> CGRect? {
        let cols = loCols
        let height = min(baseSig.count, newSig.count) / cols
        guard height > 0 else { return nil }
        var colHits = [Int](repeating: 0, count: cols)
        var rowMin = Int.max
        var rowMax = -1
        for y in stride(from: 0, to: height, by: 2) {
            let base = y * cols
            var rowHit = 0
            for c in 0..<cols where abs(Int(newSig[base + c]) - Int(baseSig[base + c])) > 24 {
                colHits[c] += 1
                rowHit += 1
            }
            if rowHit >= 2 {
                rowMin = min(rowMin, y)
                rowMax = max(rowMax, y)
            }
        }
        guard rowMax >= 0 else { return nil }
        let colThreshold = max(3, height / 100)
        var cMin = Int.max
        var cMax = -1
        for c in 0..<cols where colHits[c] > colThreshold {
            cMin = min(cMin, c)
            cMax = max(cMax, c)
        }
        guard cMax >= 0 else { return nil }
        let colWidth = Double(pixelWidth) / Double(cols)
        let x = floor(Double(cMin) * colWidth)
        let x2 = ceil(Double(cMax + 1) * colWidth)
        let y0 = max(0, rowMin - 2)
        let y1 = min(pixelHeight, rowMax + 3)
        return CGRect(x: x, y: Double(y0), width: min(Double(pixelWidth) - x, x2 - x), height: Double(y1 - y0)).integral
    }

    /// 比较 d 与 d+1 单行对齐的总差异，选更优者
    private static func roundedDelta(
        _ prevSig: [UInt8], _ nextSig: [UInt8], cols: Int,
        delta: Int, rows: [Int], height: Int
    ) -> Int {
        let overlap = height - delta
        let use = usable(cols)
        var sumA = 0
        var sumB = 0
        for y in rows {
            guard y < overlap - 1 else { continue }
            let nextBase = y * cols
            let prevBaseA = (y + delta) * cols
            let prevBaseB = (y + delta + 1) * cols
            for c in 0..<use {
                let n = Int(nextSig[nextBase + c])
                sumA += abs(n - Int(prevSig[prevBaseA + c]))
                sumB += abs(n - Int(prevSig[prevBaseB + c]))
            }
        }
        return sumB < sumA ? delta + 1 : delta
    }

    /// 两帧是否几乎相同（采样行容差比较）
    private static func framesAlmostEqual(_ prevSig: [UInt8], _ nextSig: [UInt8], height: Int) -> Bool {
        let cols = loCols
        let use = usable(cols)
        var changedRows = 0
        var total = 0
        for y in stride(from: 0, to: height, by: 4) {
            var diff = 0
            let base = y * cols
            for c in 0..<use {
                diff += abs(Int(nextSig[base + c]) - Int(prevSig[base + c]))
            }
            if diff > use * 4 { changedRows += 1 }
            total += 1
        }
        return total > 0 && Double(changedRows) / Double(total) < 0.02
    }

    static func compose(strips: [CGImage], totalHeight: Int) -> CGImage? {
        guard let width = strips.first?.width, totalHeight > 0,
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: totalHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        var top = 0
        for strip in strips {
            let y = totalHeight - top - strip.height
            ctx.draw(strip, in: CGRect(x: 0, y: y, width: strip.width, height: strip.height))
            top += strip.height
        }
        return ctx.makeImage()
    }
}
