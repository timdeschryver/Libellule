import AppKit
import SwiftUI
import Testing
@testable import Libellule

@Suite(.serialized)
struct WorkflowViewTests {
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
        let views: [(String, AnyView, CGSize)] = [
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
