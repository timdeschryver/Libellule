#if os(macOS)
import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// The panes of the Settings window. The choice is remembered, and the main window sets it to open on Shortcuts.
enum SettingsTab: String {
    case general, capture, annotate, presenting, redaction, shortcuts

    static let defaultsKey = "settingsTab"
}

/// Settings in panes, as macOS apps lay them out, so no single pane runs taller than a laptop screen.
struct SettingsView: View {
    @AppStorage(SettingsTab.defaultsKey) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettings()
            }
            Tab("Capture", systemImage: "camera.viewfinder", value: SettingsTab.capture) {
                CaptureSettings()
            }
            Tab("Annotate", systemImage: "pencil.and.outline", value: SettingsTab.annotate) {
                AnnotateSettings()
            }
            Tab("Presenting", systemImage: "person.wave.2", value: SettingsTab.presenting) {
                PresentingSettings()
            }
            Tab("Redaction", systemImage: "eye.slash", value: SettingsTab.redaction) {
                RedactionSettings()
            }
            Tab("Shortcuts", systemImage: "keyboard", value: SettingsTab.shortcuts) {
                ShortcutSettings()
            }
        }
    }
}

private extension View {
    /// The look of every pane: a grouped form at a fixed width, which the window takes its height from.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .frame(width: 520)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(ExportFormat.defaultsKey) private var saveFormat = ExportFormat.png.rawValue
    @AppStorage(TextRecognizer.joinsLinesKey) private var joinsLines = false
    @AppStorage(Preferences.showsDockIconKey) private var showsDockIcon = false
    @AppStorage(Preferences.playsSoundsKey) private var playsSounds = false

