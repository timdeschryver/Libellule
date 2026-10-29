#if os(macOS)
import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Draw-on-top-of-everything mode: transparent overlays on every display, or frozen pictures of them, plus a floating palette.
/// Nothing is captured unless the user asks for it (Return, the capture shortcut, or the palette button).
@Observable
final class LiveAnnotationSession {
    enum Outcome {
        case dismissed
        /// The drawings per display, in that display's point space, for a follow-up capture, and while the screen
        /// was frozen, the picture each display showed underneath.
        case capture([CGDirectDisplayID: SurfaceDrawing], frozen: [CGDirectDisplayID: CGImage])
    }

    /// Lights on, everything dimmed, or dimmed except a circle that follows the pointer.
    enum LightsMode: CaseIterable {
        case on, dim, pointer

        var title: String {
            switch self {
            case .on: String(localized: "Lights on")
            case .dim: String(localized: "Dim lights")
            case .pointer: String(localized: "Pointer spotlight")
            }
        }

        var systemImage: String {
            switch self {
            case .on: "sun.max"
            case .dim: "moon.fill"
            case .pointer: "flashlight.on.fill"
            }
        }

        var next: LightsMode {
            let all = Self.allCases
            return all[(all.firstIndex(of: self)! + 1) % all.count]
        }
    }

    /// Remembers the tool, colour and width between sessions, and can start with a fixed tool (a setting).
    let toolbox = AnnotationToolbox(context: .live)
    /// Shared by all displays so ⌘Z always undoes the most recent stroke, wherever it was.
    let undoManager = UndoManager()
    let clickEffects = ClickEffectTracker()

    private var surfaces: [(screen: NSScreen, layer: AnnotationLayer, window: LiveAnnotationWindow)] = []
    private var palette: PalettePanel?
    private let paletteLayout = Preferences.paletteLayout
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var backdropRefresh: Task<Void, Never>?
    private var freezing: Task<Void, Never>?
    private var windowObservers: [NSObjectProtocol] = []
    /// Windows lifted above the overlays for the session, with the level to give back afterwards.
    private var liftedWindows: [(window: NSWindow, level: NSWindow.Level)] = []
    private var completion: ((Outcome) -> Void)?
    private var wasAppActive = false
    private var previousApp: NSRunningApplication?
    private let hiddenWindows = HiddenWindows()
    private var pointerMonitors: [Any] = []
    private var feed: LiveScreenFeed?

    /// While paused the drawing stays visible but clicks go to the apps underneath.
    private(set) var isPaused = false
    private(set) var lightsMode: LightsMode = .on
    /// A live loupe that follows the pointer, also while paused.
    private(set) var pointerLoupe = false
    /// A whiteboard or blackboard over the screen, on every display.
    private(set) var board: Board?
    /// The drawings are kept but not shown, for a look at the screen underneath.
    private(set) var drawingsHidden = false
    private(set) var isPaletteHidden = false
    /// What was on the screens when the session ended, for the next one to start from (a setting).
    private(set) var keptDrawings: [CGDirectDisplayID: SurfaceDrawing] = [:]

    /// The screen keeps moving under the drawing, or holds still on a picture of it. Starts from the preference;
    /// the palette's Live button switches it for this session.
    private(set) var isLive = !LiveAnnotationSession.freezesScreen

    static let freezesScreenKey = "annotateFreezesScreen"

    /// The preference: draw on the moving screen (the default), or freeze it first.
    static var freezesScreen: Bool {
        UserDefaults.standard.bool(forKey: freezesScreenKey)
    }

    /// The overlays show still pictures of the displays, or are about to. Paused, the screen moves either way,
    /// since clicks go to the apps underneath.
    private var isFrozen: Bool { !isLive && !isPaused }

    /// Drawings fade away by themselves shortly after the pen stops. Kept across sessions.
    private(set) var fadesInk = UserDefaults.standard.bool(forKey: LiveAnnotationSession.fadesInkKey)
    static let fadesInkKey = "liveFadingInk"

    var layers: [AnnotationLayer] { surfaces.map(\.layer) }

    var hasAnnotations: Bool {
        surfaces.contains { !$0.layer.annotations.isEmpty || !$0.layer.fadingAnnotations.isEmpty }
    }

    func setFadesInk(_ on: Bool) {
        fadesInk = on
        UserDefaults.standard.set(on, forKey: Self.fadesInkKey)
        for surface in surfaces { surface.layer.fadesInk = on }
    }

    func toggleFadesInk() {
        setFadesInk(!fadesInk)
    }

    var hasMagnifiers: Bool {
        surfaces.contains { surface in
            surface.layer.annotations.contains { if case .magnifier = $0.shape { true } else { false } }
        }
    }

    /// Anything drawn from the picture underneath: magnifiers, and pixelated or blurred areas.
    private var hasBackdropShapes: Bool {
        surfaces.contains { $0.layer.annotations.contains(where: \.needsBackdrop) }
    }

