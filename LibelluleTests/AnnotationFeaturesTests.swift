import AppKit
import SwiftUI
import Testing
@testable import Libellule

@Suite(.serialized)
struct AnnotationFeaturesTests {
    private func image(width: Int = 200, height: Int = 120, color: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func rect(_ x: CGFloat, _ y: CGFloat = 20) -> Annotation {
        Annotation(shape: .rectangle(CGRect(x: x, y: y, width: 30, height: 20)), color: .init(red: 1, green: 0, blue: 0), lineWidth: 2)
    }

    private func drag(_ layer: AnnotationLayer, from: CGPoint, to: CGPoint) {
        layer.updateDrag(from: from, to: from, constrained: false)
        layer.updateDrag(from: from, to: to, constrained: false)
        layer.endDrag()
    }

    @Test func calloutLabelMovesWithoutMovingItsTargetAndRemainsEditable() throws {
        let layer = AnnotationLayer(size: CGSize(width: 500, height: 300))
        layer.toolbox.tool = .callout
        layer.toolbox.arrowStyle = .elbow
        drag(layer, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 180, y: 120))
        layer.textEditing?.text = "Click here"
        layer.commitTextEditing()
        let callout = try #require(layer.annotations.first)
        #expect(callout.calloutTarget == CGPoint(x: 30, y: 30))
        #expect(callout.arrowStyle == .elbow)
        #expect(callout.connectorGeometry?.shaft.isEmpty == false)
        layer.select([callout.id])
        layer.nudgeSelection(by: CGPoint(x: 30, y: 10))
        #expect(layer.annotations[0].calloutTarget == callout.calloutTarget)
        #expect(layer.annotations[0].textBox?.minX == callout.textBox!.minX + 30)
        layer.editSelectedText()
        layer.textEditing?.text = "Updated"
        layer.commitTextEditing()
        #expect(layer.annotations[0].calloutTarget == callout.calloutTarget)
        #expect(layer.annotations[0].arrowStyle == .elbow)
        layer.undoManager.undo()
        #expect(layer.annotations[0].textBox == callout.movedForSelection(by: CGPoint(x: 30, y: 10)).textBox)
    }