    var body: some View {
        Form {
            Section {
                LaunchAtLoginToggle()
                Toggle("Show Libellule in the Dock", isOn: $showsDockIcon)
                    .onChange(of: showsDockIcon) { _, _ in DockIcon.apply() }
                    .help("Off, Libellule lives in the menu bar only; on, it also gets a Dock icon and shows up in ⌘-Tab")
                Toggle("Play a sound when annotation mode starts, ends or is cleared", isOn: $playsSounds)
                    .help("Short system sounds for the overlay coming up, going away and being cleared")
            }

            Section {
                Picker("Save screenshots as", selection: $saveFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
                .help("PNG keeps every pixel and transparency; JPEG is smaller and loses a little")
            } header: {
                Text("Saving")
            } footer: {
                Text("The save panel starts with this format and lets you switch it per file. Copying, dragging and sharing always hand over a PNG.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Join lines into paragraphs", isOn: $joinsLines)
                    .help("Run the lines of a paragraph together when copying text from the screen")
            } header: {
                Text("Copy Text")
            } footer: {
                Text("Off keeps one line per line on screen. On runs the lines of a paragraph together, which suits text copied from a document or a chat. Double spaces are always collapsed.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("This is version \(AppInfo.version)") {
                    Button("Check for Updates…") {
                        AppInfo.checkForUpdates()
                    }
                    .help("Open the latest release on GitHub in your browser")
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Opens the latest release in your browser so you can compare versions and download it. Libellule has no network access of its own, so it can't check in the background.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }
}

private struct CaptureSettings: View {
    @AppStorage(CaptureCompletion.defaultsKey) private var completion = CaptureCompletion.openEditor.rawValue
    @AppStorage(SelectionSession.includesWindowShadowKey) private var includeWindowShadow = true
    @AppStorage(SelectionSession.freezesScreenKey) private var freezesScreen = true
    @AppStorage(LiveAnnotationSession.freezesScreenKey) private var freezesAnnotatedScreen = false

    var body: some View {
        Form {
            Section {
                Picker("After capturing", selection: $completion) {
                    ForEach(CaptureCompletion.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .help("What happens with a screenshot once the area or window is chosen")
                Toggle("Freeze the screen while choosing what to capture", isOn: $freezesScreen)
                    .help("Holds menus, tooltips and animations still while you choose; off, the picture is taken when you release")
                Toggle("Include the window's shadow when capturing a window", isOn: $includeWindowShadow)
                    .help("Keep the shadow around a captured window, on a transparent edge")
            } header: {
                Text("Capture")
            } footer: {
                Text("The menu next to Screenshot on the capture bar changes what happens after capturing too (O steps through it), and keeps that choice for next time. With the freeze off, the screen keeps moving under the selection and the picture is taken the moment you release the area or click a window; the capture bar's Live button (L) switches this for one capture. Hold ⌥ while clicking a window to do the opposite of the shadow setting. In the editor, ⌘C copies and ⌘S saves at any time.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Freeze the screen while annotating it", isOn: $freezesAnnotatedScreen)
                    .help("Draw on a still picture of the screen instead of the moving screen; the palette's Live button switches it per session")
            } header: {
                Text("Annotate Screen")
            } footer: {
                Text("Frozen, you draw on a picture of the screen taken when annotating starts, so videos, animations and scrolling hold still; keeping it as a screenshot keeps that picture too. The palette's Live button (⌘L) switches this for one session. Pausing lets the screen move again so you can see what you click, and it freezes afresh when you resume.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }
}

private struct AnnotateSettings: View {
    @AppStorage(Preferences.liveStartToolKey) private var liveStartTool = ""
    @AppStorage(Preferences.editorStartToolKey) private var editorStartTool = ""
    @AppStorage(Preferences.badgeStyleKey) private var badgeStyle = BadgeStyle.filled.rawValue
    @AppStorage(Preferences.fadeDelayKey) private var fadeDelay = 2.0
    @AppStorage(Preferences.keepsDrawingsKey) private var keepsDrawings = false
    @AppStorage(Preferences.paletteLayoutKey) private var paletteLayout = PaletteLayout.horizontal.rawValue

    var body: some View {
        Form {
            Section {
                startToolPicker("Annotating the screen starts with", selection: $liveStartTool)
                startToolPicker("Editing a screenshot starts with", selection: $editorStartTool)
            } header: {
                Text("Tools")
            } footer: {
                Text("The colour and size are always remembered from last time, for the screen and for screenshots separately.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Step numbers", selection: $badgeStyle) {
                    ForEach(BadgeStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help("How new step numbers look: a solid disc, or a ring")
            } footer: {
                Text("Filled is a solid disc with the number cut out; Bordered is a ring with the number inside. \(OverlayShortcuts.shared.label(for: .resetStepNumbers)) starts the count again at 1.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Fading ink stays for") {
                    HStack {
                        Slider(value: $fadeDelay, in: Preferences.fadeDelayRange, step: 0.25)
                        Text(fadeDelay, format: .number.precision(.fractionLength(0...2)))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                        Text("s")
                    }
                }
                .help("How long drawings made with fading ink stay before they fade: a quarter of a second to five seconds")
            } footer: {
                Text("With fading ink on, drawings fade out this long after the pen stops.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep the drawing when leaving annotation mode", isOn: $keepsDrawings)
                    .help("Start the next annotation session with the drawing the last one ended with")
            } footer: {
                Text("On, the next annotation session starts with what was on the screens when the last one ended, until the app quits. Off, every session starts clean.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Palette", selection: $paletteLayout) {
                    ForEach(PaletteLayout.allCases) { layout in
                        Text(layout.title).tag(layout.rawValue)
                    }
                }
                .help("Where the tool palette sits while annotating the screen")
            } footer: {
                Text("Drag the palette anywhere; it remembers where it was left on each display. \(OverlayShortcuts.shared.label(for: .togglePalette)) hides and shows it. Takes effect the next time annotation mode starts.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }

    private func startToolPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("The tool used last").tag("")
            Divider()
            ForEach(ToolPicker.groups.flatMap { $0 }) { tool in
                Label(tool.title, systemImage: tool.systemImage).tag(tool.rawValue)
            }
        }
        .help("The tool in hand at the start: whichever was used last time, or always the same one")
    }
}

private struct PresentingSettings: View {
    @AppStorage(Preferences.boardStyleKey) private var boardStyle = BoardStyle.automatic.rawValue
    @AppStorage(Preferences.boardOpacityKey) private var boardOpacity = 1.0
    @AppStorage(Preferences.dimAmountKey) private var dimAmount = 0.65
    @AppStorage(Preferences.spotlightRadiusKey) private var spotlightRadius = 120.0
    @AppStorage(Preferences.cursorStyleKey) private var cursorStyle = CursorStyle.none.rawValue
    @AppStorage(Preferences.cursorSizeKey) private var cursorSize = 14.0
    @AppStorage(Preferences.clickEffectsKey) private var clickEffects = false
    @AppStorage(Preferences.clickEffectSizeKey) private var clickEffectSize = 50.0
    @State private var effectColor = Preferences.effectColor

    var body: some View {
        Form {
            Section {
                Picker("Board", selection: $boardStyle) {
                    ForEach(BoardStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .help("A white or black board, or whichever suits the system's light or dark appearance")
                percentSlider("Opacity", value: $boardOpacity, in: Preferences.boardOpacityRange)
                    .help("How solid the board is: lower lets the screen show through it")
            } header: {
                Text("Board")
            } footer: {
                Text("A whiteboard or blackboard laid over the screen to draw on, switched on from the palette or with \(OverlayShortcuts.shared.label(for: .board)). Lower the opacity to let the screen show through.")
                    .foregroundStyle(.secondary)
            }

            Section {
                percentSlider("Dim lights darkens by", value: $dimAmount, in: Preferences.dimAmountRange)
                    .help("How dark everything outside the highlights and the spotlight gets")
                LabeledContent("Pointer spotlight size") {
                    HStack {
                        Slider(value: $spotlightRadius, in: Preferences.spotlightRadiusRange, step: 10)
                        Text("\(Int(spotlightRadius)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .help("The radius of the bright circle that follows the pointer while the lights are dimmed")
            } header: {
                Text("Lights")
            } footer: {
                Text("The spotlight is the bright circle that follows the pointer while the lights are dimmed (\(OverlayShortcuts.shared.label(for: .lights)) cycles through lights on, dimmed and spotlight).")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Mark the pointer with", selection: $cursorStyle) {
                    ForEach(CursorStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .help("A ring, a disc or a crosshair drawn on the pointer while annotating the screen, so an audience can find it")
                LabeledContent("Mark size") {
                    HStack {
                        Slider(value: $cursorSize, in: Preferences.cursorSizeRange, step: 1)
                        Text("\(Int(cursorSize)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .disabled(cursorStyle == CursorStyle.none.rawValue)
                .help("The radius of the mark on the pointer")
                Toggle("Show a ripple where you click", isOn: $clickEffects)
                    .help("A ring spreads out from every click, and a disc shows while the button is held")
                LabeledContent("Ripple size") {
                    HStack {
                        Slider(value: $clickEffectSize, in: Preferences.clickEffectSizeRange, step: 5)
                        Text("\(Int(clickEffectSize)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .disabled(!clickEffects)
                .help("How far the ripple spreads")
                ColorPicker("Colour of the mark and ripples", selection: $effectColor, supportsOpacity: false)
                    .onChange(of: effectColor) { _, color in Preferences.effectColor = color }
                    .help("The colour of the pointer mark and the click ripples")
            } header: {
                Text("Cursor")
            } footer: {
                Text("Shown while annotating the screen, also while paused, so an audience can follow the pointer and see every click. Changes apply the next time annotation mode starts.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }

    private func percentSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: 0.05)
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

private struct RedactionSettings: View {
    @AppStorage(SelectionSession.redactsCapturesKey) private var redactsCaptures = false
    @AppStorage(RedactionStyle.defaultsKey) private var redactionStyle = RedactionStyle.blackout

    var body: some View {
        Form {
            Section {
                Toggle("Redact every screenshot", isOn: $redactsCaptures)
                    .help("Cover anything sensitive before a screenshot is copied, saved or edited; the capture bar's Redact button switches this too")
                Picker("Hide with", selection: $redactionStyle) {
                    ForEach(RedactionStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .help("Solid black can't be read back; pixelated or blurred text sometimes can")
            } header: {
                Text("Redaction")
            } footer: {
                Text("Covers email addresses, phone numbers, IBANs and card numbers, keys and tokens, and faces before a screenshot is copied, saved or edited. The capture bar's Redact button (R) switches this too and keeps the choice. The Redact buttons in the editor and while annotating the screen (\(OverlayShortcuts.shared.label(for: .redact))) do it on demand. Black out is the safe choice: pixelated or blurred text, digits especially, can sometimes be read back. Check the result before sharing: only text Libellule can read gets covered.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }
}

private struct ShortcutSettings: View {
    private var hotKeys: HotKeyManager { .shared }
    private var overlay: OverlayShortcuts { .shared }

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(action: action)
                    }
                    if let error = hotKeys.registrationErrors[action] {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("System-wide")
            } footer: {
                Text("They work even while Libellule is in the background. Use at least one of ⌘, ⌥ or ⌃. While annotating the screen, the capture shortcut keeps the drawing as a screenshot. Repeat retakes the area of the previous capture without asking again; the delayed capture counts down three seconds first, so a menu can be opened in time, and pressing it again during the countdown cancels it.")
                    .foregroundStyle(.secondary)
            }

            ForEach(OverlayAction.Group.allCases) { group in
                Section {
                    ForEach(group.actions) { action in
                        LabeledContent(action.title) {
                            OverlayShortcutRecorder(action: action)
                        }
                    }
                } header: {
                    if group == .tools {
                        Text("While drawing: \(group.title.lowercased())")
                    } else {
                        Text(group.title)
                    }
                } footer: {
                    if group == OverlayAction.Group.allCases.last {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("These work while the editor or the screen overlay has the keyboard. A key on its own, or with ⌘, ⌥ or ⌃; ⇧ is ignored so the digits work on every keyboard. The colours keep their letters (R O Y G B P W K), the digits 1–9 and 0 pick the shapes in toolbar order, and ⌘Z, ⌘A, ⌘C, ⌘X, ⌘V and ⌘D are fixed. Loupe, fading ink, board, hiding, live and the palette apply to the screen only.")
                            HStack {
                                Spacer()
                                Button("Reset All to Defaults") {
                                    overlay.resetAll()
                                }
                                .disabled(!overlay.hasOverrides)
                                .help("Put every drawing key back to the factory setting")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .settingsPane()
    }
}

/// Registers the app as a login item with the system, which keeps the actual list (System Settings ›
/// General › Login Items), so the toggle reads it back rather than storing a copy.
struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle("Open Libellule at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: setEnabled))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                status = SMAppService.mainApp.status  // it may have been switched off in System Settings
            }
            .help("Start Libellule in the menu bar whenever you log in; the list itself lives in System Settings › General › Login Items")
        if status == .requiresApproval {
            HStack {
                Label("Turn Libellule on under Login Items to finish", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Login Items…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
                .help("Open System Settings at the Login Items list to switch Libellule on")
            }
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Couldn't change the login item: \(error.localizedDescription)"
            Diagnostics.log("Login item \(enabled ? "register" : "unregister") failed: \(error)")
        }
        status = SMAppService.mainApp.status
    }
}

/// Click, press the new combination, done. Escape keeps the current shortcut.
struct ShortcutRecorder: View {
    let action: HotKeyAction
    @State private var isRecording = false
    @State private var monitor: Any?
    private var hotKeys: HotKeyManager { .shared }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "Type shortcut…" : hotKeys.combo(for: action).displayString)
                    .font(.body.monospaced())
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? Color.accentColor : nil)
            .help(isRecording ? "Press the new shortcut, or esc to keep the current one" : "Click to record a new shortcut")

            Button("Reset") {
                hotKeys.reset(action)
            }
            .disabled(hotKeys.combo(for: action) == action.defaultCombo)
            .help("Back to the factory shortcut, \(action.defaultCombo.displayString)")
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        hotKeys.isPaused = true  // otherwise pressing a current combo would trigger it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event)
            }
            return nil  // swallow the key press while recording
        }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
        if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty {
            stopRecording()
            return
        }
        // Shift alone would hijack ordinary typing, so insist on ⌘, ⌥ or ⌃.
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else { return }
        hotKeys.update(KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers), for: action)
        stopRecording()
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        hotKeys.isPaused = false
    }
}

/// The same for the keys that work on the canvas and the overlay: any key, modifiers optional, and a way to leave
/// an action without one. A key another action, a colour or a fixed command owns is refused and says why.
struct OverlayShortcutRecorder: View {
    let action: OverlayAction
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var problem: String?
    private var shortcuts: OverlayShortcuts { .shared }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Text(isRecording ? "Type key…" : (shortcuts.shortcut(for: action)?.displayString ?? "Not Set"))
                        .font(.body.monospaced())
                        .foregroundStyle(shortcuts.shortcut(for: action) == nil && !isRecording ? .secondary : .primary)
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? Color.accentColor : nil)
                .help(isRecording ? "Press the new key, or esc to keep the current one" : "Click to record a new key")

                Button {
                    shortcuts.clear(action)
                    problem = nil
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(shortcuts.shortcut(for: action) == nil)
                .help("Leave this without a key")

                Button("Reset") {
                    shortcuts.reset(action)
                    problem = nil
                }
                .disabled(shortcuts.isDefault(action))
                .help(action.defaultShortcut.map { "Back to the factory key, \($0.displayString)" } ?? "Back to the factory setting")
            }
            if let problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        problem = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event)
            }
            return nil  // swallow the key press while recording
        }
    }

    private func handle(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            stopRecording()
            return
        }
        guard let shortcut = LocalShortcut.from(event) else { return }
        problem = shortcuts.update(shortcut, for: action)
        stopRecording()
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }
}
#endif
