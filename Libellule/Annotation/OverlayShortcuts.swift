import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A key pressed while the editor's canvas or the live overlay has the keyboard: what the key prints plus ⌘, ⌥ and ⌃.
/// ⇧ is left out on purpose: on AZERTY keyboards the digits need it, and ⇧ with a letter is still that letter.
struct LocalShortcut: Hashable, Codable, Sendable {
    struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        let rawValue: UInt8

        static let command = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let control = Modifiers(rawValue: 4)
    }

    /// The key's character, lowercased; `LocalShortcut.deleteKey` stands for ⌫.
    var character: String
    var modifiers: Modifiers

    static let deleteKey = "\u{7F}"

    init(_ character: String, _ modifiers: Modifiers = []) {
        self.character = Self.normalized(character)
        self.modifiers = modifiers
    }

    /// What the shifted punctuation keys print is folded onto their plain form, so "+" counts as "=".
    static func normalized(_ character: String) -> String {
        switch character.lowercased() {
        case "_": "-"
        case "+": "="
        case "{": "["
        case "}": "]"
        case "\u{7F}", "\u{F728}", "\u{8}": deleteKey
        case let other: other
        }
    }

    /// "⌥⌘T", "⌫", "E": the modifiers in the order macOS menus use, then the key.
    var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + keyLabel
    }

    var keyLabel: String {
        switch character {
        case Self.deleteKey: "⌫"
        case " ": "Space"
        case "\r": "↩"
        case "\t": "⇥"
        default: character.uppercased()
        }
    }

    #if os(macOS)
    /// The shortcut a key press stands for, or nil for keys without a character (modifiers alone, arrows, esc).
    static func from(_ event: NSEvent) -> LocalShortcut? {
        guard event.type == .keyDown else { return nil }
        var modifiers = Modifiers()
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1 else { return nil }
        if let scalar = characters.unicodeScalars.first, CharacterSet.controlCharacters.contains(scalar), characters != deleteKey, characters != "\r", characters != "\t", characters != "\u{8}" {
            return nil
        }
        // Function and arrow keys land in the private-use range.
        if let scalar = characters.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value), characters != "\u{F728}" {
            return nil
        }
        return LocalShortcut(characters, modifiers)
    }
    #endif

    /// The same for SwiftUI's key presses, as the editor receives them.
    static func from(_ press: KeyPress) -> LocalShortcut? {
        var modifiers = Modifiers()
        if press.modifiers.contains(.command) { modifiers.insert(.command) }
        if press.modifiers.contains(.option) { modifiers.insert(.option) }
        if press.modifiers.contains(.control) { modifiers.insert(.control) }
        if press.key == .delete || press.key == .deleteForward {
            return LocalShortcut(deleteKey, modifiers)
        }
        // The key itself rather than what it types, so ⌥N is N and not a dead key.
        let character = String(press.key.character)
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
        if CharacterSet.controlCharacters.contains(scalar) || (0xF700...0xF8FF).contains(scalar.value) { return nil }
        return LocalShortcut(character, modifiers)
    }
}

/// Everything a single key can do on the canvas or the live overlay. The tool cases share the tools' raw values.
enum OverlayAction: String, CaseIterable, Identifiable, Codable {
    // Tools
    case select, arrow, line, rectangle, ellipse, freehand, highlighter, spotlight, text, badge, pixelate, blur, magnifier, eraser, measure
    // Size
    case thinner, thicker, sizeDown, sizeUp
    // Presenting
    case lights, loupe, fadingInk, board, hideDrawings, liveOrFrozen, togglePalette
    // Editing
    case clearAll, resetStepNumbers, redact

    var id: String { rawValue }

    init?(tool: AnnotationTool) {
        self.init(rawValue: tool.rawValue)
    }

    var tool: AnnotationTool? { AnnotationTool(rawValue: rawValue) }

    var title: String {
        if let tool { return tool.title }
        switch self {
        case .thinner: return String(localized: "Thinner (preset)")
        case .thicker: return String(localized: "Thicker (preset)")
        case .sizeDown: return String(localized: "Size down")
        case .sizeUp: return String(localized: "Size up")
        case .lights: return String(localized: "Lights")
        case .loupe: return String(localized: "Loupe")
        case .fadingInk: return String(localized: "Fading ink")
        case .board: return String(localized: "Board")
        case .hideDrawings: return String(localized: "Hide drawings")
        case .liveOrFrozen: return String(localized: "Live or frozen screen")
        case .togglePalette: return String(localized: "Show or hide the palette")
        case .clearAll: return String(localized: "Clear all")
        case .resetStepNumbers: return String(localized: "Restart step numbers at 1")
        case .redact: return String(localized: "Redact")
        default: return rawValue
        }
    }

