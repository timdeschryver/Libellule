import SwiftUI

/// The crop being adjusted in the editor: a rectangle over the original capture, which may reach past it to add space.
@Observable
final class CropSession {
    /// In the original's points with a top-left origin, like `AnnotationDocument.canvas`.
    var rect: CGRect
    var fill: CanvasFill
    /// The original capture's extent.
    let pictureBounds: CGRect
    /// What the crop view shows: the original, the crop, and room around both to drag the crop out into.
    private(set) var stage: CGRect = .zero

    static let minimumSize: CGFloat = 8

    init(document: AnnotationDocument) {
        rect = document.canvas
        fill = document.canvasFill
        pictureBounds = document.originalBounds
        refitStage()
    }

    /// Called when a drag ends rather than during it, so the view doesn't shift under the pointer.
    func refitStage() {
        let content = pictureBounds.union(rect)
        let margin = max(48, max(content.width, content.height) * 0.12).rounded()
        stage = content.insetBy(dx: -margin, dy: -margin)
    }

    func reset() {
        rect = pictureBounds
        refitStage()
    }

    /// Room for callouts on the given sides: a fifth of the shorter side, at least 40 points.
    func addSpace(_ edges: Edge.Set) {
        let amount = max(40, min(rect.width, rect.height) * 0.2).rounded()
        if edges.contains(.leading) {
            rect.origin.x -= amount
            rect.size.width += amount
        }
        if edges.contains(.trailing) { rect.size.width += amount }
        if edges.contains(.top) {
            rect.origin.y -= amount
            rect.size.height += amount
        }
        if edges.contains(.bottom) { rect.size.height += amount }
        refitStage()
    }
}

/// The corners and edge midpoints of the crop rectangle.
enum CropHandle: CaseIterable {
    case topLeading, top, topTrailing, trailing, bottomTrailing, bottom, bottomLeading, leading

    var movesMinX: Bool { [.topLeading, .leading, .bottomLeading].contains(self) }
    var movesMaxX: Bool { [.topTrailing, .trailing, .bottomTrailing].contains(self) }
    var movesMinY: Bool { [.topLeading, .top, .topTrailing].contains(self) }
    var movesMaxY: Bool { [.bottomLeading, .bottom, .bottomTrailing].contains(self) }

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: movesMinX ? rect.minX : movesMaxX ? rect.maxX : rect.midX,
            y: movesMinY ? rect.minY : movesMaxY ? rect.maxY : rect.midY
        )
    }

    #if os(macOS)
    var resizePosition: FrameResizePosition {
        switch self {
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .trailing: .trailing
        case .bottomTrailing: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeading: .bottomLeading
        case .leading: .leading
        }
    }
    #endif
}

/// The editor's crop mode: the whole original with the crop on top. Drag a handle or an edge to resize, inside the
/// crop to move it, outside to draw a new one; past the picture's edge adds space. Edges snap to the picture's edges.
struct CropCanvas: View {
    let document: AnnotationDocument
    let crop: CropSession
    /// Display points per picture point.
    let displayScale: CGFloat
    @State private var drag: Drag?
    @State private var hover: Grip?

    private enum Grip: Equatable {
        case handle(CropHandle)
        case move
        case draw
    }

