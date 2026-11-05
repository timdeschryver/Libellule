import AppKit
import SwiftUI
import Testing
@testable import Libellule

@Suite(.serialized)
struct WorkflowViewTests {
    @Test func livePalettesFitWithTheArrowStylePicker() async throws {
        let session = LiveAnnotationSession(toolbox: AnnotationToolbox())
        session.setArrowStyle(.elbow)
        let layouts: [(String, PaletteLayout, Bool, CGSize)] = [
            ("live-palette-wide", .horizontal, false, CGSize(width: LiveAnnotationPalette.singleRowWidth, height: 100)),
            ("live-palette-compact", .horizontal, true, CGSize(width: 1280, height: 180)),
            ("live-palette-left", .left, false, CGSize(width: 220, height: 900)),
            ("live-palette-right", .right, false, CGSize(width: 220, height: 900)),
        ]
        for (name, layout, compact, maximum) in layouts {
            let view = LiveAnnotationPalette(session: session, compact: compact, layout: layout)
            let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
            let size = hosting.fittingSize
            #expect(size.width <= maximum.width)
            #expect(size.height <= maximum.height)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: "\(name).png")
            window.close()
        }
    }

    /// Render the native views themselves, without capturing the desktop or requesting screen access.
    @Test func workflowWindowsRenderAtTheirSupportedSizes() async throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let context = try #require(CGContext(data: nil, width: 500, height: 280, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.12, green: 0.19, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 280))
        context.setFillColor(CGColor(red: 0.25, green: 0.65, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 180, height: 140))
        let image = try #require(context.makeImage())
        let presets = ExportPresetStore(defaults: defaults)
        presets.presets = [ExportPreset(name: "Documentation", maxWidth: 1200, padding: 24)]
        let history = CaptureHistoryStore(directory: root, defaults: defaults)
        defaults.set(true, forKey: CaptureHistoryStore.enabledKey)
        history.record(AnnotationDocument(image: image, scale: 1), indexText: false)
        let review = RedactionReview(image: image, preview: image, findings: [Redactor.Finding(kind: .secret, box: CGRect(x: 0.08, y: 0.15, width: 0.36, height: 0.18))])
        let document = AnnotationDocument(image: image, scale: 1)
        var callout = Annotation(shape: .text("Review this change", origin: CGPoint(x: 240, y: 60)), color: .init(red: 0.95, green: 0.25, blue: 0.1), lineWidth: 3)
        callout.calloutTarget = CGPoint(x: 120, y: 150)
        callout.text.hasBackground = true
        callout.arrowStyle = .curved
        document.layer.apply([callout], actionName: "Fixture")
        document.layer.select([callout.id])
        let styleStore = AnnotationStyleStore(defaults: defaults)
        styleStore.save(name: "Review", layer: document.layer)
        let words = [RecognizedWord(text: "Customer", rect: CGRect(x: 40, y: 40, width: 80, height: 20), line: 0)]
        let bending = AnnotationLayer(size: document.pointSize)
        bending.toolbox.tool = .arrow
        bending.updateDrag(from: CGPoint(x: 60, y: 140), to: CGPoint(x: 420, y: 140), constrained: false)
        bending.updateDrag(from: CGPoint(x: 60, y: 140), to: CGPoint(x: 420, y: 230), constrained: false, commandHeld: true)
        let views: [(String, AnyView, CGSize)] = [
            ("arrow-bending", AnyView(AnnotationCanvas(layer: bending, background: image, displayScale: 1)), document.pointSize),
            ("editor", AnyView(AnnotationEditorView(document: document)), CGSize(width: 1180, height: 600)),
            ("editor-minimum", AnyView(AnnotationEditorView(document: document)), CGSize(width: 980, height: 460)),
            ("annotation-styles", AnyView(AnnotationStylesView(layer: document.layer, store: styleStore)), CGSize(width: 660, height: 520)),
            ("remove-section", AnyView(RemoveSectionView(image: image, pointSize: document.pointSize, apply: { _, _, _ in })), CGSize(width: 780, height: 600)),
            ("text-markup", AnyView(TextMarkupView(image: image, words: words, pointSize: document.pointSize, apply: { _, _ in })), CGSize(width: 860, height: 620)),
            ("main", AnyView(ContentView()), CGSize(width: 500, height: 760)),
            ("presets", AnyView(ExportPresetsView(store: presets)), CGSize(width: 540, height: 580)),
            ("history", AnyView(CaptureHistoryView(store: history)), CGSize(width: 900, height: 560)),
            ("comparison", AnyView(ScreenshotComparisonView(first: image, second: image)), CGSize(width: 1000, height: 600)),
            ("scrolling", AnyView(ScrollingCaptureView()), CGSize(width: 900, height: 650)),
            ("text", AnyView(StructuredTextView(image: image, result: StructuredTextResult(blocks: ["Customer report", "Only these selected text blocks are copied."], tables: [[["Name", "Count"], ["Widget", "12"]]]))), CGSize(width: 740, height: 560)),
            ("redaction-review", AnyView(RedactionReviewView(review: review, apply: { _ in })), CGSize(width: 860, height: 540)),
        ]
        for (name, view, size) in views {
            let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosting
            window.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.bounds.width >= size.width)
            #expect(hosting.bounds.height >= size.height)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(png.count > 1000)
            Attachment.record(png, named: "\(name).png")
            window.close()
        }
    }
}
