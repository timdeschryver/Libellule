import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText

/// The drawing tools offered by the annotation editor and the live overlay.
enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, eraser, arrow, line, rectangle, ellipse, freehand, highlighter, spotlight, text, badge, pixelate, blur, magnifier, measure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: String(localized: "Select")
        case .eraser: String(localized: "Eraser")
        case .arrow: String(localized: "Arrow")
        case .line: String(localized: "Line")
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Ellipse")
        case .freehand: String(localized: "Pen")
        case .highlighter: String(localized: "Marker")
        case .spotlight: String(localized: "Highlight")
        case .text: String(localized: "Text")
        case .badge: String(localized: "Step Number")
        case .pixelate: String(localized: "Pixelate")
        case .blur: String(localized: "Blur")
        case .magnifier: String(localized: "Magnifier")
        case .measure: String(localized: "Measure")
        }
    }

    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .eraser: "eraser"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .freehand: "scribble"
        case .highlighter: "highlighter"
        case .spotlight: "rectangle.center.inset.filled"
        case .text: "textformat"
        case .badge: "1.circle"
        case .pixelate: "checkerboard.rectangle"
        case .blur: "aqi.medium"
        case .magnifier: "loupe"
        case .measure: "ruler"
        }
    }

    /// The shapes answer to 1…9 and 0 as well as their letters (see `OverlayShortcuts`), in this order, which is
    /// fixed so the digits don't shift when a tool is added.
    static let digitOrder: [AnnotationTool] = [.arrow, .line, .rectangle, .ellipse, .freehand, .highlighter, .spotlight, .text, .badge, .pixelate]

    var digitKey: Character? {
        guard let index = Self.digitOrder.firstIndex(of: self), index < 10 else { return nil }
        return index == 9 ? "0" : Character(String(index + 1))
    }

    /// For tooltips: "A or 1", with whatever key the user gave the tool.
    var shortcutLabel: String { OverlayShortcuts.shared.label(for: self) }

    /// The tool for a digit key, 1…9 and 0.
    static func forDigit(_ character: String) -> AnnotationTool? {
        digitOrder.first { $0.digitKey.map(String.init) == character }
    }

    /// Pixelate, blur and the magnifier draw from the picture underneath. On the live screen that's a fresh
    /// snapshot of what's behind the overlays, taken when one of these tools is picked or used.
    var needsBackdrop: Bool { self == .pixelate || self == .blur || self == .magnifier }
}

/// Stroke width presets, in surface points (so they look the same at every zoom level). The width itself is
/// continuous (see `AnnotationToolbox.lineWidth`); these are the three stops the picker and − + offer.
enum StrokeWidth: CGFloat, CaseIterable, Identifiable {
    case thin = 2
    case medium = 4
    case thick = 8

    var id: CGFloat { rawValue }

    var title: String {
        switch self {
        case .thin: String(localized: "Thin")
        case .medium: String(localized: "Medium")
        case .thick: String(localized: "Thick")
        }
    }

    var thinner: StrokeWidth { Self.allCases[max(0, (Self.allCases.firstIndex(of: self) ?? 0) - 1)] }
    var thicker: StrokeWidth { Self.allCases[min(Self.allCases.count - 1, (Self.allCases.firstIndex(of: self) ?? 0) + 1)] }

    /// The preset closest to a width, for showing which one is in use.
    static func nearest(to width: CGFloat) -> StrokeWidth {
        allCases.min { abs($0.rawValue - width) < abs($1.rawValue - width) } ?? .medium
    }
}

/// How a step number is drawn: a solid disc with the number cut out of it, or a ring with the number inside.
enum BadgeStyle: String, CaseIterable, Identifiable, Sendable {
    case filled, bordered

    var id: String { rawValue }

    var title: String {
        switch self {
        case .filled: String(localized: "Filled")
        case .bordered: String(localized: "Bordered")
        }
    }
}

/// How a text annotation is set beyond its colour: a size of its own, a fixed width to wrap at, a background pill.
nonisolated struct TextStyle: Equatable, Sendable {
    /// In points; nil follows the line width like everything else does.
    var fontSize: CGFloat?
    /// In points; nil lets the label grow with its longest line.
    var width: CGFloat?
    /// A rounded pill behind the text, in white or black, whichever shows the colour better.
    var hasBackground = false

    /// How far the pill reaches past the text.
    static func padding(fontSize: CGFloat) -> CGSize {
        CGSize(width: max(5, fontSize * 0.35), height: max(2, fontSize * 0.15))
    }
}

/// A whiteboard or blackboard laid over the screen (or the picture) under the drawing.
nonisolated struct Board: Equatable, Sendable {
    var isDark: Bool
    /// 0.1…1; less lets the screen show through.
    var opacity: Double

    var cgColor: CGColor { CGColor(gray: isDark ? 0 : 1, alpha: opacity) }
}

/// The preset colors shown in the toolbars. Each has a letter shortcut: its first letter,
/// K for black as in CMYK.
enum AnnotationPalette {
    struct Entry {
        let name: String
        let key: Character
        let color: Color
    }

    static let entries: [Entry] = [
        Entry(name: "Red", key: "r", color: Color(red: 1.00, green: 0.23, blue: 0.19)),
        Entry(name: "Orange", key: "o", color: Color(red: 1.00, green: 0.58, blue: 0.00)),
        Entry(name: "Yellow", key: "y", color: Color(red: 1.00, green: 0.80, blue: 0.00)),
        Entry(name: "Green", key: "g", color: Color(red: 0.20, green: 0.78, blue: 0.35)),
        Entry(name: "Blue", key: "b", color: Color(red: 0.00, green: 0.48, blue: 1.00)),
        Entry(name: "Purple", key: "p", color: Color(red: 0.69, green: 0.32, blue: 0.87)),
        Entry(name: "White", key: "w", color: .white),
        Entry(name: "Black", key: "k", color: .black),
    ]

