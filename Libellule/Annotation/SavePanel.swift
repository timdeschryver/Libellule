#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension AnnotationDocument {
    enum SaveOutcome {
        case saved(URL)
        case cancelled
        /// Why, ready to show.
        case failed(String)
    }

    /// The save panel with a PNG/JPEG popup: a sheet on `window`, or a panel of its own without one (straight
    /// after a capture). Switching the format renames the file and becomes the default for next time.
    func runSavePanel(attachedTo window: NSWindow?, completion: @escaping (SaveOutcome) -> Void) {
        layer.commitTextEditing()
        let choice = SaveFormatChoice(format: ExportFormat.preferred)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [choice.format.utType]
        panel.nameFieldStringValue = Self.suggestedFileName(format: choice.format)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let accessory = NSHostingView(rootView: SaveFormatAccessory(choice: choice) { [weak panel] format in
            guard let panel else { return }
            panel.allowedContentTypes = [format.utType]
            let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(stem).\(format.fileExtension)"
            ExportFormat.preferred = format
        } presetChanged: { [weak panel] preset in
            guard let panel else { return }
            if let preset {
                choice.format = preset.format
                panel.allowedContentTypes = [preset.format.utType]
                let image = self.flattenedImage().flatMap { preset.render($0) } ?? self.image
                panel.nameFieldStringValue = preset.fileName(image: image)
            } else {
                panel.nameFieldStringValue = Self.suggestedFileName(format: choice.format)
            }
        })
        accessory.frame = NSRect(origin: .zero, size: accessory.fittingSize)
        panel.accessoryView = accessory

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                completion(.cancelled)
                return
            }
            let preset = choice.preset
            guard let flattened = self.flattenedImage(),
                  let rendered = preset.map({ $0.render(flattened) }) ?? flattened,
                  let data = self.imageData(from: rendered, format: choice.format) else {
                completion(.failed("Couldn't render the image"))
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                self.markSaved()
                completion(.saved(url))
            } catch {
                completion(.failed("Couldn't save: \(error.localizedDescription)"))
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

/// The format chosen in the save panel's popup.
@Observable
final class SaveFormatChoice {
    var format: ExportFormat
    var presetID: UUID?
    var preset: ExportPreset? { ExportPresetStore.shared.presets.first { $0.id == presetID } }

    init(format: ExportFormat) {
        self.format = format
    }
}

/// The save panel's accessory: a PNG/JPEG popup.
struct SaveFormatAccessory: View {
    @Bindable var choice: SaveFormatChoice
    let formatChanged: (ExportFormat) -> Void
    let presetChanged: (ExportPreset?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Preset:", selection: $choice.presetID) {
                Text("Original size").tag(nil as UUID?)
                ForEach(ExportPresetStore.shared.presets.filter(\.isValid)) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .onChange(of: choice.presetID) { _, _ in presetChanged(choice.preset) }
            Picker("Format:", selection: $choice.format) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            Button("Manage Presets…") { WorkspaceCoordinator.shared.showPresets() }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .help("PNG keeps every pixel and transparency; JPEG is smaller and loses a little. Remembered for next time.")
        .onChange(of: choice.format) { _, format in formatChanged(format) }
    }
}
#endif