    @Test func calloutTargetHandleAndCropTranslateCorrectly() throws {
        var callout = Annotation(shape: .text("Target", origin: CGPoint(x: 80, y: 60)), color: .init(red: 1, green: 0, blue: 0), lineWidth: 2)
        callout.calloutTarget = CGPoint(x: 20, y: 20)
        let document = AnnotationDocument(image: image(), scale: 1, annotations: [callout])
        document.layer.toolbox.tool = .select
        document.layer.select([callout.id])
        drag(document.layer, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 35, y: 35))
        #expect(document.layer.annotations[0].calloutTarget == CGPoint(x: 35, y: 35))
        document.setCanvas(CGRect(x: -10, y: -10, width: 230, height: 140), fill: .white)
        #expect(document.layer.annotations[0].calloutTarget == CGPoint(x: 45, y: 45))
        document.undoManager.undo()
        #expect(document.layer.annotations[0].calloutTarget == CGPoint(x: 35, y: 35))
    }

    @Test func eachArrowStyleHasAVisibleShaftAndHead() {
        for style in ArrowStyle.allCases {
            let geometry = Annotation.connector(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 160, y: 90), style: style, lineWidth: 4)
            #expect(!geometry.shaft.isEmpty)
            #expect(!geometry.head.isEmpty)
            #expect(geometry.head.boundingRect.insetBy(dx: -0.1, dy: -0.1).contains(CGPoint(x: 160, y: 90)))
        }
    }

    @Test func liveArrowStyleAppliesToNewArrowsAndCallouts() throws {
        let toolbox = AnnotationToolbox()
        let session = LiveAnnotationSession(toolbox: toolbox)
        let layer = AnnotationLayer(size: CGSize(width: 500, height: 300), toolbox: toolbox)
        session.setArrowStyle(.elbow)
        toolbox.tool = .arrow
        drag(layer, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 150, y: 90))
        let arrow = try #require(layer.annotations.first)
        #expect(arrow.arrowStyle == .elbow)
        #expect(session.arrowStyle == .elbow)
        layer.select([arrow.id])
        layer.setArrowStyle(.curved)
        #expect(layer.annotations[0].arrowStyle == .curved)
        layer.undoManager.undo()
        #expect(layer.annotations[0].arrowStyle == .elbow)
        toolbox.tool = .callout
        drag(layer, from: CGPoint(x: 30, y: 140), to: CGPoint(x: 200, y: 190))
        layer.textEditing?.text = "Details"
        layer.commitTextEditing()
        #expect(layer.annotations.last?.arrowStyle == .curved)
    }

    @Test func groupsSelectTogetherAndDuplicatesGetIndependentGroups() throws {
        let a = rect(10), b = rect(70), c = rect(150)
        let layer = AnnotationLayer(size: CGSize(width: 400, height: 300), annotations: [a, b, c])
        layer.select([a.id, b.id])
        layer.groupSelection()
        let group = try #require(layer.annotations[0].groupID)
        #expect(layer.annotations[1].groupID == group)
        layer.select([a.id])
        #expect(layer.selectedIDs == [a.id, b.id])
        layer.duplicateSelection()
        let copies = layer.selectedAnnotations
        #expect(copies.count == 2)
        #expect(copies[0].groupID != group)
        #expect(copies[0].groupID == copies[1].groupID)
        layer.ungroupSelection()
        #expect(layer.selectedAnnotations.allSatisfy { $0.groupID == nil })
        layer.undoManager.undo()
        #expect(layer.selectedAnnotations.allSatisfy { $0.groupID != nil })
    }

    @Test func locksProtectFromMovementEditingDeletionAndEraser() {
        let a = rect(10)
        let layer = AnnotationLayer(size: CGSize(width: 400, height: 300), annotations: [a])
        layer.select([a.id])
        layer.toggleSelectionLock()
        let locked = layer.annotations
        layer.nudgeSelection(by: CGPoint(x: 20, y: 20))
        layer.restyleSelection(lineWidth: 8)
        layer.deleteSelection()
        layer.toolbox.tool = .eraser
        drag(layer, from: CGPoint(x: 10, y: 20), to: CGPoint(x: 40, y: 20))
        #expect(layer.annotations == locked)
        layer.unlockAll()
        layer.select([a.id])
        layer.deleteSelection()
        #expect(layer.annotations.isEmpty)
    }

    @Test func alignmentDistributionAndStackingUndo() {
        let a = rect(10, 10), b = rect(90, 35), c = rect(230, 70)
        let layer = AnnotationLayer(size: CGSize(width: 400, height: 300), annotations: [a, b, c])
        layer.selectAll()
        layer.alignSelection(.top)
        #expect(Set(layer.annotations.map { $0.bounds.minY }).count == 1)
        layer.distributeSelection(horizontal: true)
        let boxes = layer.annotations.map(\.bounds)
        #expect(abs((boxes[1].minX - boxes[0].maxX) - (boxes[2].minX - boxes[1].maxX)) < 0.01)
        layer.select([a.id])
        layer.arrangeSelection(front: true)
        #expect(layer.annotations.last?.id == a.id)
        layer.undoManager.undo()
        #expect(layer.annotations.first?.id == a.id)
    }

    @Test func arrangingGroupsPreservesTheirInternalSpacing() {
        let a = rect(10, 10), b = rect(60, 30), c = rect(150, 90)
        let layer = AnnotationLayer(size: CGSize(width: 400, height: 300), annotations: [a, b, c])
        layer.select([a.id, b.id])
        layer.groupSelection()
        layer.selectAll()
        layer.alignSelection(.bottom)
        #expect(layer.annotations[1].bounds.minX - layer.annotations[0].bounds.minX == 50)
        #expect(layer.annotations[1].bounds.minY - layer.annotations[0].bounds.minY == 20)
        #expect(layer.annotations[1].bounds.maxY == layer.annotations[2].bounds.maxY)
    }

    @Test func snappingShowsGuidesAndCanBeDisabledForExactMovement() {
        let a = rect(10, 20), b = rect(100, 90)
        let layer = AnnotationLayer(size: CGSize(width: 400, height: 300), annotations: [a, b])
        layer.toolbox.tool = .select
        layer.select([a.id])
        layer.updateDrag(from: CGPoint(x: 10, y: 25), to: CGPoint(x: 10, y: 25), constrained: false)
        layer.updateDrag(from: CGPoint(x: 10, y: 25), to: CGPoint(x: 97, y: 40), constrained: false)
        #expect(!layer.alignmentGuides.isEmpty)
        #expect(layer.annotations[0].bounds.minX == b.bounds.minX)
        layer.endDrag()
        #expect(layer.alignmentGuides.isEmpty)
        layer.undoManager.undo()
        layer.snapsToAnnotations = false
        drag(layer, from: CGPoint(x: 10, y: 25), to: CGPoint(x: 97, y: 40))
        #expect(layer.annotations[0].bounds.minX == a.bounds.minX + 87)
    }

    @Test func compositionKeepsImagesMovableAndRedactionsAboveThem() throws {
        let document = AnnotationDocument(image: image(), scale: 1)
        document.layer.addRedactions([CGRect(x: 20, y: 20, width: 60, height: 60)], style: .blackout)
        try document.insertImage(image(width: 60, height: 60, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)), sourceScale: 1, placement: .inset)
        let inserted = try #require(document.layer.selectedAnnotation)
        #expect(inserted.imagePNG != nil)
        document.layer.nudgeSelection(by: CGPoint(x: 30 - inserted.bounds.minX, y: 30 - inserted.bounds.minY))
        let output = try #require(document.flattenedImage())
        let pixels = try ScreenshotPixels.rgba(output)
        let offset = (40 * output.width + 40) * 4
        #expect(Array(pixels[offset..<offset + 3]) == [0, 0, 0])
        let archive = try JSONDecoder().decode(ProjectArchive.self, from: JSONEncoder().encode(ProjectArchive(document: document)))
        let reopened = try archive.document()
        #expect(reopened.layer.annotations == document.layer.annotations)
        #expect(try ScreenshotPixels.rgba(reopened.flattenedImage()!) == pixels)
    }

    @Test func addedCanvasAndImagesUndoAsOneOperation() throws {
        let document = AnnotationDocument(image: image(), scale: 2)
        let size = document.pointSize
        try document.insertImage(image(width: 80, height: 60), sourceScale: 2, placement: .right)
        #expect(document.pointSize.width == size.width + 16 + 40)
        #expect(document.layer.annotations.count == 1)
        document.undoManager.undo()
        #expect(document.pointSize == size)
        #expect(document.layer.annotations.isEmpty)
        document.undoManager.redo()
        #expect(document.layer.annotations.count == 1)
    }

    @Test func replacingBackgroundPreservesAnnotationsAndDirtyStateUndo() throws {
        let original = image()
        let document = AnnotationDocument(image: original, scale: 1, annotations: [rect(20)])
        let annotations = document.layer.annotations
        try document.replaceBackground(with: image(width: 600, height: 400), scale: 2)
        #expect(document.pointSize == CGSize(width: 300, height: 200))
        #expect(document.layer.annotations == annotations)
        #expect(document.hasUnsavedChanges)
        document.undoManager.undo()
        #expect(document.original === original)
        #expect(document.scale == 1)
        #expect(!document.hasUnsavedChanges)
        document.undoManager.redo()
        #expect(document.scale == 2)
    }

    @Test func removingRowsOrColumnsPreservesVisibleRedactionsAndUndoes() throws {
        for axis in AnnotationDocument.CutAxis.allCases {
            let document = AnnotationDocument(image: image(), scale: 1, dimsLights: true)
            document.layer.addRedactions([CGRect(x: 10, y: 10, width: 20, height: 15)], style: .blackout)
            let before = try #require(document.flattenedImage())
            let annotations = document.layer.annotations
            Attachment.record(document.pngData()!, named: "before-\(axis.rawValue).png")
            try document.removeSection(from: 40, to: 70, axis: axis)
            #expect(document.image.width == (axis == .horizontal ? 200 : 170))
            #expect(document.image.height == (axis == .horizontal ? 90 : 120))
            #expect(!document.layer.dimsLights)
            #expect(document.layer.annotations.isEmpty)
            Attachment.record(document.pngData()!, named: "after-\(axis.rawValue).png")
            let pixels = try ScreenshotPixels.rgba(document.image)
            let offset = (15 * document.image.width + 15) * 4
            #expect(Array(pixels[offset..<offset + 3]) == [0, 0, 0])
            document.undoManager.undo()
            #expect(document.layer.dimsLights)
            #expect(document.layer.annotations == annotations)
            #expect(try ScreenshotPixels.rgba(document.flattenedImage()!) == ScreenshotPixels.rgba(before))
        }
    }

    @Test func textMarkupMatchesWholeWordsAndCombinesSelectedRuns() {
        let words = [
            RecognizedWord(text: "Token", rect: CGRect(x: 10, y: 10, width: 30, height: 12), line: 0),
            RecognizedWord(text: "value", rect: CGRect(x: 44, y: 10, width: 30, height: 12), line: 0),
            RecognizedWord(text: "token", rect: CGRect(x: 10, y: 40, width: 30, height: 12), line: 1),
            RecognizedWord(text: "tokenized", rect: CGRect(x: 10, y: 70, width: 60, height: 12), line: 2),
        ]
        let layer = AnnotationLayer(size: CGSize(width: 200, height: 120))
        TextMarkup.apply(.highlight, words: words, selected: [words[0].id, words[1].id], layer: layer)
        #expect(layer.annotations.count == 1)
        layer.undoManager.undo()
        TextMarkup.apply(.redactMatches, words: words, selected: [words[0].id], layer: layer)
        #expect(layer.annotations.count == 2)
        #expect(layer.isRedacted(words[0].rect))
        #expect(layer.isRedacted(words[2].rect))
        #expect(!layer.isRedacted(words[3].rect))
        layer.undoManager.undo()
        #expect(layer.annotations.isEmpty)
    }

    @Test func onDeviceWordBoxesFollowTextAndRedactionHidesEveryOccurrence() async throws {
        var first = Annotation(shape: .text("Customer token", origin: CGPoint(x: 30, y: 30)), color: .init(red: 0, green: 0, blue: 0), lineWidth: 4)
        first.text.fontSize = 32
        var second = first
        second.id = UUID()
        second.shape = .text("token value", origin: CGPoint(x: 30, y: 110))
        let original = image(width: 600, height: 220)
        let source = try #require(AnnotationRenderer.flatten([first, second], onto: original, scale: 1))
        let document = AnnotationDocument(image: source, scale: 1)
        let words = try await TextMarkup.words(in: source, size: document.pointSize)
        let tokens = words.filter { $0.text.lowercased() == "token" }
        #expect(tokens.count == 2)
        let token = try #require(tokens.first)
        #expect(token.rect.minY >= 25 && token.rect.maxY <= 150)
        #expect(token.rect.width > 20 && token.rect.height > 10)
        TextMarkup.apply(.redactMatches, words: words, selected: [token.id], layer: document.layer)
        #expect(tokens.allSatisfy { document.layer.isRedacted($0.rect) })
        let redacted = try #require(document.flattenedImage())
        let visibleWords = try await TextMarkup.words(in: redacted, size: document.pointSize)
        #expect(!visibleWords.contains { $0.text.lowercased() == "token" })
        #expect(visibleWords.contains { $0.text.lowercased() == "customer" })
    }

    @Test func savedStylesRetainFormattingWithoutRetainingImageOrGrouping() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = AnnotationDocument(image: image(), scale: 1)
        document.layer.insertStamp("Expected")
        document.layer.adjustTextSize(by: 8)
        document.layer.setArrowStyle(.curved)
        let store = AnnotationStyleStore(defaults: defaults)
        store.save(name: "Review", layer: document.layer)
        let restored = AnnotationStyleStore(defaults: defaults)
        let style = try #require(restored.presets.first)
        #expect(style.sample.groupID == nil)
        #expect(style.sample.imagePNG == nil)
        #expect(style.sample.arrowStyle == .curved)
        document.layer.insertStamp("Actual")
        document.layer.applyStyle(style)
        #expect(document.layer.selectedAnnotation?.text == style.sample.text)
    }

    @Test func legacyProjectsWithoutNewFieldsStillOpen() throws {
        let document = AnnotationDocument(image: image(), scale: 1, annotations: [rect(10)])
        let data = try JSONEncoder().encode(ProjectArchive(document: document))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 1
        var annotations = try #require(json["annotations"] as? [[String: Any]])
        for key in ["arrowStyle", "curveDegrees", "calloutTarget", "groupID", "isLocked", "imagePNG"] { annotations[0].removeValue(forKey: key) }
        json["annotations"] = annotations
        let old = try JSONSerialization.data(withJSONObject: json)
        let opened = try JSONDecoder().decode(ProjectArchive.self, from: old).document()
        #expect(opened.layer.annotations == document.layer.annotations)
    }
}