    static let colors: [Color] = entries.map(\.color)

    /// The color for a typed letter.
    static func color(forKey character: String) -> Color? {
        entries.first { String($0.key) == character }?.color
    }

    /// The preset a stored colour came from, so the swatch lights up again after a restart.
    static func preset(matching color: Color) -> Color? {
        let wanted = color.resolve(in: EnvironmentValues())
        return entries.map(\.color).first { candidate in
            let resolved = candidate.resolve(in: EnvironmentValues())
            return abs(resolved.red - wanted.red) < 0.01 && abs(resolved.green - wanted.green) < 0.01 && abs(resolved.blue - wanted.blue) < 0.01
        }
    }
}

/// One drawn element. All coordinates are in the surface's point space, origin at the top-left,
/// which is what both the SwiftUI canvas and the export renderer use.
struct Annotation: Identifiable, Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        case line(from: CGPoint, to: CGPoint)
        case arrow(from: CGPoint, to: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case freehand([CGPoint])
        /// A translucent marker stroke.
        case highlight([CGPoint])
        /// Keeps this area bright while everything around it is dimmed.
        case spotlight(CGRect)
        /// Text whose top-left corner sits at `origin`; it may run to several lines (see `Annotation.text`).
        case text(String, origin: CGPoint)
        /// A numbered circle for step-by-step callouts.
        case badge(Int, center: CGPoint)
        /// Covers whatever is underneath with solid black, which nothing can read back.
        case blackout(CGRect)
        /// Hides whatever is underneath with coarse blocks.
        case pixelate(CGRect)
        /// Softens whatever is underneath into an unreadable haze.
        case blur(CGRect)
        /// A round lens at `lens` showing the picture around `source` enlarged.
        case magnifier(source: CGPoint, lens: CGPoint)
        /// A dimension line between two points, labelled with the distance.
        case measure(from: CGPoint, to: CGPoint)
    }

    var id = UUID()
    var shape: Shape
    var color: Color.Resolved
    var lineWidth: CGFloat
    /// Only text uses it: its own size, a fixed width, a background pill.
    var text = TextStyle()
    /// Only step numbers use it.
    var badgeStyle = BadgeStyle.filled

    /// Derived sizes so one width setting drives every tool: thin / medium / thick (text can have a size of its own).
    var fontSize: CGFloat { text.fontSize ?? Self.fontSize(lineWidth: lineWidth) }  // 13 / 20 / 34 pt
    var badgeRadius: CGFloat { lineWidth * 2.5 + 7 }     // 12 / 17 / 27 pt
    var highlightWidth: CGFloat { lineWidth * 3 + 6 }    // 12 / 18 / 30 pt
    var magnifierSourceRadius: CGFloat { lineWidth * 6 + 18 }  // 30 / 42 / 66 pt
    var magnifierLensRadius: CGFloat { magnifierSourceRadius * Self.magnifierZoom }
    var blurRadius: CGFloat { lineWidth * 1.5 }          // 3 / 6 / 12 pt
    /// How much larger the lens shows its source.
    static let magnifierZoom: CGFloat = 2

    /// Also used for text still being typed, before it is an annotation.
    static func fontSize(lineWidth: CGFloat) -> CGFloat { lineWidth * 3.5 + 6 }

    /// Shapes only a couple of points large are accidental clicks, not drawings.
    var isMeaningful: Bool {
        switch shape {
        case .line(let a, let b), .arrow(let a, let b), .measure(let a, let b):
            return hypot(b.x - a.x, b.y - a.y) >= 3
        case .rectangle(let rect), .ellipse(let rect), .blackout(let rect), .pixelate(let rect), .spotlight(let rect), .blur(let rect):
            return rect.width >= 3 || rect.height >= 3
        case .freehand(let points), .highlight(let points):
            return !points.isEmpty
        case .text(let string, _):
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .badge, .magnifier:
            return true  // a single click places one
        }
    }

    /// The outline that gets stroked; empty for text, badges and hidden areas.
    var strokePath: Path {
        switch shape {
        case .line(let a, let b):
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            return path
        case .measure:
            return measureGeometry?.path ?? Path()
        case .arrow(let a, let b):
            return Self.arrowGeometry(from: a, to: b, lineWidth: lineWidth).shaft
        case .rectangle(let rect):
            return Path(rect)
        case .ellipse(let rect):
            return Path(ellipseIn: rect)
        case .freehand(let points), .highlight(let points):
            return Self.smoothedPath(through: points)
        case .text, .badge, .blackout, .pixelate, .spotlight, .blur, .magnifier:
            return Path()
        }
    }

    /// The solid part of the shape (an arrowhead), if it has one.
    var fillPath: Path? {
        guard case .arrow(let a, let b) = shape else { return nil }
        return Self.arrowGeometry(from: a, to: b, lineWidth: lineWidth).head
    }

    /// Where the annotation sits on the surface; drives selection outlines and hit testing.
    var bounds: CGRect {
        switch shape {
        case .text:
            return textBox ?? .zero
        case .badge(_, let center):
            return CGRect(center: center, radius: badgeRadius)
        case .measure:
            guard let geometry = measureGeometry else { return .zero }
            return geometry.path.boundingRect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2).union(geometry.labelRect)
        case .blackout(let rect), .pixelate(let rect), .spotlight(let rect), .blur(let rect):
            return rect
        case .magnifier:
            return magnifierGeometry?.bounds ?? .zero
        case .highlight:
            return strokePath.boundingRect.insetBy(dx: -highlightWidth / 2, dy: -highlightWidth / 2)
        default:
            var rect = strokePath.boundingRect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
            if let head = fillPath {
                rect = rect.union(head.boundingRect)
            }
            return rect
        }
    }

    /// Hidden areas change the picture itself, so they are drawn under the dim layer.
    var modifiesBackdrop: Bool {
        switch shape {
        case .blackout, .pixelate, .blur: true
        default: false
        }
    }

    /// Whether drawing this needs the picture underneath (pixelate, blur, magnifier).
    var needsBackdrop: Bool {
        switch shape {
        case .pixelate, .blur, .magnifier: true
        default: false
        }
    }

    /// Where a magnifier's parts sit: the source circle, the lens and the line joining them.
    struct MagnifierGeometry {
        var source: CGPoint
        var lens: CGPoint
        var sourceRadius: CGFloat
        var lensRadius: CGFloat
        var lineWidth: CGFloat

        var sourceRect: CGRect { CGRect(center: source, radius: sourceRadius) }
        var lensRect: CGRect { CGRect(center: lens, radius: lensRadius) }

        var distance: CGFloat { hypot(lens.x - source.x, lens.y - source.y) }

        /// The source ring and connector only make sense once the lens sits clear of the spot it shows.
        var showsSource: Bool { distance >= lensRadius + sourceRadius }

        /// From the edge of the source circle to the edge of the lens.
        var connector: Path {
            var path = Path()
            guard showsSource, distance > 0 else { return path }
            let ux = (lens.x - source.x) / distance
            let uy = (lens.y - source.y) / distance
            path.move(to: CGPoint(x: source.x + ux * sourceRadius, y: source.y + uy * sourceRadius))
            path.addLine(to: CGPoint(x: lens.x - ux * lensRadius, y: lens.y - uy * lensRadius))
            return path
        }

        /// Where the whole picture lands when it is enlarged `zoom` times so that `source` sits at the lens centre.
        func enlargedPictureRect(pictureSize: CGSize, zoom: CGFloat) -> CGRect {
            CGRect(x: lens.x - source.x * zoom, y: lens.y - source.y * zoom, width: pictureSize.width * zoom, height: pictureSize.height * zoom)
        }

        var bounds: CGRect {
            var rect = lensRect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
            if showsSource {
                rect = rect.union(sourceRect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2))
            }
            return rect
        }
    }

    var magnifierGeometry: MagnifierGeometry? {
        guard case .magnifier(let source, let lens) = shape else { return nil }
        return MagnifierGeometry(source: source, lens: lens, sourceRadius: magnifierSourceRadius, lensRadius: magnifierLensRadius, lineWidth: lineWidth)
    }

    /// The text's box on the surface: the glyphs, or the pill around them when it has one.
    var textBox: CGRect? {
        guard case .text(let string, let origin) = shape else { return nil }
        let size = AnnotationRenderer.textSize(string, fontSize: fontSize, width: text.width)
        let box = CGRect(origin: origin, size: CGSize(width: text.width ?? size.width, height: size.height))
        guard text.hasBackground else { return box }
        let padding = TextStyle.padding(fontSize: fontSize)
        return box.insetBy(dx: -padding.width, dy: -padding.height)
    }

    /// Where a dimension line's parts sit: the line with its end ticks, and the label beside its middle.
    struct MeasureGeometry {
        var from: CGPoint
        var to: CGPoint
        var lineWidth: CGFloat
        var path: Path
        var label: String
        var fontSize: CGFloat
        var labelRect: CGRect
    }

    var measureGeometry: MeasureGeometry? {
        guard case .measure(let a, let b) = shape else { return nil }
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        let label = "\(Int(length.rounded())) px"
        let fontSize = max(11, lineWidth * 2 + 7)
        let padding = TextStyle.padding(fontSize: fontSize)
        let textSize = AnnotationRenderer.textSize(label, fontSize: fontSize)
        let labelSize = CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        guard length > 0.5 else {
            return MeasureGeometry(from: a, to: b, lineWidth: lineWidth, path: path, label: label, fontSize: fontSize, labelRect: CGRect(center: a, radius: 0))
        }
        let ux = dx / length
        let uy = dy / length
        // Ticks across both ends, and the label on the side of the line that faces up the screen.
        let tick = max(6, lineWidth * 2.5)
        var (px, py) = (-uy, ux)
        for point in [a, b] {
            path.move(to: CGPoint(x: point.x + px * tick / 2, y: point.y + py * tick / 2))
            path.addLine(to: CGPoint(x: point.x - px * tick / 2, y: point.y - py * tick / 2))
        }
        if py > 0 || (py == 0 && px < 0) {
            (px, py) = (-px, -py)
        }
        let midpoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        // Far enough out that the label's near corner clears the line whatever its angle.
        let offset = tick / 2 + lineWidth + 4 + labelSize.width / 2 * abs(px) + labelSize.height / 2 * abs(py)
        let center = CGPoint(x: midpoint.x + px * offset, y: midpoint.y + py * offset)
        let labelRect = CGRect(x: center.x - labelSize.width / 2, y: center.y - labelSize.height / 2, width: labelSize.width, height: labelSize.height)
        return MeasureGeometry(from: a, to: b, lineWidth: lineWidth, path: path, label: label, fontSize: fontSize, labelRect: labelRect)
    }

    /// Whether `point` is on the drawn marks (not just inside a shape's empty interior).
    func hitTest(_ point: CGPoint) -> Bool {
        let tolerance: CGFloat = 6
        switch shape {
        case .text, .badge, .blackout, .pixelate, .blur:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .magnifier:
            guard let geometry = magnifierGeometry else { return false }
            if hypot(point.x - geometry.lens.x, point.y - geometry.lens.y) <= geometry.lensRadius + tolerance { return true }
            guard geometry.showsSource else { return false }
            if hypot(point.x - geometry.source.x, point.y - geometry.source.y) <= geometry.sourceRadius + tolerance { return true }
            return geometry.connector.strokedPath(StrokeStyle(lineWidth: tolerance * 2, lineCap: .round)).contains(point)
        case .measure:
            guard let geometry = measureGeometry else { return false }
            if geometry.labelRect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) { return true }
            let style = StrokeStyle(lineWidth: lineWidth + tolerance * 2, lineCap: .round, lineJoin: .round)
            return geometry.path.strokedPath(style).contains(point)
        case .spotlight:
            // Only the edge, so shapes drawn inside the bright area stay clickable.
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) && !bounds.insetBy(dx: tolerance, dy: tolerance).contains(point)
        case .highlight:
            let style = StrokeStyle(lineWidth: highlightWidth + tolerance * 2, lineCap: .round, lineJoin: .round)
            return strokePath.strokedPath(style).contains(point)
        default:
            if let head = fillPath, head.contains(point) { return true }
            let style = StrokeStyle(lineWidth: lineWidth + tolerance * 2, lineCap: .round, lineJoin: .round)
            return strokePath.strokedPath(style).contains(point)
        }
    }

    /// The same element moved by `delta`.
    func translated(by delta: CGPoint) -> Annotation {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + delta.x, y: point.y + delta.y) }
        var copy = self
        switch shape {
        case .line(let a, let b): copy.shape = .line(from: move(a), to: move(b))
        case .arrow(let a, let b): copy.shape = .arrow(from: move(a), to: move(b))
        case .rectangle(let rect): copy.shape = .rectangle(rect.offsetBy(dx: delta.x, dy: delta.y))
        case .ellipse(let rect): copy.shape = .ellipse(rect.offsetBy(dx: delta.x, dy: delta.y))
        case .freehand(let points): copy.shape = .freehand(points.map(move))
        case .highlight(let points): copy.shape = .highlight(points.map(move))
        case .text(let string, let origin): copy.shape = .text(string, origin: move(origin))
        case .badge(let number, let center): copy.shape = .badge(number, center: move(center))
        case .blackout(let rect): copy.shape = .blackout(rect.offsetBy(dx: delta.x, dy: delta.y))
        case .pixelate(let rect): copy.shape = .pixelate(rect.offsetBy(dx: delta.x, dy: delta.y))
        case .spotlight(let rect): copy.shape = .spotlight(rect.offsetBy(dx: delta.x, dy: delta.y))
        case .blur(let rect): copy.shape = .blur(rect.offsetBy(dx: delta.x, dy: delta.y))
        case .magnifier(let source, let lens): copy.shape = .magnifier(source: move(source), lens: move(lens))
        case .measure(let a, let b): copy.shape = .measure(from: move(a), to: move(b))
        }
        return copy
    }

    /// Whether `rect` crosses the annotation (for marquee selection): its bounds, which is close enough for shapes.
    func intersects(_ rect: CGRect) -> Bool {
        bounds.intersects(rect)
    }

    static func arrowGeometry(from a: CGPoint, to b: CGPoint, lineWidth: CGFloat) -> (shaft: Path, head: Path) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return (Path(), Path()) }

        let ux = dx / length
        let uy = dy / length
        let headLength = min(length, max(14, lineWidth * 4))
        let headWidth = headLength * 0.9
        let base = CGPoint(x: b.x - ux * headLength, y: b.y - uy * headLength)
        let (px, py) = (-uy, ux)  // perpendicular unit vector

        var head = Path()
        head.move(to: b)
        head.addLine(to: CGPoint(x: base.x + px * headWidth / 2, y: base.y + py * headWidth / 2))
        head.addLine(to: CGPoint(x: base.x - px * headWidth / 2, y: base.y - py * headWidth / 2))
        head.closeSubpath()

        // Stop the shaft inside the head so its round cap never pokes out of the tip.
        var shaft = Path()
        shaft.move(to: a)
        shaft.addLine(to: CGPoint(x: b.x - ux * headLength * 0.6, y: b.y - uy * headLength * 0.6))
        return (shaft, head)
    }

    /// A pen stroke smoothed with quadratic curves through the midpoints of the samples.
    static func smoothedPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else {
            path.addLine(to: first)  // a single tap becomes a dot thanks to the round cap
            return path
        }
        guard points.count > 2 else {
            path.addLine(to: points[1])
            return path
        }
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let next = points[index + 1]
            path.addQuadCurve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), control: control)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

