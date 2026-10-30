#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ComparisonMode: String, CaseIterable {
    case sideBySide = "Side by Side", overlay = "Overlay", difference = "Difference"
    var title: String {
        switch self {
        case .sideBySide: String(localized: "Side by Side")
        case .overlay: String(localized: "Overlay")
        case .difference: String(localized: "Difference")
        }
    }
}

struct ScreenshotComparisonView: View {
    @State private var first: CGImage?
    @State private var second: CGImage?
    @State private var mode = ComparisonMode.sideBySide
    @State private var opacity = 0.5
    @State private var tolerance = 12.0
    @State private var revision = UUID()
    @State private var difference: ScreenshotPixels.Difference?
    @State private var errorMessage: String?
    @State private var isComparing = false

    init(first: CGImage? = nil, second: CGImage? = nil) {
        _first = State(initialValue: first)
        _second = State(initialValue: second)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Open First Image…") { choose(firstSlot: true) }
                Button("Open Second Image…") { choose(firstSlot: false) }
                Button("Swap", systemImage: "arrow.left.arrow.right") {
                    let previous = first
                    first = second
                    second = previous
                    revision = UUID()
                }.disabled(first == nil || second == nil)
                Spacer()
                Picker("View", selection: $mode) {
                    ForEach(ComparisonMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 230)
            }
            if mode == .overlay {
                HStack {
                    Text("Second image opacity")
                    Slider(value: $opacity, in: 0...1)
                }
            } else if mode == .difference {
                HStack {
                    Text("Ignore channel changes up to \(Int(tolerance))")
                    Slider(value: $tolerance, in: 0...64, step: 1) { editing in if !editing { revision = UUID() } }
                    if let difference { Text("\(difference.changedPixels) / \(difference.totalPixels) pixels changed").monospacedDigit() }
                    Button("Edit Difference") {
                        if let difference { Task { await WorkspaceCoordinator.shared.openImage(difference.image) } }
                    }.disabled(difference == nil)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if first == nil || second == nil {
                ContentUnavailableView("Choose Two Screenshots", systemImage: "rectangle.on.rectangle", description: Text("Compare side by side, blend them, or highlight changed pixels. Overlay and difference require matching pixel dimensions."))
            } else if let first, let second {
                switch mode {
                case .sideBySide:
                    HStack(alignment: .top) {
                        picture(first, label: String(localized: "First"))
                        Divider()
                        picture(second, label: String(localized: "Second"))
                    }
                case .overlay:
                    if first.width == second.width, first.height == second.height {
                        ZStack {
                            Image(decorative: first, scale: 1).resizable()
                            Image(decorative: second, scale: 1).resizable().opacity(opacity)
                        }.aspectRatio(CGFloat(first.width) / CGFloat(first.height), contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { mismatchedSize }
                case .difference:
                    if first.width != second.width || first.height != second.height { mismatchedSize }
                    else if isComparing { ProgressView("Comparing pixels…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if let difference { picture(difference.image, label: String(localized: "Changed pixels in red")) }
                }
            }
        }.padding(20).frame(minWidth: 900, minHeight: 560)
        .task(id: "\(revision)-\(mode.rawValue)") {
            difference = nil
            errorMessage = nil
            guard mode == .difference, let first, let second, first.width == second.width, first.height == second.height else { return }
            isComparing = true
            let threshold = Int(tolerance)
            let work = Task.detached(priority: .userInitiated) { try ScreenshotPixels.difference(first, second, tolerance: threshold) }
            do {
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled else { return }
                difference = result
                isComparing = false
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isComparing = false
            }
        }
    }

    private var mismatchedSize: some View {
        ContentUnavailableView("Different Pixel Sizes", systemImage: "arrow.up.left.and.arrow.down.right", description: Text("Use Side by Side, or crop the screenshots to matching dimensions in the editor."))
    }

    private func picture(_ image: CGImage, label: String) -> some View {
        VStack {
            Text("\(label) · \(image.width) × \(image.height) px").font(.caption).foregroundStyle(.secondary)
            Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func choose(firstSlot: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let image = try ImageImport.read(url).image
                if firstSlot { first = image } else { second = image }
                revision = UUID()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
#endif
