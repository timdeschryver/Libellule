import SwiftUI

@main
struct MyApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        mainWindow

        #if os(macOS)
        Settings {
            SettingsView()
        }

        // The app icon's dragonfly and viewfinder as a template image, so the menu bar tints it.
        MenuBarExtra("Libellule", image: "MenuBarIcon") {
            MenuBarContent()
        }
        #endif
    }

    private var mainWindow: some Scene {
        #if os(macOS)
        WindowGroup(id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        #else
        WindowGroup {
            ContentView()
        }
        #endif
    }
}

#if os(macOS)
import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run inside the app for its code; they need neither its shortcuts nor the self-test.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Diagnostics.logLaunch()
        DockIcon.apply()
        CaptureCoordinator.shared.start()
        Diagnostics.runSelfTestIfRequested()
    }

    /// Closing the main window shouldn't quit: the shortcut and menu bar item keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting closes every editor without asking each one, so ask once for all of them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = CaptureCoordinator.shared.unsavedEditorCount
        guard unsaved > 0 else { return .terminateNow }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = unsaved == 1 ? "Quit without copying the open screenshot?" : "Quit without copying \(unsaved) open screenshots?"
        alert.informativeText = String(localized: "Changes that haven't been copied, saved or shared are lost when Libellule quits.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        let quit = alert.addButton(withTitle: String(localized: "Quit"))
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// The app lives in the menu bar (LSUIElement) and shows in the Dock only when asked to in Settings.
enum DockIcon {
    static func apply() {
        let wanted: NSApplication.ActivationPolicy = Preferences.showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
    }
}

/// The status-bar menu. The app has no Dock icon unless asked to, so this is also how the main window comes back.
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HotKeyMenuButton("Capture Area", action: .captureArea) {
            CaptureCoordinator.shared.captureAreaRequested(after: .milliseconds(250))
        }
        HotKeyMenuButton("Repeat Last Area", action: .repeatArea) {
            CaptureCoordinator.shared.repeatLastArea(after: .milliseconds(250))
        }
        HotKeyMenuButton(CaptureCoordinator.shared.isCountingDown ? "Cancel Delayed Capture" : "Capture After 3 Seconds", action: .captureDelayed) {
            CaptureCoordinator.shared.beginDelayedCapture()
        }
        HotKeyMenuButton("Annotate Screen", action: .annotateScreen) {
            CaptureCoordinator.shared.toggleLiveAnnotationFromMenu()
        }
        HotKeyMenuButton("Copy Text from Screen", action: .copyText) {
            CaptureCoordinator.shared.beginCapture(after: .milliseconds(250), purpose: .text)
        }
        Divider()
        Button("Open Libellule Window") {
            openWindow(id: "main")
            NSApp.activate()
        }
        SettingsLink {
            Text("Settings…")
        }
        Button("Check for Updates…") {
            AppInfo.checkForUpdates()
        }
        Divider()
        Button("Quit Libellule") {
            NSApp.terminate(nil)
        }
    }
}

/// A menu item that shows the action's global shortcut next to its title.
struct HotKeyMenuButton: View {
    let title: String
    let action: HotKeyAction
    let perform: () -> Void

    init(_ title: String, action: HotKeyAction, perform: @escaping () -> Void) {
        self.title = title
        self.action = action
        self.perform = perform
    }

    var body: some View {
        // The menu closes before the action runs, so it doesn't end up in the frozen screen.
        let button = Button(title, action: perform)
        let combo = HotKeyManager.shared.combo(for: action)
        if let character = combo.keyEquivalentCharacter {
            button.keyboardShortcut(KeyEquivalent(character), modifiers: combo.eventModifiers)
        } else {
            button
        }
    }
}
#endif
