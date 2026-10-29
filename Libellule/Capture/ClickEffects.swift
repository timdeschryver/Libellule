#if os(macOS)
import AppKit
import SwiftUI

/// A click on the screen while presenting: a ripple that spreads out and fades, and a disc while the button is held.
struct ClickEffect: Identifiable, Equatable {
    let id = UUID()
    /// In the point space of the display it landed on.
    var center: CGPoint
    var displayID: CGDirectDisplayID
    var isHeld: Bool
}

/// Watches the mouse for clicks, on the overlays and (while paused) in the apps underneath, and keeps the
/// ripples to draw until they have faded.
@Observable
final class ClickEffectTracker {
    private(set) var effects: [ClickEffect] = []
    private var monitors: [Any] = []

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        let down: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let up: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        if let local = NSEvent.addLocalMonitorForEvents(matching: down.union(up), handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: down.union(up), handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
        }) {
            monitors.append(global)
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        effects.removeAll()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }), let displayID = screen.displayID else { return }
            let frame = screen.frame
            // Cocoa screen coordinates are y-up; the surface is y-down from its top-left corner.
            let local = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
            let effect = ClickEffect(center: local, displayID: displayID, isHeld: true)
            effects.append(effect)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                self?.effects.removeAll { $0.id == effect.id }  // a very long hold ends here regardless
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let index = effects.lastIndex(where: \.isHeld) else { return }
            effects[index].isHeld = false
            let id = effects[index].id
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.effects.removeAll { $0.id == id }
            }
        default:
            break
        }
    }
}

/// The ripples on one display, laid over its drawing surface.
struct ClickEffectsView: View {
    let effects: [ClickEffect]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(effects) { effect in
                RippleView(effect: effect)
                    .position(effect.center)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct RippleView: View {
    let effect: ClickEffect
    @State private var spread = false

    var body: some View {
        let size = CGFloat(Preferences.clickEffectSize)
        let color = Preferences.effectColor
        ZStack {
            Circle()
                .stroke(color, lineWidth: max(2, size * 0.06))
                .frame(width: size, height: size)
                .scaleEffect(spread ? 1 : 0.25)
                .opacity(spread ? 0 : 0.95)
            if effect.isHeld {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: size * 0.5, height: size * 0.5)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: effect.isHeld)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { spread = true }
        }
    }
}
#endif
