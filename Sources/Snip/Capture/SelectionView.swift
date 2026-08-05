import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

/// 选区交互视图：冻结帧铺底 + 挖洞遮罩 + 放大镜 + 窗口高亮。
/// 区域模式两阶段：拖拽框选 → 就地标注（工具条 + ✓ 确认）。
final class SelectionView: NSView {
    var onComplete: ((CGImage, CGFloat) -> Void)?
    var onWindowPick: ((SCWindow) -> Void)?
    var onCancel: (() -> Void)?
    var onModeToggle: (() -> Void)?
    /// 取色完成（色值已入剪贴板），由外部关闭覆盖层并提示
    var onColorPicked: ((String) -> Void)?
    /// OCR：交付选区裁切图，由外部识别并展示结果
    var onRecognizeText: ((CGImage) -> Void)?
    /// 长截图：交付框选区域（显示器像素坐标，顶部原点）
    var onScrollRegionPicked: ((CGRect) -> Void)?
    /// 另存为：交付合成图，由外部弹保存面板
    var onSaveRequested: ((CGImage, CGFloat) -> Void)?

    /// 截取用途：OCR 模式下框选即识别，不进标注阶段
    var purpose: CapturePurpose = .image

    var mode: CaptureMode = .region {
        didSet {
            selectionRect = .zero
            startPoint = nil
            // 切到窗口模式时立即按当前光标位置高亮，无需先动鼠标
            hoveredWindow = mode == .window
                ? pickableWindows.first { $0.rect.contains(mouseLocation) }
                : nil
            needsDisplay = true
        }
    }

    private let frozenImage: CGImage
    private let screenScale: CGFloat
    /// (窗口, 该窗口在本视图坐标系中的 rect)，按 z 序前置优先
    private let pickableWindows: [(window: SCWindow, rect: NSRect)]

    private var startPoint: NSPoint?
    private var selectionRect: NSRect = .zero
    private var mouseLocation: NSPoint = .zero
    private var hoveredWindow: (window: SCWindow, rect: NSRect)?

    // MARK: 标注阶段状态

    private enum Phase { case selecting, annotating }
    private var phase: Phase = .selecting
    private var annotations: [AnnotationElement] = []
    private var annotationUndoStack: [[AnnotationElement]] = []
    private var inProgress: AnnotationElement?
    private var dragAnchor: NSPoint?
    private var toolbarModel: OverlayToolbarModel?
    private var toolbarHost: NSView?
    private var toolbarCancellable: AnyCancellable?
    private var textEditor: NSTextField?
    private var editingElementID: UUID?
    /// 选区调整：0=整体移动，1~8=八方位手柄；画过标注后锁定
    private var adjust: (handle: Int, anchor: NSPoint, orig: NSRect)?
    private var selectionLocked: Bool { !annotations.isEmpty || textEditor != nil }
    /// 马赛克底图惰性生成
    private lazy var pixellatedFrozen: CGImage? =
        AnnotationRenderer.makePixellatedImage(from: frozenImage, scale: screenScale)

