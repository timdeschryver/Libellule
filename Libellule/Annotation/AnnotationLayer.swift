import SwiftUI

/// Text being typed directly on the surface.
struct TextEditing: Equatable {
    var origin: CGPoint
    var text: String
    var color: Color.Resolved
    var lineWidth: CGFloat
    var style = TextStyle()
    /// Set when an existing text annotation is being re-edited.
    var replacing: UUID?

    var fontSize: CGFloat { style.fontSize ?? Annotation.fontSize(lineWidth: lineWidth) }

    /// The field's box while typing, in surface points, given the `room` to the right of the origin: a box of its
    /// own width, or else just as wide as the text (with space for the caret), up to the room. The text wraps at
    /// `wrapWidth`, which is where the placed text wraps too.
    func fieldBox(room: CGFloat) -> (width: CGFloat, height: CGFloat, wrapWidth: CGFloat) {
        let wrapWidth = min(style.width ?? room, room)
        let height = max(AnnotationRenderer.textSize(text, fontSize: fontSize, width: wrapWidth).height, fontSize * 1.25)
        if style.width != nil {
            return (wrapWidth, height, wrapWidth)
        }
        // Measured without a width: with one, the measure is the width itself.
        let natural = AnnotationRenderer.textSize(text, fontSize: fontSize, width: nil).width
        return (min(room, natural + fontSize * 0.8), height, wrapWidth)
    }
}

/// Shapes copied or cut from one surface, ready to paste on any other: the live overlays and every editor share it.
@Observable
final class AnnotationClipboard {
    static let shared = AnnotationClipboard()

    private(set) var annotations: [Annotation] = []

    var isEmpty: Bool { annotations.isEmpty }

    func put(_ annotations: [Annotation]) {
        self.annotations = annotations
    }
}

/// The annotations on one surface of `size` points, with drag handling, selection and undo.
@Observable
final class AnnotationLayer {
    /// Changes only when the editor crops the picture or adds space around it.
    private(set) var size: CGSize
    let toolbox: AnnotationToolbox
    let undoManager: UndoManager

    private(set) var annotations: [Annotation]
    private(set) var inProgress: Annotation?
    private(set) var selectedIDs: Set<UUID> = []
    /// The rectangle being dragged out with the select tool over empty space.
    private(set) var marquee: CGRect?
    var textEditing: TextEditing?
    /// Darkens the whole surface (highlights stay bright). Not part of undo: it's a switch, not a stroke.
    var dimsLights = false
    /// A whiteboard or blackboard under the drawing; a switch like `dimsLights`.
    var board: Board?
    /// The drawings are kept but not shown, so the screen underneath can be seen for a moment.
    var isHidden = false
    /// While presenting: where the pointer is, in surface points, so a bright circle can follow it.
    var pointerSpotlight: CGPoint?
    /// Likewise for the live loupe: where to draw a magnifier sitting on the pointer.
    var pointerLoupe: CGPoint?
    /// Likewise for the cursor mark (see `CursorStyle`).
    var pointerMark: CGPoint?
    /// The picture under this surface, for pixelate, blur and the magnifier: the capture in the editor,
    /// a fresh snapshot of the screen behind the overlay in live mode, nil while there is none.
    var backdrop: AnnotationRenderer.Backdrop?

    /// Live mode's fading ink: new drawings disappear on their own shortly after the pen stops.
    var fadesInk = false
    /// Drawings made with fading ink. They stay out of `annotations` and the undo history, and all fade
    /// together, so a circle and an arrow drawn one after the other go at the same time.
    private(set) var fadingAnnotations: [Annotation] = []
    /// 1 while they're fully shown, down to 0 as they go.
    private(set) var fadingOpacity: Double = 1
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    /// How long fading ink stays before it goes; a setting.
    static var fadeDelay: Duration { .seconds(Preferences.fadeDelay) }

    /// The radius of the bright circle that follows the pointer; a setting.
    var pointerSpotlightRadius: CGFloat { CGFloat(Preferences.spotlightRadius) }

