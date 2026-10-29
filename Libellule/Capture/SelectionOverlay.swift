#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

/// What a capture is for: a picture to annotate, or the text in it.
enum CapturePurpose: CaseIterable {
    case image
    case text

    var title: String {
        switch self {
        case .image: String(localized: "Screenshot")
        case .text: String(localized: "Copy Text")
        }
    }

    var systemImage: String {
        switch self {
        case .image: "camera.viewfinder"
        case .text: "text.viewfinder"
        }
    }
}

/// How the region is chosen.
enum CaptureMode: CaseIterable {
    case area
    case window
    case screen

    var title: String {
        switch self {
        case .area: String(localized: "Area")
        case .window: String(localized: "Window")
        case .screen: String(localized: "Screen")
        }
    }

    var systemImage: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        }
    }

    var key: String {
        switch self {
        case .area: "A"
        case .window: "W"
        case .screen: "F"
        }
    }
}

/// The state shared by the capture toolbar and the overlays on every display.
@Observable
final class CaptureOptions {
    var mode: CaptureMode = .area
    var purpose: CapturePurpose = .image
    var includeShadow = SelectionSession.includesWindowShadow
    /// The screen keeps moving under the overlay and the picture is taken on commit, instead of being frozen first.
    var isLive = false
    /// What the toolbar shows about the pointer's position: a window name or a selection size.
    var status = ""
    /// What happens with a screenshot: edit, copy or save. Unlike the shadow and live switches it sticks,
    /// since the toolbar shows it on every capture; Settings shows the same choice.
    private(set) var completion = CaptureCompletion.current
    /// Cover anything sensitive before the screenshot is copied, saved or edited. Sticks like `completion`.
    private(set) var redacts = SelectionSession.redactsCaptures

    func setCompletion(_ completion: CaptureCompletion) {
        self.completion = completion
        CaptureCompletion.current = completion
    }

    func setRedacts(_ redacts: Bool) {
        self.redacts = redacts
        SelectionSession.redactsCaptures = redacts
    }
}

/// A window the user can click in the overlay, with its frame in the screen's local point space.
struct WindowTarget {
    let window: SCWindow
    let rect: CGRect

    var title: String {
        let name = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        switch (name.isEmpty, title.isEmpty) {
        case (false, false): return "\(name) — \(title)"
        case (false, true): return name
        case (true, false): return title
        case (true, true): return "Window"
        }
    }
}

enum SelectionTarget {
    case area(CGRect)
    case window(WindowTarget, includeShadow: Bool)
}

/// What the user picked on the frozen screen.
struct ScreenSelection {
    let snapshot: ScreenSnapshot
    let target: SelectionTarget
    let purpose: CapturePurpose
    /// What to do with a screenshot (ignored when copying text).
    let completion: CaptureCompletion
    /// Cover anything sensitive in the screenshot first (ignored when copying text).
    let redacts: Bool
}

/// A display to choose on. With a `snapshot` the overlay shows that frozen picture; without one the overlay
/// is see-through, the screen keeps moving underneath, and the picture is taken when the user commits.
struct SelectionSurface {
    let screen: NSScreen
    var drawing = SurfaceDrawing()
    var snapshot: ScreenSnapshot?

    /// Live: nothing taken yet.
    init(screen: NSScreen) {
        self.screen = screen
    }

    /// Frozen: the picture taken before the overlay came up.
    init(frozen snapshot: ScreenSnapshot) {
        screen = snapshot.screen
        drawing = snapshot.drawing
        self.snapshot = snapshot
    }
}

/// How choosing ended.
enum SelectionOutcome {
    case cancelled
    case selected(ScreenSelection)
    /// The picture of a live screen couldn't be taken when the user committed.
    case failed(Error)
}