    private var isEditingText: Bool {
        surfaces.contains { $0.layer.textEditing != nil }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        for surface in surfaces {
            surface.window.ignoresMouseEvents = paused
            if paused { surface.layer.commitTextEditing() }
        }
        if paused, !isLive {
            // Clicks go to the apps underneath, so those must show: the screen moves until drawing resumes.
            thaw()
        }
        if !paused {
            NSApp.activate()
            surfaces.map(\.window).underPointer?.makeKey()
            if !isLive {
                // A fresh picture, since the apps underneath were in use meanwhile.
                freeze()
                return
            }
            // The apps underneath were in use meanwhile; lenses and hidden areas should show what's there now.
            // A running feed only covers one display, and pixelate and blur don't follow it, so refresh regardless.
            updateLiveFeed()
            if toolbox.tool.needsBackdrop || hasBackdropShapes {
                refreshBackdrops()
            }
        }
    }

    func togglePaused() {
        setPaused(!isPaused)
    }

    // MARK: - Board, hidden drawings, palette

    /// A whiteboard or blackboard (a setting says which, and how see-through) under the drawing on every display.
    func setBoard(_ on: Bool) {
        if on {
            let dark: Bool
            switch Preferences.boardStyle {
            case .white: dark = false
            case .black: dark = true
            case .automatic: dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
            board = Board(isDark: dark, opacity: Preferences.boardOpacity)
        } else {
            board = nil
        }
        for surface in surfaces { surface.layer.board = board }
    }

    func toggleBoard() {
        setBoard(board == nil)
    }

    func setDrawingsHidden(_ hidden: Bool) {
        drawingsHidden = hidden
        for surface in surfaces {
            if hidden { surface.layer.commitTextEditing() }
            surface.layer.isHidden = hidden
        }
    }

    func toggleDrawingsHidden() {
        setDrawingsHidden(!drawingsHidden)
    }

    func setPaletteHidden(_ hidden: Bool) {
        isPaletteHidden = hidden
        if hidden {
            palette?.orderOut(nil)
        } else {
            palette?.orderFrontRegardless()
        }
    }

    func togglePalette() {
        setPaletteHidden(!isPaletteHidden)
    }

    // MARK: - Live or frozen

    /// Frozen or live for the rest of the session. Freezing takes a picture of each display right now, behind
    /// the overlays, and draws on that; going live drops the pictures so the moving screen shows through again.
    /// While paused, only the choice changes: the screen freezes when drawing resumes.
    func setLive(_ live: Bool) {
        guard isLive != live, completion != nil else { return }
        isLive = live
        if live {
            thaw()
        } else if !isPaused {
            freeze()
        }
    }

    func toggleLive() {
        setLive(!isLive)
    }

    /// Shows still pictures of every display under the drawing. Lenses, pixelate, blur and redaction work from
    /// those pictures, and a capture keeps them rather than taking the screen as it is by then.
    private func freeze() {
        guard ScreenCapturer.hasPermission else {
            isLive = true
            CaptureToast.show(String(localized: "Freezing the screen needs Screen Recording access"), systemImage: "exclamationmark.triangle", on: NSScreen.underPointer)
            return
        }
        backdropRefresh?.cancel()
        updateLiveFeed()  // stops it: lenses enlarge the frozen picture from now on
        freezing?.cancel()
        let current = surfaces
        freezing = Task {
            do {
                let pictures = try await ScreenCapturer.snapshotsBehindOverlays(of: current.map(\.screen))
                // Stop if the user went live, paused or left meanwhile.
                guard !Task.isCancelled else { return }
                for (surface, picture) in zip(current, pictures) {
                    surface.window.frozen = picture
                    surface.layer.backdrop = AnnotationRenderer.Backdrop(image: picture, covering: surface.screen)
                }
                Diagnostics.log("Live annotation froze \(pictures.count) display(s)")
            } catch {
                guard !Task.isCancelled else { return }
                Diagnostics.log("Freezing the screen failed · \(error)")
                CaptureToast.show(String(localized: "Couldn't freeze the screen"), systemImage: "exclamationmark.triangle", on: NSScreen.underPointer)
                isLive = true
                updateLiveFeed()
            }
        }
    }

    /// Back to the moving screen; lenses and hidden areas show what's there now.
    private func thaw() {
        freezing?.cancel()
        freezing = nil
        for surface in surfaces {
            surface.window.frozen = nil
        }
        updateLiveFeed()
        if toolbox.tool.needsBackdrop || hasBackdropShapes {
            refreshBackdrops()
        }
    }

    // MARK: - Backdrops

    /// The magnifier enlarges, and pixelate and blur hide, what's under the overlay, which the overlay itself
    /// can't see: take a fresh picture of each display without our own windows. The one-off fallback while no
    /// live feed runs, and the instant picture when a tool is picked before the feed's first frame arrives.
    func refreshBackdrops() {
        guard !isFrozen else { return }  // the frozen pictures are the backdrops, and they don't change
        guard ScreenCapturer.hasPermission else {
            Diagnostics.log("Live backdrop skipped: no screen recording access")
            return
        }
        backdropRefresh?.cancel()
        backdropRefresh = Task {
            for surface in surfaces {
                guard !Task.isCancelled else { return }
                do {
                    let image = try await ScreenCapturer.snapshotBehindOverlays(of: surface.screen)
                    guard !Task.isCancelled else { return }  // the screen froze meanwhile, say
                    surface.layer.backdrop = AnnotationRenderer.Backdrop(image: image, covering: surface.screen)
                } catch {
                    Diagnostics.log("Live backdrop failed · \(error)")
                }
            }
        }
    }

    // MARK: - Redaction

    /// Looks at what each display shows right now, behind the overlays (or at the frozen picture), and covers
    /// anything sensitive with pixelated or blurred areas. They stay put: content that scrolls away afterwards
    /// is no longer covered, so run it again after scrolling.
    func redactScreens() {
        let screen = NSScreen.underPointer
        guard ScreenCapturer.hasPermission else {
            CaptureToast.show(String(localized: "Redacting needs Screen Recording access"), systemImage: "exclamationmark.triangle", on: screen)
            return
        }
        backdropRefresh?.cancel()
        CaptureToast.show(String(localized: "Looking for anything sensitive…"), systemImage: "eye.slash", on: screen)
        let style = RedactionStyle.preferred
        let current = surfaces
        Task {
            var total = RedactionResult(foundAnything: false, hidden: [])
            for surface in current {
                do {
                    let image: CGImage
                    if let frozen = surface.window.frozen {
                        image = frozen
                    } else {
                        image = try await ScreenCapturer.snapshotBehindOverlays(of: surface.screen)
                    }
                    // The areas are pixelated or blurred from this very picture.
                    surface.layer.backdrop = AnnotationRenderer.Backdrop(image: image, covering: surface.screen)
                    if let result = await surface.layer.redact(image, style: style) {
                        total.foundAnything = total.foundAnything || result.foundAnything
                        total.hidden += result.hidden
                    }
                } catch {
                    Diagnostics.log("Live redaction failed · \(error)")
                }
            }
            Diagnostics.log("Live redaction · \(total.message)")
            guard completion != nil else { return }  // the session ended meanwhile
            CaptureToast.show(total.message, systemImage: "eye.slash", on: screen)
        }
    }

    // MARK: - Lights, loupe and cursor

    /// Applies to every display at once.
    func setLightsMode(_ mode: LightsMode) {
        lightsMode = mode
        for surface in surfaces {
            surface.layer.dimsLights = mode != .on
            if mode != .pointer { surface.layer.pointerSpotlight = nil }
        }
        updatePointerTracking()
    }

    func cycleLightsMode() {
        setLightsMode(lightsMode.next)
    }

    func setPointerLoupe(_ on: Bool) {
        pointerLoupe = on
        if !on {
            for surface in surfaces { surface.layer.pointerLoupe = nil }
        }
        updatePointerTracking()
        updateLiveFeed()
    }

    func togglePointerLoupe() {
        setPointerLoupe(!pointerLoupe)
    }

    /// The cursor mark (a setting) follows the pointer for the whole session.
    private var marksPointer: Bool { Preferences.cursorStyle != .none }

    private func updatePointerTracking() {
        if lightsMode == .pointer || pointerLoupe || marksPointer {
            startPointerTracking()
            updatePointer()
        } else {
            stopPointerTracking()
        }
    }

    /// Mouse moves reach us through monitors rather than hover tracking, so the spotlight and the loupe
    /// keep following the pointer while paused (click-through) and while another app is frontmost.
    private func startPointerTracking() {
        guard pointerMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { self.updatePointer() }
            return event
        }) {
            pointerMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated { self.updatePointer() }
        }) {
            pointerMonitors.append(global)
        }
    }

    private func stopPointerTracking() {
        for monitor in pointerMonitors {
            NSEvent.removeMonitor(monitor)
        }
        pointerMonitors.removeAll()
    }

    private func updatePointer() {
        let mouse = NSEvent.mouseLocation
        for surface in surfaces {
            let frame = surface.screen.frame
            // Cocoa screen coordinates are y-up; the surface is y-down from its top-left corner.
            let local = frame.contains(mouse) ? CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y) : nil
            surface.layer.pointerSpotlight = lightsMode == .pointer ? local : nil
            surface.layer.pointerLoupe = pointerLoupe ? local : nil
            surface.layer.pointerMark = marksPointer ? local : nil
        }
        // The feed follows the pointer from display to display.
        if let feed, let current = NSScreen.underPointer, feed.screen.displayID != current.displayID {
            updateLiveFeed()
        }
    }

    /// The surface under the pointer and where the pointer is on it, in surface points.
    private var pointerSurface: (layer: AnnotationLayer, point: CGPoint)? {
        let mouse = NSEvent.mouseLocation
        guard let surface = surfaces.first(where: { $0.screen.frame.contains(mouse) }) else { return nil }
        let frame = surface.screen.frame
        return (surface.layer, CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y))
    }

    // MARK: - Live feed

    private var wantsLiveFeed: Bool {
        !isFrozen && (pointerLoupe || toolbox.tool == .magnifier || hasMagnifiers)
    }

    /// Streams the display under the pointer, without our own windows, while anything magnifies it, so lenses
    /// show the screen as it changes. Lenses on other displays keep their last snapshot.
    func updateLiveFeed() {
        guard wantsLiveFeed, ScreenCapturer.hasPermission, let screen = NSScreen.underPointer,
              let surface = surfaces.first(where: { $0.screen.displayID == screen.displayID })
        else {
            feed?.stop()
            feed = nil
            return
        }
        if let feed, feed.screen.displayID == surface.screen.displayID { return }
        feed?.stop()
        let newFeed = LiveScreenFeed(screen: surface.screen)
        let covered = surface.screen
        let layer = surface.layer
        newFeed.onFrame = { image in
            if let backdrop = layer.backdrop {
                layer.backdrop = backdrop.replacingPicture(with: image, scale: covered.pixelScale(of: image))
            } else {
                layer.backdrop = AnnotationRenderer.Backdrop(image: image, covering: covered)
            }
        }
        feed = newFeed
        Task {
            do {
                try await newFeed.start()
            } catch {
                Diagnostics.log("Live feed failed · \(error)")
                if self.feed === newFeed { self.feed = nil }
            }
        }
    }

    // MARK: - Session

    /// Puts the overlays up. `restoring` holds the drawing kept from the previous session, per display.
    func begin(restoring kept: [CGDirectDisplayID: SurfaceDrawing] = [:], completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        wasAppActive = NSApp.isActive
        previousApp = PreviousApp.current()
        hiddenWindows.hide()

        surfaces = NSScreen.screens.map { screen in
            let previous = screen.displayID.flatMap { kept[$0] }
            let layer = AnnotationLayer(size: screen.frame.size, toolbox: toolbox, undoManager: undoManager, annotations: previous?.annotations ?? [], dimsLights: previous?.dimsLights ?? false, board: previous?.board)
            layer.fadesInk = fadesInk
            let window = LiveAnnotationWindow(screen: screen, surface: FirstClickHostingView(rootView: LiveAnnotationSurface(layer: layer, session: self, displayID: screen.displayID)))
            return (screen, layer, window)
        }
        if let previous = kept.values.first(where: { $0.board != nil || $0.dimsLights }) {
            board = previous.board
            lightsMode = previous.dimsLights ? .dim : .on
        }
        let paletteScreen = NSScreen.underPointer ?? surfaces.first?.screen
        let palette = PalettePanel(rootView: LiveAnnotationPalette(session: self), on: paletteScreen, edge: PalettePanel.Edge(paletteLayout))
        palette.restorePlacement(layout: paletteLayout)
        self.palette = palette

        NSApp.activate()
        for surface in surfaces {
            surface.window.orderFrontRegardless()
        }
        palette.orderFrontRegardless()
        surfaces.map(\.window).underPointer?.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled: Bool = MainActor.assumeIsolated { self.handle(event) }
            return handled ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .scrollWheel, .otherMouseDown]) { event in
            let handled: Bool = MainActor.assumeIsolated { self.handleMouse(event) }
            return handled ? nil : event
        }
        startLiftingWindows()
        if Preferences.clickEffects {
            clickEffects.start()
        }
        updatePointerTracking()
        Sounds.play(.overlayOn)
        if !isLive {
            freeze()
        }
    }

    // MARK: - Other windows of ours

    /// Windows that open during the session, such as the system colour panel behind the palette's colour well,
    /// appear at a normal level: below the overlays, where they show through the transparent surface while every
    /// click on them draws a stroke instead. Lift each one above the overlays, and put it back when the session ends.
    private func startLiftingWindows() {
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            windowObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.lift(window) }
            })
        }
        // Already open from an earlier session, say.
        if NSColorPanel.sharedColorPanelExists {
            lift(NSColorPanel.shared)
        }
    }

    private func lift(_ window: NSWindow) {
        guard window.isVisible,
              window.level.rawValue < FullScreenOverlayWindow.paletteLevel.rawValue,
              window !== palette,
              !surfaces.contains(where: { $0.window === window }),
              !liftedWindows.contains(where: { $0.window === window })
        else { return }
        liftedWindows.append((window, window.level))
        window.level = FullScreenOverlayWindow.paletteLevel
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.orderFrontRegardless()
    }

    private func stopLiftingWindows() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        for lifted in liftedWindows {
            lifted.window.level = lifted.level
        }
        liftedWindows.removeAll()
    }

    /// What's drawn on each display right now, fading ink included (it's part of what the user sees).
    private var currentDrawings: [CGDirectDisplayID: SurfaceDrawing] {
        var byDisplay: [CGDirectDisplayID: SurfaceDrawing] = [:]
        for surface in surfaces {
            guard let id = surface.screen.displayID else { continue }
            let annotations = surface.layer.annotations + surface.layer.fadingAnnotations
            let drawing = SurfaceDrawing(annotations: annotations, dimsLights: surface.layer.dimsLights, board: surface.layer.board)
            guard !drawing.isEmpty else { continue }
            byDisplay[id] = drawing
        }
        return byDisplay
    }

    func capture() {
        for surface in surfaces {
            surface.layer.commitTextEditing()
        }
        var frozen: [CGDirectDisplayID: CGImage] = [:]
        for surface in surfaces {
            guard let id = surface.screen.displayID else { continue }
            frozen[id] = surface.window.frozen
        }
        end(with: .capture(currentDrawings, frozen: frozen))
    }

    func dismiss() {
        end(with: .dismissed)
    }

    func clearAll() {
        for layer in layers { layer.clearFading() }
        let drawnOn = layers.filter { !$0.annotations.isEmpty }
        guard !drawnOn.isEmpty else { return }
        // One undo step for the whole clear, however many displays were drawn on.
        undoManager.beginUndoGrouping()
        for layer in drawnOn {
            layer.clear()
        }
        undoManager.endUndoGrouping()
        Sounds.play(.clear)
    }

    func resetStepNumbers() {
        for layer in layers { layer.resetBadgeNumbers() }
        CaptureToast.show(String(localized: "Step numbers start again at 1"), systemImage: "1.circle", on: NSScreen.underPointer)
    }

    // MARK: - Keyboard

    /// Returns true when the key press was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        // Only keys aimed at our overlays or palette; the system color panel keeps its own typing. A key with no
        // window at all would go nowhere, and the overlays are what's on screen, so it's for them.
        if let window = event.window {
            guard window === palette || surfaces.contains(where: { $0.window === window }) else { return false }
        }
        // A text field being typed into owns the keyboard (it handles ↩ and esc itself).
        guard !isEditingText else { return false }
        let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
        let selectedLayers = layers.filter(\.hasSelection)

        switch (Int(event.keyCode), modifiers) {
        case (kVK_Escape, []):
            if !selectedLayers.isEmpty {
                for layer in selectedLayers { layer.clearSelection() }
            } else {
                dismiss()
            }
            return true
        case (kVK_Escape, [.shift]):
            // ⇧esc keeps the drawing on screen and hands the clicks to the apps underneath.
            setPaused(true)
            return true
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []):
            capture()
            return true
        case (kVK_Delete, []), (kVK_ForwardDelete, []):
            if !selectedLayers.isEmpty {
                for layer in selectedLayers { layer.deleteSelection() }
            } else {
                undoManager.undo()
            }
            return true
        case (kVK_LeftArrow, _), (kVK_RightArrow, _), (kVK_UpArrow, _), (kVK_DownArrow, _):
            guard !selectedLayers.isEmpty else { return false }
            let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
            let delta: CGPoint
            switch Int(event.keyCode) {
            case kVK_LeftArrow: delta = CGPoint(x: -step, y: 0)
            case kVK_RightArrow: delta = CGPoint(x: step, y: 0)
            case kVK_UpArrow: delta = CGPoint(x: 0, y: -step)
            default: delta = CGPoint(x: 0, y: step)
            }
            for layer in selectedLayers { layer.nudgeSelection(by: delta) }
            return true
        default:
            break
        }

        if let shortcut = LocalShortcut.from(event) {
            if shortcut.modifiers == .command, handleCommand(shortcut.character, shifted: modifiers.contains(.shift), selectedLayers: selectedLayers) {
                return true
            }
            if let action = OverlayShortcuts.shared.action(for: shortcut, in: .live) {
                perform(action)
                return true
            }
            if toolbox.applyColor(shortcut) {
                return true
            }
        }
        // Physical number keys, so the unshifted top row works on AZERTY keyboards too.
        guard modifiers.subtracting(.shift).isEmpty else { return false }
        if let position = Self.digitKeyCodes.firstIndex(of: Int(event.keyCode)), position < AnnotationTool.digitOrder.count {
            toolbox.tool = AnnotationTool.digitOrder[position]
            return true
        }
        return false
    }

    /// The fixed ⌘ keys: undo and redo, the clipboard, and text size.
    private func handleCommand(_ character: String, shifted: Bool, selectedLayers: [AnnotationLayer]) -> Bool {
        switch character {
        case "z":
            if shifted { undoManager.redo() } else { undoManager.undo() }
        case "a":
            for layer in layers { layer.selectAll() }
        case "c":
            guard let layer = selectedLayers.first else { return false }
            layer.copySelection()
        case "x":
            guard let layer = selectedLayers.first else { return false }
            layer.cutSelection()
        case "v":
            guard !AnnotationClipboard.shared.isEmpty else { return false }
            if let (layer, point) = pointerSurface {
                layer.paste(at: point)
            } else {
                layers.first?.paste()
            }
        case "d":
            guard !selectedLayers.isEmpty else { return false }
            for layer in selectedLayers { layer.duplicateSelection() }
        case "[":
            guard !selectedLayers.isEmpty else { return false }
            for layer in selectedLayers { layer.adjustTextSize(by: -2) }
        case "]":
            guard !selectedLayers.isEmpty else { return false }
            for layer in selectedLayers { layer.adjustTextSize(by: 2) }
        case "b" where !selectedLayers.isEmpty && selectedLayers.contains(where: { $0.selectedAnnotations.contains { if case .text = $0.shape { true } else { false } } }):
            // With texts selected ⌘B dresses them; otherwise it's the board.
            for layer in selectedLayers { layer.toggleTextBackground() }
        default:
            return false
        }
        return true
    }

    func perform(_ action: OverlayAction) {
        if toolbox.perform(action) {
            if action == .sizeDown || action == .sizeUp { showWidth() }
            return
        }
        switch action {
        case .lights: cycleLightsMode()
        case .loupe: togglePointerLoupe()
        case .fadingInk: toggleFadesInk()
        case .board: toggleBoard()
        case .hideDrawings: toggleDrawingsHidden()
        case .liveOrFrozen: toggleLive()
        case .togglePalette: togglePalette()
        case .clearAll: clearAll()
        case .resetStepNumbers: resetStepNumbers()
        case .redact: redactScreens()
        default: break
        }
    }

    private static let digitKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0]

    // MARK: - Mouse

    /// Returns true when the event was consumed.
    private func handleMouse(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === palette || surfaces.contains(where: { $0.window === window }) else { return false }
        switch event.type {
        case .leftMouseDown:
            // A lens or hidden area about to be placed should show the screen as it is right now.
            guard toolbox.tool.needsBackdrop, !isPaused, let surface = surfaces.first(where: { $0.window === event.window }) else { return false }
            if feed == nil {
                refreshBackdrops()
            } else if toolbox.tool != .magnifier {
                // The feed keeps the picture current, but pixelate and blur work from the one they were made from.
                surface.layer.backdrop = surface.layer.backdrop?.refreshingEffects()
            }
            return false
        case .scrollWheel:
            guard event.modifierFlags.contains(.command) else { return false }
            toolbox.adjustWidth(by: Self.widthStep(for: event))
            showWidth()
            return true
        case .otherMouseDown:
            // The back and forward buttons of a mouse undo and redo.
            switch event.buttonNumber {
            case 3: undoManager.undo()
            case 4: undoManager.redo()
            default: return false
            }
            return true
        default:
            return false
        }
    }

    /// How much ⌘-scrolling changes the width: a point per wheel notch, in smaller steps on a trackpad.
    static func widthStep(for event: NSEvent) -> CGFloat {
        if event.hasPreciseScrollingDeltas {
            return event.scrollingDeltaY / 6
        }
        return event.scrollingDeltaY > 0 ? 1 : (event.scrollingDeltaY < 0 ? -1 : 0)
    }

    private func showWidth() {
        CaptureToast.show(String(localized: "Line width \(StrokeWidthPicker.format(toolbox.lineWidth)) pt"), systemImage: "lineweight", on: NSScreen.underPointer)
    }

    // MARK: - Teardown

    private func end(with outcome: Outcome) {
        guard let completion else { return }
        self.completion = nil
        if case .dismissed = outcome, Preferences.keepsDrawings {
            keptDrawings = currentDrawings
        } else {
            keptDrawings = [:]
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        backdropRefresh?.cancel()
        backdropRefresh = nil
        freezing?.cancel()
        freezing = nil
        feed?.stop()
        feed = nil
        FloatingTooltipPanel.hide()
        // The colour well's panel belongs to the session: left open, it would float over whatever comes next.
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.isVisible {
            NSColorPanel.shared.orderOut(nil)
        }
        stopLiftingWindows()
        stopPointerTracking()
        clickEffects.stop()
        palette?.rememberPlacement(layout: paletteLayout)
        palette?.orderOut(nil)
        palette = nil
        for surface in surfaces {
            surface.window.orderOut(nil)
        }
        surfaces.removeAll()
        hiddenWindows.restore(inFront: wasAppActive)
        Sounds.play(.overlayOff)
        // Hand focus back to whatever the user was doing before.
        if case .dismissed = outcome {
            PreviousApp.activate(previousApp)
        }
        completion(outcome)
    }
}