    // Drag bookkeeping (not observed: it changes dozens of times per second).
    @ObservationIgnored private var isDragging = false
    @ObservationIgnored private var pendingTap: CGPoint?
    @ObservationIgnored private var textDragEnd: CGPoint?
    @ObservationIgnored private var moving: [(id: UUID, original: Annotation)] = []
    @ObservationIgnored private var beforeMove: [Annotation]?
    @ObservationIgnored private var moveActionName = "Move"
    @ObservationIgnored private var resizingText: (id: UUID, original: Annotation, edge: HorizontalEdge)?
    /// The drag's double-click opened a text for typing, so the rest of the drag means nothing.
    @ObservationIgnored private var dragOpenedText = false
    @ObservationIgnored private var marqueeBase: Set<UUID>?
    @ObservationIgnored private var erasing: [Annotation]?
    @ObservationIgnored private var lastErasePoint: CGPoint?
    /// The step numbers that were on the surface when the count was last restarted; the next number ignores them.
    @ObservationIgnored private var badgesBeforeReset: Set<UUID> = []

    init(size: CGSize, toolbox: AnnotationToolbox = AnnotationToolbox(), undoManager: UndoManager = UndoManager(), annotations: [Annotation] = [], dimsLights: Bool = false, board: Board? = nil) {
        self.size = size
        self.toolbox = toolbox
        self.undoManager = undoManager
        self.annotations = annotations
        self.dimsLights = dimsLights
        self.board = board
        // Each change is its own undo step, even when several land in one run-loop pass.
        undoManager.groupsByEvent = false
    }

    /// Committed annotations followed by the one currently being drawn. A text that is open for typing again
    /// stays out: the field shows it, and under the field it would show twice.
    var visibleAnnotations: [Annotation] {
        var shown = annotations
        if let replacing = textEditing?.replacing {
            shown.removeAll { $0.id == replacing }
        }
        if let inProgress {
            shown.append(inProgress)
        }
        return shown
    }

    // MARK: - Selection

    var hasSelection: Bool { !selectedIDs.isEmpty }

    /// The selected annotations, in drawing order.
    var selectedAnnotations: [Annotation] {
        annotations.filter { selectedIDs.contains($0.id) }
    }

    /// The one selected annotation, when exactly one is.
    var selectedAnnotation: Annotation? {
        guard selectedIDs.count == 1 else { return nil }
        return selectedAnnotations.first
    }

    func select(_ ids: some Sequence<UUID>) {
        selectedIDs = Set(ids).intersection(annotations.map(\.id))
    }

    func selectAll() {
        commitTextEditing()
        selectedIDs = Set(annotations.map(\.id))
    }

    func clearSelection() {
        selectedIDs = []
    }

    var nextBadgeNumber: Int {
        let numbers = (annotations + fadingAnnotations).compactMap { annotation -> Int? in
            guard !badgesBeforeReset.contains(annotation.id), case .badge(let number, _) = annotation.shape else { return nil }
            return number
        }
        return (numbers.max() ?? 0) + 1
    }

    /// The next step number placed is 1 again; the ones on the surface keep their numbers.
    func resetBadgeNumbers() {
        badgesBeforeReset = Set((annotations + fadingAnnotations).compactMap { annotation in
            if case .badge = annotation.shape { annotation.id } else { nil }
        })
    }

    // MARK: - Drawing

