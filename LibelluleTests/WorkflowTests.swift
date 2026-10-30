import AppKit
import SwiftUI
import Testing
@testable import Libellule

struct WorkflowTests {
    private func picture(width: Int = 80, height: Int = 40, patterned: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if patterned {
            for y in 0..<height {
                for x in 0..<width {
                    let seed = ((x * 73 + y * 137 + x * y * 19) ^ ((y * y * 17) >> 5)) % 251
                    context.setFillColor(CGColor(red: CGFloat(seed) / 250, green: CGFloat((seed * 13 + y) % 251) / 250,
                                                 blue: CGFloat((seed * 29 + x) % 251) / 250, alpha: 1))
                    context.fill(CGRect(x: x, y: height - y - 1, width: 1, height: 1))
                }
            }
        }
        return context.makeImage()!
    }

    @Test func editableProjectRestoresEveryShapeAndItsStyles() throws {
        let rect = CGRect(x: 3, y: 4, width: 15, height: 10)
        let a = CGPoint(x: 4, y: 5)
        let b = CGPoint(x: 21, y: 18)
        let shapes: [Annotation.Shape] = [
            .line(from: a, to: b), .arrow(from: a, to: b), .rectangle(rect), .ellipse(rect),
            .freehand([a, b]), .highlight([a, b]), .spotlight(rect), .text("Editable\ntext", origin: a),
            .badge(7, center: b), .blackout(rect), .pixelate(rect), .blur(rect),
            .magnifier(source: a, lens: b), .measure(from: a, to: b),
        ]
        let annotations = shapes.map {
            Annotation(shape: $0, color: .init(red: 0.8, green: 0.3, blue: 0.1, opacity: 0.7), lineWidth: 4,
                       text: TextStyle(fontSize: 18, width: 30, hasBackground: true), badgeStyle: .bordered)
        }
        let document = AnnotationDocument(image: picture(), scale: 2, annotations: annotations, dimsLights: true, board: Board(isDark: true, opacity: 0.3))
        document.setCanvas(CGRect(x: -5, y: -4, width: 50, height: 30), fill: .transparent)
        let data = try JSONEncoder().encode(ProjectArchive(document: document))
        let restored = try JSONDecoder().decode(ProjectArchive.self, from: data).document()
        #expect(restored.canvas == document.canvas)
        #expect(restored.canvasFill == .transparent)
        #expect(restored.scale == 2)
        #expect(restored.layer.annotations == document.layer.annotations)
        #expect(restored.layer.dimsLights)
        #expect(restored.layer.board == document.layer.board)
        #expect(!restored.hasUnsavedChanges)
        #expect(!restored.undoManager.canUndo)
        #expect(try ScreenshotPixels.rgba(restored.original) == ScreenshotPixels.rgba(document.original))
        #expect(restored.pngData() != nil)
    }

    @Test func projectsRejectUnknownVersionsAndOversizedCanvases() throws {
        var archive = try ProjectArchive(document: AnnotationDocument(image: picture(), scale: 1))
        archive.version = 2
        #expect(throws: (any Error).self) { try archive.document() }
        archive.version = 1
        archive.canvas.size.width = 1_000_000
        #expect(throws: (any Error).self) { try archive.document() }
    }

