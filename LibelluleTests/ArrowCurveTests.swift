import CoreGraphics
import SwiftUI
import Testing
@testable import Libellule

struct ArrowCurveTests {
    private let start = CGPoint(x: 40, y: 100)
    private let end = CGPoint(x: 240, y: 100)

    private func layer(tool: AnnotationTool = .arrow, annotations: [Annotation] = []) -> AnnotationLayer {
        let layer = AnnotationLayer(size: CGSize(width: 500, height: 400), annotations: annotations)
        layer.toolbox.tool = tool
        return layer
    }

    private func arrow(degrees: CGFloat = 0, style: ArrowStyle = .curved) -> Annotation {
        var arrow = Annotation(shape: .arrow(from: start, to: end), color: .init(red: 1, green: 0, blue: 0), lineWidth: 4)
        arrow.arrowStyle = style
        arrow.curveDegrees = degrees
        return arrow
    }

    private func picture() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 500, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 400))
        return try #require(context.makeImage())
    }

    @Test func commandBendsANewArrowWithoutMovingItsEndpointsAndUndoesInOneStep() throws {
        let layer = layer()
        layer.updateDrag(from: start, to: start, constrained: false)
        layer.updateDrag(from: start, to: end, constrained: false)
        layer.updateDrag(from: start, to: CGPoint(x: 240, y: 150), constrained: false, commandHeld: true)
        let progress = try #require(layer.inProgress)
        #expect(progress.shape == .arrow(from: start, to: end))
        #expect(progress.arrowStyle == .curved)
        #expect(abs(progress.curveDegrees - 90) < 0.001)
        layer.updateDrag(from: start, to: CGPoint(x: 240, y: 50), constrained: false, commandHeld: true)
        layer.endDrag()
        #expect(layer.annotations.count == 1)
        #expect(layer.annotations[0].shape == .arrow(from: start, to: end))
        #expect(abs(layer.annotations[0].curveDegrees + 90) < 0.001)
        layer.undoManager.undo()
        #expect(layer.annotations.isEmpty)
        layer.undoManager.redo()
        #expect(abs(layer.annotations[0].curveDegrees + 90) < 0.001)
    }

    @Test func releasingCommandResumesEndpointPlacementWithoutLosingTheBend() throws {
        let layer = layer()
        layer.updateDrag(from: start, to: end, constrained: false)
        layer.updateDrag(from: start, to: CGPoint(x: 240, y: 150), constrained: false, commandHeld: true)
        layer.updateDrag(from: start, to: CGPoint(x: 300, y: 160), constrained: false)
        let progress = try #require(layer.inProgress)
        #expect(progress.shape == .arrow(from: start, to: CGPoint(x: 300, y: 160)))
        #expect(abs(progress.curveDegrees - 90) < 0.001)
        layer.endDrag()
        #expect(abs(layer.toolbox.curveDegrees - 90) < 0.001)
        #expect(layer.toolbox.arrowStyle == .curved)
    }

    @Test func commandFromMouseDownDoesNotFreezeATinyInitialArrow() throws {
        let layer = layer()
        layer.updateDrag(from: start, to: start, constrained: false, commandHeld: true)
        layer.updateDrag(from: start, to: CGPoint(x: 80, y: 100), constrained: false, commandHeld: true)
        layer.updateDrag(from: start, to: end, constrained: false, commandHeld: true)
        #expect(layer.inProgress?.shape == .arrow(from: start, to: end))
        layer.updateDrag(from: start, to: end, constrained: false)
        layer.updateDrag(from: start, to: CGPoint(x: 240, y: 150), constrained: false, commandHeld: true)
        #expect(layer.inProgress?.shape == .arrow(from: start, to: end))
        #expect(abs(try #require(layer.inProgress).curveDegrees - 90) < 0.001)
        layer.endDrag()
    }

    @Test func shiftSnapsCurvatureWhileEndpointsStayFixed() throws {
        let layer = layer()
        layer.updateDrag(from: start, to: end, constrained: false)
        layer.updateDrag(from: start, to: CGPoint(x: 240, y: 137), constrained: true, commandHeld: true)
        let progress = try #require(layer.inProgress)
        #expect(progress.shape == .arrow(from: start, to: end))
        #expect(progress.curveDegrees == 75)
        layer.endDrag()
    }

    @Test func commandDragBendsAnExistingStraightArrowInsteadOfMovingIt() {
        let original = arrow(style: .straight)
        let layer = layer(tool: .select, annotations: [original])
        layer.updateDrag(from: CGPoint(x: 90, y: 100), to: CGPoint(x: 90, y: 100), constrained: false, commandHeld: true)
        layer.updateDrag(from: CGPoint(x: 90, y: 100), to: CGPoint(x: 90, y: 150), constrained: false, commandHeld: true)
        layer.endDrag()
        #expect(layer.annotations[0].shape == original.shape)
        #expect(layer.annotations[0].id == original.id)
        #expect(abs(layer.annotations[0].curveDegrees - 90) < 0.001)
        layer.undoManager.undo()
        #expect(layer.annotations == [original])
    }

    @Test func theCurveHandleCanCrossTheChordAndPreservesUndoAndLocks() throws {
        var original = arrow(degrees: 90)
        let layer = layer(tool: .select, annotations: [original])
        layer.select([original.id])
        let handle = try #require(original.curveHandle)
        let moved = CGPoint(x: handle.x, y: 50)
        layer.updateDrag(from: handle, to: handle, constrained: false)
        layer.updateDrag(from: handle, to: moved, constrained: false)
        layer.endDrag()
        #expect(layer.annotations[0].shape == original.shape)
        #expect(abs(layer.annotations[0].curveDegrees + 90) < 0.001)
        layer.undoManager.undo()
        #expect(layer.annotations == [original])
        original.isLocked = true
        layer.replaceCanvas(size: layer.size, annotations: [original])
        layer.select([original.id])
        layer.updateDrag(from: handle, to: handle, constrained: false, commandHeld: true)
        layer.updateDrag(from: handle, to: moved, constrained: false, commandHeld: true)
        layer.endDrag()
        #expect(layer.annotations == [original])
    }

    @Test func curveAnglesRoundTripForEveryDirectionAndClampSafely() {
        let endpoints: [CGPoint] = [CGPoint(x: 240, y: 100), CGPoint(x: 40, y: 300), CGPoint(x: 250, y: 230), CGPoint(x: 10, y: 10)]
        let angles: [CGFloat] = [-150, -90, -30, 0, Annotation.defaultCurveDegrees, 90, 150]
        for end in endpoints {
            for angle in angles {
                let handle = Annotation.curveMidpoint(from: start, to: end, degrees: angle)
                #expect(abs(Annotation.curveDegrees(from: start, to: end, through: handle) - angle) < 0.0001)
                let geometry = Annotation.connector(from: start, to: end, style: .curved, lineWidth: 4, curveDegrees: angle)
                #expect(!geometry.shaft.isEmpty)
                #expect(!geometry.head.isEmpty)
                #expect(geometry.shaft.boundingRect.minX.isFinite)
            }
        }
        #expect(Annotation.clampedCurveDegrees(999) == 150)
        #expect(Annotation.clampedCurveDegrees(-999) == -150)
        #expect(Annotation.clampedCurveDegrees(.nan) == Annotation.defaultCurveDegrees)
        #expect(Annotation.curveDegrees(from: start, to: start, through: end) == 0)
    }

    @Test func calloutBendsSurviveTextEditingAndExportedProjects() throws {
        var callout = Annotation(shape: .text("Details", origin: CGPoint(x: 260, y: 160)), color: .init(red: 1, green: 0, blue: 0), lineWidth: 4)
        callout.calloutTarget = start
        callout.arrowStyle = .curved
        callout.curveDegrees = -112.5
        let document = AnnotationDocument(image: try picture(), scale: 1, annotations: [callout])
        document.layer.select([callout.id])
        document.layer.editSelectedText()
        #expect(document.layer.textEditing?.curveDegrees == -112.5)
        document.layer.textEditing?.text = "More details"
        document.layer.commitTextEditing()
        #expect(document.layer.annotations[0].curveDegrees == -112.5)
        let archive = try ProjectArchive(document: document)
        #expect(archive.version == 3)
        let reopened = try JSONDecoder().decode(ProjectArchive.self, from: JSONEncoder().encode(archive)).document()
        #expect(reopened.layer.annotations == document.layer.annotations)
        #expect(try ScreenshotPixels.rgba(reopened.flattenedImage()!) == ScreenshotPixels.rgba(document.flattenedImage()!))
    }

    @Test func olderProjectsUseTheOriginalCurveAndInvalidAnglesAreRejected() throws {
        let document = AnnotationDocument(image: try picture(), scale: 1, annotations: [arrow(degrees: 90)])
        let archive = try ProjectArchive(document: document)
        let data = try JSONEncoder().encode(archive)
        for version in [1, 2] {
            var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            json["version"] = version
            var annotations = try #require(json["annotations"] as? [[String: Any]])
            annotations[0].removeValue(forKey: "curveDegrees")
            json["annotations"] = annotations
            let reopened = try JSONDecoder().decode(ProjectArchive.self, from: JSONSerialization.data(withJSONObject: json)).document()
            #expect(reopened.layer.annotations[0].curveDegrees == Annotation.defaultCurveDegrees)
        }
        for angle in [CGFloat.infinity, .nan, 151, -151] {
            var invalid = archive
            invalid.annotations[0].curveDegrees = angle
            #expect(throws: (any Error).self) { try invalid.document() }
        }
    }

    @Test func savedStylesIncludeCurvatureForSelectedAndNewArrows() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = arrow(degrees: -75)
        let layer = layer(annotations: [original])
        layer.select([original.id])
        let store = AnnotationStyleStore(defaults: defaults)
        store.save(name: "Bend", layer: layer)
        let style = try #require(AnnotationStyleStore(defaults: defaults).presets.first)
        #expect(style.sample.curveDegrees == -75)
        layer.clearSelection()
        layer.applyStyle(style)
        #expect(layer.toolbox.curveDegrees == -75)
        layer.updateDrag(from: CGPoint(x: 40, y: 250), to: CGPoint(x: 240, y: 250), constrained: false)
        layer.endDrag()
        #expect(layer.annotations.last?.curveDegrees == -75)
    }
}