    /// Called continuously while the pointer drags; `start` and `current` are in surface points.
    /// `optionHeld` (⌥) makes the select tool move a copy instead of the shape itself, and grows areas out
    /// from the point the drag started at. `extending` (⇧) adds to the selection instead of replacing it.
    /// `clickCount` is 2 on the second click of a double-click, which opens a text for typing.
    func updateDrag(from start: CGPoint, to current: CGPoint, constrained: Bool, optionHeld: Bool = false, extending: Bool = false, clickCount: Int = 1) {
        let surface = CGRect(origin: .zero, size: size)
        let a = start.clamped(to: surface)
        let b = current.clamped(to: surface)
        if !isDragging {
            isDragging = true
            commitTextEditing()
            dragBegan(at: a, optionHeld: optionHeld, extending: extending, clickCount: clickCount)
            holdFading()
        }
        guard !dragOpenedText else { return }
        // With Shift, lines and the lens snap to 45° and areas become squares.
        let end = constrained ? Self.snappedToAngle(from: a, to: b) : b
        let area = optionHeld ? CGRect(center: a, corner: b, square: constrained) : CGRect(from: a, to: b, square: constrained)
        func draw(_ shape: Annotation.Shape) {
            inProgress = Annotation(shape: shape, color: toolbox.resolvedColor, lineWidth: toolbox.lineWidth)
        }

        switch toolbox.tool {
        case .select:
            if let resizingText {
                resizeText(resizingText, to: b)
            } else if !moving.isEmpty {
                let delta = CGPoint(x: b.x - a.x, y: b.y - a.y)
                for item in moving {
                    if let index = annotations.firstIndex(where: { $0.id == item.id }) {
                        annotations[index] = item.original.translated(by: delta)
                    }
                }
            } else if marquee != nil {
                marquee = CGRect(from: a, to: b, square: false)
            }
        case .eraser:
            erase(to: b)
        case .text:
            pendingTap = a  // placed on release; a drag sets the width
            textDragEnd = b
        case .badge:
            pendingTap = a
        case .freehand, .highlighter:
            let stroke = toolbox.tool == .highlighter ? Annotation.Shape.highlight : Annotation.Shape.freehand
            if let points = inProgress.map({ Self.points(of: $0.shape) }), let last = points.last {
                if hypot(b.x - last.x, b.y - last.y) >= 1 {
                    inProgress?.shape = stroke(points + [b])
                }
            } else {
                draw(stroke([a]))
            }
        case .line: draw(.line(from: a, to: end))
        case .arrow: draw(.arrow(from: a, to: end))
        case .measure: draw(.measure(from: a, to: end))
        case .rectangle: draw(.rectangle(area))
        case .ellipse: draw(.ellipse(area))
        case .pixelate: draw(.pixelate(area))
        case .spotlight: draw(.spotlight(area))
        case .blur: draw(.blur(area))
        case .magnifier:
            // The drag starts on the detail and ends where the lens should sit; a click leaves the lens on the spot.
            draw(.magnifier(source: a, lens: end))
        }
    }

    private func dragBegan(at point: CGPoint, optionHeld: Bool, extending: Bool, clickCount: Int) {
        // A double-click on a text opens it for typing, with any tool whose click alone leaves no mark.
        if clickCount >= 2, Self.doubleClickEditsText(with: toolbox.tool), editText(at: point) {
            dragOpenedText = true
            return
        }
        switch toolbox.tool {
        case .select:
            selectDragBegan(at: point, duplicating: optionHeld, extending: extending)
        case .eraser:
            erasing = annotations
            lastErasePoint = point
            erase(to: point)
        default:
            break
        }
    }

    private func selectDragBegan(at point: CGPoint, duplicating: Bool, extending: Bool) {
        guard let hit = annotations.last(where: { $0.hitTest(point) }) else {
            // Empty space: start a marquee; without ⇧ it replaces the selection.
            if !extending { selectedIDs = [] }
            marqueeBase = extending ? selectedIDs : []
            marquee = CGRect(origin: point, size: .zero)
            moving = []
            beforeMove = nil
            return
        }
        // The sides of a lone selected text are handles for its width.
        if selectedIDs == [hit.id], case .text = hit.shape, let edge = textEdge(of: hit, at: point) {
            beforeMove = annotations
            resizingText = (hit.id, hit, edge)
            return
        }
        if extending {
            // ⇧-click adds or removes; it doesn't drag.
            if selectedIDs.contains(hit.id) { selectedIDs.remove(hit.id) } else { selectedIDs.insert(hit.id) }
            return
        }
        if !selectedIDs.contains(hit.id) {
            selectedIDs = [hit.id]
        }
        beforeMove = annotations
        let targets = selectedAnnotations
        if duplicating {
            // ⌥-drag peels off copies and moves those; step numbers take the next free numbers.
            var copies: [Annotation] = []
            for target in targets {
                let copy = fresh(target)
                annotations.append(copy)
                copies.append(copy)
            }
            selectedIDs = Set(copies.map(\.id))
            moving = copies.map { ($0.id, $0) }
            moveActionName = "Duplicate"
        } else {
            moving = targets.map { ($0.id, $0) }
            moveActionName = "Move"
        }
    }

