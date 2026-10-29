import CoreGraphics
import SwiftUI
import Testing
@testable import Libellule

struct AnnotationLayerTests {
    private func makeLayer(tool: AnnotationTool = .arrow) -> AnnotationLayer {
        let layer = AnnotationLayer(size: CGSize(width: 400, height: 300))
        layer.toolbox.tool = tool
        return layer
    }

    private func drag(_ layer: AnnotationLayer, from a: CGPoint, to b: CGPoint, constrained: Bool = false, optionHeld: Bool = false, extending: Bool = false) {
        layer.updateDrag(from: a, to: a, constrained: constrained, optionHeld: optionHeld, extending: extending)
        layer.updateDrag(from: a, to: b, constrained: constrained, optionHeld: optionHeld, extending: extending)
        layer.endDrag()
    }

    private func click(_ layer: AnnotationLayer, at point: CGPoint, extending: Bool = false) {
        drag(layer, from: point, to: point, extending: extending)
    }

    /// Three rectangles: two in the top-left quarter, one at the bottom-right.
    private func layerWithThreeRectangles() -> AnnotationLayer {
        let layer = makeLayer(tool: .rectangle)
        drag(layer, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))
        drag(layer, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 150, y: 150))
        drag(layer, from: CGPoint(x: 300, y: 200), to: CGPoint(x: 350, y: 250))
        layer.toolbox.tool = .select
        return layer
    }

    private func badgeNumbers(_ layer: AnnotationLayer) -> [Int] {
        layer.annotations.compactMap { if case .badge(let number, _) = $0.shape { number } else { nil } }
    }

    @Test func marqueeAndShiftClickBuildASelection() {
        let layer = layerWithThreeRectangles()
        #expect(layer.annotations.count == 3)

        drag(layer, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 200))
        #expect(layer.selectedIDs.count == 2)
        #expect(layer.selectedAnnotation == nil)  // more than one

        click(layer, at: CGPoint(x: 300, y: 225), extending: true)  // on the third one's left edge
        #expect(layer.selectedIDs.count == 3)

        click(layer, at: CGPoint(x: 300, y: 225), extending: true)  // ⇧-click again takes it out
        #expect(layer.selectedIDs.count == 2)

        layer.selectAll()
        #expect(layer.selectedIDs.count == 3)
        layer.clearSelection()
        #expect(!layer.hasSelection)
    }

    @Test func movingNudgingAndDeletingActOnTheWholeSelection() {
        let layer = layerWithThreeRectangles()
        layer.selectAll()
        let before = layer.annotations.map(\.bounds)

        drag(layer, from: CGPoint(x: 10, y: 30), to: CGPoint(x: 20, y: 45))  // grab the first one's edge
        for (old, new) in zip(before, layer.annotations.map(\.bounds)) {
            #expect(new.minX == old.minX + 10)
            #expect(new.minY == old.minY + 15)
        }

        layer.nudgeSelection(by: CGPoint(x: -10, y: -15))
        #expect(layer.annotations.map(\.bounds) == before)

        layer.deleteSelection()
        #expect(layer.annotations.isEmpty)
        layer.undoManager.undo()
        #expect(layer.annotations.count == 3)
    }

    @Test func eraserSweepsInOneUndoStep() {
        let layer = layerWithThreeRectangles()
        layer.toolbox.tool = .eraser
        // Across the first rectangle only: the second sits lower, the third far right.
        drag(layer, from: CGPoint(x: 0, y: 30), to: CGPoint(x: 80, y: 30))
        #expect(layer.annotations.count == 2)
        layer.undoManager.undo()
        #expect(layer.annotations.count == 3)
    }

    @Test func copyPasteAndDuplicateTakeFreshStepNumbers() {
        let layer = makeLayer(tool: .badge)
        click(layer, at: CGPoint(x: 20, y: 20))
        click(layer, at: CGPoint(x: 60, y: 20))
        #expect(badgeNumbers(layer) == [1, 2])

        layer.selectAll()
        #expect(layer.copySelection())
        layer.paste(at: CGPoint(x: 200, y: 200))
        #expect(badgeNumbers(layer) == [1, 2, 3, 4])
        #expect(layer.selectedIDs.count == 2)
        let pasted = layer.selectedAnnotations.map(\.bounds)
        #expect(abs(((pasted[0].midX + pasted[1].midX) / 2) - 200) < 1)

        layer.duplicateSelection()
        #expect(badgeNumbers(layer) == [1, 2, 3, 4, 5, 6])
        #expect(layer.annotations.count == 6)

        layer.cutSelection()
        #expect(layer.annotations.count == 4)
        #expect(AnnotationClipboard.shared.annotations.count == 2)
    }

    @Test func stepNumbersCanStartAgainAtOne() {
        let layer = makeLayer(tool: .badge)
        click(layer, at: CGPoint(x: 20, y: 20))
        click(layer, at: CGPoint(x: 60, y: 20))
        layer.resetBadgeNumbers()
        click(layer, at: CGPoint(x: 100, y: 20))
        click(layer, at: CGPoint(x: 140, y: 20))
        #expect(badgeNumbers(layer) == [1, 2, 1, 2])
    }

    @Test func optionGrowsAreasFromTheCentre() throws {
        let layer = makeLayer(tool: .rectangle)
        drag(layer, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 130, y: 120), optionHeld: true)
        guard case .rectangle(let rect) = try #require(layer.annotations.last).shape else {
            Issue.record("not a rectangle")
            return
        }
        #expect(rect == CGRect(x: 70, y: 80, width: 60, height: 40))

        drag(layer, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 130, y: 120), constrained: true, optionHeld: true)
        guard case .rectangle(let square) = try #require(layer.annotations.last).shape else {
            Issue.record("not a rectangle")
            return
        }
        #expect(square == CGRect(x: 70, y: 70, width: 60, height: 60))
    }

    @Test func draggingTheTextToolMakesAFixedWidthBox() throws {
        let layer = makeLayer(tool: .text)
        drag(layer, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 30))
        #expect(layer.textEditing?.style.width == 100)
        #expect(layer.textEditing?.origin.x == 10)
        layer.textEditing?.text = "A box of a fixed width that wraps onto more than one line"
        layer.commitTextEditing()
        let box = try #require(layer.annotations.last)
        #expect(box.text.width == 100)
        #expect(box.bounds.width == 100)
        #expect(box.bounds.height > box.fontSize * 2)  // wrapped

        click(layer, at: CGPoint(x: 300, y: 150))  // clear of the box: on it, the click would open it again
        #expect(layer.textEditing?.style.width == nil)
        layer.textEditing?.text = "Short"
        layer.commitTextEditing()
        #expect(layer.annotations.last?.text.width == nil)
    }

    @Test func textWrapsAtTheSurfaceEdgeInsteadOfRunningOff() throws {
        let layer = makeLayer(tool: .text)
        click(layer, at: CGPoint(x: 350, y: 10))
        layer.textEditing?.text = "This label starts near the right edge and would run off the surface"
        layer.commitTextEditing()
        let label = try #require(layer.annotations.last)
        #expect(label.text.width == 50)
        #expect(label.bounds.maxX <= 400)
    }

    @Test func textKeepsItsOwnSizeAndPillUntilTheWidthChanges() throws {
        let layer = makeLayer(tool: .text)
        click(layer, at: CGPoint(x: 10, y: 10))
        layer.textEditing?.text = "Hello"
        layer.commitTextEditing()
        let plain = try #require(layer.annotations.last)
        layer.select([plain.id])

        layer.adjustTextSize(by: 4)
        let bigger = try #require(layer.annotations.last)
        #expect(bigger.fontSize == plain.fontSize + 4)

        layer.toggleTextBackground()
        let pilled = try #require(layer.annotations.last)
        #expect(pilled.text.hasBackground)
        #expect(pilled.bounds.width > bigger.bounds.width)

        layer.restyleSelection(lineWidth: StrokeWidth.thick.rawValue)
        let restyled = try #require(layer.annotations.last)
        #expect(restyled.text.fontSize == nil)
        #expect(restyled.fontSize == Annotation.fontSize(lineWidth: StrokeWidth.thick.rawValue))
    }

    @Test func measureLabelsTheDistanceBesideTheLine() throws {
        let layer = makeLayer(tool: .measure)
        drag(layer, from: CGPoint(x: 10, y: 100), to: CGPoint(x: 310, y: 100))
        let measure = try #require(layer.annotations.last)
        let geometry = try #require(measure.measureGeometry)
        #expect(geometry.label == "300 px")
        #expect(geometry.labelRect.maxY < 100)  // above a flat line
        #expect(measure.bounds.contains(geometry.labelRect))
        #expect(measure.hitTest(CGPoint(x: 160, y: 100)))
        #expect(measure.hitTest(CGPoint(x: geometry.labelRect.midX, y: geometry.labelRect.midY)))
    }

    @Test func hidingKeepsTheDrawing() {
        let layer = layerWithThreeRectangles()
        layer.isHidden = true
        #expect(layer.annotations.count == 3)
        layer.isHidden = false
        #expect(layer.annotations.count == 3)
    }

    // MARK: - Text, opened again

    private func placeText(_ string: String, on layer: AnnotationLayer, at point: CGPoint) throws -> Annotation {
        layer.toolbox.tool = .text
        click(layer, at: point)
        layer.textEditing?.text = string
        layer.commitTextEditing()
        return try #require(layer.annotations.last)
    }

    @Test func clickingATextWithTheTextToolOpensItForTyping() throws {
        let layer = makeLayer()
        let label = try placeText("Hello", on: layer, at: CGPoint(x: 10, y: 10))

        click(layer, at: CGPoint(x: 14, y: 14))
        #expect(layer.textEditing?.replacing == label.id)
        #expect(layer.textEditing?.text == "Hello")
        #expect(layer.annotations.count == 1)
        // The field shows it meanwhile, so the layer doesn't.
        #expect(layer.visibleAnnotations.isEmpty)

        layer.textEditing?.text = "Hello again"
        layer.commitTextEditing()
        #expect(layer.annotations.count == 1)
        #expect(layer.visibleAnnotations.count == 1)
        guard case .text(let string, let origin) = try #require(layer.annotations.last).shape else {
            Issue.record("not a text")
            return
        }
        #expect(string == "Hello again")
        #expect(origin == CGPoint(x: 10, y: 10))

        // Empty space still starts a new one, and dragging a box over a text does too.
        click(layer, at: CGPoint(x: 200, y: 200))
        #expect(layer.textEditing?.replacing == nil)
        layer.cancelTextEditing()
        drag(layer, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 120, y: 20))
        #expect(layer.textEditing?.replacing == nil)
        #expect(layer.textEditing?.style.width == 115)
    }

    @Test func doubleClickingATextWithTheSelectToolOpensItForTyping() throws {
        let layer = makeLayer()
        let label = try placeText("Hello", on: layer, at: CGPoint(x: 10, y: 10))
        layer.toolbox.tool = .select

        click(layer, at: CGPoint(x: 14, y: 14))
        #expect(layer.textEditing == nil)
        #expect(layer.selectedIDs == [label.id])

        // The second click of a double-click, with the slight movement a double-click has.
        let point = CGPoint(x: 14, y: 14)
        layer.updateDrag(from: point, to: point, constrained: false, clickCount: 2)
        layer.updateDrag(from: point, to: CGPoint(x: 16, y: 15), constrained: false, clickCount: 2)
        layer.endDrag()
        #expect(layer.textEditing?.replacing == label.id)
        #expect(layer.annotations.count == 1)
        guard case .text(_, let origin) = try #require(layer.annotations.last).shape else {
            Issue.record("not a text")
            return
        }
        #expect(origin == CGPoint(x: 10, y: 10))  // not moved by the double-click

        // A double-click on empty space is just a click.
        layer.cancelTextEditing()
        layer.updateDrag(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 200, y: 200), constrained: false, clickCount: 2)
        layer.endDrag()
        #expect(layer.textEditing == nil)
        #expect(layer.selectedIDs.isEmpty)
    }

    @Test func doubleClickingATextWithAnArrowInHandOpensItToo() throws {
        let layer = makeLayer()
        let label = try placeText("Hello", on: layer, at: CGPoint(x: 10, y: 10))
        layer.toolbox.tool = .arrow
        let point = CGPoint(x: 14, y: 14)
        layer.updateDrag(from: point, to: point, constrained: false, clickCount: 2)
        layer.endDrag()
        #expect(layer.textEditing?.replacing == label.id)
        #expect(layer.annotations.count == 1)  // no arrow out of the double-click

        // A step number lands on the first click, so a double-click doesn't open the text under it.
        layer.cancelTextEditing()
        layer.toolbox.tool = .badge
        layer.updateDrag(from: point, to: point, constrained: false, clickCount: 2)
        layer.endDrag()
        #expect(layer.textEditing == nil)
    }

    @Test func theFieldIsAsWideAsItsTextUpToTheEdge() {
        var editing = TextEditing(origin: CGPoint(x: 100, y: 10), text: "", color: Color.Resolved(red: 0, green: 0, blue: 0), lineWidth: 4)
        let empty = editing.fieldBox(room: 300)
        #expect(empty.width < editing.fontSize)
        #expect(empty.height >= editing.fontSize)

        editing.text = "Hi"
        let short = editing.fieldBox(room: 300)
        #expect(short.width > empty.width)
        #expect(short.width < editing.fontSize * 4)
        #expect(short.wrapWidth == 300)

        editing.text = "A label long enough to need the whole width to the edge and then some more words after that"
        let long = editing.fieldBox(room: 300)
        #expect(long.width == 300)
        #expect(long.wrapWidth == 300)
        #expect(long.height > short.height * 1.8)  // wrapped onto more lines

        editing.style.width = 120
        let boxed = editing.fieldBox(room: 300)
        #expect(boxed.width == 120)
        #expect(boxed.wrapWidth == 120)
        #expect(boxed.height > long.height)
    }
}