    init(
        frame: NSRect,
        frozenImage: CGImage,
        screenScale: CGFloat,
        pickableWindows: [(window: SCWindow, rect: NSRect)]
    ) {
        self.frozenImage = frozenImage
        self.screenScale = screenScale
        self.pickableWindows = pickableWindows
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 响应者 / 键盘

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 初始化光标位置，避免鼠标未动时放大镜/取色/窗口高亮落在 (0,0)
        if let window {
            mouseLocation = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
        if mode == .window {
            hoveredWindow = pickableWindows.first { $0.rect.contains(mouseLocation) }
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌘Z 撤销标注
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            undoAnnotation()
            return
        }
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 49 where phase == .selecting: // Space（长截图/OCR 专用通道不切模式）
            if purpose == .image { onModeToggle?() }
        case 36, 76: // 回车：确认完成
            if phase == .annotating { confirmAnnotatedCapture() }
        case 1 where event.modifierFlags.contains(.command): // ⌘S 另存为
            if phase == .annotating { saveAnnotatedCapture() }
        case 8: // C：取色
            if phase == .selecting {
                copyColorUnderCursor() // 选择阶段：取色即结束本次截取
            } else {
                pickColorAndStay(at: mouseLocation) // 标注阶段：取色不打断标注
            }
        default:
            // 标注阶段 R/O/A/T/P/M 切换工具
            if phase == .annotating,
               let char = event.charactersIgnoringModifiers?.lowercased().first,
               let tool = AnnotationTool.allCases.first(where: { $0.shortcutKey == char }) {
                toolbarModel?.tool = tool
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// 取色：光标像素颜色写入剪贴板，本次截取即完成
    private func copyColorUnderCursor() {
        guard mode == .region else { return }
        let px = Int(floor(mouseLocation.x * screenScale))
        let py = Int(floor((bounds.height - mouseLocation.y) * screenScale))
        guard px >= 0, py >= 0, px < frozenImage.width, py < frozenImage.height else { return }
        let hex = pixelColor(atX: px, y: py)
        guard hex.hasPrefix("#") else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
        onColorPicked?(hex)
    }

    /// 光标策略对齐钉钉 -[DTSCCaptureAreaView resetCursorRects]（反汇编所得映射）：
    /// - 八方位拖拽区：dt_resizeNorthSouth / NorthWestSouthEast /
    ///   NorthEastSouthWest / EastWest 四种双向箭头
    /// - 选区内部：isDraging ? closedHandCursor : openHandCursor
    /// - 选区未确定 / 绘制工具激活：crosshair
    override func resetCursorRects() {
        discardCursorRects()
        // 吸管取色：系统取色手感用十字
        if toolbarModel?.isPickingColor == true {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        // 窗口点选模式：箭头（钉钉悬停选窗同款）
        if mode == .window {
            addCursorRect(bounds, cursor: .arrow)
            return
        }
        // 标注阶段
        if phase == .annotating {
            if let tool = toolbarModel?.tool {
                // 绘制工具激活：文字用 I 形，其余十字
                addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
                return
            }
            // 未选工具：选区可调整
            if !selectionLocked {
                for (i, p) in handlePoints().enumerated() {
                    let hot = NSRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)
                    addCursorRect(hot, cursor: Self.handleCursor(index: i + 1))
                }
                // 选区内部：拖动中闭合手，否则张开手（钉钉 closedHand/openHand）
                addCursorRect(selectionRect, cursor: adjust != nil ? .closedHand : .openHand)
            }
            addCursorRect(bounds, cursor: .arrow)
            return
        }
        // 选区未确定：悬停到窗口上时用箭头提示“可点选”，否则十字
        if selectionRect.isEmpty, hoveredWindow != nil {
            addCursorRect(bounds, cursor: .arrow)
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    /// 手柄序号 → 方向光标（与钉钉四种 dt_resize* 一一对应）
    /// 1=左下 2=下 3=右下 4=左 5=右 6=左上 7=上 8=右上
    private static func handleCursor(index: Int) -> NSCursor {
        switch index {
        case 2, 7: .resizeUpDown                      // dt_resizeNorthSouth
        case 4, 5: .resizeLeftRight                   // dt_resizeEastWest
        case 1, 8: .snipResizeNESW                    // dt_resizeNorthEastSouthWest
        default: .snipResizeNWSE                      // dt_resizeNorthWestSouthEast (3,6)
        }
    }

    /// 交互状态变化时刷新光标（钉钉 needsUpdateCursor 同款）
    private func refreshCursor() {
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .mouseEnteredAndExited],
            owner: self
        ))
    }

    // MARK: - 鼠标

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if mode == .window {
            hoveredWindow = pickableWindows.first { $0.rect.contains(mouseLocation) }
        } else if phase == .selecting, startPoint == nil, selectionRect.isEmpty {
            // 钉钉式：区域模式下悬停自动高亮窗口，单击即选中该区域
            let before = hoveredWindow?.rect
            hoveredWindow = pickableWindows.first { $0.rect.contains(mouseLocation) }
            if before != hoveredWindow?.rect { refreshCursor() }
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .region else { return }
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            annotationMouseDown(at: point, clickCount: event.clickCount)
            return
        }
        startPoint = point
        selectionRect = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region else { return }
        mouseLocation = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            annotationMouseDragged(to: mouseLocation)
            return
        }
        guard let start = startPoint else { return }
        selectionRect = NSRect(
            x: min(start.x, mouseLocation.x),
            y: min(start.y, mouseLocation.y),
            width: abs(mouseLocation.x - start.x),
            height: abs(mouseLocation.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .window:
            if let hovered = hoveredWindow {
                onWindowPick?(hovered.window)
            }
        case .region:
            if phase == .annotating {
                annotationMouseUp()
                return
            }
            defer { startPoint = nil }
            if selectionRect.width < 4 || selectionRect.height < 4 {
                // 单击：选中悬停高亮的窗口区域（钉钉式）
                guard let hovered = hoveredWindow else {
                    selectionRect = .zero
                    needsDisplay = true
                    return
                }
                selectionRect = hovered.rect.intersection(bounds).integral
            }
            hoveredWindow = nil
            if purpose == .text || purpose == .scroll {
                // OCR/长截图：框选即交付，不进标注阶段
                let pixelRect = CGRect(
                    x: selectionRect.minX * screenScale,
                    y: (bounds.height - selectionRect.maxY) * screenScale,
                    width: selectionRect.width * screenScale,
                    height: selectionRect.height * screenScale
                ).integral
                if purpose == .scroll {
                    onScrollRegionPicked?(pixelRect)
                } else if let cropped = frozenImage.cropping(to: pixelRect) {
                    onComplete?(cropped, screenScale)
                } else {
                    onCancel?()
                }
                return
            }
            // 框选完成 → 进入就地标注阶段，等待 ✓ 确认
            enterAnnotationPhase()
        }
    }

    // MARK: - 标注阶段

    private func enterAnnotationPhase() {
        phase = .annotating
        window?.makeFirstResponder(self)

        let model = OverlayToolbarModel()
        model.onUndo = { [weak self] in self?.undoAnnotation() }
        model.onCancel = { [weak self] in self?.onCancel?() }
        model.onConfirm = { [weak self] in self?.confirmAnnotatedCapture() }
        model.onOCR = { [weak self] in self?.performOCR() }
        model.onScroll = { [weak self] in self?.startScrollFromSelection() }
        model.onSave = { [weak self] in self?.saveAnnotatedCapture() }
        toolbarModel = model
        // 工具/取色模式切换时重绘（如放大镜显隐）
        toolbarCancellable = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.needsDisplay = true
                self?.refreshCursor()
            }

        let host = NSHostingView(rootView: OverlayToolbar(model: model))
        addSubview(host)
        toolbarHost = host
        layoutToolbar()
        refreshCursor()
        needsDisplay = true
    }