/// Draws annotations identically on screen (SwiftUI canvas) and on export (Core Graphics).
enum AnnotationRenderer {
    /// The picture under the annotations, for the tools that need it: pixelate, blur and the magnifier.
    /// The derived copies are made on first use, since most captures never need them.
    final class Backdrop {
        let original: CGImage
        let pointSize: CGSize
        let scale: CGFloat
        /// The picture pixelate and blur work from; usually `original`, see `replacingPicture(with:scale:)`.
        private let effects: Effects

        convenience init(original: CGImage, pointSize: CGSize, scale: CGFloat) {
            self.init(original: original, pointSize: pointSize, scale: scale, effects: Effects(source: original, scale: scale))
        }

        private init(original: CGImage, pointSize: CGSize, scale: CGFloat, effects: Effects) {
            self.original = original
            self.pointSize = pointSize
            self.scale = scale
            self.effects = effects
        }

        /// The whole picture in coarse blocks; each pixelate shape just clips a piece of it.
        var pixelated: CGImage? { effects.pixelated }
        /// The whole picture softened by `radius` points; each blur shape just clips a piece of the copy for its strength.
        func blurred(radius: CGFloat) -> CGImage? { effects.blurred(radius: radius) }

        /// A newer picture of the same display for the magnifier, keeping this one's pixelated and blurred copies.
        /// A live feed brings many pictures a second, and redoing those over the whole display for each one would
        /// stall drawing; hidden areas keep showing the picture they were made from, as they do without a feed.
        func replacingPicture(with image: CGImage, scale: CGFloat) -> Backdrop {
            Backdrop(original: image, pointSize: pointSize, scale: scale, effects: effects)
        }

