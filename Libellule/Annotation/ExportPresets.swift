#if os(macOS)
import AppKit
import SwiftUI

struct ExportPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = String(localized: "New preset")
    var maxWidth = 0
    var maxHeight = 0
    var padding = 0
    var background = CanvasFill.white
    var format = ExportFormat.png
    var filename = "Screenshot {date} {time}"

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (0...16_384).contains(maxWidth) && (0...16_384).contains(maxHeight) && (0...2_048).contains(padding)
    }

    func fileName(image: CGImage, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH.mm.ss"
        var result = filename.replacingOccurrences(of: "{date}", with: day)
            .replacingOccurrences(of: "{time}", with: formatter.string(from: date))
            .replacingOccurrences(of: "{width}", with: String(image.width))
            .replacingOccurrences(of: "{height}", with: String(image.height))
        result = result.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty || result == "." || result == ".." { result = "Screenshot" }
        return String(result.prefix(180)) + "." + format.fileExtension
    }

    func render(_ image: CGImage) -> CGImage? {
        guard isValid else { return nil }
        let ratio = min(1, maxWidth > 0 ? CGFloat(maxWidth) / CGFloat(image.width) : 1,
                        maxHeight > 0 ? CGFloat(maxHeight) / CGFloat(image.height) : 1)
        let width = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let height = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        let outputWidth = width + padding * 2
        let outputHeight = height + padding * 2
        guard outputWidth <= 32_768, outputHeight <= 32_768, outputWidth * outputHeight <= 100_000_000,
              let context = AnnotationRenderer.rgbContext(width: outputWidth, height: outputHeight, like: image) else { return nil }
        if let color = background.cgColor {
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: padding, y: padding, width: width, height: height))
        return context.makeImage()
    }
}

@Observable
final class ExportPresetStore {
    static let shared = ExportPresetStore()
    static let defaultsKey = "exportPresets"
    private let defaults: UserDefaults
    var presets: [ExportPreset] {
        didSet {
            if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.defaultsKey) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presets = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([ExportPreset].self, from: $0) } ?? []
    }
}

struct ExportPresetsView: View {
    @Bindable private var store: ExportPresetStore

    init(store: ExportPresetStore = .shared) { _store = Bindable(store) }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Export Presets").font(.title2.bold())
                Spacer()
                Button("Add Preset", systemImage: "plus") { store.presets.append(ExportPreset()) }
            }.padding()
            Text("Choose a preset in the Save panel. Size and padding are in pixels; zero leaves a dimension unrestricted.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal)
            ScrollView {
                ForEach($store.presets) { $preset in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Form {
                                TextField("Name", text: $preset.name)
                                TextField("Maximum width", value: $preset.maxWidth, format: .number)
                                TextField("Maximum height", value: $preset.maxHeight, format: .number)
                                TextField("Padding", value: $preset.padding, format: .number)
                                Picker("Background", selection: $preset.background) {
                                    ForEach(CanvasFill.allCases) { Text($0.title).tag($0) }
                                }
                                Picker("Format", selection: $preset.format) {
                                    ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                                }
                                TextField("Filename", text: $preset.filename)
                            }
                            .formStyle(.columns)
                            Text("Filename tokens: {date}, {time}, {width}, {height}. The extension is added automatically.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if !preset.isValid {
                                Text("Enter a name, dimensions from 0 to 16384, and padding from 0 to 2048.").foregroundStyle(.red)
                            }
                            Button("Delete Preset", role: .destructive) { store.presets.removeAll { $0.id == preset.id } }
                        }.padding(8)
                    }.padding(.horizontal)
                }
                if store.presets.isEmpty {
                    ContentUnavailableView("No Export Presets", systemImage: "slider.horizontal.3", description: Text("Add a preset for documentation, issue reports, or sharing."))
                }
            }
        }.frame(width: 540, height: 580)
    }
}
#endif
