#if os(macOS)
import AppKit
import ScreenCaptureKit
import os

/// Writes what the app is doing to the unified log and to a plain file, because the unified
/// log isn't always readable from where a developer is looking.
enum Diagnostics {
    /// Inside the sandbox this resolves to ~/Library/Containers/<bundle id>/Data/Library/Logs/Libellule.log
    static let logURL: URL = {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Libellule.log")
    }()

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Past this size the file moves aside to `Libellule.old.log`, replacing the one before, and starts over.
    private static let maximumLogSize: UInt64 = 1_000_000

    /// Kept open between lines; nil until the first one, or after the file couldn't be written.
    private static var logHandle: FileHandle?

    static func log(_ message: String) {
        captureLog.notice("\(message, privacy: .public)")
        let line = "\(timestamp.string(from: .now)) [\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
        append(Data(line.utf8))
    }

    private static func append(_ data: Data) {
        guard let handle = logHandle ?? openLog() else { return }
        do {
            // Another instance (a self-test, say) may have written meanwhile, so find the end each time.
            if try handle.seekToEnd() > maximumLogSize {
                try handle.close()
                logHandle = nil
                let previous = logURL.deletingLastPathComponent().appendingPathComponent("Libellule.old.log")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: logURL, to: previous)
                guard let fresh = openLog() else { return }
                try fresh.write(contentsOf: data)
            } else {
                try handle.write(contentsOf: data)
            }
        } catch {
            try? logHandle?.close()
            logHandle = nil
        }
    }

    private static func openLog() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        return logHandle
    }

    static func logLaunch() {
        log("Launched \(Bundle.main.bundlePath) · screen recording preflight=\(ScreenCapturer.hasPermission)")
    }

    /// `open -n Libellule.app --args --self-test` runs the capture pipeline headlessly, logs each step and quits.
    static func runSelfTestIfRequested() {
        guard CommandLine.arguments.contains("--self-test") else { return }
        Task {
            log("self-test: start · preflight=\(ScreenCapturer.hasPermission)")
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                log("self-test: shareable content ok · displays=\(content.displays.count) windows=\(content.windows.count)")
            } catch {
                log("self-test: shareable content failed · \(error)")
            }
            do {
                let snapshots = try await ScreenCapturer.snapshotAllScreens()
                log("self-test: captured \(snapshots.map { "\($0.image.width)×\($0.image.height)" })")
            } catch {
                log("self-test: capture failed · \(error)")
            }
            if let screen = NSScreen.main {
                do {
                    let behind = try await ScreenCapturer.snapshotBehindOverlays(of: screen)
                    log("self-test: behind-overlays capture ok · \(behind.width)×\(behind.height)")
                    // Redaction on capture, with its notices one after the other, as a copy-only capture shows them.
                    let document = AnnotationDocument(image: selfTestPicture(on: behind) ?? behind, scale: screen.backingScaleFactor)
                    CaptureToast.show("Looking for anything sensitive…", systemImage: "eye.slash", on: screen)
                    let result = await document.layer.redact(document.image, style: .preferred)
                    CaptureToast.show(result?.message ?? "-", systemImage: "eye.slash", on: screen)
                    CaptureToast.show("Copied to clipboard · \(result?.message ?? "-")", systemImage: "doc.on.clipboard", on: screen)
                    try? await Task.sleep(for: .seconds(2.5))
                    log("self-test: redaction and notices ok · \(document.layer.annotations.count) area(s) hidden")
                    // The clipboard's TIFF is only made when an app asks; ask for it, on a pasteboard of our own.
                    let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.libellule.self-test"))
                    let copied = document.copyToPasteboard(pasteboard)
                    let png = pasteboard.data(forType: .png)?.count ?? 0
                    let tiff = pasteboard.data(forType: .tiff).flatMap(NSBitmapImageRep.init(data:))
                    log("self-test: copy ok=\(copied) · png \(png) bytes · tiff \(tiff.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? "missing") · unsaved=\(document.hasUnsavedChanges)")
                    pasteboard.releaseGlobally()
                } catch {
                    log("self-test: behind-overlays capture failed · \(error)")
                }
            }
            do {
                let frozen = try await ScreenCapturer.snapshotsBehindOverlays(of: NSScreen.screens)
                log("self-test: annotation freeze ok · \(frozen.map { "\($0.width)×\($0.height)" })")
            } catch {
                log("self-test: annotation freeze failed · \(error)")
            }
            if let screen = NSScreen.main {
                let feed = LiveScreenFeed(screen: screen)
                var frames = 0
                var size = ""
                feed.onFrame = { image in
                    frames += 1
                    size = "\(image.width)×\(image.height)"
                }
                do {
                    try await feed.start()
                    try? await Task.sleep(for: .seconds(1.5))
                    feed.stop()
                    log("self-test: live feed delivered \(frames) frame(s) \(size)")
                } catch {
                    log("self-test: live feed failed · \(error)")
                }
            }
            let windows = await ScreenCapturer.onScreenWindows()
            log("self-test: \(windows.count) window candidate(s); front: \(windows.prefix(3).map { "\($0.owningApplication?.applicationName ?? "?")/\($0.title ?? "")@\($0.frame.integral)" })")
            if let first = windows.first {
                do {
                    let shadowed = try await ScreenCapturer.captureWindow(first, includeShadow: true)
                    let plain = try await ScreenCapturer.captureWindow(first, includeShadow: false)
                    log("self-test: window capture ok · with shadow \(shadowed.image.width)×\(shadowed.image.height) alpha=\(shadowed.image.alphaInfo.rawValue) · without \(plain.image.width)×\(plain.image.height) · scale \(shadowed.scale)")
                } catch {
                    log("self-test: window capture failed · \(error)")
                }
            }
            log("self-test: end · preflight=\(ScreenCapturer.hasPermission)")
            NSApp.terminate(nil)
        }
    }

    /// The screen with a made-up email address and phone number on a white card, so redaction always finds something.
    private static func selfTestPicture(on screen: CGImage) -> CGImage? {
        guard let context = AnnotationRenderer.rgbContext(width: screen.width, height: screen.height, like: screen) else { return nil }
        context.draw(screen, in: CGRect(x: 0, y: 0, width: screen.width, height: screen.height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 80, y: 80, width: 1400, height: 260))
        let font = CTFontCreateWithName("Menlo" as CFString, 48, nil)
        for (index, line) in ["Mail jane.doe@example.com", "Call +32 470 12 34 56"].enumerated() {
            let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: CGColor(gray: 0.1, alpha: 1)])
            context.textPosition = CGPoint(x: 120, y: 250 - CGFloat(index) * 100)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        return context.makeImage()
    }
}
#endif
