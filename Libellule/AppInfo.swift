import Foundation
#if os(macOS)
import AppKit
#endif

/// Where the app lives on the web, and which version this is.
enum AppInfo {
    /// The repository releases are published from. Opened in the browser for updates: the app itself has no
    /// network access, and keeps it that way.
    static let repository = URL(string: "https://github.com/timdeschryver/Libellule")!

    static var latestRelease: URL { repository.appendingPathComponent("releases/latest") }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return build == short || build == "1" ? short : "\(short) (\(build))"
    }

    #if os(macOS)
    /// Opens the latest release in the browser, where the version can be compared with `version`.
    static func checkForUpdates() {
        NSWorkspace.shared.open(latestRelease)
    }
    #endif
}

#if os(macOS)
/// Short cues for the moments that aren't visible in the corner of the eye: the overlay coming up, going away,
/// and everything being cleared. Off unless switched on in Settings; uses the system's own sounds.
enum Sounds {
    enum Cue {
        case overlayOn, overlayOff, clear

        var name: NSSound.Name {
            switch self {
            case .overlayOn: "Pop"
            case .overlayOff: "Bottle"
            case .clear: "Tink"
            }
        }
    }

    static func play(_ cue: Cue) {
        guard Preferences.playsSounds, let sound = NSSound(named: cue.name) else { return }
        sound.volume = 0.6
        sound.play()
    }
}
#endif
