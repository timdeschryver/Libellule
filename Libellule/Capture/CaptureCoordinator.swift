#if os(macOS)
import AppKit
import Observation
import ScreenCaptureKit
import os

/// Where the previous capture was taken, so the same spot can be retaken without choosing it again.
/// Stored in the display's point space and kept across launches.
struct RepeatableArea: Codable {
    var displayID: CGDirectDisplayID
    var rect: CGRect

    static let defaultsKey = "lastCapturedArea"

    static func load() -> RepeatableArea? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(RepeatableArea.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Routes the shortcuts and menu items to the two modes: capture an area, or draw on the live screen.
@Observable
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private(set) var isCapturing = false
    /// The region of the most recent capture, for "Repeat last area".
    private(set) var lastArea = RepeatableArea.load()
    /// The app the user was working in when the capture started, to hand focus back after a copy-only capture.
    private var previousApp: NSRunningApplication?
    private var selectionSession: SelectionSession?
    private var liveSession: LiveAnnotationSession?
    private var editors: [EditorWindowController] = []
    private var countdown: Task<Void, Never>?
    /// What was on the screens when annotation mode was last left, to put back next time (a setting).
    private var keptDrawings: [CGDirectDisplayID: SurfaceDrawing] = [:]

    private init() {}

    /// Call once at launch: wires the global shortcuts.
    func start() {
        HotKeyManager.shared.onPress = { action in
            switch action {
            case .captureArea: CaptureCoordinator.shared.captureAreaRequested()
            case .annotateScreen: CaptureCoordinator.shared.toggleLiveAnnotation()
            case .copyText: CaptureCoordinator.shared.beginCapture(purpose: .text)
            case .repeatArea: CaptureCoordinator.shared.repeatLastArea()
            case .captureDelayed: CaptureCoordinator.shared.beginDelayedCapture()
            }
        }
        HotKeyManager.shared.start()
    }

    /// The capture shortcut: a new capture, or, while drawing on the screen, keep that drawing as a screenshot.
    func captureAreaRequested(after delay: Duration = .zero) {
        if let liveSession {
            liveSession.capture()
        } else {
            beginCapture(after: delay)
        }
    }

    /// The annotate shortcut starts live annotation mode; while it's up, it pauses and resumes drawing
    /// (click-through to the apps underneath). Escape or the palette's Done button leave the mode.
    func toggleLiveAnnotation(after delay: Duration = .zero) {
        if let liveSession {
            liveSession.togglePaused()
        } else {
            beginLiveAnnotation(after: delay)
        }
    }

    /// Menu entry point: leaves live mode when it's up, otherwise starts it.
    func toggleLiveAnnotationFromMenu() {
        if let liveSession {
            liveSession.dismiss()
        } else {
            beginLiveAnnotation(after: .milliseconds(250))
        }
    }

    /// Transparent overlays to draw on; nothing is captured until the user asks.
    /// Pass a short `delay` when triggered from a menu so the menu has time to close.
    func beginLiveAnnotation(after delay: Duration = .zero) {
        guard !isCapturing, liveSession == nil else { return }
        if let frontmost = PreviousApp.current() {
            previousApp = frontmost  // a capture started from live mode should still return there
        }
        let session = LiveAnnotationSession()
        liveSession = session
        Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            Diagnostics.log("Live annotation started")
            session.begin(restoring: keptDrawings) { outcome in
                self.liveSession = nil
                self.keptDrawings = session.keptDrawings
                if case .capture(let drawings, let frozen) = outcome {
                    // Give the window server a moment to take the overlays off screen before the shot;
                    // a frozen screen was taken already.
                    self.beginCapture(after: frozen.isEmpty ? .milliseconds(120) : .zero, drawings: drawings, frozen: frozen)
                }
            }
        }
    }

    /// Forgets the drawing kept from the last annotation session, so the next one starts clean.
    func discardKeptDrawings() {
        keptDrawings = [:]
    }

    /// Whether a delayed capture is counting down; asking for one again now cancels it.
    var isCountingDown: Bool { countdown != nil }

