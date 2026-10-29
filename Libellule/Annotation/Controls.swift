import SwiftUI

/// Sizes shared by the editor toolbar, the capture bar and the live palette, so the three read as one set:
/// every button, segment and swatch is a capsule of the same height, and the floating bars are capsules around them.
enum BarMetrics {
    /// The height of every control on a bar, and the width of one holding a lone symbol.
    static let itemHeight: CGFloat = 28
    /// The same in the editor's compact bottom bar.
    static let smallItemHeight: CGFloat = 22
    /// The gap between the segments of a choice and the track around them.
    static let trackInset: CGFloat = 2
}

extension View {
    /// Sets a few related controls on one faint capsule, as one control: the options of a choice, or zoom
    /// out, level and in.
    func barTrack() -> some View {
        padding(BarMetrics.trackInset)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    /// A tooltip. In a window it's the system's own; on the floating bars over the overlays it's drawn in a panel
    /// of its own, since the system's tooltips sit below the overlays and would show through them behind the bar.
    /// Takes a `Text` rather than a key because the compiler only gathers literals for the string catalog from
    /// `Text` and a few other known initializers, not from a modifier of our own.
    func barHelp(_ text: Text) -> some View {
        modifier(BarHelp(text: text))
    }

    /// The same for text that is already localized.
    func barHelp(verbatim text: String) -> some View {
        modifier(BarHelp(text: Text(verbatim: text)))
    }
}

extension EnvironmentValues {
    /// Set on the floating bars, whose tooltips can't be the system's (see `View.barHelp`).
    @Entry var floatingTooltips = false
}

private struct BarHelp: ViewModifier {
    let text: Text
    @Environment(\.floatingTooltips) private var floating

    func body(content: Content) -> some View {
        #if os(macOS)
        if floating {
            content.modifier(FloatingTooltip(text: text))
        } else {
            content.help(text)
        }
        #else
        content.help(text)
        #endif
    }
}

#if os(macOS)
/// Shows `text` in `FloatingTooltipPanel` after the pointer has rested on the control for a moment, as the
/// system does, and takes it away when the pointer leaves.
private struct FloatingTooltip: ViewModifier {
    let text: Text
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.onHover { inside in
            pending?.cancel()
            pending = nil
            if inside {
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    FloatingTooltipPanel.show(text)
                }
            } else {
                FloatingTooltipPanel.hide()
            }
        }
    }
}
#endif

/// The button look shared by the three toolbars: a capsule that lights up faintly under the pointer and darker
/// while pressed, filled with the accent colour when it is the chosen option, a toggle that is on, or the bar's
/// main action, and faded while disabled.
struct BarButtonStyle: ButtonStyle {
    enum Fill {
        /// Nothing until the pointer is over it: an ordinary button.
        case none
        /// The faint track, so a toggle that is off still reads as something that can be switched on.
        case track
        /// The accent colour with a white label.
        case accent
    }

    var fill: Fill = .none
    /// A title next to the symbol needs more room either side than a lone symbol.
    var isTitled = false

    func makeBody(configuration: Configuration) -> some View {
        BarButtonLabel(configuration: configuration, fill: fill, isTitled: isTitled)
    }
}

private struct BarButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let fill: BarButtonStyle.Fill
    let isTitled: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        let height = controlSize == .small || controlSize == .mini ? BarMetrics.smallItemHeight : BarMetrics.itemHeight
        configuration.label
            .lineLimit(1)
            .padding(.horizontal, isTitled ? 10 : 5)
            .frame(minWidth: height, minHeight: height)
            .foregroundStyle(fill == .accent ? Color.white : Color.primary)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.12), value: fill == .accent)
    }

    private var background: Color {
        let wash = configuration.isPressed ? 0.16 : (isHovered && isEnabled ? 0.09 : 0)
        switch fill {
        case .accent:
            return Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1)
        case .track:
            return Color.primary.opacity(max(0.07, wash + 0.04))
        case .none:
            return Color.primary.opacity(wash)
        }
    }
}

extension ButtonStyle where Self == BarButtonStyle {
    /// A momentary button on a bar: undo, clear, cancel.
    static var bar: BarButtonStyle { BarButtonStyle() }

