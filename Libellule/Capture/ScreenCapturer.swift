#if os(macOS)
import AppKit
import ScreenCaptureKit
import os

let captureLog = Logger(subsystem: "dev.libellule", category: "capture")

/// What was drawn on one display in live annotation mode.
nonisolated struct SurfaceDrawing: Sendable {
    var annotations: [Annotation] = []
    var dimsLights = false
    /// The whiteboard or blackboard shown under the drawing, if one was.
    var board: Board? = nil

    /// Nothing drawn, the lights left on and no board: the capture shows the screen as it was.
    var isEmpty: Bool { annotations.isEmpty && !dimsLights && board == nil }
}

/// A full-resolution picture of one display, taken the moment the shortcut was pressed.
struct ScreenSnapshot: Identifiable {
    let id = UUID()
    let screen: NSScreen
    /// The raw capture: pixel-sized, top-left origin, like every CGImage.
    let image: CGImage
    /// Drawn on the live screen before capturing, in this screen's point space.
    let drawing: SurfaceDrawing
    /// What the selection overlay shows: the capture with any live drawing burned in.
    let displayImage: CGImage
    /// Pixels per point for this display (2 on Retina).
    let scale: CGFloat

    var annotations: [Annotation] { drawing.annotations }

    init(screen: NSScreen, image: CGImage, drawing: SurfaceDrawing = SurfaceDrawing()) {
        self.screen = screen
        self.image = image
        self.drawing = drawing
        let scale = screen.pixelScale(of: image)
        self.scale = scale
        let untouched = drawing.isEmpty
        // A magnifier drawn on the live screen shows the capture itself now that the overlays are gone.
        let backdrop = drawing.annotations.contains(where: \.needsBackdrop) ? AnnotationRenderer.Backdrop(image: image, covering: screen) : nil
        displayImage = untouched ? image : (AnnotationRenderer.flatten(drawing.annotations, onto: image, scale: scale, backdrop: backdrop, dimsLights: drawing.dimsLights, board: drawing.board) ?? image)
    }
}

extension NSScreen {
    /// Pixels per point of `image`, a picture of this whole display (2 on Retina).
    func pixelScale(of image: CGImage) -> CGFloat {
        frame.width > 0 ? CGFloat(image.width) / frame.width : backingScaleFactor
    }
}

extension AnnotationRenderer.Backdrop {
    /// A picture of a whole display, for drawing in that display's point space.
    convenience init(image: CGImage, covering screen: NSScreen) {
        self.init(original: image, pointSize: screen.frame.size, scale: screen.pixelScale(of: image))
    }
}

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noImage

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Libellule isn't allowed to record the screen."
        case .noImage: "The system returned no image for the display."
        }
    }
}

