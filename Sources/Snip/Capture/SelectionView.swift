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
        case 49 where phase == .selecting: // Space
            onModeToggle?()
        case 36, 76: // 回车：确认完成
            if phase == .annotating { confirmAnnotatedCapture() }
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
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
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .region else { return }
        let point = convert(event.locationInWindow, from: nil)
        if phase == .annotating {
            annotationMouseDown(at: point)
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
            guard selectionRect.width >= 2, selectionRect.height >= 2 else {
                selectionRect = .zero
                needsDisplay = true
                return
            }
            if purpose == .text {
                // OCR：框选即交付裁切图，不进标注阶段
                let pixelRect = CGRect(
                    x: selectionRect.minX * screenScale,
                    y: (bounds.height - selectionRect.maxY) * screenScale,
                    width: selectionRect.width * screenScale,
                    height: selectionRect.height * screenScale
                ).integral
                if let cropped = frozenImage.cropping(to: pixelRect) {
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
        toolbarModel = model
        // 工具/取色模式切换时重绘（如放大镜显隐）
        toolbarCancellable = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsDisplay = true }

        let host = NSHostingView(rootView: OverlayToolbar(model: model))
        addSubview(host)
        toolbarHost = host
        layoutToolbar()
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

    private func undoAnnotation() {
        guard phase == .annotating, let last = annotationUndoStack.popLast() else { return }
        annotations = last
        needsDisplay = true
    }

    private func annotationMouseDown(at point: NSPoint) {
        commitTextEditorIfNeeded()
        // 吸管取色模式：点击即取色，不画元素
        if toolbarModel?.isPickingColor == true {
            pickColorAndStay(at: point)
            return
        }
        guard let tool = toolbarModel?.tool else { return }
        let color = toolbarModel?.color ?? .systemRed

        if tool == .text {
            beginTextEditing(at: point, color: color)
            return
        }
        var element = AnnotationElement(tool: tool, color: color)
        switch tool {
        case .rect, .ellipse, .mosaic:
            element.rect = NSRect(origin: point, size: .zero)
        case .arrow:
            element.points = [point, point]
        case .pen:
            element.points = [point]
        case .text:
            break
        }
        dragAnchor = point
        inProgress = element
    }

    private func annotationMouseDragged(to point: NSPoint) {
        guard var element = inProgress else { return }
        switch element.tool {
        case .rect, .ellipse, .mosaic:
            let start = dragAnchor ?? element.rect.origin
            element.rect = NSRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
        case .arrow:
            element.points[1] = point
        case .pen:
            element.points.append(point)
        case .text:
            break
        }
        inProgress = element
        needsDisplay = true
    }

    private func annotationMouseUp() {
        defer {
            inProgress = nil
            dragAnchor = nil
            needsDisplay = true
        }
        guard let element = inProgress else { return }
        let meaningful: Bool = switch element.tool {
        case .pen: element.points.count >= 2
        case .arrow: hypot(
            element.points[1].x - element.points[0].x,
            element.points[1].y - element.points[0].y
        ) >= 4
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

    // MARK: 合成确认

    /// ✓：冻结帧 + 标注全分辨率合成，裁切选区后交付
    private func confirmAnnotatedCapture() {
        guard phase == .annotating else { return }
        commitTextEditorIfNeeded()

        let pixelRect = CGRect(
            x: selectionRect.minX * screenScale,
            y: (bounds.height - selectionRect.maxY) * screenScale,
            width: selectionRect.width * screenScale,
            height: selectionRect.height * screenScale
        ).integral

        // 无标注直接裁切，免去重绘成本
        if annotations.isEmpty {
            if let cropped = frozenImage.cropping(to: pixelRect) {
                onComplete?(cropped, screenScale)
            } else {
                onCancel?()
            }
            return
        }

        guard let ctx = CGContext(
            data: nil,
            width: frozenImage.width,
            height: frozenImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            onCancel?()
            return
        }
        ctx.draw(frozenImage, in: CGRect(x: 0, y: 0, width: frozenImage.width, height: frozenImage.height))
        ctx.scaleBy(x: screenScale, y: screenScale)
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        for element in annotations {
            AnnotationRenderer.render(element, in: ctx, pixellatedImage: pixellatedFrozen, canvasSize: bounds.size)
        }
        NSGraphicsContext.restoreGraphicsState()

        if let full = ctx.makeImage(), let cropped = full.cropping(to: pixelRect) {
            onComplete?(cropped, screenScale)
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
        // 暗色遮罩（even-odd 挖洞）
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        ctx.addRect(bounds)
        if !selectionRect.isEmpty { ctx.addRect(selectionRect) }
        ctx.fillPath(using: .evenOdd)

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
        let action = purpose == .text ? "框选识别文字" : "拖拽选取区域  ·  C 取色"
        let text = (mode == .region ? action : "点击选取窗口") + "  ·  Space 切换  ·  Esc 取消" as NSString
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