    /// The factory keys. Colours keep their first letters, so the shapes that would clash use S, C, F and X.
    var defaultShortcut: LocalShortcut? {
        switch self {
        case .select: LocalShortcut("v")
        case .arrow: LocalShortcut("a")
        case .line: LocalShortcut("l")
        case .rectangle: LocalShortcut("s")
        case .ellipse: LocalShortcut("c")
        case .freehand: LocalShortcut("f")
        case .highlighter: LocalShortcut("m")
        case .spotlight: LocalShortcut("h")
        case .text: LocalShortcut("t")
        case .badge: LocalShortcut("n")
        case .pixelate: LocalShortcut("x")
        case .blur: LocalShortcut("u")
        case .magnifier: LocalShortcut("z")
        case .eraser: LocalShortcut("e")
        case .measure: LocalShortcut("q")
        case .thinner: LocalShortcut("-")
        case .thicker: LocalShortcut("=")
        case .sizeDown: LocalShortcut("[")
        case .sizeUp: LocalShortcut("]")
        case .lights: LocalShortcut("d")
        case .loupe: LocalShortcut("e", .command)
        case .fadingInk: LocalShortcut("i")
        case .board: LocalShortcut("b", .command)
        case .hideDrawings: LocalShortcut("h", .command)
        case .liveOrFrozen: LocalShortcut("l", .command)
        case .togglePalette: LocalShortcut("t", [.command, .option])
        case .clearAll: LocalShortcut(LocalShortcut.deleteKey, .option)
        case .resetStepNumbers: LocalShortcut("n", .option)
        case .redact: LocalShortcut("r", .command)
        }
    }

    /// Where the action makes sense: the editor has no screen to freeze, loupe to follow or palette to hide.
    var scopes: Set<OverlayScope> {
        switch self {
        case .loupe, .fadingInk, .board, .hideDrawings, .liveOrFrozen, .togglePalette: [.live]
        default: [.editor, .live]
        }
    }

    /// The groups the Settings table shows.
    enum Group: String, CaseIterable, Identifiable {
        case tools, size, presenting, editing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tools: String(localized: "Tools")
            case .size: String(localized: "Size")
            case .presenting: String(localized: "Presenting")
            case .editing: String(localized: "Editing")
            }
        }

        var actions: [OverlayAction] { OverlayAction.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .thinner, .thicker, .sizeDown, .sizeUp: .size
        case .lights, .loupe, .fadingInk, .board, .hideDrawings, .liveOrFrozen, .togglePalette: .presenting
        case .clearAll, .resetStepNumbers, .redact: .editing
        default: .tools
        }
    }
}

/// Where a key is pressed: the editor window, or the overlays while annotating the screen.
enum OverlayScope: Hashable {
    case editor, live
}

/// The keys for every `OverlayAction`, with the user's changes on top of the defaults. Kept in UserDefaults.
/// A custom key can't clash with another action, a colour letter, a digit or one of the fixed commands; a new
/// action whose default is already taken by a custom key starts out unset.
@Observable
final class OverlayShortcuts {
    static let shared = OverlayShortcuts()

    static let defaultsKey = "overlayShortcuts"

    /// The user's changes: a shortcut, or nil for "not set".
    private(set) var overrides: [OverlayAction: LocalShortcut?] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// The colour letters, which every shortcut without modifiers has to steer clear of.
    static var colorKeys: [String] { AnnotationPalette.entries.map { String($0.key) } }

    /// Keys the editor and overlay use regardless of this table, so nothing can be mapped onto them.
    static let fixedCommands: [LocalShortcut: String] = [
        LocalShortcut("z", .command): "Undo",
        LocalShortcut("a", .command): "Select All",
        LocalShortcut("c", .command): "Copy",
        LocalShortcut("x", .command): "Cut",
        LocalShortcut("v", .command): "Paste",
        LocalShortcut("d", .command): "Duplicate",
        LocalShortcut("[", .command): "Smaller text",
        LocalShortcut("]", .command): "Larger text",
        LocalShortcut("k", .command): "Crop",
        LocalShortcut("s", .command): "Save",
        LocalShortcut("0", .command): "Fit to Window",
        LocalShortcut("1", .command): "Actual Size",
        LocalShortcut("-", .command): "Zoom out",
        LocalShortcut("=", .command): "Zoom in",
        LocalShortcut("q", .command): "Quit",
        LocalShortcut("w", .command): "Close",
        LocalShortcut(LocalShortcut.deleteKey): "Delete",
    ]