    /// The bar's main action, such as Capture.
    static var barProminent: BarButtonStyle { BarButtonStyle(fill: .accent, isTitled: true) }
}

/// A toggle drawn as a bar button that is plainly on or off: filled with the accent colour and a white label when
/// on, a quiet track when off. Both states take the same room, so a toolbar never shifts when one is switched.
struct ActiveToggleStyle: ToggleStyle {
    /// For toggles that show their title next to the symbol.
    var isTitled = false

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(BarButtonStyle(fill: configuration.isOn ? .accent : .track, isTitled: isTitled))
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

extension ToggleStyle where Self == ActiveToggleStyle {
    static var active: ActiveToggleStyle { ActiveToggleStyle() }

    static func active(titled: Bool) -> ActiveToggleStyle { ActiveToggleStyle(isTitled: titled) }
}

/// A hairline between groups of controls on a bar: upright on a strip, flat on a column.
struct BarSeparator: View {
    var axis: Axis = .horizontal

    var body: some View {
        Capsule()
            .fill(.separator)
            .frame(width: axis == .horizontal ? 1 : 18, height: axis == .horizontal ? 18 : 1)
            .padding(axis == .horizontal ? .horizontal : .vertical, 3)
    }
}

/// A row or a column of controls, depending on which way the bar runs.
struct BarStack<Content: View>: View {
    var axis: Axis
    var spacing: CGFloat = 2
    @ViewBuilder let content: () -> Content

    var body: some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))
        layout { content() }
    }
}

/// One group of like controls: a row on a strip; on a column, a grid a couple of controls wide, so a tall palette
/// still fits on a laptop screen.
struct BarGroup<Content: View>: View {
    var axis: Axis
    var columns = 2
    var spacing: CGFloat = 2
    let count: Int
    @ViewBuilder let content: (Int) -> Content

    var body: some View {
        if axis == .horizontal {
            HStack(spacing: spacing) {
                ForEach(0..<count, id: \.self) { content($0) }
            }
        } else {
            Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                ForEach(Array(stride(from: 0, to: count, by: columns)), id: \.self) { start in
                    GridRow {
                        ForEach(start..<min(start + columns, count), id: \.self) { content($0) }
                    }
                }
            }
        }
    }
}

/// Picks one of a few options; the chosen one is filled with the accent colour, like an `ActiveToggleStyle`
/// toggle that is on. Easier to read than a segmented control on the translucent capture bar and palette, and
/// unlike one, every option shows its own tooltip. Options can be split into groups with a hairline between.
struct ChoiceBar<Value: Hashable, Content: View>: View {
    @Binding var selection: Value
    let groups: [[Value]]
    var isTitled = false
    var axis: Axis = .horizontal
    /// How many options sit side by side on a column.
    var columns = 2
    @ViewBuilder let label: (Value) -> Content
    /// The tooltip for each option, which names its shortcut.
    let help: (Value) -> String

    init(selection: Binding<Value>, options: [Value], isTitled: Bool = false, axis: Axis = .horizontal, columns: Int = 2, @ViewBuilder label: @escaping (Value) -> Content, help: @escaping (Value) -> String) {
        self.init(selection: selection, groups: [options], isTitled: isTitled, axis: axis, columns: columns, label: label, help: help)
    }

    init(selection: Binding<Value>, groups: [[Value]], isTitled: Bool = false, axis: Axis = .horizontal, columns: Int = 2, @ViewBuilder label: @escaping (Value) -> Content, help: @escaping (Value) -> String) {
        _selection = selection
        self.groups = groups
        self.isTitled = isTitled
        self.axis = axis
        self.columns = columns
        self.label = label
        self.help = help
    }

    var body: some View {
        BarStack(axis: axis) {
            ForEach(groups.indices, id: \.self) { index in
                if index > 0 {
                    BarSeparator(axis: axis)
                }
                BarGroup(axis: axis, columns: columns, count: groups[index].count) { position in
                    let option = groups[index][position]
                    let isChosen = option == selection
                    Button {
                        selection = option
                    } label: {
                        label(option)
                    }
                    .buttonStyle(BarButtonStyle(fill: isChosen ? .accent : .none, isTitled: isTitled))
                    .barHelp(verbatim: help(option))
                    .accessibilityAddTraits(isChosen ? .isSelected : [])
                }
            }
        }
        .barTrack()
    }
}

