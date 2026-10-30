#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum WorkspaceError: LocalizedError {
    case invalidImage, imageTooLarge, noClipboardImage, incompatibleImages, noOverlap

    var errorDescription: String? {
        switch self {
        case .invalidImage: String(localized: "This file could not be read as an image or a Libellule project.")
        case .imageTooLarge: String(localized: "This image is too large. Use an image up to 32768 pixels per side and 100 million pixels in total.")
        case .noClipboardImage: String(localized: "The clipboard does not contain an image or an image file.")
        case .incompatibleImages: String(localized: "The sections must have the same pixel width. Capture the same area on the same display each time.")
        case .noOverlap: String(localized: "No reliable overlap was found. Set the overlap manually, or scroll less and capture the section again.")
        }
    }
}

enum ImageImport {
    struct Picture {
        let image: CGImage
        let scale: CGFloat
    }

    static func read(_ data: Data) throws -> Picture {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw WorkspaceError.invalidImage }
        guard width > 0, height > 0, width <= 32_768, height <= 32_768, width * height <= 100_000_000 else { throw WorkspaceError.imageTooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw WorkspaceError.invalidImage }
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        return Picture(image: image, scale: min(8, max(0.25, dpi / 72)))
    }

    static func read(_ url: URL) throws -> Picture {
        guard url.isFileURL else { throw WorkspaceError.invalidImage }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try read(Data(contentsOf: url))
    }
}

/// Owns utility windows, imports, and the commands shared by the menu bar, main window, and editor.
final class WorkspaceCoordinator {
    static let shared = WorkspaceCoordinator()
    private var windows: [String: WorkspaceWindow] = [:]

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .libelluleProject]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate()
        panel.begin { response in
            if response == .OK { self.open(panel.urls) }
        }
    }

    func open(_ urls: [URL]) {
        Task {
            for url in urls {
                do {
                    guard url.isFileURL else { throw WorkspaceError.invalidImage }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if url.pathExtension.lowercased() == "libellule" {
                        let document = try JSONDecoder().decode(ProjectArchive.self, from: Data(contentsOf: url)).document()
                        CaptureCoordinator.shared.openEditor(for: document)
                    } else {
                        let picture = try ImageImport.read(url)
                        await openImage(picture.image, scale: picture.scale)
                    }
                } catch { present(error) }
            }
        }
    }

    func pasteImage() {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            open(urls)
            return
        }
        guard let image = NSImage(pasteboard: .general), let data = image.tiffRepresentation else {
            present(WorkspaceError.noClipboardImage)
            return
        }
        do {
            let picture = try ImageImport.read(data)
            Task { await openImage(picture.image, scale: picture.scale) }
        } catch { present(error) }
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                    Task { @MainActor in
                        if let data, let url = URL(dataRepresentation: data, relativeTo: nil) { self.open([url]) }
                        else if let error { self.present(error) }
                    }
                }
            } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    Task { @MainActor in
                        do {
                            guard let data else { throw error ?? WorkspaceError.invalidImage }
                            let picture = try ImageImport.read(data)
                            await self.openImage(picture.image, scale: picture.scale)
                        } catch { self.present(error) }
                    }
                }
            }
        }
        return accepted
    }

    func openImage(_ image: CGImage, scale: CGFloat = 1) async {
        let document = AnnotationDocument(image: image, scale: scale, toolbox: AnnotationToolbox(context: .editor))
        if SelectionSession.redactsCaptures { _ = await document.layer.redact(image, style: .preferred) }
        CaptureHistoryStore.shared.record(document)
        CaptureCoordinator.shared.openEditor(for: document)
    }

    func showHistory() { show("history", title: String(localized: "Capture History"), view: CaptureHistoryView()) }
    func openHistory(_ entry: CaptureHistoryEntry) {
        do {
            let picture = try ImageImport.read(CaptureHistoryStore.shared.imageURL(entry.id))
            CaptureCoordinator.shared.openEditor(for: AnnotationDocument(image: picture.image, scale: picture.scale, toolbox: AnnotationToolbox(context: .editor)))
        } catch { present(error) }
    }
    func showPresets() { show("presets", title: String(localized: "Export Presets"), view: ExportPresetsView()) }
    func showComparison(image: CGImage? = nil) {
        show(UUID().uuidString, title: String(localized: "Compare Screenshots"), view: ScreenshotComparisonView(first: image))
    }
    func showScrollingCapture() {
        show("scrolling", title: String(localized: "Scrolling Capture"), view: ScrollingCaptureView())
    }

    func pin(_ document: AnnotationDocument) {
        document.layer.commitTextEditing()
        guard let image = document.flattenedImage() else { return }
        let id = "pin-" + UUID().uuidString
        let controller = WorkspaceWindow(title: String(localized: "Pinned Screenshot"), rootView: AnyView(PinnedScreenshotView(image: image, scale: document.scale, setOpacity: { [weak self] value in
            self?.windows[id]?.window?.alphaValue = value
        }, setClickThrough: { [weak self] value in
            self?.windows[id]?.window?.ignoresMouseEvents = value
        })), panel: true)
        controller.window?.level = .floating
        controller.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        controller.window?.setContentSize(NSSize(width: min(700, document.pointSize.width), height: min(650, document.pointSize.height + 60)))
        retain(controller, id: id)
    }

    func makePinsInteractive() {
        for (id, controller) in windows where id.hasPrefix("pin-") { controller.window?.ignoresMouseEvents = false }
    }

    func closePins() {
        for (id, controller) in Array(windows) where id.hasPrefix("pin-") { controller.close() }
    }

    private func show<V: View>(_ id: String, title: String, view: V) {
        if let controller = windows[id] { controller.showWindow(nil); NSApp.activate(); return }
        retain(WorkspaceWindow(title: title, rootView: AnyView(view)), id: id)
    }

    private func retain(_ controller: WorkspaceWindow, id: String) {
        windows[id] = controller
        controller.onClose = { [weak self] in self?.windows.removeValue(forKey: id) }
        controller.showWindow(nil)
        NSApp.activate()
    }

    func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't complete the action")
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}

