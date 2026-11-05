import SwiftUI
import ImageIO

enum ArrowStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case straight, curved, elbow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .straight: String(localized: "Straight")
        case .curved: String(localized: "Curved")
        case .elbow: String(localized: "Elbow")
        }
    }
}

extension Annotation {
    /// A signed change in tangent direction, in degrees. Positive and negative values bend to opposite sides.
    nonisolated static let defaultCurveDegrees: CGFloat = 53.13010235415598
    nonisolated static let curveDegreeRange: ClosedRange<CGFloat> = -150...150

    static func clampedCurveDegrees(_ degrees: CGFloat) -> CGFloat {
        guard degrees.isFinite else { return defaultCurveDegrees }
        return min(curveDegreeRange.upperBound, max(curveDegreeRange.lowerBound, degrees))
    }

    /// Callout connectors start at the edge of the label and end at their fixed target.
    var connectorEndpoints: (from: CGPoint, to: CGPoint)? {
        if case .arrow(let from, let to) = shape { return (from, to) }
        guard let target = calloutTarget, let box = textBox else { return nil }
        let center = CGPoint(x: box.midX, y: box.midY)
        let dx = target.x - center.x, dy = target.y - center.y
        guard !box.contains(target), abs(dx) + abs(dy) > 0 else { return nil }
        let factor = min(dx == 0 ? CGFloat.infinity : box.width / 2 / abs(dx),
                         dy == 0 ? CGFloat.infinity : box.height / 2 / abs(dy))
        return (CGPoint(x: center.x + dx * factor, y: center.y + dy * factor), target)
    }

    var connectorGeometry: (shaft: Path, head: Path)? {
        guard let ends = connectorEndpoints else { return nil }
        return Self.connector(from: ends.from, to: ends.to, style: arrowStyle, lineWidth: lineWidth, curveDegrees: curveDegrees)
    }

    /// The midpoint of the full quadratic curve is its direct-manipulation handle.
    var curveHandle: CGPoint? {
        guard arrowStyle == .curved, let ends = connectorEndpoints else { return nil }
        return Self.curveMidpoint(from: ends.from, to: ends.to, degrees: curveDegrees)
    }

