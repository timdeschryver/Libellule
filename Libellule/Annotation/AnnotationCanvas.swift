import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A drawing surface: an optional image with the annotation layer on top; drags act with the current tool.
struct AnnotationCanvas: View {
    let layer: AnnotationLayer
    var background: CGImage? = nil
    var backgroundScale: CGFloat = 1
    /// Display points per layer point (1 = true size).
    let displayScale: CGFloat
    /// Told where the pointer is over the surface, in layer points, and nil when it leaves (for pasting at the pointer).
    var pointerMoved: ((CGPoint?) -> Void)? = nil
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let background {
                Image(decorative: background, scale: backgroundScale)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.clear
            }
            Canvas { context, _ in
                context.scaleBy(x: displayScale, y: displayScale)
                if !layer.isHidden {
                    drawAnnotations(in: &context)
                }
                drawPointerMark(in: &context)
            }
            if let editing = layer.textEditing {
                textField(for: editing)
            }
        }
        .contentShape(Rectangle())
        .gesture(drawingGesture)
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard let pointerMoved else { return }
            switch phase {
            case .active(let location):
                let factor = 1 / max(displayScale, 0.001)
                pointerMoved(CGPoint(x: location.x * factor, y: location.y * factor))
            case .ended:
                pointerMoved(nil)
            }
        }
        #if os(macOS)
        .pointerStyle(pointerStyle)
        #endif
    }

    private func drawAnnotations(in context: inout GraphicsContext) {
        let pointer = layer.pointerSpotlight.map { AnnotationRenderer.PointerSpotlight(center: $0, radius: layer.pointerSpotlightRadius) }
        var shown = layer.visibleAnnotations
        if let center = layer.pointerLoupe {
            // The live loupe: a magnifier sitting on the pointer, in the current colour and size.
            shown.append(Annotation(shape: .magnifier(source: center, lens: center), color: layer.toolbox.resolvedColor, lineWidth: layer.toolbox.lineWidth))
        }
        AnnotationRenderer.drawAll(shown, dimsLights: layer.dimsLights, size: layer.size, backdrop: layer.backdrop, pointer: pointer, board: layer.board, in: &context)
        if !layer.fadingAnnotations.isEmpty {
            context.drawLayer { fading in
                fading.opacity = layer.fadingOpacity
                AnnotationRenderer.drawAll(layer.fadingAnnotations, dimsLights: false, size: layer.size, backdrop: layer.backdrop, in: &fading)
            }
        }
        let hairline = 1 / displayScale
        // A text open for typing shows its field, not its outline.
        for selected in layer.selectedAnnotations where selected.id != layer.textEditing?.replacing {
            let outline = Path(roundedRect: selected.bounds.insetBy(dx: -6, dy: -6), cornerRadius: 4)
            context.stroke(outline, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: hairline * 3))
            context.stroke(outline, with: .color(.accentColor), style: StrokeStyle(lineWidth: hairline, dash: [4 * hairline, 3 * hairline]))
            // A lone text shows handles on its sides: drag them to set the width it wraps to.
            if layer.selectedIDs.count == 1, let box = selected.textBox {
                for x in [box.minX, box.maxX] {
                    let handle = Path(roundedRect: CGRect(center: CGPoint(x: x, y: box.midY), radius: 4 * hairline), cornerRadius: hairline)
                    context.fill(handle, with: .color(.white))
                    context.stroke(handle, with: .color(.accentColor), lineWidth: hairline)
                }
            }
        }
        if let marquee = layer.marquee, marquee.width > 1 || marquee.height > 1 {
            context.fill(Path(marquee), with: .color(.accentColor.opacity(0.12)))
            context.stroke(Path(marquee), with: .color(.accentColor), style: StrokeStyle(lineWidth: hairline, dash: [4 * hairline, 3 * hairline]))
        }
    }

    /// The mark on the pointer while presenting: a ring, a disc or a crosshair, in the effect colour.
    private func drawPointerMark(in context: inout GraphicsContext) {
        guard let center = layer.pointerMark else { return }
        let style = Preferences.cursorStyle
        guard style != .none else { return }
        let radius = CGFloat(Preferences.cursorSize)
        let color = Preferences.effectColor
        let ring = Path(ellipseIn: CGRect(center: center, radius: radius))
        context.drawLayer { mark in
            mark.addFilter(.shadow(color: .black.opacity(0.35), radius: 2, y: 1))
            switch style {
            case .none:
                break
            case .outline:
                mark.stroke(ring, with: .color(color), lineWidth: max(2, radius * 0.18))
            case .circle:
                mark.fill(ring, with: .color(color.opacity(0.45)))
                mark.stroke(ring, with: .color(color), lineWidth: 1.5)
            case .crosshair:
                var cross = Path()
                let arm = radius * 1.4
                cross.move(to: CGPoint(x: center.x - arm, y: center.y))
                cross.addLine(to: CGPoint(x: center.x + arm, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - arm))
                cross.addLine(to: CGPoint(x: center.x, y: center.y + arm))
                mark.stroke(cross, with: .color(color), style: StrokeStyle(lineWidth: max(2, radius * 0.15), lineCap: .round))
                mark.stroke(ring, with: .color(color), lineWidth: 1.5)
            }
        }
    }

    #if os(macOS)
    private var pointerStyle: PointerStyle {
        switch layer.toolbox.tool {
        case .select: .default
        case .eraser: .default
        default: .rectSelection
        }
    }
    #endif

    // MARK: - Text

    @ViewBuilder
    private func textField(for editing: TextEditing) -> some View {
        #if os(macOS)
        // As wide as the text, or the box dragged out for it; either wraps at the edge of the surface.
        let box = editing.fieldBox(room: layer.textRoom(from: editing.origin))
        let padding = TextStyle.padding(fontSize: editing.fontSize)
        AnnotationTextEditor(layer: layer, editing: editing, displayScale: displayScale, wrapWidth: box.wrapWidth * displayScale)
            .frame(width: box.width * displayScale, height: box.height * displayScale, alignment: .topLeading)
            .padding(.horizontal, padding.width * displayScale)
            .padding(.vertical, padding.height * displayScale)
            .background(editingBackground(for: editing), in: RoundedRectangle(cornerRadius: editing.fontSize * 0.35 * displayScale))
            .overlay(RoundedRectangle(cornerRadius: editing.fontSize * 0.35 * displayScale).strokeBorder(Color.accentColor, lineWidth: 1))
            .offset(x: (editing.origin.x - padding.width) * displayScale, y: (editing.origin.y - padding.height) * displayScale)
        #else
        TextField("Text", text: Binding(
            get: { layer.textEditing?.text ?? "" },
            set: { layer.textEditing?.text = $0 }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: editing.fontSize * displayScale, weight: .bold))
        .foregroundStyle(Color(editing.color))
        .fixedSize()
        .focused($textFieldFocused)
        .onSubmit { layer.commitTextEditing() }
        .offset(x: editing.origin.x * displayScale, y: editing.origin.y * displayScale)
        .onAppear { textFieldFocused = true }
        #endif
    }

    /// The pill the text will have, or a faint wash so the field shows against anything.
    private func editingBackground(for editing: TextEditing) -> Color {
        guard editing.style.hasBackground else { return Color.primary.opacity(0.08) }
        let light = 0.299 * Double(editing.color.red) + 0.587 * Double(editing.color.green) + 0.114 * Double(editing.color.blue) > 0.65
        return light ? Color.black.opacity(0.75) : Color.white.opacity(0.9)
    }

    // MARK: - Gestures

    private var drawingGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let factor = 1 / max(displayScale, 0.001)
                layer.updateDrag(
                    from: CGPoint(x: value.startLocation.x * factor, y: value.startLocation.y * factor),
                    to: CGPoint(x: value.location.x * factor, y: value.location.y * factor),
                    constrained: Self.isShiftPressed,
                    optionHeld: Self.isOptionPressed,
                    extending: Self.isShiftPressed,
                    clickCount: Self.clickCount
                )
            }
            .onEnded { _ in
                layer.endDrag()
            }
    }

    /// How many times the button went down in a row: 2 on the second click of a double-click, which opens a text
    /// for typing. The drag gesture doesn't say, but the mouse-down it is handling does.
    private static var clickCount: Int {
        #if os(macOS)
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return 1 }
        return event.clickCount
        #else
        return 1
        #endif
    }

    private static var isShiftPressed: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    private static var isOptionPressed: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
    }
}