    /// Counts down on screen, then starts an ordinary capture: time to open the menu or hover state
    /// that should be in the picture before the screens freeze. Called again during the countdown, it stops it.
    func beginDelayedCapture(seconds: Int = 3) {
        if let countdown {
            countdown.cancel()
            return
        }
        guard !isCapturing, liveSession == nil else { return }
        // The countdown runs over other apps, which keep the keyboard, so the shortcut itself cancels.
        let shortcut = HotKeyManager.shared.combo(for: .captureDelayed).displayString
        countdown = Task {
            defer { countdown = nil }
            for remaining in stride(from: seconds, through: 1, by: -1) {
                CaptureToast.show(String(localized: "Capturing in \(remaining)… · \(shortcut) cancels"), systemImage: "timer", on: NSScreen.underPointer)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    CaptureToast.show(String(localized: "Capture cancelled"), systemImage: "timer", on: NSScreen.underPointer)
                    return
                }
            }
            CaptureToast.hide()
            // Give the window server a moment to take the countdown off screen before the shot.
            beginCapture(after: .milliseconds(150))
        }
    }

    /// Retakes the area of the previous capture on the same display, skipping the selection overlay.
    /// With nothing to repeat yet (or that display gone), an ordinary capture starts instead.
    func repeatLastArea(after delay: Duration = .zero) {
        guard !isCapturing else { return }
        guard let lastArea, let screen = NSScreen.screens.first(where: { $0.displayID == lastArea.displayID }) else {
            beginCapture(after: delay)
            return
        }
        let rect = lastArea.rect.intersection(CGRect(origin: .zero, size: screen.frame.size)).integral
        guard rect.width >= 1, rect.height >= 1 else {
            beginCapture(after: delay)
            return
        }
        isCapturing = true

        Task {
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
                Diagnostics.log("Repeat capture of \(rect) on display \(lastArea.displayID)")
                let snapshot = try await ScreenCapturer.snapshot(of: screen)
                isCapturing = false
                await handle(ScreenSelection(snapshot: snapshot, target: .area(rect), purpose: .image, completion: .current, redacts: SelectionSession.redactsCaptures))
            } catch {
                isCapturing = false
                Diagnostics.log("Repeat capture failed · \(error)")
                presentError(error)
            }
        }
    }

    /// Shows the selection overlay on every display and acts on the chosen region or window: opens the editor,
    /// copies or saves, as chosen on the toolbar, or with `purpose == .text` copies the recognized text.
    /// The screens are frozen first unless the preference keeps them live, in which case the picture is taken
    /// when the user commits. `drawings` (per display) come from live annotation mode, stay editable in the
    /// editor, and need the frozen screen they were drawn on. When annotation mode had frozen the screen, its
    /// pictures (`frozen`, per display) are chosen on instead of the screen as it is by now.
    func beginCapture(after delay: Duration = .zero, drawings: [CGDirectDisplayID: SurfaceDrawing] = [:], frozen: [CGDirectDisplayID: CGImage] = [:], purpose: CapturePurpose = .image) {
        guard !isCapturing else { return }
        isCapturing = true

        Task {
            do {
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
                let live = frozen.isEmpty && !SelectionSession.freezesScreen && drawings.values.allSatisfy(\.isEmpty)
                Diagnostics.log("Capture requested · live=\(live) annotationFrozen=\(!frozen.isEmpty) preflight=\(ScreenCapturer.hasPermission)")
                async let windowCandidates = ScreenCapturer.onScreenWindows()
                let surfaces: [SelectionSurface]
                if live {
                    try await ScreenCapturer.ensurePermission()
                    surfaces = NSScreen.screens.map(SelectionSurface.init(screen:))
                } else if !frozen.isEmpty {
                    // Every display of the annotation session was frozen; only one connected since has no picture.
                    surfaces = NSScreen.screens.compactMap { screen in
                        guard let id = screen.displayID, let image = frozen[id] else { return nil }
                        return SelectionSurface(frozen: ScreenSnapshot(screen: screen, image: image, drawing: drawings[id] ?? SurfaceDrawing()))
                    }
                } else {
                    surfaces = try await ScreenCapturer.snapshotAllScreens(drawings: drawings).map(SelectionSurface.init(frozen:))
                }
                let session = SelectionSession()
                selectionSession = session
                session.begin(on: surfaces, windowCandidates: await windowCandidates, purpose: purpose) { outcome in
                    self.selectionSession = nil
                    self.isCapturing = false
                    switch outcome {
                    case .cancelled:
                        break
                    case .selected(let selection):
                        Task { await self.handle(selection) }
                    case .failed(let error):
                        Diagnostics.log("Live capture failed · \(error)")
                        self.presentError(error)
                    }
                }
            } catch {
                isCapturing = false
                Diagnostics.log("Capture failed · \(error)")
                presentError(error)
            }
        }
    }

    /// Turns the selection into pixels (cropping the frozen screen, or capturing a window cleanly),
    /// then copies the text, or copies, saves or edits the image as chosen on the toolbar.
    private func handle(_ selection: ScreenSelection) async {
        let snapshot = selection.snapshot
        let scale = snapshot.scale
        var image: CGImage?
        var imageScale = scale
        var annotations: [Annotation] = []

        func cropFrozenScreen(to rect: CGRect) {
            let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
            image = snapshot.image.cropping(to: pixelRect)
            // Live-screen drawings were made in display coordinates; move them into the cropped image.
            annotations = snapshot.annotations.map { $0.translated(by: CGPoint(x: -rect.minX, y: -rect.minY)) }
        }

        let capturedRect: CGRect
        switch selection.target {
        case .area(let rect):
            capturedRect = rect
            cropFrozenScreen(to: rect)
        case .window(let target, let includeShadow):
            let bounds = CGRect(origin: .zero, size: snapshot.screen.frame.size)
            capturedRect = target.rect.intersection(bounds)
            if selection.purpose == .image, snapshot.annotations.isEmpty {
                do {
                    let captured = try await ScreenCapturer.captureWindow(target.window, includeShadow: includeShadow)
                    image = captured.image
                    imageScale = captured.scale
                } catch {
                    Diagnostics.log("Window capture failed, cropping the frozen screen instead · \(error)")
                    cropFrozenScreen(to: target.rect.intersection(bounds))
                }
            } else {
                // Drawings must line up, and text only needs what's visible: crop the frozen screen.
                cropFrozenScreen(to: target.rect.intersection(bounds))
            }
        }
        guard let image else {
            Diagnostics.log("Selection produced no image")
            return
        }
        if let displayID = snapshot.screen.displayID {
            let area = RepeatableArea(displayID: displayID, rect: capturedRect)
            lastArea = area
            area.save()
        }

        if selection.purpose == .text {
            let copied = await TextRecognizer.copyText(from: image)
            Diagnostics.log("Copy text: \(copied.map { "\($0)" } ?? "nothing recognized")")
            if let copied {
                CaptureToast.show(copied.message, systemImage: copied.systemImage, on: snapshot.screen)
            } else {
                CaptureToast.show(String(localized: "No text or code found"), systemImage: "text.viewfinder", on: snapshot.screen)
            }
            returnToPreviousApp()
            return
        }

        let document = AnnotationDocument(image: image, scale: imageScale, annotations: annotations, dimsLights: snapshot.drawing.dimsLights, board: snapshot.drawing.board, toolbox: AnnotationToolbox(context: .editor))
        // Covered before anything leaves the app; the areas stay editable in the editor.
        var redaction: RedactionResult?
        if selection.redacts {
            CaptureToast.show(String(localized: "Looking for anything sensitive…"), systemImage: "eye.slash", on: snapshot.screen)
            redaction = await document.layer.redact(document.image, style: .preferred)
            Diagnostics.log("Capture redacted · \(redaction?.message ?? "-")")
            if let redaction {
                CaptureToast.show(redaction.message, systemImage: "eye.slash", on: snapshot.screen)
            }
        }
        let completion = selection.completion
        if completion == .saveAs {
            save(document, on: snapshot.screen)
            return
        }
        if completion.copiesToClipboard {
            let copied = document.copyToPasteboard()
            Diagnostics.log("Capture copied to clipboard: \(copied)")
            if !completion.opensEditor {
                if copied {
                    let note = redaction.map { " · \($0.message)" } ?? ""
                    CaptureToast.show(String(localized: "Copied to clipboard\(note)"), systemImage: "doc.on.clipboard", on: snapshot.screen)
                    returnToPreviousApp()
                    return
                }
                // Rendering failed; fall through to the editor rather than losing the capture.
            }
        }
        openEditor(for: document, on: snapshot.screen)
    }

    /// Editors holding changes that haven't been copied or saved, which quitting would throw away.
    var unsavedEditorCount: Int {
        editors.filter { $0.document.hasUnsavedChanges }.count
    }

    private func openEditor(for document: AnnotationDocument, on screen: NSScreen) {
        previousApp = nil
        // What the editor opens with (drawings from the screen, automatic redaction) is where it starts, not a change.
        document.markSaved()
        let controller = EditorWindowController(document: document, on: screen)
        controller.onClose = { [weak controller] in
            CaptureCoordinator.shared.editors.removeAll { $0 === controller }
        }
        editors.append(controller)
        controller.show()
    }

    /// Asks where the capture should go, then hands focus back. Cancelling the panel discards the capture;
    /// if it can't be written, the editor opens instead so nothing is lost.
    private func save(_ document: AnnotationDocument, on screen: NSScreen) {
        NSApp.activate()
        document.runSavePanel(attachedTo: nil) { outcome in
            switch outcome {
            case .saved(let url):
                Diagnostics.log("Capture saved to \(url.path)")
                CaptureToast.show(String(localized: "Saved \(url.lastPathComponent)"), systemImage: "square.and.arrow.down", on: screen)
                self.returnToPreviousApp()
            case .cancelled:
                Diagnostics.log("Capture save cancelled")
                self.returnToPreviousApp()
            case .failed(let message):
                Diagnostics.log("Capture save failed · \(message)")
                CaptureToast.show(message, systemImage: "exclamationmark.triangle", on: screen)
                self.openEditor(for: document, on: screen)
            }
        }
    }

    /// Back to where the user was, so ⌘V works straight away.
    private func returnToPreviousApp() {
        PreviousApp.activate(previousApp)
        previousApp = nil
    }

    /// Without access, whatever failed is down to the missing permission. ScreenCaptureKit shows the system
    /// prompt itself; this adds the part it leaves out.
    private func presentError(_ error: Error) {
        let error = ScreenCapturer.hasPermission ? error : ScreenCaptureError.permissionDenied
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        if case ScreenCaptureError.permissionDenied = error {
            alert.messageText = String(localized: "Libellule needs Screen Recording access")
            alert.informativeText = String(localized: "Turn on Libellule under System Settings › Privacy & Security › Screen & System Audio Recording. macOS applies the change only to a freshly started app, so quit and reopen Libellule afterwards.\n\nIf Libellule is already switched on there, just quit and reopen it. If it isn't listed, click + below the list and choose the app.")
            alert.addButton(withTitle: String(localized: "Open System Settings"))
            alert.addButton(withTitle: String(localized: "Quit & Reopen"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: ScreenCapturer.openPrivacySettings()
            case .alertSecondButtonReturn: relaunch()
            default: break
            }
        } else {
            alert.messageText = String(localized: "Couldn't capture the screen")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
#endif

#if os(macOS)
extension CaptureCoordinator {
    /// Starts a fresh copy of the app and quits this one, so a new privacy grant takes effect.
    func relaunch() {
        Diagnostics.log("Relaunch requested")
        // Free the global shortcuts first so the new instance can register them.
        HotKeyManager.shared.isPaused = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    Diagnostics.log("Relaunch failed · \(error)")
                    HotKeyManager.shared.isPaused = false
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
#endif