    @Test func customRulesMatchLiteralTextAndRegularExpressions() {
        let literal = CustomRedactionRule(name: "Company", pattern: "Acme (Internal)")
        let pattern = CustomRedactionRule(name: "Customer", pattern: #"CUST-\d{5}"#, isRegularExpression: true)
        let invalid = CustomRedactionRule(pattern: "(", isRegularExpression: true)
        let disabled = CustomRedactionRule(pattern: "public", isEnabled: false)
        let text = "acme (internal) CUST-12345 public"
        let matches = Redactor.matches(in: text, rules: [literal, pattern, invalid, disabled])
        #expect(matches.map(\.kind) == [.custom, .custom])
        #expect(matches.map { String(text[$0.range]) } == ["acme (internal)", "CUST-12345"])
        #expect(!invalid.isValid)
        #expect(Redactor.matches(in: text, rules: [literal, pattern], disabled: [.custom]).isEmpty)
        #expect(Redactor.matches(in: "a@example.com", disabled: [.email]).isEmpty)
        let broad = CustomRedactionRule(pattern: "Contact a@example.com for Acme")
        let sensitive = "Contact a@example.com for Acme"
        #expect(Redactor.matches(in: sensitive, rules: [broad]).map { String(sensitive[$0.range]) } == [sensitive])
    }

    @Test func exportPresetsPreserveAspectRatioAddPaddingAndSanitizeNames() throws {
        let preset = ExportPreset(name: "Docs", maxWidth: 40, padding: 5, background: .black, filename: "Docs/{width}:{height}")
        let rendered = try #require(preset.render(picture()))
        #expect(rendered.width == 50)
        #expect(rendered.height == 30)
        #expect(preset.fileName(image: rendered) == "Docs-50-30.png")
        let pixels = try ScreenshotPixels.rgba(rendered)
        #expect(Array(pixels.prefix(4)) == [0, 0, 0, 255])
        #expect(ExportPreset(padding: -1).render(picture()) == nil)
        #expect(ExportPreset(maxWidth: 200).render(picture())?.width == 80)
    }

    @Test func tableExportsEscapeCellsAndPreserveEmptyColumns() {
        let rows = [["Name", "Notes", "Value"], ["A,B", "Say \"hello\"\nNext", ""], ["short"]]
        #expect(StructuredTextRecognizer.csv(rows) == "Name,Notes,Value\r\n\"A,B\",\"Say \"\"hello\"\"\nNext\",\r\nshort,,")
        #expect(StructuredTextRecognizer.markdown([["A", "B"], ["x|y", "one\ntwo"]]) == "| A | B |\n| --- | --- |\n| x\\|y | one<br>two |")
        #expect(StructuredTextRecognizer.csv([]).isEmpty)
        #expect(StructuredTextRecognizer.markdown([]).isEmpty)
    }

    @Test func documentRecognitionExtractsARealTableOnDevice() async throws {
        let image = NSImage(size: CGSize(width: 800, height: 400), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            NSColor.black.setStroke()
            let grid = NSBezierPath()
            grid.lineWidth = 2
            for y in [50, 150, 250, 350] {
                grid.move(to: CGPoint(x: 50, y: y))
                grid.line(to: CGPoint(x: 750, y: y))
            }
            for x in [50, 500, 750] {
                grid.move(to: CGPoint(x: x, y: 50))
                grid.line(to: CGPoint(x: x, y: 350))
            }
            grid.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]
            for (row, values) in [["Product", "Count"], ["Widgets", "12"], ["Gadgets", "34"]].enumerated() {
                values[0].draw(at: CGPoint(x: 75, y: 285 - row * 100), withAttributes: attributes)
                values[1].draw(at: CGPoint(x: 525, y: 285 - row * 100), withAttributes: attributes)
            }
            return true
        }
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let result = try await StructuredTextRecognizer.recognize(pixels)
        let table = try #require(result.tables.first)
        #expect(table.count == 3)
        #expect(table.allSatisfy { $0.count == 2 })
        #expect(table.flatMap { $0 }.contains { $0.localizedCaseInsensitiveContains("Widgets") })
        #expect(table.flatMap { $0 }.contains("12"))
        #expect(table.flatMap { $0 }.contains("34"))
    }

    @Test func pixelDifferenceCountsChangesAndHonorsTolerance() throws {
        let first = picture(width: 20, height: 10)
        let document = AnnotationDocument(image: first, scale: 1)
        document.layer.addRedactions([CGRect(x: 2, y: 3, width: 5, height: 3)], style: .blackout)
        let second = try #require(document.flattenedImage())
        #expect(try ScreenshotPixels.difference(first, first).changedPixels == 0)
        let result = try ScreenshotPixels.difference(first, second)
        #expect(result.changedPixels == 15)
        #expect(result.totalPixels == 200)
        #expect(try ScreenshotPixels.difference(first, second, tolerance: 255).changedPixels == 0)
        #expect(throws: (any Error).self) { try ScreenshotPixels.difference(first, picture()) }
    }