    /// 工具条跟随选区：优先下方，其次上方，再其次选区内部
    private func layoutToolbar() {
        guard let host = toolbarHost else { return }
        let size = host.fittingSize
        var origin = NSPoint(
            x: selectionRect.maxX - size.width,
            y: selectionRect.minY - size.height - 8
        )
        if origin.y < bounds.minY + 8 {
            origin.y = selectionRect.maxY + 8
        }
        if origin.y + size.height > bounds.maxY - 8 {
            origin.y = selectionRect.minY + 8
        }
        origin.x = max(bounds.minX + 8, min(origin.x, bounds.maxX - size.width - 8))
        host.frame = NSRect(origin: origin, size: size)
    }

    /// 标注阶段取色：色值入剪贴板 + 轻提示，不结束截取、不丢标注
    private func pickColorAndStay(at point: NSPoint) {
        let px = Int(floor(point.x * screenScale))
        let py = Int(floor((bounds.height - point.y) * screenScale))
        guard px >= 0, py >= 0, px < frozenImage.width, py < frozenImage.height else { return }
        let hex = pixelColor(atX: px, y: py)
        guard hex.hasPrefix("#") else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
        toolbarModel?.isPickingColor = false
        Toast.show("已复制 \(hex)")
    }

    /// 工具条 OCR：裁切选区原图（不含标注）交给识别
    private func performOCR() {
        guard phase == .annotating else { return }
        commitTextEditorIfNeeded()
        let pixelRect = CGRect(
            x: selectionRect.minX * screenScale,
            y: (bounds.height - selectionRect.maxY) * screenScale,
            width: selectionRect.width * screenScale,
            height: selectionRect.height * screenScale
        ).integral
        if let cropped = frozenImage.cropping(to: pixelRect) {
            onRecognizeText?(cropped)
        }
    }

