#if os(macOS)
import AppKit
import SwiftUI

/// A borderless window covering one display, above everything else including the menu bar.
class FullScreenOverlayWindow: NSWindow {
    /// The level for small panels that must float above these overlays.
    static let paletteLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    init(screen: NSScreen, opaque: Bool) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = opaque
        backgroundColor = opaque ? .black : .clear
        hasShadow = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Must be set explicitly: otherwise macOS lets clicks fall through the transparent parts
        // of a non-opaque window to whatever is underneath, and nothing can be drawn.
        ignoresMouseEvents = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Keeps the app's ordinary windows (main window, editors, settings) out of the way while an overlay
/// session runs. Activating the app would otherwise pull them in front of whatever the user was looking at.
final class HiddenWindows {
    private var windows: [NSWindow] = []

    func hide() {
        windows = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        for window in windows {
            window.orderOut(nil)
        }
    }

    /// Puts them back: in front when the user was in Libellule anyway, otherwise behind everything.
    func restore(inFront: Bool) {
        for window in windows.reversed() {
            if inFront { window.orderFront(nil) } else { window.orderBack(nil) }
        }
        windows.removeAll()
    }
}

/// The app that was frontmost before an overlay took over, so focus can go back to it afterwards.
enum PreviousApp {
    static func current() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return app
    }

    static func activate(_ app: NSRunningApplication?) {
        guard let app else { return }
        NSApp.yieldActivation(to: app)
        app.activate()
    }
}

extension NSScreen {
    /// The Core Graphics display this screen shows; stable across the app's lifetime unlike the NSScreen object.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The screen currently under the pointer, falling back to the main screen.
    static var underPointer: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) } ?? main
    }
}

extension Collection where Element: NSWindow {
    /// The window under the pointer, falling back to the first one.
    var underPointer: Element? {
        let mouse = NSEvent.mouseLocation
        return first { $0.frame.contains(mouse) } ?? first
    }
}

/// A borderless, draggable panel that floats above the overlays.
final class PalettePanel: NSPanel {
    /// Which edge of the screen the panel starts on, and which of its own edges stays put when its content resizes.
    enum Edge {
        case top, bottom, left, right

        init(_ layout: PaletteLayout) {
            switch layout {
            case .horizontal: self = .top
            case .left: self = .left
            case .right: self = .right
            }
        }
    }

    private let edge: Edge

    /// `followsContent` lets the panel grow and shrink with its SwiftUI content (toolbars whose controls come and
    /// go). Without it the panel keeps the size it opened with, for content that never changes, like a notice.
    init(rootView: some View, on screen: NSScreen?, edge: Edge = .top, followsContent: Bool = true) {
        let hosting = NSHostingView(rootView: rootView)
        let size = hosting.fittingSize
        self.edge = edge
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        // Clicks on the translucent material must reach the controls, not fall through to the overlay.
        ignoresMouseEvents = false
        // Set last: `isFloatingPanel` and friends would silently reset the level below the overlays.
        level = FullScreenOverlayWindow.paletteLevel
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        if followsContent {
            contentView = hosting
        } else {
            // As the content view, a hosting view keeps fitting the panel to its content after every layout.
            // Notices shown right after a redaction sent that into a loop until AppKit gave up and the app
            // crashed; inside a plain container with no sizing of its own it can't touch the panel at all.
            hosting.sizingOptions = []
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            contentView = container
        }
        setContentSize(size)

        let area = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin: NSPoint
        switch edge {
        case .top: origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 8)
        case .bottom: origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 16)
        case .left: origin = NSPoint(x: area.minX + 8, y: area.midY - size.height / 2)
        case .right: origin = NSPoint(x: area.maxX - size.width - 8, y: area.midY - size.height / 2)
        }
        setFrameOrigin(origin)
    }

    override var canBecomeKey: Bool { true }

    /// AppKit keeps the top-left corner when the content resizes the panel, so a bar whose controls come and go
    /// would creep sideways. Keep it centred where it is (also after the user dragged it) and on its edge.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(anchored(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(anchored(frameRect), display: displayFlag, animate: animateFlag)
    }

    private func anchored(_ proposed: NSRect) -> NSRect {
        let current = frame
        guard proposed.size != current.size, !current.isEmpty else { return proposed }
        var anchored = proposed
        switch edge {
        case .top:
            anchored.origin.x = current.midX - proposed.width / 2
            anchored.origin.y = current.maxY - proposed.height
        case .bottom:
            anchored.origin.x = current.midX - proposed.width / 2
            anchored.origin.y = current.minY
        case .left:
            anchored.origin.x = current.minX
            anchored.origin.y = current.midY - proposed.height / 2
        case .right:
            anchored.origin.x = current.maxX - proposed.width
            anchored.origin.y = current.midY - proposed.height / 2
        }
        return anchored
    }

    /// Puts the panel where it was last left on this display, if it was, and still fits there.
    func restorePlacement(layout: PaletteLayout) {
        guard let screen = screen ?? NSScreen.main, let origin = PalettePlacement.origin(on: screen, layout: layout) else { return }
        let area = screen.visibleFrame
        let clamped = NSPoint(
            x: min(max(origin.x, area.minX), max(area.minX, area.maxX - frame.width)),
            y: min(max(origin.y, area.minY), max(area.minY, area.maxY - frame.height))
        )
        setFrameOrigin(clamped)
    }

    func rememberPlacement(layout: PaletteLayout) {
        guard let screen else { return }
        PalettePlacement.remember(frame.origin, on: screen, layout: layout)
    }
}

