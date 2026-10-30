#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class ScrollingCaptureModel {
    private(set) var sections: [CGImage] = []
    private(set) var overlaps: [Int] = []
    private(set) var preview: CGImage?
    private(set) var needsReview: Set<Int> = []
    private(set) var isBusy = false
    var errorMessage: String?
    weak var window: NSWindow?
    private var area: RepeatableArea?
    private var scale: CGFloat = 1

    func chooseArea() {
        guard !isBusy else { return }
        isBusy = true
        window?.orderOut(nil)
        CaptureCoordinator.shared.beginCapture(after: .milliseconds(200), receiving: { [weak self] document in
            guard let self else { return }
            area = CaptureCoordinator.shared.lastArea
            scale = document.scale
            sections = []
            overlaps = []
            needsReview = []
            preview = nil
            Task { await self.append(document) }
        }, onCancel: { [weak self] in
            self?.isBusy = false
            self?.showWindow()
        })
    }

    func captureNext() {
        guard !isBusy, let area,
              let screen = NSScreen.screens.first(where: { $0.displayID == area.displayID }) else { return }
        isBusy = true
        window?.orderOut(nil)
        Task {
            do {
                try await Task.sleep(for: .milliseconds(200))
                let snapshot = try await ScreenCapturer.snapshot(of: screen)
                let rect = CGRect(x: area.rect.minX * snapshot.scale, y: area.rect.minY * snapshot.scale,
                                  width: area.rect.width * snapshot.scale, height: area.rect.height * snapshot.scale).integral
                guard let image = snapshot.image.cropping(to: rect) else { throw WorkspaceError.invalidImage }
                let document = AnnotationDocument(image: image, scale: snapshot.scale)
                if SelectionSession.redactsCaptures { _ = await document.layer.redact(image, style: .preferred) }
                await append(document)
            } catch {
                errorMessage = error.localizedDescription
                isBusy = false
                showWindow()
            }
        }
    }

    var canCaptureNext: Bool {
        !isBusy && area.map { area in NSScreen.screens.contains { $0.displayID == area.displayID } } == true
    }

    func importSections() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose sections in order from top to bottom. You can adjust every join afterwards.")
        panel.begin { response in
            guard response == .OK else { return }
            Task {
                self.isBusy = true
                for url in panel.urls {
                    do {
                        let picture = try ImageImport.read(url)
                        if self.sections.isEmpty { self.scale = picture.scale }
                        let document = AnnotationDocument(image: picture.image, scale: picture.scale)
                        if SelectionSession.redactsCaptures { _ = await document.layer.redact(picture.image, style: .preferred) }
                        await self.append(document)
                        self.isBusy = true
                    } catch { self.errorMessage = error.localizedDescription; break }
                }
                self.isBusy = false
            }
        }
    }

    private func append(_ document: AnnotationDocument) async {
        guard let image = document.flattenedImage() else { isBusy = false; showWindow(); return }
        guard sections.count < 50 else {
            errorMessage = String(localized: "Finish this capture before adding more than 50 sections.")
            isBusy = false
            showWindow()
            return
        }
        if let last = sections.last {
            guard last.width == image.width else {
                errorMessage = WorkspaceError.incompatibleImages.localizedDescription
                isBusy = false
                showWindow()
                return
            }
            do {
                let overlap = try await Task.detached(priority: .userInitiated) { try ScreenshotPixels.detectOverlap(last, image) }.value
                overlaps.append(overlap)
            } catch {
                overlaps.append(0)
                needsReview.insert(overlaps.count - 1)
                errorMessage = error.localizedDescription
            }
        }
        sections.append(image)
        await rebuild()
        showWindow()
    }

    func setOverlap(_ value: Int, at index: Int) {
        overlaps[index] = value
        needsReview.remove(index)
        preview = nil
    }

    func confirmJoin(_ index: Int) {
        needsReview.remove(index)
        Task { await rebuild() }
    }

    func removeLast() {
        guard !isBusy, !sections.isEmpty else { return }
        sections.removeLast()
        if !overlaps.isEmpty { overlaps.removeLast() }
        needsReview = needsReview.filter { $0 < overlaps.count }
        preview = nil
        Task { await rebuild() }
    }

    func rebuild() async {
        isBusy = true
        defer { isBusy = false }
        guard !sections.isEmpty else { preview = nil; return }
        let images = sections
        let joins = overlaps
        do {
            preview = try await Task.detached(priority: .userInitiated) { try ScreenshotPixels.stitch(images, overlaps: joins) }.value
            if needsReview.isEmpty { errorMessage = nil }
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    func finish() {
        guard let preview, needsReview.isEmpty else { return }
        Task { await WorkspaceCoordinator.shared.openImage(preview, scale: scale) }
    }

    private func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate() }
}

struct ScrollingCaptureView: View {
    @State private var model = ScrollingCaptureModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scrolling Capture").font(.title2.bold())
            Text("Select an area without fixed headers or footers. Scroll the app underneath, leaving some overlap, then capture the next section. Sections are joined from top to bottom.")
                .foregroundStyle(.secondary)
            HStack {
                Button(model.sections.isEmpty ? "Select Area…" : "Start Over…") { model.chooseArea() }
                Button("Capture Next Section") { model.captureNext() }.disabled(!model.canCaptureNext)
                Button("Add Image Files…") { model.importSections() }
                Button("Remove Last") { model.removeLast() }.disabled(model.sections.isEmpty)
            }.disabled(model.isBusy)
            HStack(alignment: .top) {
                if let preview = model.preview {
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(width: 420)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("\(model.sections.count) Sections", systemImage: "rectangle.split.1x2", description: Text("Add sections, then update the preview."))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.overlaps.indices, id: \.self) { index in
                            GroupBox("Join \(index + 1) → \(index + 2)") {
                                VStack(alignment: .leading) {
                                    TextField("Overlap (pixels)", value: Binding(get: { model.overlaps[index] }, set: { model.setOverlap($0, at: index) }), format: .number)
                                    if model.needsReview.contains(index) {
                                        Text("Check this join. Zero concatenates sections without removing overlap.").font(.caption).foregroundStyle(.orange)
                                        Button("Accept Join") { model.confirmJoin(index) }
                                    }
                                }.padding(6)
                            }
                        }
                    }
                }.frame(width: 240).disabled(model.isBusy)
            }
            if let message = model.errorMessage { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text("\(model.sections.count) sections").foregroundStyle(.secondary)
                Spacer()
                Button("Update Preview") { Task { await model.rebuild() } }.disabled(model.sections.isEmpty || model.isBusy)
                Button("Open in Editor") { model.finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.preview == nil || !model.needsReview.isEmpty || model.isBusy)
            }
        }.padding(20).frame(minWidth: 820, minHeight: 600)
        .background(WindowReference { model.window = $0 })
    }
}

struct WindowReference: NSViewRepresentable {
    let receive: (NSWindow?) -> Void
    func makeNSView(context: Context) -> Observer { Observer(receive: receive) }
    func updateNSView(_ nsView: Observer, context: Context) {}

    final class Observer: NSView {
        let receive: (NSWindow?) -> Void
        init(receive: @escaping (NSWindow?) -> Void) { self.receive = receive; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            Task { @MainActor in receive(window) }
        }
    }
}
#endif
