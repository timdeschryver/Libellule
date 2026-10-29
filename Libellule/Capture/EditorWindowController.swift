#if os(macOS)
import AppKit
import SwiftUI

/// Owns one annotation window. Kept alive by `CaptureCoordinator` until the window closes.
final class EditorWindowController: NSObject, NSWindowDelegate {
    let document: AnnotationDocument
    let window: NSWindow
    var onClose: (() -> Void)?
    private var eventMonitor: Any?

    init(document: AnnotationDocument, on screen: NSScreen?) {
        self.document = document
        let hosting = NSHostingController(rootView: AnnotationEditorView(document: document))
        window = NSWindow(contentViewController: hosting)
        super.init()

        window.title = String(localized: "Screenshot")
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 460)
        window.delegate = self

        // Open at true size when the capture fits comfortably on its display, otherwise scaled to fit.
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let padding: CGFloat = 48
        let bars = AnnotationEditorView.barsHeight
        let image = document.pointSize
        let fit = min(1, (visible.width * 0.9 - padding) / image.width, (visible.height * 0.85 - padding - bars) / image.height)
        let content = NSSize(
            width: max(window.minSize.width, image.width * fit + padding),
            height: max(window.minSize.height, image.height * fit + padding + bars)
        )
        window.setContentSize(content)
        let frame = window.frame
        window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2))
        updateSubtitle()
        updateEditedMark()
        watchMouse()
    }

    /// ⌘-scroll changes the line width, and the mouse's back and forward buttons undo and redo, as in the overlay.
    private func watchMouse() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseDown]) { [weak self] event in
            guard let self, event.window === window else { return event }
            let step = event.type == .scrollWheel && event.modifierFlags.contains(.command) ? LiveAnnotationSession.widthStep(for: event) : nil
            let button = event.type == .otherMouseDown ? event.buttonNumber : -1
            let handled: Bool = MainActor.assumeIsolated {
                if let step {
                    self.document.layer.toolbox.adjustWidth(by: step)
                    return true
                }
                switch button {
                case 3: self.document.undoManager.undo()
                case 4: self.document.undoManager.redo()
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    /// The picture's size, kept current through crops and their undo.
    private func updateSubtitle() {
        window.subtitle = withObservationTracking {
            "\(document.image.width) × \(document.image.height) px"
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateSubtitle() }
        }
    }

    /// The dot in the close button while there are changes that haven't been copied or saved.
    private func updateEditedMark() {
        window.isDocumentEdited = withObservationTracking {
            document.hasUnsavedChanges
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateEditedMark() }
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Closing throws the capture away, so ask first when it changed since it was last copied or saved.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        document.layer.commitTextEditing()
        guard document.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Copy the screenshot before closing?")
        alert.informativeText = String(localized: "Your changes haven't been copied, saved or shared yet, and are lost when the window closes.")
        alert.addButton(withTitle: String(localized: "Copy and Close"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let discard = alert.addButton(withTitle: String(localized: "Discard"))
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                // If rendering fails the window stays, so nothing is lost.
                if document.copyToPasteboard() { window.close() }
            case .alertThirdButtonReturn:
                window.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        onClose?()
    }

    /// Lets Edit › Undo/Redo (and ⌘Z) drive the document's own undo stack.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document.undoManager
    }
}
#endif