    /// 工具条长截图：以当前选区为滚动区域启动拼接会话
    private func startScrollFromSelection() {
        guard phase == .annotating else { return }
        commitTextEditorIfNeeded()
        let pixelRect = CGRect(
            x: selectionRect.minX * screenScale,
            y: (bounds.height - selectionRect.maxY) * screenScale,
            width: selectionRect.width * screenScale,
            height: selectionRect.height * screenScale
        ).integral
        onScrollRegionPicked?(pixelRect)
    }

    /// 工具条保存：合成后交给外部弹保存面板
    private func saveAnnotatedCapture() {
        guard phase == .annotating else { return }
        commitTextEditorIfNeeded()
        if let image = compositeSelection() {
            onSaveRequested?(image, screenScale)
        }
    }

    private func undoAnnotation() {
        guard phase == .annotating, let last = annotationUndoStack.popLast() else { return }
        annotations = last
        needsDisplay = true
    }

    private func annotationMouseDown(at point: NSPoint, clickCount: Int) {
        commitTextEditorIfNeeded()
        // 吸管取色模式：点击即取色，不画元素
        if toolbarModel?.isPickingColor == true {
            pickColorAndStay(at: point)
            return
        }
        if toolbarModel?.tool == nil {
            // 双击选区内 = 完成（钉钉式）
            if clickCount >= 2, selectionRect.contains(point) {
                confirmAnnotatedCapture()
                return
            }
            // 未选工具且未画标注：可拖手柄调整 / 拖内部移动选区
            if !selectionLocked {
                if let handle = handleHit(at: point) {
                    adjust = (handle, point, selectionRect)
                    refreshCursor()
                    return
                }
                if selectionRect.contains(point) {
                    adjust = (0, point, selectionRect)
                    refreshCursor()
                    return
                }
            }
            return
        }
        guard let tool = toolbarModel?.tool else { return }
        let color = toolbarModel?.color ?? .systemRed

        if tool == .text {
            beginTextEditing(at: point, color: color)
            return
        }
        var element = AnnotationElement(tool: tool, color: color)
        element.lineWidth = toolbarModel?.lineWidth ?? 3
        element.stepIndex = annotations.filter { $0.tool == .step }.count + 1
        switch tool {
        case .rect, .ellipse, .mosaic, .highlight:
            element.rect = NSRect(origin: point, size: .zero)
        case .line, .arrow:
            element.points = [point, point]
        case .pen:
            element.points = [point]
        case .step:
            // 序号：单击即落一个，rect.origin 记圆心
            element.rect = NSRect(origin: point, size: .zero)
            annotationUndoStack.append(annotations)
            annotations.append(element)
            needsDisplay = true
            return
        case .text:
            break
        }
        dragAnchor = point
        inProgress = element
    }

    private func annotationMouseDragged(to point: NSPoint) {
        if let a = adjust {
            applyAdjust(a, to: point)
            return
        }
        guard var element = inProgress else { return }
        switch element.tool {
        case .rect, .ellipse, .mosaic, .highlight:
            let start = dragAnchor ?? element.rect.origin
            element.rect = NSRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
        case .line, .arrow:
            element.points[1] = point
        case .pen:
            element.points.append(point)
        case .step, .text:
            break
        }
        inProgress = element
        needsDisplay = true
    }

    private func annotationMouseUp() {
        if adjust != nil {
            adjust = nil
            selectionRect = selectionRect.integral
            layoutToolbar()
            refreshCursor()
            needsDisplay = true
            return
        }
        defer {
            inProgress = nil
            dragAnchor = nil
            needsDisplay = true
        }
        guard let element = inProgress else { return }
        let meaningful: Bool = switch element.tool {
        case .pen: element.points.count >= 2
        case .line, .arrow: hypot(
            element.points[1].x - element.points[0].x,
            element.points[1].y - element.points[0].y
        ) >= 4
        case .step: true
        default: element.rect.width >= 6 && element.rect.height >= 6
        }
        if meaningful {
            annotationUndoStack.append(annotations)
            annotations.append(element)
        }
    }

    // MARK: 文字内联编辑

