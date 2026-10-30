import SwiftUI
import CoreTransferable
import ImageIO
import UniformTypeIdentifiers

/// A captured image plus the annotation layer drawn on top of it.
@Observable
final class AnnotationDocument {
    /// The picture as captured. Every crop is cut from it afresh, so a crop can be widened again later.
    let original: CGImage
    /// Pixels per point of the source capture (2 on Retina displays).
    let scale: CGFloat
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

    init(image: CGImage, scale: CGFloat, annotations: [Annotation] = [], dimsLights: Bool = false, board: Board? = nil, toolbox: AnnotationToolbox = AnnotationToolbox()) {
        original = image
        self.image = image
        self.scale = scale > 0 ? scale : 1
        let pointSize = CGSize(width: CGFloat(image.width) / self.scale, height: CGFloat(image.height) / self.scale)
        canvas = CGRect(origin: .zero, size: pointSize)
        layer = AnnotationLayer(size: pointSize, toolbox: toolbox, annotations: annotations, dimsLights: dimsLights, board: board)
        backdrop = AnnotationRenderer.Backdrop(original: image, pointSize: pointSize, scale: self.scale)
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
        var canvas: CGRect
        var fill: CanvasFill
        var annotations: [Annotation]
        var dimsLights: Bool
        var board: Board?
    }

    private var editState: EditState {
        EditState(canvas: canvas, fill: canvasFill, annotations: layer.annotations, dimsLights: layer.dimsLights, board: layer.board)
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
        restore(CanvasState(canvas: rect, fill: fill, image: picture, annotations: moved), actionName: "Crop")
    }

    private struct CanvasState {
        var canvas: CGRect
        var fill: CanvasFill
        var image: CGImage
        var annotations: [Annotation]
    }

    /// Swaps in a picture and its annotations, registering the way back for undo (and redo).
    private func restore(_ state: CanvasState, actionName: String) {
        let previous = CanvasState(canvas: canvas, fill: canvasFill, image: image, annotations: layer.annotations)
        canvas = state.canvas
        canvasFill = state.fill
        image = state.image
        backdrop = AnnotationRenderer.Backdrop(original: state.image, pointSize: state.canvas.size, scale: scale)
        layer.backdrop = backdrop
        layer.replaceCanvas(size: state.canvas.size, annotations: state.annotations)
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

    // MARK: - Export

    /// The capture with all annotations burned in, at the capture's native pixel size.
    func flattenedImage() -> CGImage? {
        AnnotationRenderer.flatten(layer.annotations, onto: image, scale: scale, backdrop: backdrop, dimsLights: layer.dimsLights, board: layer.board)
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
