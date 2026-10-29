import SwiftUI

/// The settings around drawing, presenting and the live palette, with typed accessors for the code that runs
/// outside SwiftUI views (`@AppStorage` reads the same keys in Settings).
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    // MARK: - Annotate

    /// Which tool a session starts with: "" (or nothing stored) means the one used last time.
    static let liveStartToolKey = "annotateStartTool"
    static let editorStartToolKey = "editorStartTool"

    static func startTool(for context: AnnotationToolbox.Context) -> AnnotationTool? {
        let key = context == .live ? liveStartToolKey : editorStartToolKey
        return defaults.string(forKey: key).flatMap(AnnotationTool.init(rawValue:))
    }

    static let badgeStyleKey = "stepNumberStyle"

    static var badgeStyle: BadgeStyle {
        defaults.string(forKey: badgeStyleKey).flatMap(BadgeStyle.init(rawValue:)) ?? .filled
    }

    /// Seconds fading ink stays before it goes.
    static let fadeDelayKey = "fadeDelay"
    static let fadeDelayRange: ClosedRange<Double> = 0.25...5

    static var fadeDelay: Double {
        let stored = defaults.double(forKey: fadeDelayKey)
        return stored > 0 ? min(max(stored, fadeDelayRange.lowerBound), fadeDelayRange.upperBound) : 2
    }

    /// Leave annotation mode and come back to the same drawing, instead of starting afresh.
    static let keepsDrawingsKey = "annotateKeepsDrawings"

    static var keepsDrawings: Bool { defaults.bool(forKey: keepsDrawingsKey) }

    static let paletteLayoutKey = "paletteLayout"

    static var paletteLayout: PaletteLayout {
        defaults.string(forKey: paletteLayoutKey).flatMap(PaletteLayout.init(rawValue:)) ?? .horizontal
    }

    // MARK: - Board

    static let boardStyleKey = "boardStyle"
    static let boardOpacityKey = "boardOpacity"
    static let boardOpacityRange: ClosedRange<Double> = 0.1...1

    static var boardStyle: BoardStyle {
        defaults.string(forKey: boardStyleKey).flatMap(BoardStyle.init(rawValue:)) ?? .automatic
    }

    static var boardOpacity: Double {
        let stored = defaults.double(forKey: boardOpacityKey)
        return stored > 0 ? min(max(stored, boardOpacityRange.lowerBound), boardOpacityRange.upperBound) : 1
    }

    // MARK: - Cursor

    static let cursorStyleKey = "cursorStyle"
    static let cursorSizeKey = "cursorSize"
    static let cursorSizeRange: ClosedRange<Double> = 8...24
    static let spotlightRadiusKey = "spotlightRadius"
    static let spotlightRadiusRange: ClosedRange<Double> = 60...300
    static let dimAmountKey = "dimAmount"
    static let dimAmountRange: ClosedRange<Double> = 0.2...0.9
    static let clickEffectsKey = "clickEffects"
    static let clickEffectSizeKey = "clickEffectSize"
    static let clickEffectSizeRange: ClosedRange<Double> = 30...100
    static let effectColorKey = "effectColor"

    static var cursorStyle: CursorStyle {
        defaults.string(forKey: cursorStyleKey).flatMap(CursorStyle.init(rawValue:)) ?? .none
    }

    static var cursorSize: Double { number(cursorSizeKey, in: cursorSizeRange, default: 14) }

    /// The radius of the bright circle that follows the pointer while the lights are dimmed.
    static var spotlightRadius: Double { number(spotlightRadiusKey, in: spotlightRadiusRange, default: 120) }

    /// How dark "dim lights" makes everything outside the highlights.
    static var dimAmount: Double { number(dimAmountKey, in: dimAmountRange, default: 0.65) }

    static var clickEffects: Bool { defaults.bool(forKey: clickEffectsKey) }

    static var clickEffectSize: Double { number(clickEffectSizeKey, in: clickEffectSizeRange, default: 50) }

    static var effectColor: Color {
        get { color(forKey: effectColorKey) ?? Color(red: 1, green: 0.8, blue: 0) }
        set { setColor(newValue, forKey: effectColorKey) }
    }

    // MARK: - General

    static let showsDockIconKey = "showsDockIcon"
    static let playsSoundsKey = "playsSounds"

    static var showsDockIcon: Bool { defaults.bool(forKey: showsDockIconKey) }
    static var playsSounds: Bool { defaults.bool(forKey: playsSoundsKey) }

    // MARK: - Helpers

    private static func number(_ key: String, in range: ClosedRange<Double>, default fallback: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return min(max(defaults.double(forKey: key), range.lowerBound), range.upperBound)
    }

    /// Colours are stored as their red, green and blue, so they survive without an archiver.
    static func color(forKey key: String) -> Color? {
        guard let parts = defaults.array(forKey: key) as? [Double], parts.count == 3 else { return nil }
        return Color(red: parts[0], green: parts[1], blue: parts[2])
    }

    static func setColor(_ color: Color, forKey key: String) {
        let resolved = color.resolve(in: EnvironmentValues())
        defaults.set([Double(resolved.red), Double(resolved.green), Double(resolved.blue)], forKey: key)
    }
}

/// Where the live palette sits: a strip along the top, or a column down the left or right edge.
enum PaletteLayout: String, CaseIterable, Identifiable {
    case horizontal, left, right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .horizontal: String(localized: "Across the top")
        case .left: String(localized: "Down the left edge")
        case .right: String(localized: "Down the right edge")
        }
    }

    var axis: Axis { self == .horizontal ? .horizontal : .vertical }
}

/// Whiteboard, blackboard, or whichever matches the system appearance.
enum BoardStyle: String, CaseIterable, Identifiable {
    case automatic, white, black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "Match the appearance")
        case .white: String(localized: "Whiteboard")
        case .black: String(localized: "Blackboard")
        }
    }
}

/// A mark drawn on the pointer while presenting.
enum CursorStyle: String, CaseIterable, Identifiable {
    case none, outline, circle, crosshair

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .outline: String(localized: "Outline")
        case .circle: String(localized: "Circle")
        case .crosshair: String(localized: "Crosshair")
        }
    }
}