/// Puts an overlay on every display (the frozen picture, or see-through over the moving screen), a capture
/// toolbar at the bottom, and lets the user drag out a region, click a window or take a whole screen.
/// Return takes the display under the pointer, Escape cancels, L switches between frozen and live.
final class SelectionSession {
    private var windows: [SelectionWindow] = []
    private var toolbar: PalettePanel?
    private var completion: ((SelectionOutcome) -> Void)?
    private var liveCapture: Task<Void, Never>?
    private var wasAppActive = false
    private var previousApp: NSRunningApplication?
    private let hiddenWindows = HiddenWindows()
    let options = CaptureOptions()
    /// Drawings from live annotation mode need the frozen screen they were made on, so the Live button goes away then.
    private(set) var canToggleLive = true

    static let includesWindowShadowKey = "captureWindowShadow"

    static var includesWindowShadow: Bool {
        UserDefaults.standard.object(forKey: includesWindowShadowKey) as? Bool ?? true
    }

    static let redactsCapturesKey = "captureRedacts"

    static var redactsCaptures: Bool {
        get { UserDefaults.standard.bool(forKey: redactsCapturesKey) }
        set { UserDefaults.standard.set(newValue, forKey: redactsCapturesKey) }
    }

    static let freezesScreenKey = "captureFreezesScreen"

    /// The preference: freeze the screens before choosing (the default), or keep them live and take the picture on commit.
    static var freezesScreen: Bool {
        UserDefaults.standard.object(forKey: freezesScreenKey) as? Bool ?? true
    }

    func begin(on surfaces: [SelectionSurface], windowCandidates: [SCWindow], purpose: CapturePurpose, completion: @escaping (SelectionOutcome) -> Void) {
        self.completion = completion
        options.purpose = purpose
        options.isLive = surfaces.contains { $0.snapshot == nil }
        canToggleLive = surfaces.allSatisfy { $0.drawing.isEmpty }
        wasAppActive = NSApp.isActive
        previousApp = PreviousApp.current()
        hiddenWindows.hide()

        windows = surfaces.map { surface in
            let window = SelectionWindow(surface: surface, options: options)
            let displayRect = ScreenCapturer.displaySpaceRect(for: surface.screen)
            let bounds = CGRect(origin: .zero, size: surface.screen.frame.size)
            window.selectionView.windowTargets = windowCandidates.compactMap { candidate in
                let local = candidate.frame.offsetBy(dx: -displayRect.minX, dy: -displayRect.minY)
                guard local.intersects(bounds) else { return nil }
                return WindowTarget(window: candidate, rect: local)
            }
            window.selectionView.onCommit = { [weak self, weak window] target in
                guard let self, let window else { return }
                commit(target, on: window)
            }
            window.selectionView.onCancel = { [weak self] in
                self?.finish(with: .cancelled)
            }
            window.selectionView.onOptionsChanged = { [weak self] in
                self?.refresh()
            }
            window.selectionView.onToggleLive = { [weak self] in
                guard let self else { return }
                setLive(!options.isLive)
            }
            return window
        }
        prefetchLiveFilters()

        let toolbarScreen = NSScreen.underPointer ?? surfaces.first?.screen
        let toolbar = PalettePanel(rootView: CaptureToolbar(session: self), on: toolbarScreen, edge: .bottom)
        self.toolbar = toolbar

        // Key-window status (for Escape/Return) needs the app to be active.
        NSApp.activate()
        for window in windows {
            window.orderFrontRegardless()
        }
        toolbar.orderFrontRegardless()
        windows.underPointer?.makeKey()
    }

    /// Called whenever the toolbar or a key changes mode, result or shadow, so every overlay redraws.
    func refresh() {
        for window in windows {
            window.selectionView.needsDisplay = true
            window.selectionView.updateStatus()
        }
    }

    func cancel() {
        finish(with: .cancelled)
    }

    /// The toolbar's Capture button: the whole screen under the pointer. An area is taken the moment it's drawn.
    func captureNow() {
        guard options.mode != .window else { return }  // a window is taken by clicking it
        windows.underPointer?.selectionView.commitWholeScreen()
    }