/// Where the user left the palette on each display, per layout, kept across launches as an offset from the
/// display's usable area, so it survives the Dock and menu bar changing.
enum PalettePlacement {
    static let defaultsKey = "palettePlacements"

    private static func key(_ screen: NSScreen, _ layout: PaletteLayout) -> String? {
        screen.displayID.map { "\($0)-\(layout.rawValue)" }
    }

    static func origin(on screen: NSScreen, layout: PaletteLayout) -> NSPoint? {
        guard let key = key(screen, layout),
              let stored = UserDefaults.standard.dictionary(forKey: defaultsKey)?[key] as? [Double], stored.count == 2
        else { return nil }
        let area = screen.visibleFrame
        return NSPoint(x: area.minX + stored[0], y: area.minY + stored[1])
    }

    static func remember(_ origin: NSPoint, on screen: NSScreen, layout: PaletteLayout) {
        guard let key = key(screen, layout) else { return }
        let area = screen.visibleFrame
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        all[key] = [Double(origin.x - area.minX), Double(origin.y - area.minY)]
        UserDefaults.standard.set(all, forKey: defaultsKey)
    }
}

/// The tooltip for controls on the floating bars, drawn in a panel just above them. The system's own tooltips sit
/// at a lower level than the overlays covering the displays, so they would appear through the overlay, behind the bar.
enum FloatingTooltipPanel {
    private static var panel: NSPanel?
    private static var dismissMonitor: Any?

    static let level = NSWindow.Level(rawValue: FullScreenOverlayWindow.paletteLevel.rawValue + 1)

    static let maximumWidth: CGFloat = 360

    static func show(_ text: Text) {
        hide()
        // Sized in two passes: on one line when it fits, otherwise wrapped at the maximum width. Asking a hosting
        // view for a wrapping label's size in one go gives back its narrowest layout, a tall column of words.
        let line = text.font(.callout).fixedSize()
        let lineSize = NSHostingView(rootView: line).fittingSize
        let width = min(lineSize.width, maximumWidth)
        let content = text
            .font(.callout)
            .multilineTextAlignment(.leading)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = hosting
        panel.level = level

        // Just below the pointer, as the system's tooltips are, and kept on the display.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 18)
        if origin.x + size.width > area.maxX { origin.x = max(area.minX, area.maxX - size.width - 4) }
        if origin.y < area.minY { origin.y = mouse.y + 20 }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel

        // A click or a key means the control is being used; the tooltip has done its job.
        dismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { event in
            MainActor.assumeIsolated { hide() }
            return event
        }
        Task {
            try? await Task.sleep(for: .seconds(8))
            if self.panel === panel { hide() }
        }
    }

    static func hide() {
        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
        }
        dismissMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A hosting view that treats the click that activates the app as a real click, so the first stroke isn't lost.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension View {
    /// The look of the bars that float above the overlays: a capsule of translucent material with a faint rim,
    /// and room around it for the window shadow inside the transparent panel. The insets match the corner
    /// radius, so the capsule-shaped controls at either end sit concentric with the bar.
    func floatingBar() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .padding(12)
    }
}
#endif
