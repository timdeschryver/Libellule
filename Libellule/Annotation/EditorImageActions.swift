#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// Image imports and new captures share the same redaction path before entering an existing canvas.
enum EditorImageActions {
    static func chooseImages(for document: AnnotationDocument, placement: AnnotationDocument.ImagePlacement = .inset, replacing: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = !replacing
        panel.canChooseDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            Task {
                for url in panel.urls {
                    do {
                        let picture = try ImageImport.read(url)
                        try await add(picture, to: document, placement: placement, replacing: replacing)
                    } catch { WorkspaceCoordinator.shared.present(error) }
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    static func capture(for document: AnnotationDocument, placement: AnnotationDocument.ImagePlacement = .inset, replacing: Bool = false) {
        document.layer.commitTextEditing()
        let window = NSApp.keyWindow
        window?.orderOut(nil)
        func restoreWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate() }
        CaptureCoordinator.shared.beginCapture(after: .milliseconds(180), receiving: { captured in
            Task {
                defer { restoreWindow() }
                do {
                    guard let image = captured.flattenedImage() else { throw WorkspaceError.invalidImage }
                    try await add(ImageImport.Picture(image: image, scale: captured.scale), to: document, placement: placement, replacing: replacing)
                } catch { WorkspaceCoordinator.shared.present(error) }
            }
        }, onCancel: { restoreWindow() })
    }

    static func paste(into document: AnnotationDocument) {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            Task {
                for url in urls {
                    do { try await add(ImageImport.read(url), to: document, placement: .inset) }
                    catch { WorkspaceCoordinator.shared.present(error) }
                }
            }
            return
        }
        guard let data = NSImage(pasteboard: .general)?.tiffRepresentation else { WorkspaceCoordinator.shared.present(WorkspaceError.noClipboardImage); return }
        Task {
            do { try await add(ImageImport.read(data), to: document, placement: .inset) }
            catch { WorkspaceCoordinator.shared.present(error) }
        }
    }

    static func acceptDrop(_ providers: [NSItemProvider], document: AnnotationDocument) -> Bool {
        let accepted = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || $0.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: .image) == true }
        }
        // Load in order; asynchronous provider callbacks must not reorder a multi-image drop.
        Task {
            for provider in accepted {
                do {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let data = try await data(from: provider, type: UTType.fileURL.identifier)
                        guard let url = URL(dataRepresentation: data, relativeTo: nil) else { throw WorkspaceError.invalidImage }
                        if url.pathExtension.lowercased() == "libellule" { WorkspaceCoordinator.shared.open([url]); continue }
                        try await add(ImageImport.read(url), to: document, placement: .inset)
                    } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                        let picture = try ImageImport.read(await data(from: provider, type: type))
                        try await add(picture, to: document, placement: .inset)
                    }
                } catch { WorkspaceCoordinator.shared.present(error) }
            }
        }
        return !accepted.isEmpty
    }

    private static func data(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? WorkspaceError.invalidImage) }
            }
        }
    }

    static func add(_ picture: ImageImport.Picture, to document: AnnotationDocument, placement: AnnotationDocument.ImagePlacement, replacing: Bool = false) async throws {
        var image = picture.image
        if SelectionSession.redactsCaptures {
            let incoming = AnnotationDocument(image: image, scale: picture.scale)
            _ = await incoming.layer.redact(image, style: .preferred)
            guard let redacted = incoming.flattenedImage() else { throw WorkspaceError.invalidImage }
            image = redacted
        }
        if replacing { try document.replaceBackground(with: image, scale: picture.scale) }
        else { try document.insertImage(image, sourceScale: picture.scale, placement: placement) }
    }
}
#endif