/// One display while annotating, with the drawing surface on top: see-through over the moving screen, or an
/// opaque window showing a frozen picture of it. Setting `frozen` switches between the two.
final class LiveAnnotationWindow: FullScreenOverlayWindow {
    private let backdrop: NSView

    /// The frozen picture, or nil while the screen moves underneath.
    var frozen: CGImage? {
        didSet {
            isOpaque = frozen != nil
            backgroundColor = frozen != nil ? .black : .clear
            backdrop.layer?.contents = frozen
        }
    }

    init(screen: NSScreen, surface: NSView) {
        backdrop = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(screen: screen, opaque: false)
        // The frozen picture lives in a layer so only the drawing surface redraws while drawing.
        backdrop.wantsLayer = true
        backdrop.layer?.contentsGravity = .resize
        backdrop.layer?.contentsScale = screen.backingScaleFactor
        surface.frame = backdrop.bounds
        surface.autoresizingMask = [.width, .height]
        backdrop.addSubview(surface)
        contentView = backdrop
    }
}

/// One display's transparent drawing surface, with the click ripples on top.
struct LiveAnnotationSurface: View {
    let layer: AnnotationLayer
    let session: LiveAnnotationSession
    let displayID: CGDirectDisplayID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            AnnotationCanvas(layer: layer, displayScale: 1)
            ClickEffectsView(effects: session.clickEffects.effects.filter { $0.displayID == displayID })
        }
        .ignoresSafeArea()
    }
}