    /// Frozen or live for this capture. Freezing takes a picture of each display right now, behind the
    /// overlays; going live drops the pictures so the moving screen shows through again.
    func setLive(_ live: Bool) {
        guard canToggleLive, options.isLive != live, completion != nil else { return }
        options.isLive = live
        if live {
            for window in windows {
                window.snapshot = nil
            }
            prefetchLiveFilters()
            refresh()
            return
        }
        Task {
            do {
                for window in windows {
                    // Stop if the user cancelled or went live again while a display was being taken.
                    guard completion != nil, !options.isLive else { return }
                    window.snapshot = try await window.takeSnapshot()
                }
                refresh()
            } catch {
                finish(with: .failed(error))
            }
        }
    }

    /// A live overlay captures what's behind it through a display filter; fetch those now so the commit doesn't wait.
    private func prefetchLiveFilters() {
        for window in windows where window.isLive && window.liveFilter == nil {
            Task {
                window.liveFilter = try? await ScreenCapturer.filterBehindOverlays(for: window.coveredScreen)
            }
        }
    }

    private func commit(_ target: SelectionTarget, on window: SelectionWindow) {
        guard completion != nil, liveCapture == nil else { return }
        let purpose = options.purpose
        let result = options.completion
        let redacts = options.redacts
        func selection(of snapshot: ScreenSnapshot) -> SelectionOutcome {
            .selected(ScreenSelection(snapshot: snapshot, target: target, purpose: purpose, completion: result, redacts: redacts))
        }
        if let snapshot = window.snapshot {
            finish(with: selection(of: snapshot))
            return
        }
        // Live: the picture is taken now, behind the overlays, so what the user has just seen is what they get.
        liveCapture = Task {
            do {
                finish(with: selection(of: try await window.takeSnapshot()))
            } catch {
                finish(with: .failed(error))
            }
        }
    }

    private func finish(with outcome: SelectionOutcome) {
        guard let completion else { return }
        self.completion = nil
        liveCapture = nil
        FloatingTooltipPanel.hide()
        toolbar?.orderOut(nil)
        toolbar = nil
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        hiddenWindows.restore(inFront: wasAppActive)
        // Hand focus back to whatever the user was doing if they changed their mind.
        if case .cancelled = outcome {
            PreviousApp.activate(previousApp)
        }
        completion(outcome)
    }
}

/// The strip at the bottom of the screen while choosing what to capture. Laid out like the system's own
/// screenshot bar: close at the leading end, then how and what to capture, the options, and Capture last.
struct CaptureToolbar: View {
    let session: SelectionSession