/// The drawing tools, grouped: selecting and erasing, shapes, pens, callouts, and hiding, enlarging or measuring
/// what's underneath. Each tooltip names the tool's key and digit.
struct ToolPicker: View {
    @Binding var selection: AnnotationTool
    var axis: Axis = .horizontal

    static let groups: [[AnnotationTool]] = [
        [.select, .eraser],
        [.arrow, .line, .rectangle, .ellipse],
        [.freehand, .highlighter],
        [.spotlight, .text, .badge],
        [.pixelate, .blur, .magnifier, .measure],
    ]

    var body: some View {
        ChoiceBar(selection: $selection, groups: Self.groups, axis: axis) { tool in
            Image(systemName: tool.systemImage)
                .frame(width: 18)
                .accessibilityLabel(tool.title)
        } help: { tool in
            "\(tool.title) (\(tool.shortcutLabel))"
        }
    }
}

/// Thin, medium or thick, each drawn as a stroke of that weight so the choice shows at a glance, and the width
/// itself as a number, which opens a slider for anything in between.
struct StrokeWidthPicker: View {
    @Bindable var toolbox: AnnotationToolbox
    var axis: Axis = .horizontal
    /// What the size changes besides the line width, for the tooltip.
    var alsoSets = "text size, badge size and blur strength"
    @State private var showsSlider = false

    var body: some View {
        BarStack(axis: axis, spacing: 2) {
            ChoiceBar(selection: $toolbox.strokeWidth, options: StrokeWidth.allCases, axis: axis) { width in
                Capsule()
                    .frame(width: 14, height: min(width.rawValue, 6))
                    .frame(width: 18, height: 18)
                    .accessibilityLabel(width.title)
            } help: { width in
                "\(width.title): line width, \(alsoSets) (− thinner, + thicker)"
            }

            Button {
                showsSlider.toggle()
            } label: {
                Text(Self.format(toolbox.lineWidth))
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 22)
            }
            .buttonStyle(.bar)
            .barHelp(Text("Line width in points: click for a slider ([ and ] step by 1, ⌘-scroll too)"))
            .popover(isPresented: $showsSlider, arrowEdge: axis == .horizontal ? .bottom : .trailing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Line width: \(Self.format(toolbox.lineWidth)) pt")
                        .font(.callout.monospacedDigit())
                    Slider(value: $toolbox.lineWidth, in: AnnotationToolbox.widthRange, step: 0.5) {
                        Text("Line width")
                    } minimumValueLabel: {
                        Text("1")
                    } maximumValueLabel: {
                        Text("24")
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .barHelp(Text("Any width from 1 to 24 points; the presets are 2, 4 and 8"))
                }
                .padding(14)
            }
        }
    }

    static func format(_ width: CGFloat) -> String {
        width.rounded() == width ? String(Int(width)) : String(format: "%.1f", Double(width))
    }
}

/// Preset swatches plus a system color picker for anything else.
struct ColorPalette: View {
    @Binding var selection: Color
    var axis: Axis = .horizontal

    var body: some View {
        BarStack(axis: axis, spacing: 0) {
            BarGroup(axis: axis, columns: 3, spacing: 0, count: AnnotationPalette.entries.count) { index in
                let entry = AnnotationPalette.entries[index]
                ColorSwatch(color: entry.color, isSelected: selection == entry.color) {
                    selection = entry.color
                }
                .barHelp(Text("\(entry.name) (\(String(entry.key).uppercased()))"))
                .accessibilityLabel(entry.name)
            }
            // Small, so the well reads as one more swatch rather than outweighing the presets.
            ColorPicker("Custom Color", selection: $selection, supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .padding(axis == .horizontal ? .leading : .top, 4)
                .barHelp(Text("Custom color"))
        }
    }
}

/// One preset colour. The chosen one gets a ring in the text colour with a gap around the swatch, which stands
/// out against every swatch, blue and white included; the others grow a little under the pointer.
private struct ColorSwatch: View {
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                .frame(width: 16, height: 16)
                .scaleEffect(isHovered && !isSelected ? 1.15 : 1)
                .padding(4)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(.primary, lineWidth: 2)
                    }
                }
                .frame(width: 26, height: BarMetrics.itemHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