/// The floating tool strip shown while annotating the screen: a strip along the top (two rows on a display too
/// narrow for one), or a column down one side.
struct LiveAnnotationPalette: View {
    let session: LiveAnnotationSession
    @Bindable private var toolbox: AnnotationToolbox
    @AppStorage(RedactionStyle.defaultsKey) private var redactionStyle = RedactionStyle.blackout
    private let layout = Preferences.paletteLayout
    private let isCompact: Bool

    /// The width of the strip in one row; narrower displays get two.
    static let singleRowWidth: CGFloat = 1560

    /// `compact` forces or forbids the two-row strip; nil decides from the width of the display under the pointer.
    init(session: LiveAnnotationSession, compact: Bool? = nil) {
        self.session = session
        _toolbox = Bindable(session.toolbox)
        let width = (NSScreen.underPointer ?? NSScreen.main)?.visibleFrame.width ?? Self.singleRowWidth
        isCompact = compact ?? (width < Self.singleRowWidth)
    }

    private var axis: Axis { layout.axis }

    /// The annotate shortcut pauses and resumes; it can be changed in Settings.
    private var pauseHelp: String {
        let shortcut = HotKeyManager.shared.combo(for: .annotateScreen).displayString
        return session.isPaused
            ? "Paused: clicks reach the apps underneath; click to draw again (\(shortcut), or ⇧esc)"
            : "Pause: keep the drawing on screen but let clicks reach the apps underneath (\(shortcut), or ⇧esc)"
    }