    static func curveControl(from a: CGPoint, to b: CGPoint, degrees: CGFloat) -> CGPoint {
        let amount = tan(clampedCurveDegrees(degrees) * .pi / 360) / 2
        return CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) * amount,
                       y: (a.y + b.y) / 2 + (b.x - a.x) * amount)
    }

    static func curveMidpoint(from a: CGPoint, to b: CGPoint, degrees: CGFloat) -> CGPoint {
        let control = curveControl(from: a, to: b, degrees: degrees)
        return CGPoint(x: a.x / 4 + control.x / 2 + b.x / 4, y: a.y / 4 + control.y / 2 + b.y / 4)
    }

    /// Recover the tangent angle from a point on the middle of the curve. Motion along the chord is ignored.
    static func curveDegrees(from a: CGPoint, to b: CGPoint, through point: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength >= 1 else { return 0 }
        let offset = ((point.x - (a.x + b.x) / 2) * -dy + (point.y - (a.y + b.y) / 2) * dx) / squaredLength
        return clampedCurveDegrees(2 * atan(4 * offset) * 180 / .pi)
    }

    static func connector(from a: CGPoint, to b: CGPoint, style: ArrowStyle, lineWidth: CGFloat, curveDegrees: CGFloat = defaultCurveDegrees) -> (shaft: Path, head: Path) {
        guard style != .straight else { return arrowGeometry(from: a, to: b, lineWidth: lineWidth) }
        let dx = b.x - a.x, dy = b.y - a.y
        guard hypot(dx, dy) > 0.5 else { return (Path(), Path()) }
        var path = Path()
        path.move(to: a)
        let tangent: CGPoint
        switch style {
        case .curved:
            let control = curveControl(from: a, to: b, degrees: curveDegrees)
            let head = arrowGeometry(from: control, to: b, lineWidth: lineWidth)
            let inset = min(hypot(b.x - control.x, b.y - control.y), max(14, lineWidth * 4)) * 0.6
            // Split the quadratic near the tip, preserving the original curve and its midpoint handle exactly.
            func point(at t: CGFloat) -> CGPoint {
                let u = 1 - t
                return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x,
                               y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
            }
            var lower: CGFloat = 0, upper: CGFloat = 1
            for _ in 0..<20 {
                let t = (lower + upper) / 2
                let p = point(at: t)
                if hypot(b.x - p.x, b.y - p.y) > inset { lower = t } else { upper = t }
            }
            let t = (lower + upper) / 2
            let splitControl = CGPoint(x: a.x + (control.x - a.x) * t, y: a.y + (control.y - a.y) * t)
            path.addQuadCurve(to: point(at: t), control: splitControl)
            return (path, head.head)
        case .elbow:
            let bend = abs(dx) >= abs(dy) ? CGPoint(x: a.x, y: b.y) : CGPoint(x: b.x, y: a.y)
            tangent = bend
            path.addLine(to: bend)
        case .straight: tangent = a
        }
        let end = arrowGeometry(from: tangent, to: b, lineWidth: lineWidth)
        path.addPath(end.shaft)
        return (path, end.head)
    }

    /// Selection drags leave a callout's target fixed; coordinate changes such as cropping move both parts.
    func movedForSelection(by delta: CGPoint) -> Annotation {
        var result = translated(by: delta)
        result.calloutTarget = calloutTarget
        return result
    }

    var embeddedImage: CGImage? {
        guard let imagePNG else { return nil }
        let key = imagePNG as NSData
        if let image = EmbeddedImageCache.images.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithData(imagePNG as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        EmbeddedImageCache.images.setObject(image, forKey: key, cost: image.width * image.height * 4)
        return image
    }
}

private enum EmbeddedImageCache {
    static let images: NSCache<NSData, CGImage> = {
        let cache = NSCache<NSData, CGImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()
}

enum AnnotationAlignment: String, CaseIterable, Identifiable {
    case left, center, right, top, middle, bottom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: String(localized: "Align Left")
        case .center: String(localized: "Align Centers")
        case .right: String(localized: "Align Right")
        case .top: String(localized: "Align Top")
        case .middle: String(localized: "Align Middles")
        case .bottom: String(localized: "Align Bottom")
        }
    }
}

/// A named style is independent of geometry, image data, groups and locks.
struct AnnotationStylePreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var sample: Annotation
}

@Observable
final class AnnotationStyleStore {
    static let shared = AnnotationStyleStore()
    static let defaultsKey = "annotationStylePresets"
    private let defaults: UserDefaults
    var stamps: [String] {
        didSet { defaults.set(stamps, forKey: Self.defaultsKey + ".stamps") }
    }
    var presets: [AnnotationStylePreset] {
        didSet { if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.defaultsKey) } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stamps = defaults.stringArray(forKey: Self.defaultsKey + ".stamps") ?? []
        presets = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode([AnnotationStylePreset].self, from: $0) } ?? []
    }

    func save(name: String, layer: AnnotationLayer) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var sample = Annotation(shape: .text("", origin: .zero), color: layer.toolbox.resolvedColor, lineWidth: layer.toolbox.lineWidth)
        let source = layer.selectedAnnotations.first
        sample.color = source?.color ?? sample.color
        sample.lineWidth = source?.lineWidth ?? sample.lineWidth
        sample.text = source?.text ?? layer.toolbox.textStyle
        sample.arrowStyle = source?.arrowStyle ?? layer.toolbox.arrowStyle
        sample.curveDegrees = source?.curveDegrees ?? layer.toolbox.curveDegrees
        sample.badgeStyle = source?.badgeStyle ?? layer.toolbox.badgeStyle
        presets.append(AnnotationStylePreset(name: name, sample: sample))
    }
}