    /// Keys the editor window's menus take before the canvas sees them, so actions that work in the editor
    /// can't be put on them.
    static let editorMenuCommands: [LocalShortcut: String] = [
        LocalShortcut("n", .command): "New Window",
        LocalShortcut("m", .command): "Minimize",
        LocalShortcut("h", .command): "Hide Libellule",
        LocalShortcut(",", .command): "Settings",
        LocalShortcut("t", [.command, .option]): "Show or Hide Toolbar",
    ]

    // MARK: - Lookup

    /// The key for an action: the user's, or the default unless a custom key took it.
    func shortcut(for action: OverlayAction) -> LocalShortcut? {
        if let override = overrides[action] { return override }
        guard let fallback = action.defaultShortcut else { return nil }
        let takenByCustom = overrides.contains { other, shortcut in other != action && shortcut == fallback }
        return takenByCustom ? nil : fallback
    }

    /// Which action a key press triggers in `scope`, if any.
    func action(for shortcut: LocalShortcut, in scope: OverlayScope) -> OverlayAction? {
        OverlayAction.allCases.first { $0.scopes.contains(scope) && self.shortcut(for: $0) == shortcut }
    }

    func isDefault(_ action: OverlayAction) -> Bool {
        overrides[action] == nil
    }

    var hasOverrides: Bool { !overrides.isEmpty }

    /// For tooltips: "E", or "" when unset.
    func label(for action: OverlayAction) -> String {
        shortcut(for: action)?.displayString ?? ""
    }

    /// For a tool's tooltip: "A or 1", "E", or "unassigned".
    func label(for tool: AnnotationTool) -> String {
        let key = OverlayAction(tool: tool).flatMap { shortcut(for: $0) }?.displayString
        switch (key, tool.digitKey) {
        case (let key?, let digit?): return String(localized: "\(key) or \(digit)")
        case (let key?, nil): return key
        case (nil, let digit?): return String(digit)
        case (nil, nil): return String(localized: "no key")
        }
    }

    // MARK: - Changes

    /// What stops `shortcut` being given to `action`, or nil when it's free.
    func conflict(_ shortcut: LocalShortcut, for action: OverlayAction) -> String? {
        if let fixed = Self.fixedCommands[shortcut] { return String(localized: "\(shortcut.displayString) is \(fixed)") }
        if action.scopes.contains(.editor), let menu = Self.editorMenuCommands[shortcut] { return String(localized: "\(shortcut.displayString) is \(menu) in the editor") }
        if shortcut.modifiers.isEmpty {
            if Self.colorKeys.contains(shortcut.character) { return String(localized: "\(shortcut.displayString) picks a colour") }
            if shortcut.character.count == 1, shortcut.character.first?.isNumber == true { return String(localized: "The digits pick tools") }
        }
        if let other = OverlayAction.allCases.first(where: { $0 != action && self.shortcut(for: $0) == shortcut }) {
            return String(localized: "\(shortcut.displayString) is \(other.title)")
        }
        return nil
    }

    /// Gives `action` the key, unless something else owns it; returns the reason when refused.
    @discardableResult
    func update(_ shortcut: LocalShortcut, for action: OverlayAction) -> String? {
        if let conflict = conflict(shortcut, for: action) { return conflict }
        if shortcut == action.defaultShortcut {
            overrides[action] = nil
        } else {
            overrides[action] = .some(shortcut)
        }
        save()
        return nil
    }

    func clear(_ action: OverlayAction) {
        overrides[action] = .some(nil)
        save()
    }

    func reset(_ action: OverlayAction) {
        overrides[action] = nil
        save()
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode([String: LocalShortcut?].self, from: data)
        else { return }
        overrides = stored.reduce(into: [:]) { result, item in
            if let action = OverlayAction(rawValue: item.key) { result[action] = item.value }
        }
    }

    private func save() {
        let stored = overrides.reduce(into: [String: LocalShortcut?]()) { $0[$1.key.rawValue] = $1.value }
        if stored.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
