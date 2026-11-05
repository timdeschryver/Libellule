import SwiftUI
import CoreTransferable
import ImageIO
import UniformTypeIdentifiers

/// A captured image plus the annotation layer drawn on top of it.
@Observable
final class AnnotationDocument {
    /// The picture as captured. Every crop is cut from it afresh, so a crop can be widened again later.
    private(set) var original: CGImage
    /// Pixels per point of the source capture (2 on Retina displays).
    private(set) var scale: CGFloat
    let layer: AnnotationLayer

    /// The part of the original that makes up the picture, in the original's points with a top-left origin.
    /// It reaches past the original where space was added around it.
    private(set) var canvas: CGRect
    /// What fills the space added around the original.
    private(set) var canvasFill = CanvasFill.preferred
    /// The picture being annotated: the original cut to `canvas`, any added space filled in.
    private(set) var image: CGImage
    /// The picture as the picture-based tools (pixelate, blur, magnifier) see it; derived copies are built on first use.
    private(set) var backdrop: AnnotationRenderer.Backdrop
    private var sourceRevision = UUID()
    private var backdropImages: [Annotation] = []

    init(image: CGImage, scale: CGFloat, annotations: [Annotation] = [], dimsLights: Bool = false, board: Board? = nil, toolbox: AnnotationToolbox = AnnotationToolbox()) {
        original = image
        self.image = image
        let pixelScale = scale > 0 ? scale : 1
        self.scale = pixelScale
        let pointSize = CGSize(width: CGFloat(image.width) / pixelScale, height: CGFloat(image.height) / pixelScale)
        canvas = CGRect(origin: .zero, size: pointSize)
        layer = AnnotationLayer(size: pointSize, toolbox: toolbox, annotations: annotations, dimsLights: dimsLights, board: board)
        backdrop = AnnotationRenderer.Backdrop(original: image, pointSize: pointSize, scale: pixelScale)
        layer.backdrop = backdrop
        savedState = editState
    }

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
    var pointSize: CGSize { layer.size }
    var undoManager: UndoManager { layer.undoManager }

    /// The original's extent in its own points.
    var originalBounds: CGRect {
        CGRect(x: 0, y: 0, width: CGFloat(original.width) / scale, height: CGFloat(original.height) / scale)
    }

    // MARK: - Changes since the last copy or save

    /// Everything the editor can change about the picture.
    private struct EditState: Equatable {
        var sourceRevision: UUID
        var canvas: CGRect
        var fill: CanvasFill
        var annotations: [Annotation]
        var dimsLights: Bool
        var board: Board?
    }

    private var editState: EditState {
        EditState(sourceRevision: sourceRevision, canvas: canvas, fill: canvasFill, annotations: layer.annotations, dimsLights: layer.dimsLights, board: layer.board)
    }

    /// How the picture looked when it was last copied, saved, dragged or shared.
    private var savedState: EditState?

    /// Whether closing the editor would throw away work: the picture changed since it last left the app.
    var hasUnsavedChanges: Bool { editState != savedState }

    /// Call whenever the picture leaves the app, and when the editor opens with what's there already.
    func markSaved() {
        savedState = editState
    }

    // MARK: - Crop and added space

    /// Makes `rect` (in the original's points) the picture: a crop inside the original, added space around it, or both.
    /// Annotations stay where they were on the picture; any left wholly outside are dropped. One undo step.
    func setCanvas(_ rect: CGRect, fill: CanvasFill) {
        let rect = pixelAligned(rect)
        guard rect.width >= 1, rect.height >= 1, rect != canvas || fill != canvasFill,
              let picture = Self.picture(of: original, scale: scale, cutTo: rect, fill: fill)
        else { return }
        layer.commitTextEditing()
        let shift = CGPoint(x: canvas.minX - rect.minX, y: canvas.minY - rect.minY)
        let surface = CGRect(origin: .zero, size: rect.size)
        let moved = layer.annotations.map { $0.translated(by: shift) }.filter { $0.bounds.intersects(surface) }
        restore(CanvasState(original: original, scale: scale, revision: sourceRevision, dimsLights: layer.dimsLights, board: layer.board, canvas: rect, fill: fill, image: picture, annotations: moved), actionName: "Crop")
    }

    private struct CanvasState {
        var original: CGImage
        var scale: CGFloat
        var revision: UUID
        var dimsLights: Bool
        var board: Board?
        var canvas: CGRect
        var fill: CanvasFill
        var image: CGImage
        var annotations: [Annotation]
    }