    private func beginTextEditing(at point: NSPoint, color: NSColor) {
        var element = AnnotationElement(tool: .text, color: color)
        element.rect = NSRect(origin: point, size: .zero)
        annotationUndoStack.append(annotations)
        annotations.append(element)
        editingElementID = element.id

        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 4, width: 220, height: element.fontSize + 10))
        field.font = NSFont.systemFont(ofSize: element.fontSize, weight: .semibold)
        field.textColor = color
        field.backgroundColor = NSColor.white.withAlphaComponent(0.6)
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "输入文字…"
        field.target = self
        field.action = #selector(textEditingCommitted)
        addSubview(field)
        window?.makeFirstResponder(field)
        textEditor = field
    }

    @objc private func textEditingCommitted() {
        commitTextEditorIfNeeded()
    }

    private func commitTextEditorIfNeeded() {
        guard let field = textEditor, let id = editingElementID else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = annotations.firstIndex(where: { $0.id == id }) {
            if text.isEmpty {
                annotations.remove(at: index)
                _ = annotationUndoStack.popLast()
            } else {
                annotations[index].text = text
            }
        }
        field.removeFromSuperview()
        textEditor = nil
        editingElementID = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: 选区调整（钩钉式手柄）

    /// 8 手柄位置：1~8 = 左下、下、右下、左、右、左上、上、右上
    private func handlePoints() -> [NSPoint] {
        let r = selectionRect
        return [
            NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.midX, y: r.minY), NSPoint(x: r.maxX, y: r.minY),
            NSPoint(x: r.minX, y: r.midY), NSPoint(x: r.maxX, y: r.midY),
            NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.midX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
        ]
    }

    private func handleHit(at point: NSPoint) -> Int? {
        for (i, p) in handlePoints().enumerated()
        where abs(p.x - point.x) <= 8 && abs(p.y - point.y) <= 8 {
            return i + 1
        }
        return nil
    }

    private func applyAdjust(_ a: (handle: Int, anchor: NSPoint, orig: NSRect), to point: NSPoint) {
        let dx = point.x - a.anchor.x
        let dy = point.y - a.anchor.y
        var r = a.orig
        switch a.handle {
        case 0: // 整体移动，限制在屏内
            r.origin.x = min(max(bounds.minX, r.origin.x + dx), bounds.maxX - r.width)
            r.origin.y = min(max(bounds.minY, r.origin.y + dy), bounds.maxY - r.height)
        case 1: r.origin.x += dx; r.size.width -= dx; r.origin.y += dy; r.size.height -= dy
        case 2: r.origin.y += dy; r.size.height -= dy
        case 3: r.size.width += dx; r.origin.y += dy; r.size.height -= dy
        case 4: r.origin.x += dx; r.size.width -= dx
        case 5: r.size.width += dx
        case 6: r.origin.x += dx; r.size.width -= dx; r.size.height += dy
        case 7: r.size.height += dy
        case 8: r.size.width += dx; r.size.height += dy
        default: break
        }
        var next = r.standardized.intersection(bounds)
        if next.width < 20 { next.size.width = 20 }
        if next.height < 20 { next.size.height = 20 }
        selectionRect = next
        layoutToolbar()
        needsDisplay = true
    }

    // MARK: 合成确认

    /// 冻结帧 + 标注全分辨率合成，裁切选区
    private func compositeSelection() -> CGImage? {
        let pixelRect = CGRect(
            x: selectionRect.minX * screenScale,
            y: (bounds.height - selectionRect.maxY) * screenScale,
            width: selectionRect.width * screenScale,
            height: selectionRect.height * screenScale
        ).integral

        // 无标注直接裁切，免去重绘成本
        if annotations.isEmpty {
            return frozenImage.cropping(to: pixelRect)
        }

        guard let ctx = CGContext(
            data: nil,
            width: frozenImage.width,
            height: frozenImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(frozenImage, in: CGRect(x: 0, y: 0, width: frozenImage.width, height: frozenImage.height))
        ctx.scaleBy(x: screenScale, y: screenScale)
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        for element in annotations {
            AnnotationRenderer.render(element, in: ctx, pixellatedImage: pixellatedFrozen, canvasSize: bounds.size)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()?.cropping(to: pixelRect)
    }

    /// ✓：合成后交付
    private func confirmAnnotatedCapture() {
        guard phase == .annotating else { return }
        commitTextEditorIfNeeded()
        if let image = compositeSelection() {
            onComplete?(image, screenScale)
        } else {
            onCancel?()
        }
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 冻结帧铺底
        ctx.draw(frozenImage, in: bounds)

        switch mode {
        case .region: drawRegionMode(in: ctx)
        case .window: drawWindowMode(in: ctx)
        }

        drawHint(in: ctx)
    }

    private func drawRegionMode(in ctx: CGContext) {
        // 悬停窗口高亮（选择阶段、尚未开始拖拽）
        let hoverRect: NSRect? = (phase == .selecting && selectionRect.isEmpty && startPoint == nil)
            ? hoveredWindow.map { $0.rect.intersection(bounds) }
            : nil

        // 暗色遮罩（even-odd 挖洞）
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        ctx.addRect(bounds)
        if !selectionRect.isEmpty {
            ctx.addRect(selectionRect)
        } else if let hoverRect {
            ctx.addRect(hoverRect)
        }
        ctx.fillPath(using: .evenOdd)

        if let hoverRect {
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(3)
            let path = CGPath(
                roundedRect: hoverRect.insetBy(dx: 1.5, dy: 1.5),
                cornerWidth: 8, cornerHeight: 8, transform: nil
            )
            ctx.addPath(path)
            ctx.strokePath()
        }

        if !selectionRect.isEmpty {
            // 标注阶段：已画元素 + 进行中元素，裁剪到选区内
            if phase == .annotating {
                ctx.saveGState()
                ctx.clip(to: selectionRect)
                for element in annotations where element.id != editingElementID {
                    AnnotationRenderer.render(element, in: ctx, pixellatedImage: pixellatedFrozen, canvasSize: bounds.size)
                }
                if let element = inProgress {
                    AnnotationRenderer.render(element, in: ctx, pixellatedImage: pixellatedFrozen, canvasSize: bounds.size)
                }
                ctx.restoreGState()
            }
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(1)
            ctx.stroke(selectionRect.insetBy(dx: -0.5, dy: -0.5))
            // 可调整阶段画 8 手柄
            if phase == .annotating, !selectionLocked, inProgress == nil {
                let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
                for p in handlePoints() {
                    let dot = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fillEllipse(in: dot)
                    ctx.setStrokeColor(accent.cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.strokeEllipse(in: dot)
                }
            }
            drawSizeLabel(in: ctx)
        }

        if phase == .selecting || toolbarModel?.isPickingColor == true {
            drawMagnifier(in: ctx)
        }
    }

    private func drawWindowMode(in ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        if let hovered = hoveredWindow {
            let rect = hovered.rect.intersection(bounds)
            // 遮罩挖洞 + 强调色描边
            ctx.addRect(bounds)
            ctx.addRect(rect)
            ctx.fillPath(using: .evenOdd)

            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(3)
            let path = CGPath(
                roundedRect: rect.insetBy(dx: 1.5, dy: 1.5),
                cornerWidth: 8, cornerHeight: 8, transform: nil
            )
            ctx.addPath(path)
            ctx.strokePath()
        } else {
            ctx.fill(bounds)
        }
    }

    // MARK: - 放大镜

    private func drawMagnifier(in ctx: CGContext) {
        let gridCount = 11           // 11×11 像素
        let cell: CGFloat = 10       // 每像素放大到 10pt
        let loupeSize = CGFloat(gridCount) * cell
        let labelHeight: CGFloat = 34

        // 光标对应的图像像素（原点左上）
        let px = floor(mouseLocation.x * screenScale)
        let py = floor((bounds.height - mouseLocation.y) * screenScale)
        guard px >= 0, py >= 0, px < CGFloat(frozenImage.width), py < CGFloat(frozenImage.height) else { return }

        // 放大镜位置：默认光标右下，贴边时翻转
        var origin = NSPoint(x: mouseLocation.x + 20, y: mouseLocation.y - 20 - loupeSize - labelHeight)
        if origin.x + loupeSize > bounds.maxX { origin.x = mouseLocation.x - 20 - loupeSize }
        if origin.y < bounds.minY { origin.y = mouseLocation.y + 20 }
        let loupeRect = NSRect(x: origin.x, y: origin.y + labelHeight, width: loupeSize, height: loupeSize)

        // 源区域裁剪（越界部分留黑）
        let half = CGFloat(gridCount / 2)
        let srcRect = CGRect(x: px - half, y: py - half, width: CGFloat(gridCount), height: CGFloat(gridCount))

        ctx.saveGState()
        let clipPath = CGPath(roundedRect: loupeRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(loupeRect)
        if let cropped = frozenImage.cropping(to: srcRect.intersection(
            CGRect(x: 0, y: 0, width: frozenImage.width, height: frozenImage.height)
        )) {
            // 越界裁剪后需要按偏移对齐绘制
            let clamped = srcRect.intersection(CGRect(x: 0, y: 0, width: frozenImage.width, height: frozenImage.height))
            let offsetX = (clamped.minX - srcRect.minX) * cell
            let offsetYTop = (clamped.minY - srcRect.minY) * cell
            let drawRect = NSRect(
                x: loupeRect.minX + offsetX,
                y: loupeRect.maxY - offsetYTop - clamped.height * cell,
                width: clamped.width * cell,
                height: clamped.height * cell
            )
            ctx.interpolationQuality = .none
            ctx.draw(cropped, in: drawRect)
            ctx.interpolationQuality = .default
        }
        ctx.restoreGState()

        // 中心像素十字标记
        let centerCell = NSRect(
            x: loupeRect.minX + half * cell,
            y: loupeRect.minY + half * cell,
            width: cell, height: cell
        )
        ctx.setStrokeColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1))
        ctx.setLineWidth(1.5)
        ctx.stroke(centerCell)

        // 边框
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
        ctx.setLineWidth(1)
        ctx.addPath(clipPath)
        ctx.strokePath()

        // 坐标 + 颜色标签
        let rgb = pixelColor(atX: Int(px), y: Int(py))
        let text = String(format: "(%d, %d)  %@", Int(px), Int(py), rgb) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let labelRect = NSRect(x: loupeRect.minX, y: origin.y, width: loupeSize, height: labelHeight - 6)
        let labelPath = CGPath(roundedRect: labelRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(labelPath)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.75))
        ctx.fillPath()
        text.draw(
            at: NSPoint(
                x: labelRect.midX - textSize.width / 2,
                y: labelRect.midY - textSize.height / 2
            ),
            withAttributes: attributes
        )
    }

    /// 读取冻结帧单个像素的十六进制颜色
    private func pixelColor(atX x: Int, y: Int) -> String {
        guard let cropped = frozenImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return "—" }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return "—" }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }

    // MARK: - 标签

    private func drawSizeLabel(in ctx: CGContext) {
        let w = Int(selectionRect.width * screenScale)
        let h = Int(selectionRect.height * screenScale)
        let text = "\(w) × \(h)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding: CGFloat = 5
        var labelOrigin = NSPoint(x: selectionRect.minX, y: selectionRect.maxY + 6)
        if labelOrigin.y + textSize.height + padding * 2 > bounds.maxY {
            labelOrigin.y = selectionRect.maxY - textSize.height - padding * 2 - 6
        }
        let labelRect = NSRect(
            x: labelOrigin.x, y: labelOrigin.y,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        let path = CGPath(roundedRect: labelRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.7))
        ctx.fillPath()
        text.draw(at: NSPoint(x: labelRect.minX + padding, y: labelRect.minY + padding), withAttributes: attributes)
    }

    private func drawHint(in ctx: CGContext) {
        // 拖拽中/标注阶段不显示顶部提示，减少干扰
        guard startPoint == nil, phase == .selecting else { return }
        let action = switch purpose {
        case .text: "框选识别文字"
        case .scroll: "框选要长截图的区域，松手后在里面滚动"
        case .image: "拖拽框选 · 点击选中窗口 · C 取色"
        }
        let windowAction = "点击选取窗口"
        let text = (mode == .region ? action : windowAction) + "  ·  Esc 取消" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let textSize = text.size(withAttributes: attributes)
        let labelRect = NSRect(
            x: bounds.midX - textSize.width / 2 - 14,
            y: bounds.maxY - 80,
            width: textSize.width + 28,
            height: textSize.height + 14
        )
        let path = CGPath(
            roundedRect: labelRect,
            cornerWidth: labelRect.height / 2, cornerHeight: labelRect.height / 2,
            transform: nil
        )
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fillPath()
        text.draw(
            at: NSPoint(x: labelRect.midX - textSize.width / 2, y: labelRect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }
}
