#if os(macOS)
import AppKit
import SwiftUI

/// What happens once a region has been selected. Chosen in Settings or on the capture toolbar, which share it.
enum CaptureCompletion: String, CaseIterable, Identifiable {
    case openEditor
    case copyAndOpenEditor
    case copyOnly
    case saveAs

    static let defaultsKey = "captureCompletion"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openEditor: String(localized: "Open the editor")
        case .copyAndOpenEditor: String(localized: "Copy to the clipboard and open the editor")
        case .copyOnly: String(localized: "Copy to the clipboard only")
        case .saveAs: String(localized: "Save to a file (asks where)")
        }
    }

    /// For the capture toolbar's menu.
    var shortTitle: String {
        switch self {
        case .openEditor: String(localized: "Edit")
        case .copyAndOpenEditor: String(localized: "Copy & Edit")
        case .copyOnly: String(localized: "Copy")
        case .saveAs: String(localized: "Save As…")
        }
    }

    var systemImage: String {
        switch self {
        case .openEditor: "square.and.pencil"
        case .copyAndOpenEditor: "doc.on.clipboard"
        case .copyOnly: "clipboard"
        case .saveAs: "square.and.arrow.down"
        }
    }

    /// The O key on the capture toolbar steps through them in order.
    var next: CaptureCompletion {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var copiesToClipboard: Bool { self == .copyAndOpenEditor || self == .copyOnly }
    var opensEditor: Bool { self == .openEditor || self == .copyAndOpenEditor }

    static var current: CaptureCompletion {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(CaptureCompletion.init(rawValue:)) ?? .openEditor }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

extension AnnotationDocument {
    /// Puts the annotated image on the clipboard as PNG, and as TIFF for apps that only take that. The TIFF is
    /// uncompressed (about 60 MB for a 5K display), so it is only made when an app actually asks for it.
    @discardableResult
    func copyToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        layer.commitTextEditing()
        guard let flattened = flattenedImage(), let png = pngData(from: flattened) else { return false }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let tiff = PromisedTIFF(image: flattened, size: pointSize)
        item.setDataProvider(tiff, forTypes: [.tiff])
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        markSaved()
        return true
    }
}

/// Renders the clipboard's TIFF on request. AppKit asks for anything still owed when the app quits,
/// so the clipboard keeps working after that too.
private final class PromisedTIFF: NSObject, NSPasteboardItemDataProvider {
    let image: CGImage
    let size: CGSize

    init(image: CGImage, size: CGSize) {
        self.image = image
        self.size = size
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let tiff = NSImage(cgImage: image, size: size).tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
    }
}

/// A short-lived "Copied" notice at the top of the screen, for captures that skip the editor.
@MainActor
enum CaptureToast {
    private static var panel: PalettePanel?

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    static func show(_ text: String, systemImage: String, on screen: NSScreen?) {
        let content = Label(text, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .padding(12)
        let toast = PalettePanel(rootView: content, on: screen, followsContent: false)
        toast.ignoresMouseEvents = true
        panel?.orderOut(nil)
        panel = toast
        toast.orderFrontRegardless()
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if panel === toast {
                toast.orderOut(nil)
                panel = nil
            }
        }
    }
}
#endif