    private func key(_ action: OverlayAction) -> String {
        let label = OverlayShortcuts.shared.label(for: action)
        return label.isEmpty ? "" : " (\(label))"
    }

    /// Laid out like the capture bar: leave at the leading end, then what to draw with, editing, presenting
    /// aids, how the session runs, and Capture last. Switches show only their symbol; tooltips name them.
    var body: some View {
        Group {
            if axis == .horizontal, isCompact {
                VStack(spacing: 6) {
                    HStack(spacing: 6) { drawingControls }
                    HStack(spacing: 6) { sessionControls }
                }
            } else {
                BarStack(axis: axis, spacing: 6) {
                    drawingControls
                    BarSeparator(axis: axis)
                    sessionControls
                }
            }
        }
        .controlSize(.large)
        .fixedSize()  // the panel's first size would otherwise squeeze a title into "Fading I…"
        .onChange(of: toolbox.tool) { _, tool in
            if tool.needsBackdrop { session.refreshBackdrops() }
            session.updateLiveFeed()
        }
        .onChange(of: session.hasMagnifiers) { _, _ in
            session.updateLiveFeed()
        }
        .onChange(of: toolbox.color) { _, color in
            let resolved = color.resolve(in: EnvironmentValues())
            for layer in session.layers { layer.restyleSelection(color: resolved) }
        }
        .onChange(of: toolbox.lineWidth) { _, width in
            for layer in session.layers { layer.restyleSelection(lineWidth: width) }
        }
        .floatingBar()
        .environment(\.floatingTooltips, true)
    }

