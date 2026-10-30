#if os(macOS)
import AppKit
import Combine
import ImageIO
import SwiftUI

struct CaptureHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date.now
    var title = String(localized: "Screenshot")
    var text = ""
    var isFavorite = false
}

/// Only flattened visible pixels are persisted; OCR indexes those same pixels after redaction.
@Observable
final class CaptureHistoryStore {
    static let shared = CaptureHistoryStore()
    static let enabledKey = "captureHistoryEnabled"
    static let retentionKey = "captureHistoryRetentionDays"
    private(set) var entries: [CaptureHistoryEntry] = []
    private(set) var errorMessage: String?
    private let directory: URL
    private let defaults: UserDefaults
    private var indexIsReadable = true
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Libellule/History", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: indexURL.path) {
                entries = try JSONDecoder().decode([CaptureHistoryEntry].self, from: Data(contentsOf: indexURL))
            }
        } catch {
            indexIsReadable = false
            errorMessage = error.localizedDescription
        }
        prune()
    }

    func record(_ document: AnnotationDocument, indexText: Bool = true) {
        guard indexIsReadable, defaults.bool(forKey: Self.enabledKey), let image = document.flattenedImage(), let data = document.pngData(from: image) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let entry = CaptureHistoryEntry()
            try data.write(to: imageURL(entry.id), options: .atomic)
            entries.insert(entry, at: 0)
            guard persist() else {
                entries.removeAll { $0.id == entry.id }
                try? FileManager.default.removeItem(at: imageURL(entry.id))
                return
            }
            prune()
            guard indexText else { return }
            Task {
                let text = (try? await TextRecognizer.recognizeText(in: image, joining: false)) ?? ""
                guard defaults.bool(forKey: Self.enabledKey), let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
                entries[index].text = text
                persist()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func imageURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("png") }

    func image(_ entry: CaptureHistoryEntry) -> CGImage? { try? ImageImport.read(imageURL(entry.id)).image }

    func thumbnail(_ entry: CaptureHistoryEntry) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(imageURL(entry.id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                              kCGImageSourceCreateThumbnailWithTransform: true,
                                                              kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary)
    }

    func favorite(_ entry: CaptureHistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isFavorite.toggle()
        persist()
        prune()
    }

    func delete(_ entry: CaptureHistoryEntry) {
        do {
            let url = imageURL(entry.id)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            entries.removeAll { $0.id == entry.id }
            persist()
        } catch { errorMessage = error.localizedDescription }
    }

    func clear() {
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            entries = []
            indexIsReadable = true
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func prune(now: Date = .now) {
        let days = defaults.object(forKey: Self.retentionKey) as? Int ?? 7
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86400)
        var retained = 0
        let expired = entries.filter { entry in
            guard !entry.isFavorite else { return false }
            retained += 1
            return entry.date < cutoff || retained > 100
        }
        for entry in expired { delete(entry) }
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct CaptureHistoryView: View {
    @Bindable private var store: CaptureHistoryStore
    @AppStorage(CaptureHistoryStore.enabledKey) private var enabled = false
    @AppStorage(CaptureHistoryStore.retentionKey) private var retention = 7
    @State private var query = ""
    @State private var favoritesOnly = false
    @State private var confirmingClear = false

    init(store: CaptureHistoryStore = .shared) { _store = Bindable(store) }

    private var filtered: [CaptureHistoryEntry] {
        store.entries.filter { (!favoritesOnly || $0.isFavorite) && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Keep capture history on this Mac", isOn: $enabled)
                Spacer()
                Picker("Delete after", selection: $retention) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }.frame(width: 210)
                .onChange(of: retention) { _, _ in store.prune() }
            }
            Text("Stores the visible image and searchable text after redaction. Keeps up to 100 recent captures; favorites stay until deleted. Turning history off stops new saves.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Search recognized text", text: $query)
                Toggle("Favorites", isOn: $favoritesOnly)
                Button("Delete All…", role: .destructive) { confirmingClear = true }.disabled(store.entries.isEmpty && store.errorMessage == nil)
            }
            if let message = store.errorMessage { Text(message).foregroundStyle(.red) }
            if filtered.isEmpty {
                ContentUnavailableView("No Captures", systemImage: "photo.stack", description: Text(enabled ? "New captures will appear here." : "Enable history to keep future captures."))
            } else {
                List(filtered) { entry in
                    HStack(spacing: 16) {
                        if let image = store.thumbnail(entry) {
                            Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 120, height: 75)
                        }
                        VStack(alignment: .leading) {
                            Text(entry.date, style: .date)
                            Text(entry.date, style: .time).foregroundStyle(.secondary)
                            Text(entry.text.prefix(120)).lineLimit(2).font(.caption)
                        }
                        Spacer()
                        Button { store.favorite(entry) } label: {
                            Image(systemName: entry.isFavorite ? "star.fill" : "star")
                        }.help("Keep this capture until it is deleted")
                        Button("Open") { WorkspaceCoordinator.shared.openHistory(entry) }
                        Button(role: .destructive) { store.delete(entry) } label: { Image(systemName: "trash") }
                    }.padding(.vertical, 6)
                }
            }
        }.padding(20).frame(minWidth: 760, minHeight: 500)
        .confirmationDialog("Delete all capture history, including favorites?", isPresented: $confirmingClear) {
            Button("Delete All", role: .destructive) { store.clear() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in store.prune() }
    }
}
#endif