    @Test func scrollingJoinsPreserveEveryRowWithoutDuplicatingOverlap() throws {
        let source = picture(width: 40, height: 240, patterned: true)
        let first = try #require(source.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 140)))
        let second = try #require(source.cropping(to: CGRect(x: 0, y: 80, width: 40, height: 140)))
        #expect(try ScreenshotPixels.detectOverlap(first, second) == 60)
        let joined = try ScreenshotPixels.stitch([first, second], overlaps: [60])
        let expected = try #require(source.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 220)))
        #expect(joined.height == 220)
        #expect(try ScreenshotPixels.rgba(joined) == ScreenshotPixels.rgba(expected))
        #expect(throws: (any Error).self) { try ScreenshotPixels.detectOverlap(first, first) }
        #expect(throws: (any Error).self) { try ScreenshotPixels.stitch([first, second], overlaps: [140]) }
        #expect(throws: (any Error).self) { try ScreenshotPixels.stitch([first, picture()], overlaps: [0]) }
    }

    @Test func imageImportReadsExportedDPIAndRejectsInvalidData() throws {
        let document = AnnotationDocument(image: picture(), scale: 2)
        let data = try #require(document.pngData())
        let imported = try ImageImport.read(data)
        #expect(imported.image.width == 80)
        #expect(imported.image.height == 40)
        #expect(abs(imported.scale - 2) < 0.01)
        #expect(throws: (any Error).self) { try ImageImport.read(Data("not an image".utf8)) }
        #expect(throws: WorkspaceError.invalidImage) { try ImageImport.read(URL(string: "https://example.invalid/image.png")!) }
    }

    @Test func scrollingDetectsOddPixelOverlapsInTallSections() throws {
        let source = picture(width: 40, height: 2200, patterned: true)
        let first = try #require(source.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 1400)))
        let second = try #require(source.cropping(to: CGRect(x: 0, y: 667, width: 40, height: 1400)))
        #expect(try ScreenshotPixels.detectOverlap(first, second) == 733)
    }

    @Test func historyIsOptInAndStoresOnlyFlattenedRedactedPixels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = CaptureHistoryStore(directory: root, defaults: defaults)
        let document = AnnotationDocument(image: picture(), scale: 1)
        store.record(document, indexText: false)
        #expect(store.entries.isEmpty)
        defaults.set(true, forKey: CaptureHistoryStore.enabledKey)
        document.layer.addRedactions([CGRect(x: 0, y: 0, width: 80, height: 40)], style: .blackout)
        store.record(document, indexText: false)
        let entry = try #require(store.entries.first)
        let saved = try #require(store.image(entry))
        #expect(try ScreenshotPixels.rgba(saved).prefix(4).elementsEqual([0, 0, 0, 255]))
        let restored = CaptureHistoryStore(directory: root, defaults: defaults)
        #expect(restored.entries.count == 1)
        restored.delete(entry)
        #expect(restored.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: restored.imageURL(entry.id).path))
    }

    @Test func historyRetentionDeletesExpiredImagesButKeepsFavorites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = CaptureHistoryEntry(date: .now.addingTimeInterval(-10 * 86400))
        let favorite = CaptureHistoryEntry(date: old.date, isFavorite: true)
        let data = try #require(AnnotationDocument(image: picture(), scale: 1).pngData())
        for entry in [old, favorite] { try data.write(to: root.appendingPathComponent(entry.id.uuidString + ".png")) }
        try JSONEncoder().encode([old, favorite]).write(to: root.appendingPathComponent("index.json"))
        let store = CaptureHistoryStore(directory: root, defaults: defaults)
        #expect(store.entries.map(\.id) == [favorite.id])
        #expect(!FileManager.default.fileExists(atPath: store.imageURL(old.id).path))
        #expect(FileManager.default.fileExists(atPath: store.imageURL(favorite.id).path))
        store.favorite(favorite)
        #expect(store.entries.isEmpty)
    }

    @Test func corruptHistoryDoesNotOverwriteItsIndexAndCanBeCleared() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalid = Data("invalid index".utf8)
        try invalid.write(to: root.appendingPathComponent("index.json"))
        try Data("orphaned image".utf8).write(to: root.appendingPathComponent("orphan.png"))
        defaults.set(true, forKey: CaptureHistoryStore.enabledKey)
        let store = CaptureHistoryStore(directory: root, defaults: defaults)
        #expect(store.errorMessage != nil)
        store.record(AnnotationDocument(image: picture(), scale: 1), indexText: false)
        #expect(try Data(contentsOf: root.appendingPathComponent("index.json")) == invalid)
        store.clear()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(store.errorMessage == nil)
        store.record(AnnotationDocument(image: picture(), scale: 1), indexText: false)
        #expect(store.entries.count == 1)
    }
}
