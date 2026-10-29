import SwiftUI

/// Tool settings shared by every surface the user draws on (an editor window, or all live-screen overlays).
/// With a `context` the tool, colour and width are remembered between sessions, and the session can start with a
/// fixed tool instead of the last one (a setting).
@Observable
final class AnnotationToolbox {
    enum Context: String {
        case editor, live

        /// What a fresh install starts with: the pen on the screen, an arrow on a screenshot.
        var fallbackTool: AnnotationTool { self == .live ? .freehand : .arrow }
    }

    let context: Context?

    var tool: AnnotationTool {
        didSet { remember() }
    }

    var color: Color {
        didSet { remember() }
    }

    /// The line width in surface points, anywhere from hairline to heavy; the three presets are stops on the way.
    /// (A plain `didSet` can't clamp here: under `@Observable` assigning the property from its own observer
    /// re-enters the setter without end.)
    var lineWidth: CGFloat {
        get { storedLineWidth }
        set {
            storedLineWidth = Self.clamped(newValue)
            remember()
        }
    }

    private var storedLineWidth: CGFloat

    static let widthRange: ClosedRange<CGFloat> = 1...24

    /// The preset closest to the width, for the picker; picking a preset sets the width to it.
    var strokeWidth: StrokeWidth {
        get { StrokeWidth.nearest(to: lineWidth) }
        set { lineWidth = newValue.rawValue }
    }

    var resolvedColor: Color.Resolved { color.resolve(in: EnvironmentValues()) }

    init(context: Context? = nil) {
        self.context = context
        tool = context?.fallbackTool ?? .arrow
        color = AnnotationPalette.colors[0]
        storedLineWidth = StrokeWidth.medium.rawValue
        if let context {
            restore(context)
        }
    }

    // MARK: - Shortcuts

    /// Carries out an action that changes the toolbox: picking a tool, or stepping the size. Returns false for
    /// anything else, which the caller handles.
    @discardableResult
    func perform(_ action: OverlayAction) -> Bool {
        if let tool = action.tool {
            self.tool = tool
            return true
        }
        switch action {
        case .thinner: strokeWidth = strokeWidth.thinner
        case .thicker: strokeWidth = strokeWidth.thicker
        case .sizeDown: adjustWidth(by: -1)
        case .sizeUp: adjustWidth(by: 1)
        default: return false
        }
        return true
    }

    /// A colour letter, when the press is one.
    @discardableResult
    func applyColor(_ shortcut: LocalShortcut) -> Bool {
        guard shortcut.modifiers.isEmpty, let color = AnnotationPalette.color(forKey: shortcut.character) else { return false }
        self.color = color
        return true
    }

    func adjustWidth(by delta: CGFloat) {
        lineWidth = Self.clamped(lineWidth + delta)
    }

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    // MARK: - Memory

    private var keyPrefix: String? { context.map { "toolbox.\($0.rawValue)." } }

    private func remember() {
        guard let keyPrefix else { return }
        let defaults = UserDefaults.standard
        defaults.set(tool.rawValue, forKey: keyPrefix + "tool")
        defaults.set(Double(lineWidth), forKey: keyPrefix + "lineWidth")
        Preferences.setColor(color, forKey: keyPrefix + "color")
    }

    private func restore(_ context: Context) {
        let prefix = "toolbox.\(context.rawValue)."
        let defaults = UserDefaults.standard
        if let fixed = Preferences.startTool(for: context) {
            tool = fixed
        } else if let remembered = defaults.string(forKey: prefix + "tool").flatMap(AnnotationTool.init(rawValue:)) {
            tool = remembered
        }
        if defaults.object(forKey: prefix + "lineWidth") != nil {
            lineWidth = Self.clamped(CGFloat(defaults.double(forKey: prefix + "lineWidth")))
        }
        if let stored = Preferences.color(forKey: prefix + "color") {
            color = AnnotationPalette.preset(matching: stored) ?? stored
        }
    }
}
