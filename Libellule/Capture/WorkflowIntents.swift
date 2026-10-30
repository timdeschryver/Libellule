#if os(macOS)
import AppIntents
import UniformTypeIdentifiers

struct RedactImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Redact Image"
    static let description = IntentDescription("Hide sensitive text and faces in an image using Libellule's redaction settings. Returns a flattened PNG. Processing stays on your Mac.")
    @Parameter(title: "Image", supportedContentTypes: [.image]) var image: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let picture = try ImageImport.read(image.data)
        let document = AnnotationDocument(image: picture.image, scale: picture.scale)
        _ = await document.layer.redact(picture.image, style: .preferred)
        guard let data = document.pngData() else { throw WorkspaceError.invalidImage }
        return .result(value: IntentFile(data: data, filename: "Redacted.png", type: .png))
    }
}

struct ExtractImageTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Extract Text from Image"
    static let description = IntentDescription("Read text from an image on your Mac, without changing the clipboard.")
    @Parameter(title: "Image", supportedContentTypes: [.image]) var image: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let picture = try ImageImport.read(image.data)
        return .result(value: try await TextRecognizer.recognizeText(in: picture.image, joining: TextRecognizer.joinsLines))
    }
}

struct OpenImageInLibelluleIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Image in Libellule"
    static let description = IntentDescription("Open an image in Libellule's annotation editor.")
    static let openAppWhenRun = true
    @Parameter(title: "Image", supportedContentTypes: [.image]) var image: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        let picture = try ImageImport.read(image.data)
        await WorkspaceCoordinator.shared.openImage(picture.image, scale: picture.scale)
        return .result()
    }
}

struct CaptureInLibelluleIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture with Libellule"
    static let description = IntentDescription("Show Libellule's interactive area, window, and display selection.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureCoordinator.shared.beginCapture(after: .milliseconds(250))
        return .result()
    }
}
#endif
