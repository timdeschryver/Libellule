#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let libelluleProject = UTType(exportedAs: "dev.libellule.project", conformingTo: .data)
}

/// Explicit project saves retain the source pixels. Ordinary exports and history never use this format.
struct ProjectArchive: Codable {
    var version = 1
    var originalPNG: Data
    var scale: CGFloat
    var canvas: CGRect
    var fill: CanvasFill
    var annotations: [Annotation]
    var dimsLights: Bool
    var board: Board?

    init(document: AnnotationDocument) throws {
        document.layer.commitTextEditing()
        guard let png = document.imageData(from: document.original, format: .png) else { throw CocoaError(.fileWriteUnknown) }
        originalPNG = png
        scale = document.scale
        canvas = document.canvas
        fill = document.canvasFill
        annotations = document.layer.annotations
        dimsLights = document.layer.dimsLights
        board = document.layer.board
    }

    func document() throws -> AnnotationDocument {
        guard version == 1, scale.isFinite, (0.25...8).contains(scale),
              [canvas.minX, canvas.minY, canvas.maxX, canvas.maxY, canvas.width, canvas.height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              canvas.width >= 1, canvas.height >= 1,
              canvas.width * scale <= 32_768, canvas.height * scale <= 32_768,
              canvas.width * canvas.height * scale * scale <= 100_000_000,
              annotations.count <= 100_000, annotations.allSatisfy(\.isValidForProject),
              board.map({ $0.opacity.isFinite && (0...1).contains($0.opacity) }) ?? true
        else { throw CocoaError(.fileReadCorruptFile) }
        let image = try ImageImport.read(originalPNG).image
        let document = AnnotationDocument(image: image, scale: scale, toolbox: AnnotationToolbox(context: .editor))
        document.setCanvas(canvas, fill: fill)
        document.layer.replaceCanvas(size: canvas.size, annotations: annotations)
        document.layer.dimsLights = dimsLights
        document.layer.board = board
        document.undoManager.removeAllActions()
        document.markSaved()
        return document
    }
}

private extension Annotation {
    var isValidForProject: Bool {
        func point(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite && abs(p.x) <= 1_000_000 && abs(p.y) <= 1_000_000 }
        func rect(_ r: CGRect) -> Bool { point(r.origin) && r.width.isFinite && r.height.isFinite && (0...1_000_000).contains(r.width) && (0...1_000_000).contains(r.height) }
        guard lineWidth.isFinite, (0.1...100).contains(lineWidth),
              [color.linearRed, color.linearGreen, color.linearBlue, color.opacity].allSatisfy({ $0.isFinite && abs($0) <= 100 }),
              text.fontSize.map({ $0.isFinite && (1...1_000).contains($0) }) ?? true,
              text.width.map({ $0.isFinite && (1...1_000_000).contains($0) }) ?? true else { return false }
        switch shape {
        case .line(let a, let b), .arrow(let a, let b), .measure(let a, let b), .magnifier(let a, let b): return point(a) && point(b)
        case .rectangle(let r), .ellipse(let r), .spotlight(let r), .blackout(let r), .pixelate(let r), .blur(let r): return rect(r)
        case .freehand(let points), .highlight(let points): return points.count <= 1_000_000 && points.allSatisfy(point)
        case .text(let string, let origin): return string.count <= 1_000_000 && point(origin)
        case .badge(_, let center): return point(center)
        }
    }
}

extension AnnotationDocument {
    func saveProject(attachedTo window: NSWindow?) {
        layer.commitTextEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.libelluleProject]
        panel.nameFieldStringValue = "Screenshot.libellule"
        panel.canCreateDirectories = true
        panel.message = String(localized: "Editable projects include the original image, including pixels hidden by redactions. Share a PNG or JPEG to share only the visible result.")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try JSONEncoder().encode(ProjectArchive(document: self)).write(to: url, options: .atomic)
                self.markSaved()
            } catch {
                WorkspaceCoordinator.shared.present(error)
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}
#endif