    /// Swaps in a picture and its annotations, registering the way back for undo (and redo).
    private func restore(_ state: CanvasState, actionName: String) {
        let previous = CanvasState(original: original, scale: scale, revision: sourceRevision, dimsLights: layer.dimsLights, board: layer.board, canvas: canvas, fill: canvasFill, image: image, annotations: layer.annotations)
        original = state.original
        scale = state.scale
        sourceRevision = state.revision
        canvas = state.canvas
        canvasFill = state.fill
        image = state.image
        backdrop = AnnotationRenderer.Backdrop(original: state.image, pointSize: state.canvas.size, scale: scale)
        layer.backdrop = backdrop
        layer.replaceCanvas(size: state.canvas.size, annotations: state.annotations)
        layer.dimsLights = state.dimsLights
        layer.board = state.board
        backdropImages = []
        refreshBackdrop()
        undoManager.registerChange(on: self, actionName: actionName) { document in
            document.restore(previous, actionName: actionName)
        }
    }

    /// Whole pixels only, so the picture is never resampled.
    private func pixelAligned(_ rect: CGRect) -> CGRect {
        func align(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = align(rect.minX)
        let minY = align(rect.minY)
        return CGRect(x: minX, y: minY, width: align(rect.maxX) - minX, height: align(rect.maxY) - minY)
    }

    /// `original` cut to `canvas` (in points), with the space outside the original filled in.
    static func picture(of original: CGImage, scale: CGFloat, cutTo canvas: CGRect, fill: CanvasFill) -> CGImage? {
        let pixels = CGRect(
            x: (canvas.minX * scale).rounded(),
            y: (canvas.minY * scale).rounded(),
            width: (canvas.width * scale).rounded(),
            height: (canvas.height * scale).rounded()
        )
        let bounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        if pixels == bounds { return original }
        // Inside the original a plain cut will do (CGImage crops with a top-left origin).
        if bounds.contains(pixels) { return original.cropping(to: pixels) }

        guard let context = AnnotationRenderer.rgbContext(width: Int(pixels.width), height: Int(pixels.height), like: original) else { return nil }
        if let color = fill.cgColor {
            context.setFillColor(color)
            context.fill(CGRect(origin: .zero, size: pixels.size))
        }
        // Core Graphics is y-up: the original's top edge sits `pixels.minY` below the canvas's top edge.
        context.interpolationQuality = .none
        context.draw(original, in: CGRect(x: -pixels.minX, y: pixels.height + pixels.minY - CGFloat(original.height), width: CGFloat(original.width), height: CGFloat(original.height)))
        return context.makeImage()
    }

    /// Rebuild picture-based effects when an embedded image moves or changes size.
    func refreshBackdrop() {
        let images = layer.annotations.filter { $0.imagePNG != nil }
        guard images != backdropImages else { return }
        backdropImages = images
        let composed = AnnotationRenderer.flatten(images, onto: image, scale: scale) ?? image
        backdrop = AnnotationRenderer.Backdrop(original: composed, pointSize: pointSize, scale: scale)
        layer.backdrop = backdrop
    }

    enum ImagePlacement: String, CaseIterable, Identifiable {
        case inset, right, below
        var id: String { rawValue }
        var title: String {
            switch self {
            case .inset: String(localized: "Inset")
            case .right: String(localized: "To the Right")
            case .below: String(localized: "Below")
            }
        }
    }

    /// Each image remains independently movable and resizable. Added space and image insertion undo together.
    func insertImage(_ picture: CGImage, sourceScale: CGFloat, placement: ImagePlacement) throws {
        layer.commitTextEditing()
        let natural = CGSize(width: CGFloat(picture.width) / max(0.25, sourceScale), height: CGFloat(picture.height) / max(0.25, sourceScale))
        let gap: CGFloat = 16
        var frame = CGRect(origin: .zero, size: natural)
        var newCanvas = canvas
        switch placement {
        case .inset:
            let fit = min(1, pointSize.width * 0.45 / natural.width, pointSize.height * 0.45 / natural.height)
            frame.size = CGSize(width: natural.width * fit, height: natural.height * fit)
            frame.origin = CGPoint(x: max(0, pointSize.width - frame.width - gap), y: max(0, pointSize.height - frame.height - gap))
        case .right:
            frame.origin.x = pointSize.width + gap
            newCanvas.size = CGSize(width: frame.maxX, height: max(pointSize.height, frame.height))
        case .below:
            frame.origin.y = pointSize.height + gap
            newCanvas.size = CGSize(width: max(pointSize.width, frame.width), height: frame.maxY)
        }
        try validateSize(newCanvas.size)
        guard let png = imageData(from: picture, format: .png), let base = Self.picture(of: original, scale: scale, cutTo: newCanvas, fill: canvasFill) else { throw WorkspaceError.invalidImage }
        var annotation = Annotation(shape: .rectangle(frame), color: layer.toolbox.resolvedColor, lineWidth: layer.toolbox.lineWidth)
        annotation.imagePNG = png
        restore(CanvasState(original: original, scale: scale, revision: sourceRevision, dimsLights: layer.dimsLights, board: layer.board, canvas: newCanvas, fill: canvasFill, image: base, annotations: layer.annotations + [annotation]), actionName: "Add Image")
        layer.select([annotation.id])
        layer.toolbox.tool = .select
    }

    /// Coordinates remain in points; a different-sized replacement keeps the old crop where possible.
    func replaceBackground(with picture: CGImage, scale newScale: CGFloat) throws {
        guard newScale.isFinite, (0.25...8).contains(newScale) else { throw WorkspaceError.invalidImage }
        layer.commitTextEditing()
        let size = CGSize(width: CGFloat(picture.width) / newScale, height: CGFloat(picture.height) / newScale)
        let wasUncropped = canvas == originalBounds
        let target = wasUncropped ? CGRect(origin: .zero, size: size) : canvas
        guard target.width * newScale <= 32768, target.height * newScale <= 32768,
              target.width * target.height * newScale * newScale <= 100_000_000,
              let base = Self.picture(of: picture, scale: newScale, cutTo: target, fill: canvasFill) else { throw WorkspaceError.imageTooLarge }
        restore(CanvasState(original: picture, scale: newScale, revision: UUID(), dimsLights: layer.dimsLights, board: layer.board, canvas: target, fill: canvasFill, image: base, annotations: layer.annotations), actionName: "Replace Screenshot")
    }

    private func validateSize(_ size: CGSize) throws {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width * scale <= 32768, size.height * scale <= 32768,
              size.width * size.height * scale * scale <= 100_000_000 else { throw WorkspaceError.imageTooLarge }
    }

    enum CutAxis: String, CaseIterable, Identifiable {
        case horizontal, vertical
        var id: String { rawValue }
        var title: String { self == .horizontal ? String(localized: "Rows") : String(localized: "Columns") }
    }

    /// Remove a full-width or full-height band. Flattening preserves clipped annotations and redactions exactly.
    /// The original state, including editable annotations, remains available through undo.
    func removeSection(from: CGFloat, to: CGFloat, axis: CutAxis) throws {
        layer.commitTextEditing()
        let lower = (min(from, to) * scale).rounded()
        let upper = (max(from, to) * scale).rounded()
        let limit = CGFloat(axis == .horizontal ? image.height : image.width)
        guard lower >= 1, upper < limit, upper - lower >= 1,
              let source = flattenedImage() else { throw WorkspaceError.invalidImage }
        let removed = upper - lower
        let width = source.width - (axis == .vertical ? Int(removed) : 0)
        let height = source.height - (axis == .horizontal ? Int(removed) : 0)
        guard let context = AnnotationRenderer.rgbContext(width: width, height: height, like: source) else { throw WorkspaceError.imageTooLarge }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        func piece(_ rect: CGRect, at origin: CGPoint) {
            guard let part = source.cropping(to: rect) else { return }
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y + rect.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(part, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        if axis == .horizontal {
            piece(CGRect(x: 0, y: 0, width: source.width, height: Int(lower)), at: .zero)
            piece(CGRect(x: 0, y: upper, width: CGFloat(source.width), height: CGFloat(source.height) - upper), at: CGPoint(x: 0, y: lower))
        } else {
            piece(CGRect(x: 0, y: 0, width: Int(lower), height: source.height), at: .zero)
            piece(CGRect(x: upper, y: 0, width: CGFloat(source.width) - upper, height: CGFloat(source.height)), at: CGPoint(x: lower, y: 0))
        }
        // A visible dashed seam makes the omitted content explicit.
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(4 * scale)
        let a = axis == .horizontal ? CGPoint(x: 0, y: lower) : CGPoint(x: lower, y: 0)
        let b = axis == .horizontal ? CGPoint(x: width, y: Int(lower)) : CGPoint(x: Int(lower), y: height)
        context.move(to: a); context.addLine(to: b); context.strokePath()
        context.setStrokeColor(CGColor(gray: 0.25, alpha: 1))
        context.setLineWidth(scale)
        context.setLineDash(phase: 0, lengths: [6 * scale, 4 * scale])
        context.move(to: a); context.addLine(to: b); context.strokePath()
        guard let result = context.makeImage() else { throw WorkspaceError.invalidImage }
        let size = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        restore(CanvasState(original: result, scale: scale, revision: UUID(), dimsLights: false, board: nil, canvas: CGRect(origin: .zero, size: size), fill: canvasFill, image: result, annotations: []), actionName: "Remove Section")
    }

    // MARK: - Export

    /// The capture with all annotations burned in, at the capture's native pixel size.
    func flattenedImage() -> CGImage? {
        refreshBackdrop()
        return AnnotationRenderer.flatten(layer.annotations, onto: image, scale: scale, backdrop: backdrop, dimsLights: layer.dimsLights, board: layer.board)
    }

    /// Bytes of `flattenedImage()` in `format`, tagged with the capture's DPI so Retina shots open at true size.
    func imageData(format: ExportFormat) -> Data? {
        guard let flattened = flattenedImage() else { return nil }
        return imageData(from: flattened, format: format)
    }

    func pngData() -> Data? { imageData(format: .png) }

    func pngData(from flattened: CGImage) -> Data? { imageData(from: flattened, format: .png) }

    func imageData(from flattened: CGImage, format: ExportFormat) -> Data? {
        let source: CGImage
        switch format {
        case .png:
            source = flattened
        case .jpeg:
            guard let opaque = Self.opaqueCopy(of: flattened) else { return nil }
            source = opaque
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, format.utType.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        }
        CGImageDestinationAddImage(destination, source, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// JPEG has no transparency: anything see-through (the area around a window's shadow, say) lands on white.
    private static func opaqueCopy(of image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst: return image
        default: break
        }
        let colorSpace = AnnotationRenderer.rgbColorSpace(of: image)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// Mirrors the system's own "Screenshot 2026-10-22 at 09.41.07.png" naming.
    static func suggestedFileName(format: ExportFormat = .png, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).\(format.fileExtension)"
    }

    /// Writes the annotated capture to the temporary folder, for shares that need a file.
    func writeTemporaryFile(format: ExportFormat = .png) -> URL? {
        guard let data = imageData(format: format) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.suggestedFileName(format: format))
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A drag payload that other apps receive as a PNG file (Finder, Mail, Slack) or as image data.
    func dragItemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let name = Self.suggestedFileName()
        provider.suggestedName = name
        guard let png = pngData() else { return provider }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? png.write(to: url, options: .atomic)
        // Only a drop counts as handing the picture over; a drag let go of over nothing asks for neither.
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            Task { @MainActor in self.markSaved() }
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(png, nil)
            Task { @MainActor in self.markSaved() }
            return nil
        }
        return provider
    }
}

/// The file formats a capture can be saved as.
enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case png, jpeg

    static let defaultsKey = "saveFormat"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: String(localized: "PNG")
        case .jpeg: String(localized: "JPEG")
        }
    }

    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    /// The format chosen in Settings, or last used in the save panel; PNG until changed.
    static var preferred: ExportFormat {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(ExportFormat.init(rawValue:)) ?? .png }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// What fills the space added around a capture.
enum CanvasFill: String, CaseIterable, Identifiable, Codable {
    case white, black, transparent

    static let defaultsKey = "canvasFill"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: String(localized: "White")
        case .black: String(localized: "Black")
        case .transparent: String(localized: "Transparent")
        }
    }

    /// nil leaves the space see-through (JPEG turns it white).
    var cgColor: CGColor? {
        switch self {
        case .white: CGColor(gray: 1, alpha: 1)
        case .black: CGColor(gray: 0, alpha: 1)
        case .transparent: nil
        }
    }

    /// The fill used last; white until changed.
    static var preferred: CanvasFill {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(CanvasFill.init(rawValue:)) ?? .white }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// The annotated capture as a PNG file, produced only when a share actually happens.
nonisolated struct SharedScreenshot: Transferable {
    let document: AnnotationDocument

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { item in
            let url = try await MainActor.run { () throws -> URL in
                guard let url = item.document.writeTemporaryFile(format: .png) else { throw CocoaError(.fileWriteUnknown) }
                item.document.markSaved()
                return url
            }
            return SentTransferredFile(url, allowAccessingOriginalFile: false)
        }
    }
}