struct WorkspaceCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Image or Project…") { WorkspaceCoordinator.shared.openPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Paste Image") { WorkspaceCoordinator.shared.pasteImage() }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Divider()
            Button("Capture History…") { WorkspaceCoordinator.shared.showHistory() }
            Button("Scrolling Capture…") { WorkspaceCoordinator.shared.showScrollingCapture() }
            Button("Compare Screenshots…") { WorkspaceCoordinator.shared.showComparison() }
            Button("Export Presets…") { WorkspaceCoordinator.shared.showPresets() }
        }
    }
}

final class WorkspaceWindow: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(title: String, rootView: AnyView, panel: Bool = false) {
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let window = panel ? NSPanel(contentRect: .zero, styleMask: style, backing: .buffered, defer: false) : NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: rootView)
        window.title = title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if let panel = window as? NSPanel { panel.hidesOnDeactivate = false }
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

private struct PinnedScreenshotView: View {
    let image: CGImage
    let scale: CGFloat
    let setOpacity: (Double) -> Void
    let setClickThrough: (Bool) -> Void
    @State private var opacity = 1.0

    var body: some View {
        VStack(spacing: 8) {
            Image(decorative: image, scale: scale).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: $opacity, in: 0.2...1).onChange(of: opacity) { _, value in setOpacity(value) }
                    .accessibilityLabel("Screenshot opacity")
                Button("Click Through") { setClickThrough(true) }
                    .help("Use Libellule's menu → Make Pinned Screenshots Interactive to restore mouse interaction")
            }.padding(10)
        }.frame(minWidth: 220, minHeight: 160)
    }
}
#endif
