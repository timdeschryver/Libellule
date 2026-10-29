#if os(macOS)
import AppKit
import SwiftUI
import Carbon.HIToolbox

/// The field a text annotation is typed into, right on the surface: several lines (⇧↩ or ⌥↩ breaks one), wrapped to
/// the box's width or to the edge of the surface, in the annotation's own font. ↩ places the text, esc drops it,
/// ⌘B puts a pill behind it, ⌘[ and ⌘] change its size.
struct AnnotationTextEditor: NSViewRepresentable {
    let layer: AnnotationLayer
    let editing: TextEditing
    /// Display points per surface point.
    let displayScale: CGFloat
    /// The width the text wraps to, in display points.
    let wrapWidth: CGFloat

    func makeNSView(context: Context) -> EditingTextView {
        let view = EditingTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.usesFontPanel = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.onCommit = { [layer] in layer.commitTextEditing() }
        view.onCancel = { [layer] in layer.cancelTextEditing() }
        view.onToggleBackground = { [layer] in layer.toggleTextBackground() }
        view.onSizeChange = { [layer] step in layer.adjustTextSize(by: step) }
        view.string = editing.text
        apply(to: view)
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        }
        return view
    }

    func updateNSView(_ view: EditingTextView, context: Context) {
        apply(to: view)
        if view.string != editing.text {
            view.string = editing.text
        }
    }

    /// The box around the field proposes its exact size, and the field takes it: left to itself it would be as
    /// wide as its container, which is where the text wraps, not where the text ends.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditingTextView, context: Context) -> CGSize? {
        let own = nsView.intrinsicContentSize
        var size = proposal.replacingUnspecifiedDimensions(by: own)
        if size.width == .infinity { size.width = own.width }
        if size.height == .infinity { size.height = own.height }
        return size
    }

    /// Font, colour and wrapping width, which the size keys and the handles change while typing.
    private func apply(to view: EditingTextView) {
        let font = NSFont.boldSystemFont(ofSize: editing.fontSize * displayScale)
        if view.font != font {
            view.font = font
            view.typingAttributes[.font] = font
        }
        let color = NSColor(Color(editing.color))
        view.textColor = color
        view.insertionPointColor = color
        view.typingAttributes[.foregroundColor] = color
        let width = max(wrapWidth, 10)
        if view.textContainer?.size.width != width {
            view.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        // The field is only as wide as its text (the box around it sets that); the container, wider, is where
        // the text wraps. A minimum width here would push the field out to the container's.
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(layer: layer)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let layer: AnnotationLayer
        /// Typing has an undo history of its own. The window's is the document's, which groups its steps by hand
        /// and so throws when a text view registers typing on it; placing the text is the document's step.
        private let typingUndo = UndoManager()

        init(layer: AnnotationLayer) {
            self.layer = layer
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            typingUndo
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            layer.textEditing?.text = view.string
        }
    }
}

/// An `NSTextView` whose ↩ places the text instead of starting a line.
final class EditingTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleBackground: (() -> Void)?
    var onSizeChange: ((CGFloat) -> Void)?

    override func keyDown(with event: NSEvent) {
        let code = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                insertNewline(nil)
            } else {
                onCommit?()
            }
            return
        }
        if code == kVK_Escape {
            onCancel?()
            return
        }
        if handleCommandKey(event) { return }
        super.keyDown(with: event)
    }

    /// The text-style keys arrive here first when something else in the window binds ⌘ keys.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleCommandKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers == .command, let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch characters {
        case "b":
            onToggleBackground?()
        case "[", "{":
            onSizeChange?(-2)
        case "]", "}":
            onSizeChange?(2)
        default:
            return false
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// The room the lines take, when nothing else sizes the field.
    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else { return super.intrinsicContentSize }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        return NSSize(width: ceil(used.width), height: ceil(used.height))
    }
}
#endif