enum ScreenCapturer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Makes macOS show its Screen Recording prompt and list Libellule in System Settings.
    /// Asking ScreenCaptureKit for the shareable content is what registers the app with the
    /// privacy system; the older `CGRequestScreenCaptureAccess` doesn't reliably do that anymore.
    @discardableResult
    static func requestPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Diagnostics.log("Access request ended with · \(error)")
        }
        let granted = hasPermission
        Diagnostics.log("Access granted after request: \(granted)")
        return granted
    }

    /// A live capture doesn't touch the screen until the user commits, so check before the overlay goes up,
    /// letting macOS show its prompt (which also lists the app in System Settings) the first time.
    static func ensurePermission() async throws {
        if hasPermission { return }
        await requestPermission()
        guard hasPermission else { throw ScreenCaptureError.permissionDenied }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Captures every connected display, without the cursor, as SDR images, attaching any
    /// live-screen `annotations` (keyed by display) to the matching snapshot.
    /// The first call without access makes macOS show its permission prompt and throw.
    static func snapshotAllScreens(drawings: [CGDirectDisplayID: SurfaceDrawing] = [:]) async throws -> [ScreenSnapshot] {
        let started = ContinuousClock.now
        let screens = NSScreen.screens
        // All displays at once: each capture mostly waits on the window server, so one after another adds up.
        let snapshots = try await withThrowingTaskGroup(of: (Int, ScreenSnapshot).self) { group in
            for (index, screen) in screens.enumerated() {
                let drawing = screen.displayID.flatMap { drawings[$0] } ?? SurfaceDrawing()
                group.addTask { (index, try await snapshot(of: screen, drawing: drawing)) }
            }
            var captured: [(Int, ScreenSnapshot)] = []
            for try await result in group {
                captured.append(result)
            }
            return captured.sorted { $0.0 < $1.0 }.map(\.1)  // in NSScreen.screens order, the main display first
        }
        Diagnostics.log("Captured \(snapshots.count) display(s) in \(started.duration(to: .now))")
        return snapshots
    }

    /// One display, without the cursor, as an SDR image.
    static func snapshot(of screen: NSScreen, drawing: SurfaceDrawing = SurfaceDrawing()) async throws -> ScreenSnapshot {
        let output = try await SCScreenshotManager.captureScreenshot(rect: displaySpaceRect(for: screen), configuration: screenshotConfiguration())
        return ScreenSnapshot(screen: screen, image: try sdrImage(of: output), drawing: drawing)
    }

    /// What one display shows behind this app's windows: the picture a live-screen magnifier enlarges,
    /// and the one a live capture takes the moment the user commits.
    static func snapshotBehindOverlays(of screen: NSScreen) async throws -> CGImage {
        try await snapshot(behind: filterBehindOverlays(for: screen))
    }

    /// What every display in `screens` shows behind this app's windows, all taken at once so they show the same
    /// moment: the pictures annotation mode draws on while the screen is frozen. In the order of `screens`.
    static func snapshotsBehindOverlays(of screens: [NSScreen]) async throws -> [CGImage] {
        try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (index, screen) in screens.enumerated() {
                group.addTask { (index, try await snapshotBehindOverlays(of: screen)) }
            }
            var taken: [(Int, CGImage)] = []
            for try await result in group {
                taken.append(result)
            }
            return taken.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// One display without this app's own windows. The filter can be made ahead of time and kept:
    /// it excludes the app, so overlays opened later stay out of the picture too.
    static func filterBehindOverlays(for screen: NSScreen) async throws -> SCContentFilter {
        guard let displayID = screen.displayID else { throw ScreenCaptureError.noImage }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw ScreenCaptureError.noImage }
        let ourProcess = ProcessInfo.processInfo.processIdentifier
        let ours = content.applications.filter { $0.processID == ourProcess }
        return SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
    }

    /// What the filter describes, right now, without the cursor, as an SDR image.
    static func snapshot(behind filter: SCContentFilter) async throws -> CGImage {
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: screenshotConfiguration())
        return try sdrImage(of: output)
    }

    /// The windows a user might want to grab, front-most first, without our own windows or the
    /// system's full-screen helper layers (the Dock, for instance, reports a window the size of the display).
    static func onScreenWindows() async -> [SCWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let ourProcess = ProcessInfo.processInfo.processIdentifier
        let ourBundle = Bundle.main.bundleIdentifier
        let hiddenBundles: Set<String> = ["com.apple.dock", "com.apple.WindowManager", "com.apple.notificationcenterui"]
        let displayRects = content.displays.map(\.frame)
        return content.windows.filter { window in
            guard let app = window.owningApplication, app.processID != ourProcess, app.bundleIdentifier != ourBundle else { return false }
            guard !hiddenBundles.contains(app.bundleIdentifier) else { return false }
            guard window.frame.width >= 20, window.frame.height >= 20 else { return false }
            // System overlays above the normal layer that blanket a whole display aren't real windows.
            if window.windowLayer != 0, displayRects.contains(where: { window.frame.contains($0) }) { return false }
            return true
        }
    }

    /// One window on its own, even where other windows overlap it. With the shadow included the
    /// image is larger than the window and transparent around it, like the system's own ⇧⌘4 + Space.
    static func captureWindow(_ window: SCWindow, includeShadow: Bool) async throws -> (image: CGImage, scale: CGFloat) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = screenshotConfiguration()
        configuration.ignoreShadows = !includeShadow
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
        return (try sdrImage(of: output), CGFloat(filter.pointPixelScale))
    }

    /// Every capture leaves the cursor out and asks for SDR.
    private static func screenshotConfiguration() -> SCScreenshotConfiguration {
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        return configuration
    }

    private static func sdrImage(of output: SCScreenshotOutput) throws -> CGImage {
        guard let image = output.sdrImage else { throw ScreenCaptureError.noImage }
        return image
    }

    /// Converts a Cocoa screen frame (origin at the bottom-left of the primary display) to the
    /// display space ScreenCaptureKit uses (origin at the top-left of the primary display).
    static func displaySpaceRect(for screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screen.frame }
        let frame = screen.frame
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }
}
#endif