    private struct Drag {
        var grip: Grip
        var startRect: CGRect
    }

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(x: displayScale, y: displayScale)
            context.translateBy(x: -crop.stage.minX, y: -crop.stage.minY)
            draw(in: &context)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hover = grip(at: stagePoint(location))
            case .ended: hover = nil
            }
        }
        .pointerStyle(pointerStyle)
        #endif
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext) {
        let rect = crop.rect
        let hairline = 1 / displayScale

        // The new picture's background, seen where it reaches past the capture.
        if let color = crop.fill.cgColor {
            context.fill(Path(rect), with: .color(Color(cgColor: color)))
        } else {
            context.fill(Path(rect), with: .tiledImage(Image(decorative: Self.checkerboard, scale: 1), scale: hairline))
        }
        context.draw(Image(decorative: document.original, scale: document.scale), in: crop.pictureBounds)

        // The annotations where they sit now, so it's clear what the crop would cut. Without the dim layer, which
        // would only cover the current picture.
        let shapes = document.layer.annotations.filter { if case .spotlight = $0.shape { false } else { true } }
        context.drawLayer { layer in
            layer.translateBy(x: document.canvas.minX, y: document.canvas.minY)
            AnnotationRenderer.drawAll(shapes, dimsLights: false, size: document.canvas.size, backdrop: document.backdrop, in: &layer)
        }

        var outside = Path(crop.stage)
        outside.addRect(rect)
        context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

        if drag != nil {
            var thirds = Path()
            for step in 1...2 {
                let x = rect.minX + rect.width * CGFloat(step) / 3
                let y = rect.minY + rect.height * CGFloat(step) / 3
                thirds.move(to: CGPoint(x: x, y: rect.minY))
                thirds.addLine(to: CGPoint(x: x, y: rect.maxY))
                thirds.move(to: CGPoint(x: rect.minX, y: y))
                thirds.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(thirds, with: .color(.white.opacity(0.4)), lineWidth: hairline)
        }
        context.stroke(Path(rect.insetBy(dx: -hairline, dy: -hairline)), with: .color(.black.opacity(0.5)), lineWidth: hairline)
        context.stroke(Path(rect), with: .color(.white), lineWidth: hairline * 1.5)

        let side = 9 * hairline
        for handle in CropHandle.allCases {
            let center = handle.point(in: rect)
            let square = Path(roundedRect: CGRect(center: center, radius: side / 2), cornerRadius: 2 * hairline)
            context.fill(square, with: .color(.white))
            context.stroke(square, with: .color(.black.opacity(0.45)), lineWidth: hairline)
        }
    }

    /// Light and lighter grey squares for transparent space, 8 pixels each.
    private static let checkerboard: CGImage = {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
        return context.makeImage()!
    }()

    // MARK: Dragging

    private func stagePoint(_ location: CGPoint) -> CGPoint {
        let factor = 1 / max(displayScale, 0.001)
        return CGPoint(x: location.x * factor + crop.stage.minX, y: location.y * factor + crop.stage.minY)
    }

    /// Hit tolerance in picture points: about 8 points on screen at any zoom.
    private var tolerance: CGFloat { 8 / max(displayScale, 0.001) }

    private func grip(at point: CGPoint) -> Grip {
        let rect = crop.rect
        if let handle = CropHandle.allCases.first(where: { hypot($0.point(in: rect).x - point.x, $0.point(in: rect).y - point.y) <= tolerance * 1.5 }) {
            return .handle(handle)
        }
        // An edge can be grabbed anywhere along its length, not just at its handle.
        let alongX = point.x > rect.minX - tolerance && point.x < rect.maxX + tolerance
        let alongY = point.y > rect.minY - tolerance && point.y < rect.maxY + tolerance
        if alongY, abs(point.x - rect.minX) <= tolerance { return .handle(.leading) }
        if alongY, abs(point.x - rect.maxX) <= tolerance { return .handle(.trailing) }
        if alongX, abs(point.y - rect.minY) <= tolerance { return .handle(.top) }
        if alongX, abs(point.y - rect.maxY) <= tolerance { return .handle(.bottom) }
        return rect.contains(point) ? .move : .draw
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let start = stagePoint(value.startLocation)
                if drag == nil {
                    drag = Drag(grip: grip(at: start), startRect: crop.rect)
                }
                guard let drag else { return }
                crop.rect = adjusted(drag, from: start, to: stagePoint(value.location))
            }
            .onEnded { _ in
                // A click outside the crop (or a tiny drag) keeps the crop as it was.
                if let drag, crop.rect.width < CropSession.minimumSize || crop.rect.height < CropSession.minimumSize {
                    crop.rect = drag.startRect
                }
                drag = nil
                crop.refitStage()
            }
    }

    private func adjusted(_ drag: Drag, from start: CGPoint, to current: CGPoint) -> CGRect {
        let stage = crop.stage
        let rect = drag.startRect
        let minimum = CropSession.minimumSize
        switch drag.grip {
        case .move:
            var moved = rect.offsetBy(dx: current.x - start.x, dy: current.y - start.y)
            moved.origin.x = min(max(moved.minX, stage.minX), stage.maxX - moved.width)
            moved.origin.y = min(max(moved.minY, stage.minY), stage.maxY - moved.height)
            moved.origin.x += snapOffset(moved.minX, moved.maxX, to: [crop.pictureBounds.minX, crop.pictureBounds.maxX])
            moved.origin.y += snapOffset(moved.minY, moved.maxY, to: [crop.pictureBounds.minY, crop.pictureBounds.maxY])
            return moved
        case .handle(let handle):
            let dx = current.x - start.x
            let dy = current.y - start.y
            var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
            if handle.movesMinX { minX = min(snapX(max(minX + dx, stage.minX)), maxX - minimum) }
            if handle.movesMaxX { maxX = max(snapX(min(maxX + dx, stage.maxX)), minX + minimum) }
            if handle.movesMinY { minY = min(snapY(max(minY + dy, stage.minY)), maxY - minimum) }
            if handle.movesMaxY { maxY = max(snapY(min(maxY + dy, stage.maxY)), minY + minimum) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .draw:
            func inStage(_ point: CGPoint) -> CGPoint {
                let point = point.clamped(to: stage)
                return CGPoint(x: snapX(point.x), y: snapY(point.y))
            }
            return CGRect(from: inStage(start), to: inStage(current), square: false)
        }
    }

    private func snapX(_ x: CGFloat) -> CGFloat {
        [crop.pictureBounds.minX, crop.pictureBounds.maxX].first { abs($0 - x) <= tolerance } ?? x
    }

    private func snapY(_ y: CGFloat) -> CGFloat {
        [crop.pictureBounds.minY, crop.pictureBounds.maxY].first { abs($0 - y) <= tolerance } ?? y
    }

    /// How far to shift a moved crop so its nearest edge lands on a picture edge, when one is close.
    private func snapOffset(_ low: CGFloat, _ high: CGFloat, to edges: [CGFloat]) -> CGFloat {
        let offsets = edges.flatMap { [$0 - low, $0 - high] }.filter { abs($0) <= tolerance }
        return offsets.min { abs($0) < abs($1) } ?? 0
    }

    #if os(macOS)
    private var pointerStyle: PointerStyle {
        switch drag?.grip ?? hover {
        case .handle(let handle): .frameResize(position: handle.resizePosition)
        case .move: drag == nil ? .grabIdle : .grabActive
        case .draw: .rectSelection
        case nil: .default
        }
    }
    #endif
}
