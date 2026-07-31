import AppKit
import Combine

/// 标注画布：底图 + 矢量元素实时渲染，支持绘制新元素、选中拖动、内联文字编辑。
final class AnnotationCanvasView: NSView {
    private let document: AnnotationDocument
    private var cancellables: Set<AnyCancellable> = []

    /// 交互状态
    private enum DragState {
        case none
        case drawing(AnnotationElement)
        case moving(id: UUID, last: NSPoint)
    }

    private var dragState: DragState = .none
    private var textEditor: NSTextField?
    private var editingElementID: UUID?

    init(document: AnnotationDocument) {
        self.document = document
        super.init(frame: NSRect(origin: .zero, size: document.canvasSize))
        wantsLayer = true
        document.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 53: // Esc：取消选中，无选中则关窗
            if document.selectedID != nil {
                document.selectedID = nil
            } else {
                window?.close()
            }
        case 51, 117: // Delete / Fn+Delete
            document.deleteSelected()
        default:
            // R/O/A/T/P/M 切换工具
            if let char = event.charactersIgnoringModifiers?.lowercased().first,
               let tool = AnnotationTool.allCases.first(where: { $0.shortcutKey == char }) {
                document.tool = tool
                document.selectedID = nil
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        commitTextEditorIfNeeded()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        // 命中已有元素（后画的在上层）→ 选中并进入移动
        if let hit = document.elements.last(where: { $0.boundingBox.contains(point) }) {
            document.selectedID = hit.id
            document.snapshot()
            dragState = .moving(id: hit.id, last: point)
            return
        }
        document.selectedID = nil

        // 文字工具：单击即放置编辑框
        if document.tool == .text {
            beginTextEditing(at: point)
            return
        }

        // 其余工具：开始绘制
        var element = AnnotationElement(tool: document.tool, color: document.color)
        element.stepIndex = document.elements.filter { $0.tool == .step }.count + 1
        switch document.tool {
        case .rect, .ellipse, .mosaic, .highlight:
            element.rect = NSRect(origin: point, size: .zero)
        case .line, .arrow:
            element.points = [point, point]
        case .pen:
            element.points = [point]
        case .step:
            element.rect = NSRect(origin: point, size: .zero)
            document.snapshot()
            document.elements.append(element)
            needsDisplay = true
            return
        case .text:
            break
        }
        dragAnchor = point
        dragState = .drawing(element)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch dragState {
        case .none:
            break
        case .drawing(var element):
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
            dragState = .drawing(element)
            needsDisplay = true
        case .moving(let id, let last):
            let delta = NSPoint(x: point.x - last.x, y: point.y - last.y)
            if let index = document.elements.firstIndex(where: { $0.id == id }) {
                document.elements[index].translate(by: delta)
            }
            dragState = .moving(id: id, last: point)
        }
    }

    /// 绘制矩形类元素时的固定锚点（按下位置）
    private var dragAnchor: NSPoint?

    override func mouseUp(with event: NSEvent) {
        switch dragState {
        case .drawing(let element):
            let big = element.boundingBox
            let meaningful: Bool = switch element.tool {
            case .pen: element.points.count >= 2
            case .step: true
            case .line, .arrow: hypot(
                element.points[1].x - element.points[0].x,
                element.points[1].y - element.points[0].y
            ) >= 4
            default: big.width >= 8 && big.height >= 8
            }
            if meaningful {
                document.snapshot()
                document.elements.append(element)
            }
        case .moving, .none:
            break
        }
        dragState = .none
        dragAnchor = nil
        needsDisplay = true
    }

    // MARK: - 文字内联编辑

    private func beginTextEditing(at point: NSPoint) {
        var element = AnnotationElement(tool: .text, color: document.color)
        element.rect = NSRect(origin: point, size: .zero)
        document.snapshot()
        document.elements.append(element)
        editingElementID = element.id

        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 4, width: 220, height: element.fontSize + 10))
        field.font = NSFont.systemFont(ofSize: element.fontSize, weight: .semibold)
        field.textColor = element.color
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

    func commitTextEditorIfNeeded() {
        guard let field = textEditor, let id = editingElementID else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = document.elements.firstIndex(where: { $0.id == id }) {
            if text.isEmpty {
                document.elements.remove(at: index)
            } else {
                document.elements[index].text = text
            }
        }
        field.removeFromSuperview()
        textEditor = nil
        editingElementID = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(document.baseImage, in: bounds)

        for element in document.elements where element.id != editingElementID {
            AnnotationRenderer.render(
                element, in: ctx,
                pixellatedImage: document.pixellatedImage,
                canvasSize: document.canvasSize
            )
        }

        if case .drawing(let element) = dragState {
            AnnotationRenderer.render(
                element, in: ctx,
                pixellatedImage: document.pixellatedImage,
                canvasSize: document.canvasSize
            )
        }

        // 选中态：虚线包围盒
        if let id = document.selectedID,
           let selected = document.elements.first(where: { $0.id == id }) {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(selected.boundingBox)
            ctx.setLineDash(phase: 0, lengths: [])
        }
    }
}
