import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The window content for annotating one capture: zoomable canvas in the middle, tools in the toolbar.
struct AnnotationEditorView: View {
    let document: AnnotationDocument
    @Bindable private var toolbox: AnnotationToolbox
    @Bindable private var layer: AnnotationLayer
    @FocusState private var canvasFocused: Bool
    @State private var status: StatusMessage?
    /// nil means "fit to window".
    @State private var zoom: CGFloat?
    @State private var magnifyStart: CGFloat?
    /// Set while cropping or adding space; the canvas shows the whole original then.
    @State private var crop: CropSession?
    /// Where the pointer is over the picture, for pasting shapes there.
    @State private var pointerLocation: CGPoint?
    /// A board came with the capture from annotating the screen; the markup bar then offers to take it off.
    private let cameWithBoard: Bool
    @AppStorage(RedactionStyle.defaultsKey) private var redactionStyle = RedactionStyle.blackout

    private struct StatusMessage: Equatable {
        let id = UUID()
        let text: String
    }

    private static let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]

    init(document: AnnotationDocument) {
        self.document = document
        _toolbox = Bindable(document.layer.toolbox)
        _layer = Bindable(document.layer)
        cameWithBoard = document.layer.board != nil
    }

    var body: some View {
        GeometryReader { proxy in
            let fit = fitScale(in: proxy.size)
            let displayScale = zoom ?? fit
            let content = contentSize
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let crop {
                        CropCanvas(document: document, crop: crop, displayScale: displayScale)
                            .frame(width: content.width * displayScale, height: content.height * displayScale)
                    } else {
                        AnnotationCanvas(layer: document.layer, background: document.image, backgroundScale: document.scale, displayScale: displayScale, pointerMoved: { pointerLocation = $0 })
                            .frame(width: content.width * displayScale, height: content.height * displayScale)
                            .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    }
                }
                .padding(24)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
            }
            .background(Color(white: 0.11))
            .gesture(magnifyGesture(fit: fit))
        }
        .frame(minWidth: 720, minHeight: 360)
        .focusable()
        .focusEffectDisabled()
        .focused($canvasFocused)
        .defaultFocus($canvasFocused, true)
        .onKeyPress(phases: .down, action: handleKey)
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            canvasFocused = true
        }
        // The text field takes the keyboard while a text is typed, and the canvas must get it back afterwards:
        // let go of it on the way in, so taking it again on the way out is a change SwiftUI acts on.
        .onChange(of: document.layer.textEditing == nil) { _, finished in
            canvasFocused = finished
        }
        .onChange(of: toolbox.color) { _, color in
            document.layer.restyleSelection(color: color.resolve(in: EnvironmentValues()))
            refocusCanvas()
        }
        .onChange(of: toolbox.lineWidth) { _, width in
            document.layer.restyleSelection(lineWidth: width)
            refocusCanvas()
        }
        .onChange(of: toolbox.tool) { _, tool in
            document.layer.convertSelection(to: tool)
            refocusCanvas()
        }
        .onChange(of: layer.dimsLights) { _, _ in refocusCanvas() }
        .onChange(of: layer.board == nil) { _, _ in refocusCanvas() }
        .onChange(of: zoom) { _, _ in refocusCanvas() }
        .onChange(of: crop == nil) { _, _ in refocusCanvas() }
        .safeAreaInset(edge: .top, spacing: 0) { markupBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .overlay(alignment: .bottom) { statusView.padding(.bottom, 52) }
        .background { editCommands }
        .toolbar { toolbarContent }
    }

    /// The ⌘ keys for the selection, bound to buttons that aren't seen: a window's own key equivalents come
    /// before the Edit menu's, whose Select All, Cut and Paste would otherwise swallow them.
    private var editCommands: some View {
        Group {
            Button("Select All") { handleCommand("a") }.keyboardShortcut("a", modifiers: .command)
            Button("Cut") { handleCommand("x") }.keyboardShortcut("x", modifiers: .command)
            Button("Paste") { handleCommand("v") }.keyboardShortcut("v", modifiers: .command)
            Button("Duplicate") { handleCommand("d") }.keyboardShortcut("d", modifiers: .command)
            Button("Smaller Text") { handleCommand("[") }.keyboardShortcut("[", modifiers: .command)
            Button("Larger Text") { handleCommand("]") }.keyboardShortcut("]", modifiers: .command)
            Button("Text Background") { handleCommand("b") }.keyboardShortcut("b", modifiers: .command)
        }
        .disabled(crop != nil || document.layer.textEditing != nil)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// The height of the markup bar above the picture and the zoom bar below it, which the window adds to the
    /// picture's size when it opens.
    static let barsHeight: CGFloat = markupBarHeight + bottomBarHeight
    private static let markupBarHeight: CGFloat = 44
    private static let bottomBarHeight: CGFloat = 36

    /// Single-key shortcuts need the canvas to have the keyboard, so give it back after a click on the markup
    /// bar, unless a text annotation is being typed.
    private func refocusCanvas() {
        if document.layer.textEditing == nil { canvasFocused = true }
    }

    /// The picture, or while cropping the whole original with room around it.
    private var contentSize: CGSize {
        crop?.stage.size ?? document.pointSize
    }

    /// Shows the capture at true size when it fits, otherwise scaled down to fit the window.
    private func fitScale(in size: CGSize) -> CGFloat {
        let available = CGSize(width: size.width - 48, height: size.height - 48)
        let image = contentSize
        guard available.width > 0, available.height > 0, image.width > 0, image.height > 0 else { return 1 }
        return min(1, available.width / image.width, available.height / image.height)
    }

    // MARK: - Zoom

    private func magnifyGesture(fit: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyStart == nil { magnifyStart = zoom ?? fit }
                zoom = min(8, max(0.1, (magnifyStart ?? fit) * value.magnification))
            }
            .onEnded { _ in magnifyStart = nil }
    }

    private func zoomIn(fit: CGFloat) {
        let current = zoom ?? fit
        zoom = Self.zoomSteps.first { $0 > current + 0.001 } ?? min(8, current * 1.5)
    }

    private func zoomOut(fit: CGFloat) {
        let current = zoom ?? fit
        zoom = Self.zoomSteps.last { $0 < current - 0.001 } ?? max(0.1, current / 1.5)
    }

    private var bottomBar: some View {
        GeometryReader { proxy in
            let fit = fitScale(in: CGSize(width: proxy.size.width, height: proxy.size.height + 300))  // approximate; exact fit is recomputed by the main view
            HStack(spacing: 10) {
                zoomControls(fit: fit)

                if let crop {
                    cropControls(crop)
                } else {
                    Text(toolHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Label("Drag to export", systemImage: "square.and.arrow.up")
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .frame(height: BarMetrics.smallItemHeight + 2 * BarMetrics.trackInset)
                        .background(.quaternary, in: Capsule())
                        .contentShape(Capsule())
                        .pointerStyle(.grabIdle)
                        .onDrag { document.dragItemProvider() }
                        .help("Drag this into Finder, Mail, Slack… to hand over the PNG")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: proxy.size.height)
        }
        .frame(height: Self.bottomBarHeight)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// What to draw with, as on the live palette: the tools, the colour and size, dimming, and crop at the end.
    /// A bar of its own below the window toolbar, as in Preview, so the toolbar has room for every action
    /// and none of them ends up in its overflow menu at the window's usual width.
    private var markupBar: some View {
        let isCropping = crop != nil
        return HStack(spacing: 6) {
            Group {
                ToolPicker(selection: $toolbox.tool)
                    .fixedSize()

                BarSeparator()

                ColorPalette(selection: $toolbox.color)

                StrokeWidthPicker(toolbox: toolbox)
                    .fixedSize()

                BarSeparator()

                Toggle(isOn: $layer.dimsLights) {
                    Label("Dim Lights", systemImage: layer.dimsLights ? "moon.fill" : "moon")
                }
                .toggleStyle(.active)
                .labelStyle(.iconOnly)
                .help("Dim lights: darken everything except highlighted areas (\(OverlayShortcuts.shared.label(for: .lights)))")

                if cameWithBoard {
                    Toggle(isOn: Binding(get: { layer.board != nil }, set: { on in layer.board = on ? boardFromSettings : nil })) {
                        Label("Board", systemImage: "rectangle.inset.filled")
                    }
                    .toggleStyle(.active)
                    .labelStyle(.iconOnly)
                    .help("The board the screen was annotated on: switch it off to show the picture underneath")
                }
            }
            .disabled(isCropping)

            Spacer(minLength: 0)

            Toggle(isOn: Binding(get: { crop != nil }, set: { $0 ? startCrop() : applyCrop() })) {
                Label("Crop", systemImage: "crop")
            }
            .toggleStyle(.active(titled: true))
            .keyboardShortcut("k", modifiers: .command)
            .help("Crop, or add space around the picture (⌘K)")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.markupBarHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Zoom out, the level (a menu of steps) and zoom in, on one track like the bars' other grouped controls.
    private func zoomControls(fit: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { zoomOut(fit: fit) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.bar)
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom out (⌘−)")
            Menu {
                Button("Fit to Window") { zoom = nil }.keyboardShortcut("0", modifiers: .command)
                Button("Actual Size") { zoom = 1 }.keyboardShortcut("1", modifiers: .command)
                Divider()
                ForEach(Self.zoomSteps, id: \.self) { step in
                    Button("\(Int(step * 100))%") { zoom = step }
                }
            } label: {
                Text(zoom.map { "\(Int(($0 * 100).rounded()))%" } ?? "Fit")
                    .monospacedDigit()
                    .frame(minWidth: 40)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Zoom level: fit (⌘0), actual size (⌘1) or a step")
            Button { zoomIn(fit: fit) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.bar)
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom in (⌘+)")
        }
        .controlSize(.small)
        .barTrack()
    }

    @ViewBuilder
    private func cropControls(_ crop: CropSession) -> some View {
        Text("Drag the edges · past the picture adds space · ↩ crops · esc cancels")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

        Spacer()

        Text("\(Int((crop.rect.width * document.scale).rounded())) × \(Int((crop.rect.height * document.scale).rounded())) px")
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()

        Picker("Fill", selection: Bindable(crop).fill) {
            ForEach(CanvasFill.allCases) { fill in
                Text(fill.title).tag(fill)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("What fills the space added around the picture")

        Menu("Add Space") {
            Button("All Around") { crop.addSpace(.all) }
            Divider()
            Button("Top") { crop.addSpace(.top) }
            Button("Bottom") { crop.addSpace(.bottom) }
            Button("Left") { crop.addSpace(.leading) }
            Button("Right") { crop.addSpace(.trailing) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Make room for callouts next to the picture")

        Button("Reset") { crop.reset() }
            .disabled(crop.rect == crop.pictureBounds)
            .help("Back to the whole capture")
        Button("Cancel") { self.crop = nil }
            .help("Leave the picture as it was (esc)")
        Button("Crop", action: applyCrop)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Cut the picture to the rectangle, with any added space filled in (↩)")
    }

    /// The board as Settings describe it, for putting one back after taking it off.
    private var boardFromSettings: Board {
        let dark: Bool
        switch Preferences.boardStyle {
        case .white: dark = false
        case .black: dark = true
        case .automatic: dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        return Board(isDark: dark, opacity: Preferences.boardOpacity)
    }

    private var toolHint: String {
        let action: String
        switch toolbox.tool {
        case .select: action = String(localized: "Click to select · drag a box or ⇧-click for several · ⌘A all · drag to move · ⌥-drag duplicates · ⌘C ⌘X ⌘V ⌘D · ⌫ deletes · arrows nudge · double-click text to edit · ⌘[ ⌘] text size · ⌘B pill")
        case .eraser: action = String(localized: "Drag over anything to remove it")
        case .text: action = String(localized: "Click where the text should start, or on a text to change it · drag out a box of a width · ⇧↩ breaks a line · ↩ places · esc drops · ⌘B pill · ⌘[ ⌘] size")
        case .badge: action = String(localized: "Click to drop the next step number · \(OverlayShortcuts.shared.label(for: .resetStepNumbers)) starts again at 1")
        case .pixelate: action = String(localized: "Drag over the part to hide · \(OverlayShortcuts.shared.label(for: .redact)) hides anything sensitive")
        case .blur: action = String(localized: "Drag over the part to soften · the size sets how strongly · \(OverlayShortcuts.shared.label(for: .redact)) hides anything sensitive")
        case .magnifier: action = String(localized: "Click a detail for a loupe on it · drag from the detail to where the enlarged view should sit")
        case .measure: action = String(localized: "Drag between two points to measure the distance · ⇧ for straight angles")
        case .spotlight: action = String(localized: "Drag over the part to keep bright · \(OverlayShortcuts.shared.label(for: .lights)) dims the rest even more")
        case .freehand, .highlighter: action = String(localized: "Drag to draw")
        case .line, .arrow: action = String(localized: "Drag to draw · ⇧ for straight angles")
        case .rectangle, .ellipse: action = String(localized: "Drag to draw · ⇧ for a square or circle · ⌥ from the centre")
        }
        return action + " · tools 1–9 0 · colors R O Y G B P W K · size − + [ ]"
    }

    // MARK: - Toolbar

    /// The actions, in groups the toolbar sets on glass of their own: history, reading the picture, and handing
    /// it over at the trailing edge. The drawing controls live on the markup bar below.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        let isCropping = crop != nil
        // While a text is typed, ⌘Z belongs to the typing (the Edit menu's Undo reaches the field).
        let isTyping = document.layer.textEditing != nil

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                document.undoManager.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(isCropping || isTyping || !document.undoManager.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help("Undo (⌘Z)")

            Button {
                document.undoManager.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(isCropping || isTyping || !document.undoManager.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help("Redo (⇧⌘Z)")

            Button(role: .destructive) {
                document.layer.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(isCropping || document.layer.annotations.isEmpty)
            .help("Remove all annotations (\(OverlayShortcuts.shared.label(for: .clearAll)))")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Hide With", selection: $redactionStyle) {
                    ForEach(RedactionStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Redact", systemImage: "eye.slash")
            } primaryAction: {
                redact()
            }
            .disabled(isCropping)
            .help("Hide email addresses, phone numbers, IBANs, card numbers, keys and tokens, and faces (\(OverlayShortcuts.shared.label(for: .redact)))")

            #if os(macOS)
            Button(action: copyText) {
                Label("Copy Text", systemImage: "text.viewfinder")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(isCropping)
            .help("Recognize the text, or a QR code, in the capture and copy it (⇧⌘C)")
            #endif
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        // Handing the picture over comes last, at the trailing edge.
        ToolbarItemGroup(placement: .primaryAction) {
            #if os(macOS)
            Button(action: copyToClipboard) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(isCropping)
            .help("Copy the annotated image (⌘C; with shapes selected, ⌘C copies those instead)")

            Button(action: save) {
                Label("Save…", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(isCropping)
            .help("Save as PNG or JPEG (⌘S)")
            #endif

            ShareLink(item: SharedScreenshot(document: document), preview: SharePreview("Screenshot", image: Image(decorative: document.image, scale: document.scale))) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(isCropping)
            .help("Send the annotated image to another app or person")
        }
    }

    // MARK: - Crop

    private func startCrop() {
        document.layer.commitTextEditing()
        document.layer.clearSelection()
        crop = CropSession(document: document)
    }

    private func applyCrop() {
        guard let crop else { return }
        CanvasFill.preferred = crop.fill
        document.setCanvas(crop.rect, fill: crop.fill)
        self.crop = nil
    }

    // MARK: - Redact

    private func redact() {
        document.layer.commitTextEditing()
        showStatus(String(localized: "Looking for anything sensitive…"))
        let image = document.image
        let style = redactionStyle
        Task {
            if let result = await document.layer.redact(image, style: style, stillShowing: { document.image === image }) {
                showStatus(result.message)
            }
        }
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let layer = document.layer
        guard layer.textEditing == nil else { return .ignored }  // the text field owns the keyboard

        if let crop {
            if press.key == .return {
                applyCrop()
            } else if press.key == .escape {
                self.crop = nil
            } else if let delta = Self.nudge(for: press) {
                crop.rect = crop.rect.offsetBy(dx: delta.x, dy: delta.y)
                crop.refitStage()
            }
            return .handled  // drawing keys mean nothing while cropping
        }
        if press.key == .escape {
            // Out of whatever is going on: the selection, or else the drawing tool.
            if layer.hasSelection {
                layer.clearSelection()
            } else if toolbox.tool != .select {
                toolbox.tool = .select
            }
            return .handled
        }
        if press.key == .return, press.modifiers.isEmpty, let selected = layer.selectedAnnotation, case .text = selected.shape {
            layer.editSelectedText()
            return .handled
        }
        if press.key == .delete || press.key == .deleteForward, press.modifiers.subtracting(.shift).isEmpty {
            layer.deleteSelectedOrLast()
            return .handled
        }
        if let delta = Self.nudge(for: press) {
            layer.nudgeSelection(by: delta)
            return .handled
        }
        guard let shortcut = LocalShortcut.from(press) else { return .ignored }
        if shortcut.modifiers == .command, handleCommand(shortcut.character) {
            return .handled
        }
        if let action = OverlayShortcuts.shared.action(for: shortcut, in: .editor) {
            perform(action)
            return .handled
        }
        if toolbox.applyColor(shortcut) {
            return .handled
        }
        // Shift is allowed: on AZERTY keyboards digits need it.
        if shortcut.modifiers.isEmpty, let tool = AnnotationTool.forDigit(shortcut.character) {
            toolbox.tool = tool
            return .handled
        }
        return .ignored
    }

    /// The fixed ⌘ keys: the clipboard and text styling. (⌘Z, ⌘C and the rest of the toolbar's keys arrive as
    /// the toolbar's own shortcuts, not here.)
    @discardableResult
    private func handleCommand(_ character: String) -> Bool {
        let layer = document.layer
        switch character {
        case "a":
            layer.selectAll()
        case "x":
            guard layer.hasSelection else { return false }
            layer.cutSelection()
        case "v":
            guard !AnnotationClipboard.shared.isEmpty else { return false }
            layer.paste(at: pointerLocation)
        case "d":
            guard layer.hasSelection else { return false }
            layer.duplicateSelection()
        case "[":
            layer.adjustTextSize(by: -2)
        case "]":
            layer.adjustTextSize(by: 2)
        case "b":
            layer.toggleTextBackground()
        default:
            return false
        }
        return true
    }

    private func perform(_ action: OverlayAction) {
        let layer = document.layer
        // The text tool's key, with a text already selected and the tool in hand, opens that text for typing.
        if action == .text, toolbox.tool == .text, layer.selectedAnnotation.map({ if case .text = $0.shape { true } else { false } }) == true {
            layer.editSelectedText()
            return
        }
        if toolbox.perform(action) { return }
        switch action {
        case .lights: layer.dimsLights.toggle()
        case .clearAll: layer.clear()
        case .resetStepNumbers:
            layer.resetBadgeNumbers()
            showStatus(String(localized: "Step numbers start again at 1"))
        case .redact: redact()
        default: break
        }
    }

    /// How far an arrow key moves things: a point, or ten with ⇧.
    private static func nudge(for press: KeyPress) -> CGPoint? {
        let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
        switch press.key {
        case .leftArrow: return CGPoint(x: -step, y: 0)
        case .rightArrow: return CGPoint(x: step, y: 0)
        case .upArrow: return CGPoint(x: 0, y: -step)
        case .downArrow: return CGPoint(x: 0, y: step)
        default: return nil
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusView: some View {
        if let status {
            Text(status.text)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showStatus(_ text: String) {
        let message = StatusMessage(text: text)
        withAnimation(.snappy) { status = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if status == message {
                withAnimation(.easeOut) { status = nil }
            }
        }
    }

    // MARK: - Export (macOS)

    #if os(macOS)
    /// The toolbar button copies the picture. ⌘C does too, unless shapes are selected: then it copies those,
    /// for pasting on another capture or on the screen.
    private func copyToClipboard() {
        let layer = document.layer
        if NSApp.currentEvent?.type == .keyDown, layer.hasSelection {
            let count = layer.selectedAnnotations.count
            layer.copySelection()
            showStatus(count == 1 ? String(localized: "Copied 1 shape") : String(localized: "Copied \(count) shapes"))
            return
        }
        showStatus(document.copyToPasteboard() ? "Copied to clipboard" : "Couldn't render the image")
    }

    private func copyText() {
        showStatus(String(localized: "Reading text…"))
        Task {
            if let copied = await TextRecognizer.copyText(from: document.image) {
                showStatus(copied.message)
            } else {
                showStatus(String(localized: "No text or code found"))
            }
        }
    }

    private func save() {
        document.runSavePanel(attachedTo: NSApp.keyWindow) { outcome in
            switch outcome {
            case .saved(let url): showStatus(String(localized: "Saved \(url.lastPathComponent)"))
            case .failed(let message): showStatus(message)
            case .cancelled: break
            }
        }
    }
    #endif
}