    var body: some View {
        let options = session.options
        let hasOptions = options.purpose == .image || options.mode == .window || session.canToggleLive
        HStack(spacing: 6) {
            Button {
                session.cancel()
            } label: {
                Image(systemName: "xmark")
                    .fontWeight(.semibold)
                    .accessibilityLabel("Cancel")
            }
            .buttonStyle(.bar)
            .barHelp(Text("Cancel (esc)"))

            BarSeparator()

            ChoiceBar(selection: Binding(get: { options.mode }, set: { options.mode = $0; session.refresh() }), options: CaptureMode.allCases, isTitled: true) { mode in
                Label(mode.title, systemImage: mode.systemImage)
            } help: { mode in
                "\(mode.title) (\(mode.key))"
            }
            .fixedSize()

            ChoiceBar(selection: Binding(get: { options.purpose }, set: { options.purpose = $0; session.refresh() }), options: CapturePurpose.allCases, isTitled: true) { purpose in
                Label(purpose.title, systemImage: purpose.systemImage)
            } help: { purpose in
                "\(purpose.title) (T switches)"
            }
            .fixedSize()

            if hasOptions {
                BarSeparator()
            }

            if options.purpose == .image {
                Picker("After Capturing", selection: Binding(get: { options.completion }, set: { options.setCompletion($0) })) {
                    ForEach(CaptureCompletion.allCases) { completion in
                        Label(completion.shortTitle, systemImage: completion.systemImage)
                            .tag(completion)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .barHelp(Text("Then: open the editor, copy to the clipboard, or save to a file (O switches; remembered for next time)"))

                Toggle(isOn: Binding(get: { options.redacts }, set: { options.setRedacts($0) })) {
                    Label("Redact", systemImage: "eye.slash")
                }
                .toggleStyle(.active(titled: true))
                .barHelp(Text("Hide email addresses, phone numbers, account and card numbers, keys and tokens, and faces before the screenshot is copied, saved or edited (R; remembered for next time)"))
            }

            if options.mode == .window {
                Toggle(isOn: Binding(get: { options.includeShadow }, set: { options.includeShadow = $0 })) {
                    Label("Shadow", systemImage: "shadow")
                }
                .toggleStyle(.active(titled: true))
                .barHelp(Text("Include the window's shadow (⌥-click a window for the opposite)"))
            }

            if session.canToggleLive {
                Toggle(isOn: Binding(get: { options.isLive }, set: { session.setLive($0) })) {
                    Label("Live", systemImage: "livephoto")
                }
                .toggleStyle(.active(titled: true))
                .barHelp(Text("Keep the screen moving instead of frozen while choosing; the picture is taken when you capture (L)"))
            }

            BarSeparator()

            // A fixed size, so the bar doesn't change width with every window title or selection size under the
            // pointer; two lines leave room for the longer hints.
            Text(options.status.isEmpty ? hint(for: options) : options.status)
                .font(options.status.isEmpty ? .callout : .callout.monospacedDigit())
                .foregroundStyle(options.status.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(width: 250, height: BarMetrics.itemHeight + 4, alignment: .leading)

            Button {
                session.captureNow()
            } label: {
                Label("Capture", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.barProminent)
            .disabled(options.mode == .window)
            .barHelp(verbatim: captureHelp(for: options))
        }
        .controlSize(.large)
        .fixedSize()  // the panel's first size would otherwise squeeze the titles into "R…" and "Ca…"
        .floatingBar()
        .environment(\.floatingTooltips, true)
    }

    private func hint(for options: CaptureOptions) -> String {
        switch (options.mode, options.purpose) {
        case (.area, .image): "Drag an area, release to capture · ⇧ for a square · ↩ whole screen"
        case (.area, .text): "Drag over text or a QR code, release to copy it"
        case (.window, .image): "Click a window · drag for an area instead"
        case (.window, .text): "Click a window to copy its text"
        case (.screen, _): "Capture or click takes the whole screen under the pointer"
        }
    }

    private func captureHelp(for options: CaptureOptions) -> String {
        switch options.mode {
        case .area: "Capture the whole screen under the pointer (↩)"
        case .window: "Click a window to capture it"
        case .screen: "Capture the whole screen under the pointer (↩)"
        }
    }
}

/// One display while choosing, with the rubber-band selection view on top: an opaque window showing the
/// frozen picture, or a see-through one over the moving screen. Setting `snapshot` switches between the two.
final class SelectionWindow: FullScreenOverlayWindow {
    let selectionView: SelectionView
    /// The display this overlay covers (`screen` is wherever the window server currently has the window).
    let coveredScreen: NSScreen
    let drawing: SurfaceDrawing
    /// Live only: the filter that keeps our overlays out of the picture, fetched ahead of the commit.
    var liveFilter: SCContentFilter?
    private let backdrop: NSView

    /// The frozen picture, or nil while the screen is live.
    var snapshot: ScreenSnapshot? {
        didSet { showSnapshot() }
    }

    var isLive: Bool { snapshot == nil }

    init(surface: SelectionSurface, options: CaptureOptions) {
        coveredScreen = surface.screen
        drawing = surface.drawing
        snapshot = surface.snapshot
        selectionView = SelectionView(options: options)
        backdrop = NSView(frame: NSRect(origin: .zero, size: surface.screen.frame.size))
        super.init(screen: surface.screen, opaque: surface.snapshot != nil)

        // The frozen screen lives in a layer so only the thin selection view redraws on mouse moves.
        backdrop.wantsLayer = true
        backdrop.layer?.contentsGravity = .resize
        backdrop.layer?.contentsScale = surface.screen.backingScaleFactor
        selectionView.frame = backdrop.bounds
        selectionView.autoresizingMask = [.width, .height]
        backdrop.addSubview(selectionView)
        contentView = backdrop
        makeFirstResponder(selectionView)
        showSnapshot()
    }

    /// Live only: the display as it is this instant, without our own windows in the way.
    func takeSnapshot() async throws -> ScreenSnapshot {
        let started = ContinuousClock.now
        let filter: SCContentFilter
        if let liveFilter {
            filter = liveFilter
        } else {
            filter = try await ScreenCapturer.filterBehindOverlays(for: coveredScreen)
            liveFilter = filter
        }
        let image = try await ScreenCapturer.snapshot(behind: filter)
        Diagnostics.log("Live capture of display \(coveredScreen.displayID ?? 0) · \(image.width)×\(image.height) in \(started.duration(to: .now))")
        return ScreenSnapshot(screen: coveredScreen, image: image, drawing: drawing)
    }

    private func showSnapshot() {
        let frozen = snapshot != nil
        isOpaque = frozen
        backgroundColor = frozen ? .black : .clear
        backdrop.layer?.contents = snapshot?.displayImage
        selectionView.needsDisplay = true
    }
}

/// Dims the frozen screen, shows what a click would take, keeps an adjustable selection and reports the result.
final class SelectionView: NSView {
    let options: CaptureOptions
    var windowTargets: [WindowTarget] = []
    var onCommit: ((SelectionTarget) -> Void)?
    var onCancel: (() -> Void)?
    var onOptionsChanged: (() -> Void)?
    var onToggleLive: (() -> Void)?

    /// The rubber band while it is being dragged out; the area is captured as soon as the mouse is released.
    private(set) var selection: CGRect? {
        didSet { needsDisplay = true }
    }

    private var dragAnchor: CGPoint?
    private var hoverPoint: CGPoint?
    private var trackingArea: NSTrackingArea?

    init(options: CaptureOptions) {
        self.options = options
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Top-left origin, matching the image and the editor.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    private func updateCursor() {
        if options.mode == .area {
            NSCursor.crosshair.set()
        } else {
            NSCursor.pointingHand.set()
        }
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = location(of: event)
        // On multi-display setups the display under the pointer is the one Return should capture.
        if let window, !window.isKeyWindow {
            window.makeKey()
        }
        updateCursor()
        updateStatus()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragAnchor = location(of: event)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let rect = CGRect(from: anchor, to: location(of: event), square: event.modifierFlags.contains(.shift))
        if options.mode == .window, rect.width >= 4 || rect.height >= 4 {
            setMode(.area)  // a drag in window mode becomes an area selection
        }
        if options.mode == .area {
            selection = rect.integral.intersection(bounds)
            updateStatus()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        dragAnchor = nil
        let band = selection
        selection = nil
        updateCursor()

        switch options.mode {
        case .area:
            // Letting go of the rubber band takes the shot; a plain click without a drag takes nothing.
            if let band, band.width >= 4, band.height >= 4 {
                onCommit?(.area(band))
            } else {
                updateStatus()
            }
        case .window:
            if let target = windowTarget(at: anchor) {
                // ⌥ inverts the shadow setting for this one capture.
                let includeShadow = options.includeShadow != event.modifierFlags.contains(.option)
                onCommit?(.window(target, includeShadow: includeShadow))
            }
        case .screen:
            commitWholeScreen()
        }
    }

    // MARK: Committing

    func commitWholeScreen() {
        onCommit?(.area(bounds))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            onCancel?()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commitWholeScreen()
        case kVK_Space:
            setMode(options.mode == .window ? .area : .window)
        case kVK_ANSI_A:
            setMode(.area)
        case kVK_ANSI_W:
            setMode(.window)
        case kVK_ANSI_F:
            setMode(.screen)
        case kVK_ANSI_T:
            options.purpose = options.purpose == .image ? .text : .image
            onOptionsChanged?()
        case kVK_ANSI_L:
            onToggleLive?()
        case kVK_ANSI_O:
            guard options.purpose == .image else { break }  // copied text always goes to the clipboard
            options.setCompletion(options.completion.next)
            onOptionsChanged?()
        case kVK_ANSI_R:
            guard options.purpose == .image else { break }
            options.setRedacts(!options.redacts)
            onOptionsChanged?()
        default:
            break  // swallow silently instead of beeping
        }
    }

    private func setMode(_ mode: CaptureMode) {
        guard options.mode != mode else { return }
        options.mode = mode
        updateCursor()
        onOptionsChanged?()
    }

    /// Tells the toolbar what the pointer is over.
    func updateStatus() {
        guard window?.isKeyWindow == true else { return }
        switch options.mode {
        case .area:
            if let rect = selection, rect.width >= 1 {
                options.status = "\(Int(rect.width)) × \(Int(rect.height))"
            } else {
                options.status = ""
            }
        case .window:
            options.status = hoveredWindow?.title ?? ""
        case .screen:
            options.status = "Whole screen · \(Int(bounds.width)) × \(Int(bounds.height))"
        }
    }

    // MARK: Geometry

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil).clamped(to: bounds)
    }

    private func windowTarget(at point: CGPoint) -> WindowTarget? {
        windowTargets.first { $0.rect.contains(point) }
    }

    private var hoveredWindow: WindowTarget? {
        guard options.mode == .window, dragAnchor == nil, let hoverPoint else { return nil }
        return windowTarget(at: hoverPoint)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.4)

        if options.mode == .area, let rect = selection, rect.width >= 1, rect.height >= 1 {
            let cutout = NSBezierPath(rect: bounds)
            cutout.appendRect(rect)
            cutout.windingRule = .evenOdd
            dim.setFill()
            cutout.fill()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()

            drawPill("\(Int(rect.width)) × \(Int(rect.height))", centeredAt: CGPoint(x: rect.midX, y: rect.maxY + 22))
            return
        }

        switch options.mode {
        case .window:
            if let hovered = hoveredWindow {
                // Lift the window under the pointer out of the dim so a click's result is obvious.
                let visible = hovered.rect.intersection(bounds)
                let cutout = NSBezierPath(rect: bounds)
                cutout.appendRoundedRect(visible, xRadius: 8, yRadius: 8)
                cutout.windingRule = .evenOdd
                dim.setFill()
                cutout.fill()
                NSColor.white.setStroke()
                let outline = NSBezierPath(roundedRect: visible.insetBy(dx: -1, dy: -1), xRadius: 9, yRadius: 9)
                outline.lineWidth = 2
                outline.stroke()
            } else {
                dim.setFill()
                NSBezierPath(rect: bounds).fill()
            }
        case .screen:
            // The whole display is the target: leave it bright, just frame it.
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            outline.lineWidth = 4
            outline.stroke()
        case .area:
            dim.setFill()
            NSBezierPath(rect: bounds).fill()
            if let hoverPoint {
                NSColor.white.withAlphaComponent(0.6).setStroke()
                let guides = NSBezierPath()
                guides.lineWidth = 1
                guides.move(to: CGPoint(x: hoverPoint.x + 0.5, y: 0))
                guides.line(to: CGPoint(x: hoverPoint.x + 0.5, y: bounds.height))
                guides.move(to: CGPoint(x: 0, y: hoverPoint.y + 0.5))
                guides.line(to: CGPoint(x: bounds.width, y: hoverPoint.y + 0.5))
                guides.stroke()
            }
        }
    }

    private func drawPill(_ text: String, centeredAt center: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        var frame = CGRect(
            x: center.x - textSize.width / 2 - 12, y: center.y - textSize.height / 2 - 6,
            width: textSize.width + 24, height: textSize.height + 12
        )
        frame.origin.x = min(max(frame.minX, 8), bounds.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.minY, 8), bounds.maxY - frame.height - 8)

        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: frame, xRadius: frame.height / 2, yRadius: frame.height / 2).fill()
        string.draw(at: CGPoint(x: frame.minX + 12, y: frame.minY + 6))
    }
}
#endif
