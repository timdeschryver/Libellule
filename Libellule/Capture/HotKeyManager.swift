#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Observation
import os

/// The things a global shortcut can trigger.
enum HotKeyAction: UInt32, CaseIterable, Identifiable {
    case captureArea = 1
    case annotateScreen = 2
    case copyText = 3
    case repeatArea = 4
    case captureDelayed = 5

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .captureArea: String(localized: "Capture area")
        case .annotateScreen: String(localized: "Annotate screen")
        case .copyText: String(localized: "Copy text")
        case .repeatArea: String(localized: "Repeat last area")
        case .captureDelayed: String(localized: "Capture after 3 seconds")
        }
    }

    /// ⇧⌘7, ⇧⌘8 and ⇧⌘9: free on a stock macOS install (the system uses ⇧⌘3–6 for its own screenshots).
    /// Repeat is the capture shortcut plus ⌥, the delayed capture the same plus ⌃.
    var defaultCombo: KeyCombo {
        switch self {
        case .captureArea: KeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: [.command, .shift])
        case .annotateScreen: KeyCombo(keyCode: UInt32(kVK_ANSI_8), modifiers: [.command, .shift])
        case .copyText: KeyCombo(keyCode: UInt32(kVK_ANSI_9), modifiers: [.command, .shift])
        case .repeatArea: KeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: [.command, .shift, .option])
        case .captureDelayed: KeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: [.command, .shift, .control])
        }
    }

    fileprivate var defaultsKey: String { "hotKey.\(rawValue)" }
}

/// Registers the system-wide shortcuts through Carbon's hot-key API, which works from a
/// sandboxed app and needs no Accessibility or Input Monitoring permission.
@Observable
final class HotKeyManager {
    static let shared = HotKeyManager()

    private(set) var combos: [HotKeyAction: KeyCombo] = [:]
    /// Set when the system refuses a combo (usually because another app, or our other action, owns it).
    private(set) var registrationErrors: [HotKeyAction: String] = [:]
    /// Suspends every shortcut, e.g. while the settings window records a new one.
    var isPaused = false {
        didSet { registerAll() }
    }
    var onPress: ((HotKeyAction) -> Void)?

    private var hotKeyRefs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4C42_4C4C  // "LBLL"

    private init() {
        for action in HotKeyAction.allCases {
            combos[action] = Self.loadCombo(for: action)
        }
    }

    func combo(for action: HotKeyAction) -> KeyCombo {
        combos[action] ?? action.defaultCombo
    }

    func start() {
        installHandler()
        registerAll()
    }

    func update(_ combo: KeyCombo, for action: HotKeyAction) {
        combos[action] = combo
        save(combo, for: action)
        registerAll()  // the other action may have been blocked by this combo before
    }

    func reset(_ action: HotKeyAction) {
        update(action.defaultCombo, for: action)
    }

    // MARK: - Carbon plumbing

    private func registerAll() {
        for action in HotKeyAction.allCases {
            register(action)
        }
    }

    private func register(_ action: HotKeyAction) {
        unregister(action)
        guard !isPaused else { return }
        let combo = combo(for: action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr {
            hotKeyRefs[action] = ref
            registrationErrors[action] = nil
            Diagnostics.log("Registered \(combo.displayString) for \(action.title)")
        } else {
            registrationErrors[action] = "\(combo.displayString) couldn't be registered (error \(status)). It may be in use by another app."
            Diagnostics.log("RegisterEventHotKey for \(action.title) failed with status \(status)")
        }
    }

    private func unregister(_ action: HotKeyAction) {
        if let ref = hotKeyRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), hotKeyEventHandler, 1, &spec, nil, &handlerRef)
    }

    fileprivate func handle(_ event: EventRef) {
        var id = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &id
        )
        guard status == noErr, id.signature == Self.signature, let action = HotKeyAction(rawValue: id.id) else { return }
        onPress?(action)
    }

    // MARK: - Persistence

    private static func loadCombo(for action: HotKeyAction) -> KeyCombo {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey),
              let combo = try? JSONDecoder().decode(KeyCombo.self, from: data)
        else { return action.defaultCombo }
        return combo
    }

    private func save(_ combo: KeyCombo, for action: HotKeyAction) {
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        }
    }
}

/// Carbon calls this on the main thread for every registered hot key press.
private nonisolated func hotKeyEventHandler(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    MainActor.assumeIsolated {
        HotKeyManager.shared.handle(event)
    }
    return noErr
}
#endif