        /// The same picture, with pixelate and blur working from it too (made again on first use).
        func refreshingEffects() -> Backdrop {
            Backdrop(original: original, pointSize: pointSize, scale: scale)
        }

        private final class Effects {
            let source: CGImage
            let scale: CGFloat

            init(source: CGImage, scale: CGFloat) {
                self.source = source
                self.scale = scale
            }

            lazy var pixelated: CGImage? = AnnotationRenderer.pixelated(source, blockSize: Int(12 * scale))

            /// One copy per strength in use, each made the first time a blur needs it.
            private var blurredByRadius: [CGFloat: CGImage?] = [:]

            func blurred(radius: CGFloat) -> CGImage? {
                if let cached = blurredByRadius[radius] { return cached }
                let image = AnnotationRenderer.blurred(source, radius: radius * scale)
                blurredByRadius[radius] = image
                return image
            }
        }
    }

    private static let shadowAlpha = 0.35

    // MARK: On screen

    static func draw(_ annotation: Annotation, in context: inout GraphicsContext, backdrop: Backdrop? = nil) {
        switch annotation.shape {
        case .spotlight:
            break  // part of the dim pass, see drawDim(_:)
        case .blackout(let rect):
            context.fill(Path(rect), with: .color(.black))
        case .pixelate(let rect):
            guard let backdrop, let pixelated = backdrop.pixelated else { return drawCover(rect, in: &context) }
            drawClipped(pixelated, to: Path(rect), backdrop: backdrop, in: &context)
        case .blur(let rect):
            guard let backdrop, let blurred = backdrop.blurred(radius: annotation.blurRadius) else { return drawCover(rect, in: &context) }
            drawClipped(blurred, to: Path(rect), backdrop: backdrop, in: &context)
        case .magnifier:
            guard let geometry = annotation.magnifierGeometry else { return }
            drawMagnifier(annotation, geometry: geometry, backdrop: backdrop, in: &context)
        case .highlight:
            context.drawLayer { layer in
                layer.blendMode = .multiply
                let style = StrokeStyle(lineWidth: annotation.highlightWidth, lineCap: .round, lineJoin: .round)
                layer.stroke(annotation.strokePath, with: .color(Color(annotation.color).opacity(0.45)), style: style)
            }
        case .text, .badge, .measure:
            context.drawLayer { layer in
                layer.withCGContext { cg in
                    drawGlyphs(annotation, in: cg, shadowScale: 1)
                }
            }
        default:
            let shading = GraphicsContext.Shading.color(Color(annotation.color))
            let style = StrokeStyle(lineWidth: annotation.lineWidth, lineCap: .round, lineJoin: .round)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(shadowAlpha), radius: 1.5, y: 1))
                layer.stroke(annotation.strokePath, with: shading, style: style)
                if let head = annotation.fillPath {
                    layer.fill(head, with: shading)
                }
            }
        }
    }

    // MARK: Export

    /// Expects `context` to already use the surface's point space with a top-left origin.
    /// `scale` is the pixels-per-point factor, used to size shadows in device pixels.
    static func draw(_ annotation: Annotation, in context: CGContext, scale: CGFloat, backdrop: Backdrop? = nil) {
        context.saveGState()
        defer { context.restoreGState() }

        switch annotation.shape {
        case .spotlight:
            break  // part of the dim pass, see drawDim(_:)
        case .blackout(let rect):
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rect)
        case .pixelate(let rect):
            guard let backdrop, let pixelated = backdrop.pixelated else { return drawCover(rect, in: context) }
            drawClipped(pixelated, to: Path(rect), backdrop: backdrop, interpolation: .none, in: context)
        case .blur(let rect):
            guard let backdrop, let blurred = backdrop.blurred(radius: annotation.blurRadius) else { return drawCover(rect, in: context) }
            drawClipped(blurred, to: Path(rect), backdrop: backdrop, interpolation: .high, in: context)
        case .magnifier:
            guard let geometry = annotation.magnifierGeometry else { return }
            drawMagnifier(annotation, geometry: geometry, backdrop: backdrop, scale: scale, in: context)
        case .highlight:
            context.setBlendMode(.multiply)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(annotation.highlightWidth)
            context.setStrokeColor(annotation.color.cgColor.copy(alpha: 0.45) ?? annotation.color.cgColor)
            context.addPath(annotation.strokePath.cgPath)
            context.strokePath()
        case .text, .badge, .measure:
            drawGlyphs(annotation, in: context, shadowScale: scale)
        default:
            // Shadow offsets are in device space, where y points up, hence the negative height.
            context.setShadow(offset: CGSize(width: 0, height: -scale), blur: 1.5 * scale, color: CGColor(gray: 0, alpha: shadowAlpha))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(annotation.lineWidth)
            let color = annotation.color.cgColor
            context.setStrokeColor(color)
            context.setFillColor(color)
            context.addPath(annotation.strokePath.cgPath)
            context.strokePath()
            if let head = annotation.fillPath {
                context.addPath(head.cgPath)
                context.fillPath()
            }
            context.endTransparencyLayer()
        }
    }

    // MARK: Picture-based tools (pixelate, blur, magnifier)

    /// Without a picture to pixelate or blur (on the live screen before its snapshot arrives, or without
    /// screen recording access) the area is covered plainly, so a hidden spot never shows through.
    private static let coverColor = CGColor(gray: 0.55, alpha: 1)

    private static func drawCover(_ rect: CGRect, in context: inout GraphicsContext) {
        context.fill(Path(rect), with: .color(Color(cgColor: coverColor)))
    }

    private static func drawCover(_ rect: CGRect, in context: CGContext) {
        context.setFillColor(coverColor)
        context.fill(rect)
    }

    /// Draws `picture` (a copy of the backdrop at the surface's size) inside `path`.
    private static func drawClipped(_ picture: CGImage, to path: Path, backdrop: Backdrop, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.clip(to: path)
            layer.draw(Image(decorative: picture, scale: backdrop.scale), in: CGRect(origin: .zero, size: backdrop.pointSize))
        }
    }

    /// The export twin of `drawClipped(_:to:backdrop:in:)`, for a y-down context in surface points.
    private static func drawClipped(_ picture: CGImage, to path: Path, backdrop: Backdrop, interpolation: CGInterpolationQuality, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.addPath(path.cgPath)
        context.clip()
        // The context is flipped for drawing; flip back so the image isn't upside down.
        context.translateBy(x: 0, y: backdrop.pointSize.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = interpolation
        context.draw(picture, in: CGRect(origin: .zero, size: backdrop.pointSize))
    }

    /// A round lens showing the picture around the source enlarged, with a ring on the source and a
    /// line between the two once the lens has been dragged away from it. Without a backdrop (no picture
    /// yet, or no permission to take one) the lens is drawn empty.
    private static func drawMagnifier(_ annotation: Annotation, geometry: Annotation.MagnifierGeometry, backdrop: Backdrop?, in context: inout GraphicsContext) {
        let shading = GraphicsContext.Shading.color(Color(annotation.color))
        let lens = Path(ellipseIn: geometry.lensRect)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.4), radius: 6, y: 3))
            if let backdrop {
                let enlarged = geometry.enlargedPictureRect(pictureSize: backdrop.pointSize, zoom: Annotation.magnifierZoom)
                layer.drawLayer { inner in
                    inner.clip(to: lens)
                    inner.draw(Image(decorative: backdrop.original, scale: backdrop.scale).interpolation(.high), in: enlarged)
                }
            }
            layer.stroke(lens, with: shading, style: StrokeStyle(lineWidth: annotation.lineWidth))
            if geometry.showsSource {
                let thin = StrokeStyle(lineWidth: max(1, annotation.lineWidth / 2), lineCap: .round)
                layer.stroke(Path(ellipseIn: geometry.sourceRect), with: shading, style: thin)
                layer.stroke(geometry.connector, with: shading, style: thin)
            }
        }
    }

    /// The export twin of `drawMagnifier(_:geometry:backdrop:in:)`, for a y-down context in surface points.
    private static func drawMagnifier(_ annotation: Annotation, geometry: Annotation.MagnifierGeometry, backdrop: Backdrop?, scale: CGFloat, in context: CGContext) {
        let color = annotation.color.cgColor
        let zoom = Annotation.magnifierZoom
        // Shadow offsets are in device space, where y points up, hence the negative height.
        context.setShadow(offset: CGSize(width: 0, height: -3 * scale), blur: 6 * scale, color: CGColor(gray: 0, alpha: 0.4))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }

        if let backdrop {
            context.saveGState()
            context.addEllipse(in: geometry.lensRect)
            context.clip()
            // Enlarge the picture about the source so that spot lands in the lens, then flip for the image.
            context.translateBy(x: geometry.lens.x, y: geometry.lens.y)
            context.scaleBy(x: zoom, y: zoom)
            context.translateBy(x: -geometry.source.x, y: -geometry.source.y)
            context.translateBy(x: 0, y: backdrop.pointSize.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(backdrop.original, in: CGRect(origin: .zero, size: backdrop.pointSize))
            context.restoreGState()
        }

        context.setStrokeColor(color)
        context.setLineCap(.round)
        context.setLineWidth(annotation.lineWidth)
        context.strokeEllipse(in: geometry.lensRect)
        if geometry.showsSource {
            context.setLineWidth(max(1, annotation.lineWidth / 2))
            context.strokeEllipse(in: geometry.sourceRect)
            context.addPath(geometry.connector.cgPath)
            context.strokePath()
        }
    }

    // MARK: Drawing order (shared)

    /// A bright circle around the pointer, cut out of the dim layer while presenting.
    struct PointerSpotlight {
        var center: CGPoint
        var radius: CGFloat
    }

    /// Hidden areas change the picture itself, so they go under the dim layer; everything else sits on top.
    /// A board, when there is one, covers the picture before anything is drawn.
    static func drawAll(_ annotations: [Annotation], dimsLights: Bool, size: CGSize, backdrop: Backdrop?, pointer: PointerSpotlight? = nil, board: Board? = nil, in context: inout GraphicsContext) {
        if let board {
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(cgColor: board.cgColor)))
        }
        for annotation in annotations where annotation.modifiesBackdrop {
            draw(annotation, in: &context, backdrop: backdrop)
        }
        drawDim(annotations, dimsLights: dimsLights, size: size, pointer: pointer, in: &context)
        for annotation in annotations where !annotation.modifiesBackdrop {
            draw(annotation, in: &context, backdrop: backdrop)
        }
    }

    static func drawAll(_ annotations: [Annotation], dimsLights: Bool, size: CGSize, scale: CGFloat, backdrop: Backdrop?, board: Board? = nil, in context: CGContext) {
        if let board {
            context.saveGState()
            context.setFillColor(board.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            context.restoreGState()
        }
        for annotation in annotations where annotation.modifiesBackdrop {
            draw(annotation, in: context, scale: scale, backdrop: backdrop)
        }
        drawDim(annotations, dimsLights: dimsLights, size: size, in: context)
        for annotation in annotations where !annotation.modifiesBackdrop {
            draw(annotation, in: context, scale: scale, backdrop: backdrop)
        }
    }

    // MARK: Dimming (shared)

    /// How dark the area outside the highlights gets: "dim lights" darkens everything by the amount set in
    /// Settings, otherwise highlights alone dim their surroundings a little less.
    static func dimOpacity(dimsLights: Bool, hasSpotlights: Bool) -> Double {
        if dimsLights { return Preferences.dimAmount }
        return hasSpotlights ? 0.5 : 0
    }

    static func spotlightRects(in annotations: [Annotation]) -> [CGRect] {
        annotations.compactMap { if case .spotlight(let rect) = $0.shape { rect } else { nil } }
    }

    /// The whole surface minus the highlighted areas (filled with the even-odd rule).
    static func dimPath(size: CGSize, spotlights: [CGRect]) -> Path {
        var path = Path(CGRect(origin: .zero, size: size))
        for rect in spotlights {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
        }
        return path
    }

    /// Draws the dim layer; call it after the picture and before the other annotations.
    static func drawDim(_ annotations: [Annotation], dimsLights: Bool, size: CGSize, pointer: PointerSpotlight? = nil, in context: inout GraphicsContext) {
        let spotlights = spotlightRects(in: annotations)
        let opacity = dimOpacity(dimsLights: dimsLights, hasSpotlights: !spotlights.isEmpty)
        guard opacity > 0 else { return }
        let dim = dimPath(size: size, spotlights: spotlights)
        guard let pointer, dimsLights else {
            context.fill(dim, with: .color(.black.opacity(opacity)), style: FillStyle(eoFill: true))
            return
        }
        context.drawLayer { layer in
            layer.fill(dim, with: .color(.black.opacity(opacity)), style: FillStyle(eoFill: true))
            // Erase a soft-edged circle around the pointer: clear in the middle, fading into the dim.
            layer.blendMode = .destinationOut
            let rect = CGRect(center: pointer.center, radius: pointer.radius)
            let fade = Gradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.7),
                .init(color: .clear, location: 1),
            ])
            layer.fill(Path(ellipseIn: rect), with: .radialGradient(fade, center: pointer.center, startRadius: 0, endRadius: pointer.radius))
        }
    }

    static func drawDim(_ annotations: [Annotation], dimsLights: Bool, size: CGSize, in context: CGContext) {
        let spotlights = spotlightRects(in: annotations)
        let opacity = dimOpacity(dimsLights: dimsLights, hasSpotlights: !spotlights.isEmpty)
        guard opacity > 0 else { return }
        context.saveGState()
        context.addPath(dimPath(size: size, spotlights: spotlights).cgPath)
        context.setFillColor(CGColor(gray: 0, alpha: opacity))
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    // MARK: Text, badges and measurements (shared)

    /// Draws text, a numbered badge or a dimension line with Core Text, in a y-down context in surface points.
    private static func drawGlyphs(_ annotation: Annotation, in context: CGContext, shadowScale: CGFloat) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setShadow(offset: CGSize(width: 0, height: -shadowScale), blur: 2 * shadowScale, color: CGColor(gray: 0, alpha: 0.5))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }

        switch annotation.shape {
        case .text(let string, let origin):
            if annotation.text.hasBackground, let box = annotation.textBox {
                // The pill casts the shadow; the glyphs on it don't need one.
                let pill = CGPath(roundedRect: box, cornerWidth: annotation.fontSize * 0.35, cornerHeight: annotation.fontSize * 0.35, transform: nil)
                context.setFillColor(isLight(annotation.color) ? CGColor(gray: 0, alpha: 0.75) : CGColor(gray: 1, alpha: 0.9))
                context.addPath(pill)
                context.fillPath()
                context.setShadow(offset: .zero, blur: 0, color: nil)
            }
            drawText(string, fontSize: annotation.fontSize, color: annotation.color.cgColor, topLeft: origin, width: annotation.text.width, in: context)
        case .badge(let number, let center):
            let radius = annotation.badgeRadius
            let circle = CGRect(center: center, radius: radius)
            let label = String(number)
            let fontSize = radius * 1.25
            let size = textSize(label, fontSize: fontSize)
            let textColor: CGColor
            switch annotation.badgeStyle {
            case .filled:
                context.setFillColor(annotation.color.cgColor)
                context.fillEllipse(in: circle)
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
                context.setLineWidth(max(1.5, radius * 0.1))
                context.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
                textColor = isLight(annotation.color) ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
            case .bordered:
                let ring = max(2, radius * 0.18)
                context.setFillColor(isLight(annotation.color) ? CGColor(gray: 0, alpha: 0.75) : CGColor(gray: 1, alpha: 0.92))
                context.fillEllipse(in: circle)
                context.setStrokeColor(annotation.color.cgColor)
                context.setLineWidth(ring)
                context.strokeEllipse(in: circle.insetBy(dx: ring / 2, dy: ring / 2))
                textColor = annotation.color.cgColor
            }
            // No shadow on the digit itself; the circle already casts one.
            context.setShadow(offset: .zero, blur: 0, color: nil)
            drawText(label, fontSize: fontSize, color: textColor, topLeft: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), width: nil, in: context)
        case .measure:
            guard let geometry = annotation.measureGeometry else { return }
            let color = annotation.color.cgColor
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(annotation.lineWidth)
            context.setStrokeColor(color)
            context.addPath(geometry.path.cgPath)
            context.strokePath()
            let corner = geometry.labelRect.height / 2
            context.setFillColor(color)
            context.addPath(CGPath(roundedRect: geometry.labelRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            let textColor = isLight(annotation.color) ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
            let size = textSize(geometry.label, fontSize: geometry.fontSize)
            drawText(geometry.label, fontSize: geometry.fontSize, color: textColor, topLeft: CGPoint(x: geometry.labelRect.midX - size.width / 2, y: geometry.labelRect.midY - size.height / 2), width: nil, in: context)
        default:
            break
        }
    }

    /// Draws `string`, which may run to several lines, with its top-left corner at `topLeft`. With a `width` the
    /// lines wrap to it; without, each line is as long as it is.
    private static func drawText(_ string: String, fontSize: CGFloat, color: CGColor, topLeft: CGPoint, width: CGFloat?, in context: CGContext) {
        let layout = textLayout(string, fontSize: fontSize, color: color, width: width)
        context.saveGState()
        // Core Text draws y-up; flip so the frame's top edge lands on `topLeft`.
        context.translateBy(x: topLeft.x, y: topLeft.y + layout.size.height)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTFrameDraw(layout.frame, context)
        context.restoreGState()
    }

    /// The room `string` takes at `fontSize`: as wide as its longest line, or wrapped to `width`.
    static func textSize(_ string: String, fontSize: CGFloat, width: CGFloat? = nil) -> CGSize {
        textLayout(string, fontSize: fontSize, color: CGColor(gray: 0, alpha: 1), width: width).size
    }

    private static func textLayout(_ string: String, fontSize: CGFloat, color: CGColor, width: CGFloat?) -> (frame: CTFrame, size: CGSize) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: fontSize),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
        ]
        // An empty string still takes a line, so the box a text is typed into has a height from the start.
        let shown = string.isEmpty ? " " : string
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: shown, attributes: attributes))
        let limit = CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        var fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, limit, nil)
        fitted = CGSize(width: ceil(width ?? fitted.width), height: ceil(fitted.height))
        // A little slack in the path keeps Core Text from dropping the last line to rounding.
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: fitted.width + 1, height: fitted.height + 2), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        return (frame, CGSize(width: string.isEmpty ? 0 : fitted.width, height: fitted.height))
    }

    private static func font(size: CGFloat) -> CTFont {
        let system = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return CTFontCreateCopyWithSymbolicTraits(system, size, nil, .boldTrait, .boldTrait) ?? system
    }

    private static func isLight(_ color: Color.Resolved) -> Bool {
        0.299 * Double(color.red) + 0.587 * Double(color.green) + 0.114 * Double(color.blue) > 0.65
    }

    // MARK: Images

    /// `image` with `annotations` (in points) burned in, at the image's own pixel size.
    static func flatten(_ annotations: [Annotation], onto image: CGImage, scale: CGFloat, backdrop: Backdrop? = nil, dimsLights: Bool = false, board: Board? = nil) -> CGImage? {
        guard let context = rgbContext(width: image.width, height: image.height, like: image) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // Switch to the drawing coordinate system: points, origin at the top-left.
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: scale, y: -scale)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        drawAll(annotations, dimsLights: dimsLights, size: size, scale: scale, backdrop: backdrop, board: board, in: context)
        return context.makeImage()
    }

    /// A coarse-block copy of `image`; `blockSize` is in pixels.
    static func pixelated(_ image: CGImage, blockSize: Int) -> CGImage? {
        let block = max(2, blockSize)
        let smallWidth = max(1, image.width / block)
        let smallHeight = max(1, image.height / block)
        guard let small = rgbContext(width: smallWidth, height: smallHeight, like: image) else { return nil }
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let shrunk = small.makeImage(), let big = rgbContext(width: image.width, height: image.height, like: image) else { return nil }
        big.interpolationQuality = .none
        big.draw(shrunk, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return big.makeImage()
    }

    /// A softened copy of `image`; `radius` is in pixels. The edges are extended first so they don't fade to transparent.
    static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return blurContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: rgbColorSpace(of: image))
    }

    private static let blurContext = CIContext()

    /// An RGBA bitmap in `image`'s colour space, falling back to sRGB.
    static func rgbContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: rgbColorSpace(of: image), bitmapInfo: bitmapInfo)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: bitmapInfo)
    }

    /// `image`'s own colour space when it is RGB, otherwise sRGB.
    static func rgbColorSpace(of image: CGImage) -> CGColorSpace {
        image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
}