    /// Leaving, the tools, the colour and the size.
    @ViewBuilder
    private var drawingControls: some View {
        Button {
            session.dismiss()
        } label: {
            Image(systemName: "xmark")
                .fontWeight(.semibold)
                .accessibilityLabel("Done")
        }
        .buttonStyle(.bar)
        .barHelp(Text("Leave annotation mode (esc)"))

        BarSeparator(axis: axis)

        ToolPicker(selection: $toolbox.tool, axis: axis)
            .fixedSize()

        BarSeparator(axis: axis)

        ColorPalette(selection: $toolbox.color, axis: axis)

        StrokeWidthPicker(toolbox: toolbox, axis: axis, alsoSets: "text size, badge size, blur strength and the loupe")
            .fixedSize()
    }

    /// Editing, the presenting aids, how the session runs, and Capture.
    @ViewBuilder
    private var sessionControls: some View {
        Group {
            BarGroup(axis: axis, columns: 4, count: 4) { index in
                switch index {
                case 0:
                    Button {
                        session.undoManager.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(!session.undoManager.canUndo)
                    .barHelp(Text("Undo (⌘Z, or the mouse's back button)"))
                case 1:
                    Button {
                        session.undoManager.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .disabled(!session.undoManager.canRedo)
                    .barHelp(Text("Redo (⇧⌘Z, or the mouse's forward button)"))
                case 2:
                    Button {
                        session.clearAll()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!session.hasAnnotations)
                    .barHelp(Text("Clear all drawings\(key(.clearAll))"))
                default:
                    Menu {
                        Picker("Hide With", selection: $redactionStyle) {
                            ForEach(RedactionStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "eye.slash")
                    } primaryAction: {
                        session.redactScreens()
                    }
                    // Drawn as a bar button like its neighbours; a borderless menu would grey its symbol as if disabled.
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .barHelp(Text("Hide email addresses, phone numbers, account and card numbers, keys and tokens, and faces on screen right now\(key(.redact)); run it again after scrolling"))
                }
            }
            .buttonStyle(.bar)

            BarSeparator(axis: axis)

            ChoiceBar(selection: Binding(get: { session.lightsMode }, set: { session.setLightsMode($0) }), options: LiveAnnotationSession.LightsMode.allCases, axis: axis, columns: 3) { mode in
                Image(systemName: mode.systemImage)
                    .frame(width: 18)
                    .accessibilityLabel(mode.title)
            } help: { mode in
                let cycles = OverlayShortcuts.shared.label(for: .lights)
                return "\(mode.title) (\(cycles.isEmpty ? "the buttons switch" : "\(cycles) cycles"); the spotlight's size is set in Settings)"
            }
            .fixedSize()

            BarGroup(axis: axis, columns: 4, spacing: 4, count: 4) { index in
                switch index {
                case 0:
                    Toggle(isOn: Binding(get: { session.pointerLoupe }, set: { session.setPointerLoupe($0) })) {
                        Label("Loupe", systemImage: "magnifyingglass")
                    }
                    .barHelp(Text("Loupe: a live loupe follows the pointer, also while paused\(key(.loupe)); size sets the lens, the colour its ring"))
                case 1:
                    Toggle(isOn: Binding(get: { session.fadesInk }, set: { session.setFadesInk($0) })) {
                        Label("Fading Ink", systemImage: "laser.burst")
                    }
                    .barHelp(Text("Fading ink: drawings fade away shortly after you stop drawing, for pointing things out while presenting\(key(.fadingInk)); text, highlights and hidden areas stay"))
                case 2:
                    Toggle(isOn: Binding(get: { session.board != nil }, set: { session.setBoard($0) })) {
                        Label("Board", systemImage: "rectangle.inset.filled")
                    }
                    .barHelp(Text("Board: a whiteboard or blackboard over the screen to draw on\(key(.board)); which one, and how see-through, is set in Settings"))
                default:
                    Toggle(isOn: Binding(get: { session.drawingsHidden }, set: { session.setDrawingsHidden($0) })) {
                        Label("Hide Drawings", systemImage: "eye.slash.circle")
                    }
                    .barHelp(Text("Hide the drawings for a moment to see the screen underneath; they come back when switched off\(key(.hideDrawings))"))
                }
            }
            .toggleStyle(.active)
            .labelStyle(.iconOnly)

            BarSeparator(axis: axis)

            BarGroup(axis: axis, spacing: 4, count: 2) { index in
                if index == 0 {
                    Toggle(isOn: Binding(get: { session.isLive }, set: { session.setLive($0) })) {
                        Label("Live", systemImage: "livephoto")
                    }
                    .barHelp(Text("Live: keep the screen moving under the drawing instead of frozen\(key(.liveOrFrozen)); a frozen screen moves while paused and freezes again when you resume"))
                } else {
                    // Lit while paused, so it's clear clicks are going to the apps underneath.
                    Toggle(isOn: Binding(get: { session.isPaused }, set: { session.setPaused($0) })) {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .barHelp(verbatim: pauseHelp)
                }
            }
            .toggleStyle(.active)
            .labelStyle(.iconOnly)

            Button {
                session.capture()
            } label: {
                if axis == .horizontal {
                    Label("Capture", systemImage: "camera.viewfinder")
                } else {
                    Image(systemName: "camera.viewfinder")
                        .accessibilityLabel("Capture")
                }
            }
            .buttonStyle(.barProminent)
            .barHelp(Text("Keep the drawing as a screenshot (↩)"))
        }
    }
}
#endif
