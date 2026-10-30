import SwiftUI

#if os(macOS)
import AppKit
import Combine
import UniformTypeIdentifiers

/// The main window: buttons to try both modes, the global shortcuts at a glance, and whether capturing is allowed.
/// The title bar stays empty and see-through, since the window names the app itself.
struct ContentView: View {
    @State private var hasScreenAccess = ScreenCapturer.hasPermission
    @AppStorage(SettingsTab.defaultsKey) private var settingsTab = SettingsTab.general
    @Environment(\.openSettings) private var openSettings
    private var hotKeys: HotKeyManager { .shared }

    var body: some View {
        VStack(spacing: 24) {
            header
            actions
            workspaceActions
            shortcutList
            permissionRow
        }
        .padding(.horizontal, 28)
        .padding(.top, 4)
        .padding(.bottom, 28)
        .frame(width: 500)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { WorkspaceCoordinator.shared.acceptDrop($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenAccess = ScreenCapturer.hasPermission
        }
    }

    private var workspaceActions: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Open Image or Project…", systemImage: "folder") { WorkspaceCoordinator.shared.openPanel() }
                Button("Paste Image", systemImage: "doc.on.clipboard") { WorkspaceCoordinator.shared.pasteImage() }
            }
            HStack {
                Button("History", systemImage: "photo.stack") { WorkspaceCoordinator.shared.showHistory() }
                Button("Scrolling Capture", systemImage: "rectangle.split.1x2") { WorkspaceCoordinator.shared.showScrollingCapture() }
                Button("Compare", systemImage: "rectangle.on.rectangle") { WorkspaceCoordinator.shared.showComparison() }
            }
            Text("Drop an image or an editable project here to open it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Libellule")
                .font(.largeTitle.bold())
            Text("See everything. Share only what matters.")
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                Button {
                    CaptureCoordinator.shared.captureAreaRequested(after: .milliseconds(150))
                } label: {
                    Label("Capture Area", systemImage: "plus.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("Choose an area, a window or a whole screen to capture (\(hotKeys.combo(for: .captureArea).displayString))")
                Text("Drag an area · click a window · ↩ whole screen · T copies text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)  // wrap rather than cut off the keys
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 8) {
                Button {
                    CaptureCoordinator.shared.toggleLiveAnnotationFromMenu()
                } label: {
                    Label("Annotate Screen", systemImage: "pencil.and.outline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Draw on top of every app, on every display, without taking a screenshot first (\(hotKeys.combo(for: .annotateScreen).displayString))")
                Text("Draw anywhere · ↩ keeps a screenshot · esc leaves")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    /// Every global shortcut on its own row with its keys, instead of buried in a sentence.
    private var shortcutList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Shortcuts")
                    .font(.headline)
                Spacer()
                Button("Change…") {
                    settingsTab = .shortcuts
                    openSettings()
                }
                .buttonStyle(.link)
                .help("Record different shortcuts in Settings")
            }
            VStack(spacing: 0) {
                ForEach(HotKeyAction.allCases) { action in
                    if action != HotKeyAction.allCases.first {
                        Divider()
                    }
                    HStack {
                        Label {
                            Text(action.title)
                        } icon: {
                            Image(systemName: symbol(for: action))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                        }
                        Spacer()
                        KeyCaps(hotKeys.combo(for: action).displayString)
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func symbol(for action: HotKeyAction) -> String {
        switch action {
        case .captureArea: "plus.viewfinder"
        case .annotateScreen: "pencil.and.outline"
        case .copyText: "text.viewfinder"
        case .repeatArea: "arrow.clockwise"
        case .captureDelayed: "timer"
        }
    }

    private var permissionRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hasScreenAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(hasScreenAccess ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(hasScreenAccess ? "Screen Recording access granted" : "Screen Recording access needed for screenshots")
                    .font(.callout.weight(.medium))
                if !hasScreenAccess {
                    Text("Drawing on the screen works without it. macOS asks the first time you capture; turn Libellule on in System Settings (use + if it isn't listed), then quit and reopen the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if !hasScreenAccess {
                Button("Grant Access…") {
                    Task {
                        hasScreenAccess = await ScreenCapturer.requestPermission()
                        if !hasScreenAccess {
                            ScreenCapturer.openPrivacySettings()
                        }
                    }
                }
                .help("Ask macOS for Screen Recording access, or open the setting if it has already been asked")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background((hasScreenAccess ? Color.green : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A shortcut such as ⇧⌘7 drawn as a key cap.
private struct KeyCaps: View {
    let keys: String

    init(_ keys: String) {
        self.keys = keys
    }

    var body: some View {
        Text(keys)
            .font(.callout.monospaced().weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator))
    }
}

#else

struct ContentView: View {
    var body: some View {
        ContentUnavailableView(
            "Libellule runs on the Mac",
            systemImage: "camera.viewfinder",
            description: Text("Screen capture and annotation are available in the macOS app.")
        )
    }
}

#endif

#Preview {
    ContentView()
}