    func endDrag() {
        isDragging = false
        defer {
            pendingTap = nil
            textDragEnd = nil
            moving = []
            beforeMove = nil
            resizingText = nil
            dragOpenedText = false
            marquee = nil
            marqueeBase = nil
            erasing = nil
            lastErasePoint = nil
            if !fadingAnnotations.isEmpty { scheduleFade() }
        }
        guard !dragOpenedText else { return }

        switch toolbox.tool {
        case .select:
            if let marquee {
                let hits = annotations.filter { $0.intersects(marquee) }.map(\.id)
                selectedIDs = (marqueeBase ?? []).union(hits)
            } else if moving.isEmpty == false || resizingText != nil, let beforeMove {
                let changed = annotations
                annotations = beforeMove
                apply(changed, actionName: resizingText != nil ? "Resize Text" : moveActionName)
            }
        case .eraser:
            if let erasing, erasing != annotations {
                // One undo step for the whole sweep.
                let erased = annotations
                annotations = erasing
                apply(erased, actionName: "Erase")
            }
        case .text:
            guard let point = pendingTap else { return }
            let draggedWidth = textDragEnd.map { abs($0.x - point.x) } ?? 0
            // A click on a text opens that one for typing instead of starting another on top of it.
            if draggedWidth < 12, editText(at: point) { return }
            var origin = point
            var style = TextStyle()
            if draggedWidth >= 12, let end = textDragEnd {
                // Dragged out: a box of that width, which the text wraps to and grows down from.
                style.width = draggedWidth
                origin.x = min(point.x, end.x)
            }
            textEditing = TextEditing(origin: origin, text: "", color: toolbox.resolvedColor, lineWidth: toolbox.lineWidth, style: style, replacing: nil)
        case .badge:
            if let point = pendingTap {
                var badge = Annotation(shape: .badge(nextBadgeNumber, center: point), color: toolbox.resolvedColor, lineWidth: toolbox.lineWidth)
                badge.badgeStyle = Preferences.badgeStyle
                add(badge, actionName: "Add Step Number")
            }
        default:
            guard let annotation = inProgress else { return }
            inProgress = nil
            guard annotation.isMeaningful else { return }
            add(annotation, actionName: "Add \(toolbox.tool.title)")
        }
    }

    /// A finished drawing joins the annotations, or with fading ink the drawings that are about to go.
    /// Highlights stay (they're part of the dim layer, which doesn't fade), and so do pixelated and blurred
    /// areas: what they hide should stay hidden.
    private func add(_ annotation: Annotation, actionName: String) {
        if fadesInk, !Self.isSpotlight(annotation), !annotation.modifiesBackdrop {
            fadingAnnotations.append(annotation)
        } else {
            apply(annotations + [annotation], actionName: actionName)
        }
    }

    private static func isSpotlight(_ annotation: Annotation) -> Bool {
        if case .spotlight = annotation.shape { true } else { false }
    }

    /// A copy with an identity of its own; a step number takes the next free number.
    private func fresh(_ annotation: Annotation) -> Annotation {
        var copy = annotation
        copy.id = UUID()
        if case .badge(_, let center) = annotation.shape {
            copy.shape = .badge(nextBadgeNumber, center: center)
        }
        return copy
    }

    // MARK: - Eraser

    /// Removes whatever the pointer passed over since the last sample, so a quick sweep misses nothing.
    private func erase(to point: CGPoint) {
        let from = lastErasePoint ?? point
        lastErasePoint = point
        let distance = hypot(point.x - from.x, point.y - from.y)
        let steps = max(1, Int(distance / 4))
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let sample = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
            annotations.removeAll { $0.hitTest(sample) }
            fadingAnnotations.removeAll { $0.hitTest(sample) }
        }
        selectedIDs = selectedIDs.filter { id in annotations.contains { $0.id == id } }
    }

    // MARK: - Fading ink

    /// Drawing again keeps what's still fading on screen, at full strength, until the new stroke is done.
    private func holdFading() {
        guard !fadingAnnotations.isEmpty else { return }
        fadeTask?.cancel()
        fadeTask = nil
        fadingOpacity = 1
    }

    /// A moment after the last stroke (the fade delay in Settings), everything drawn with fading ink fades out
    /// over half a second.
    private func scheduleFade() {
        fadeTask?.cancel()
        fadingOpacity = 1
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.fadeDelay)
            let steps = 20
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                self?.fadingOpacity = 1 - Double(step) / Double(steps)
                try? await Task.sleep(for: .milliseconds(25))
            }
            guard !Task.isCancelled else { return }
            self?.clearFading()
        }
    }

    func clearFading() {
        fadeTask?.cancel()
        fadeTask = nil
        fadingAnnotations.removeAll()
        fadingOpacity = 1
    }

    // MARK: - Text

    func commitTextEditing() {
        guard let editing = textEditing else { return }
        textEditing = nil
        guard !editing.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var annotation = Annotation(shape: .text(editing.text, origin: editing.origin), color: editing.color, lineWidth: editing.lineWidth)
        annotation.text = editing.style
        if annotation.text.width == nil {
            // Typed up to the edge of the surface: keep wrapping there rather than running off it.
            let natural = AnnotationRenderer.textSize(editing.text, fontSize: editing.fontSize).width
            let room = textRoom(from: editing.origin)
            if natural > room { annotation.text.width = room }
        }
        if let replacing = editing.replacing, let index = annotations.firstIndex(where: { $0.id == replacing }) {
            annotation.id = replacing
            var updated = annotations
            updated[index] = annotation
            apply(updated, actionName: "Edit Text")
        } else {
            apply(annotations + [annotation], actionName: "Add Text")
        }
    }

    func cancelTextEditing() {
        textEditing = nil
    }

    /// Re-opens the selected text annotation for typing.
    func editSelectedText() {
        guard let selected = selectedAnnotation, case .text(let string, let origin) = selected.shape else { return }
        textEditing = TextEditing(origin: origin, text: string, color: selected.color, lineWidth: selected.lineWidth, style: selected.text, replacing: selected.id)
    }

    /// Opens the text annotation at `point` for typing (a click with the text tool, a double-click with the select
    /// tool). Returns false when there is none there.
    @discardableResult
    func editText(at point: CGPoint) -> Bool {
        guard let hit = annotations.last(where: { annotation in
            guard case .text = annotation.shape else { return false }
            return annotation.hitTest(point)
        }) else { return false }
        commitTextEditing()
        selectedIDs = [hit.id]
        editSelectedText()
        return true
    }

    /// Whether a double-click with `tool` may open a text for typing: with any tool whose click alone leaves
    /// nothing behind (a step number, a lens or the eraser act on the first click already).
    private static func doubleClickEditsText(with tool: AnnotationTool) -> Bool {
        switch tool {
        case .eraser, .badge, .magnifier: false
        default: true
        }
    }

    /// How much room a label can take to the right of its origin before it runs off the surface.
    func textRoom(from origin: CGPoint) -> CGFloat {
        max(40, size.width - origin.x)
    }

    static let textSizeRange: ClosedRange<CGFloat> = 8...160

    /// Makes the text being typed, or the selected texts, bigger (`step` > 0) or smaller, by `step` points.
    func adjustTextSize(by step: CGFloat) {
        if textEditing != nil {
            let current = textEditing!.fontSize
            textEditing!.style.fontSize = min(max(current + step, Self.textSizeRange.lowerBound), Self.textSizeRange.upperBound)
            return
        }
        var updated = annotations
        var changed = false
        for index in updated.indices where selectedIDs.contains(updated[index].id) {
            guard case .text = updated[index].shape else { continue }
            let current = updated[index].fontSize
            updated[index].text.fontSize = min(max(current + step, Self.textSizeRange.lowerBound), Self.textSizeRange.upperBound)
            changed = true
        }
        if changed { apply(updated, actionName: "Change Text Size") }
    }

    /// Switches the pill behind the text being typed, or behind the selected texts.
    func toggleTextBackground() {
        if textEditing != nil {
            textEditing!.style.hasBackground.toggle()
            return
        }
        var updated = annotations
        var changed = false
        for index in updated.indices where selectedIDs.contains(updated[index].id) {
            guard case .text = updated[index].shape else { continue }
            updated[index].text.hasBackground.toggle()
            changed = true
        }
        if changed { apply(updated, actionName: "Change Text Background") }
    }

    /// Which side of a text's box `point` is on, when it is on one.
    private func textEdge(of annotation: Annotation, at point: CGPoint) -> HorizontalEdge? {
        guard let box = annotation.textBox else { return nil }
        let tolerance: CGFloat = 6
        guard point.y >= box.minY - tolerance, point.y <= box.maxY + tolerance else { return nil }
        if abs(point.x - box.maxX) <= tolerance { return .trailing }
        if abs(point.x - box.minX) <= tolerance { return .leading }
        return nil
    }

    private func resizeText(_ resizing: (id: UUID, original: Annotation, edge: HorizontalEdge), to point: CGPoint) {
        guard let index = annotations.firstIndex(where: { $0.id == resizing.id }), case .text(let string, let origin) = resizing.original.shape else { return }
        let natural = AnnotationRenderer.textSize(string, fontSize: resizing.original.fontSize, width: nil).width
        let startWidth = resizing.original.text.width ?? natural
        let minimum: CGFloat = max(24, resizing.original.fontSize * 1.5)
        var updated = resizing.original
        switch resizing.edge {
        case .trailing:
            updated.text.width = max(minimum, point.x - origin.x)
        case .leading:
            let maxX = origin.x + startWidth
            let width = max(minimum, maxX - point.x)
            updated.text.width = width
            updated.shape = .text(string, origin: CGPoint(x: maxX - width, y: origin.y))
        }
        annotations[index] = updated
    }

    // MARK: - Editing the selection

    func deleteSelection() {
        guard hasSelection else { return }
        let ids = selectedIDs
        selectedIDs = []
        apply(annotations.filter { !ids.contains($0.id) }, actionName: "Delete")
    }

    /// Removes the selected annotations, or the most recent one when nothing is selected.
    func deleteSelectedOrLast() {
        if hasSelection {
            deleteSelection()
        } else if !annotations.isEmpty {
            apply(Array(annotations.dropLast()), actionName: "Delete")
        }
    }

    func nudgeSelection(by delta: CGPoint) {
        guard hasSelection else { return }
        var updated = annotations
        for index in updated.indices where selectedIDs.contains(updated[index].id) {
            updated[index] = updated[index].translated(by: delta)
        }
        apply(updated, actionName: "Move")
    }

    /// Applies a new color or width to the selected annotations (called when the toolbox changes). A new width
    /// lets a text's size follow it again.
    func restyleSelection(color: Color.Resolved? = nil, lineWidth: CGFloat? = nil) {
        guard hasSelection else { return }
        var updated = annotations
        for index in updated.indices where selectedIDs.contains(updated[index].id) {
            if let color { updated[index].color = color }
            if let lineWidth {
                updated[index].lineWidth = lineWidth
                updated[index].text.fontSize = nil
            }
        }
        apply(updated, actionName: "Change Style")
    }

    /// Picking pixelate or blur while areas hidden another way are selected switches those areas over.
    func convertSelection(to tool: AnnotationTool) {
        guard hasSelection else { return }
        var updated = annotations
        var changed = false
        for index in updated.indices where selectedIDs.contains(updated[index].id) {
            switch (updated[index].shape, tool) {
            case (.pixelate(let rect), .blur), (.blackout(let rect), .blur):
                updated[index].shape = .blur(rect)
                changed = true
            case (.blur(let rect), .pixelate), (.blackout(let rect), .pixelate):
                updated[index].shape = .pixelate(rect)
                changed = true
            default:
                continue
            }
        }
        if changed { apply(updated, actionName: "Change Style") }
    }

    // MARK: - Clipboard

    /// Copies the selected shapes for pasting on any surface. Returns false with nothing selected.
    @discardableResult
    func copySelection() -> Bool {
        let selected = selectedAnnotations
        guard !selected.isEmpty else { return false }
        AnnotationClipboard.shared.put(selected)
        return true
    }

    func cutSelection() {
        guard copySelection() else { return }
        deleteSelection()
    }

    /// Pastes the copied shapes centred on `point`, or a little below and to the right of where they were.
    /// They become the selection.
    func paste(at point: CGPoint? = nil) {
        let items = AnnotationClipboard.shared.annotations
        guard !items.isEmpty else { return }
        commitTextEditing()
        let union = items.dropFirst().reduce(items[0].bounds) { $0.union($1.bounds) }
        var delta = point.map { CGPoint(x: $0.x - union.midX, y: $0.y - union.midY) } ?? CGPoint(x: 16, y: 16)
        // Keep them on the surface.
        let moved = union.offsetBy(dx: delta.x, dy: delta.y)
        delta.x -= max(0, moved.maxX - size.width) - max(0, -moved.minX)
        delta.y -= max(0, moved.maxY - size.height) - max(0, -moved.minY)
        var pasted: [Annotation] = []
        var updated = annotations
        for item in items {
            let copy = fresh(item).translated(by: delta)
            updated.append(copy)
            pasted.append(copy)
            annotations.append(copy)  // so the next step number counts this one
        }
        annotations.removeLast(pasted.count)
        apply(updated, actionName: "Paste")
        selectedIDs = Set(pasted.map(\.id))
    }

    /// Copies of the selected shapes a little below and to the right, which become the selection.
    func duplicateSelection() {
        let selected = selectedAnnotations
        guard !selected.isEmpty else { return }
        var copies: [Annotation] = []
        var updated = annotations
        for item in selected {
            let copy = fresh(item).translated(by: CGPoint(x: 16, y: 16))
            updated.append(copy)
            copies.append(copy)
            annotations.append(copy)
        }
        annotations.removeLast(copies.count)
        apply(updated, actionName: "Duplicate")
        selectedIDs = Set(copies.map(\.id))
    }

    // MARK: - Redaction

    /// Whether `rect` already sits under a hidden area.
    func isRedacted(_ rect: CGRect) -> Bool {
        annotations.contains { annotation in
            switch annotation.shape {
            case .blackout(let area), .pixelate(let area), .blur(let area): area.insetBy(dx: -2, dy: -2).contains(rect)
            default: false
            }
        }
    }

    /// Covers each of `rects` with a black, pixelated or blurred area, as one undo step. What was found
    /// has to stay unreadable whatever size is picked, so a blur gets the strongest level.
    func addRedactions(_ rects: [CGRect], style: RedactionStyle) {
        let areas = rects.filter { !$0.isEmpty }.map {
            Annotation(shape: style.shape(covering: $0), color: toolbox.resolvedColor, lineWidth: StrokeWidth.thick.rawValue)
        }
        guard !areas.isEmpty else { return }
        apply(annotations + areas, actionName: "Redact")
    }

    func clear() {
        guard !annotations.isEmpty else { return }
        selectedIDs = []
        apply([], actionName: "Clear Annotations")
    }

    // MARK: - Canvas

    /// After a crop or added space: the new surface size and the annotations moved onto it. The document
    /// registers the undo step, since the picture changes along with them.
    func replaceCanvas(size: CGSize, annotations: [Annotation]) {
        textEditing = nil
        inProgress = nil
        selectedIDs = []
        self.size = size
        self.annotations = annotations
    }

    // MARK: - Undo

    /// Every change goes through here, so undo and redo fall out of a single registration.
    private func apply(_ newValue: [Annotation], actionName: String) {
        let oldValue = annotations
        guard oldValue != newValue else { return }
        annotations = newValue
        let remaining = Set(newValue.map(\.id))
        if !selectedIDs.isSubset(of: remaining) {
            selectedIDs = selectedIDs.intersection(remaining)
        }
        undoManager.registerChange(on: self, actionName: actionName) { layer in
            layer.apply(oldValue, actionName: actionName)
        }
    }

    // MARK: - Geometry helpers

    private static func points(of shape: Annotation.Shape) -> [CGPoint] {
        switch shape {
        case .freehand(let points), .highlight(let points): points
        default: []
        }
    }

    /// Snaps the end point to the nearest 45° so straight lines stay straight while Shift is held.
    static func snappedToAngle(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return b }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }
}
