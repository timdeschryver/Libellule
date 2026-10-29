#if os(macOS)
import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// A steady feed of what one display shows behind this app's windows, so lenses on the live screen stay live.
/// Frames only arrive while something on the display changes, at most `framesPerSecond` times a second.
final class LiveScreenFeed: NSObject, SCStreamDelegate, SCStreamOutput {
    let screen: NSScreen
    /// Called on the main thread with each new frame: a pixel-sized picture of the whole display.
    var onFrame: ((CGImage) -> Void)?

    private var stream: SCStream?
    private let frameQueue = DispatchQueue(label: "dev.libellule.live-feed", qos: .userInteractive)
    private static let framesPerSecond: Int32 = 15

    init(screen: NSScreen) {
        self.screen = screen
    }

    func start() async throws {
        guard stream == nil else { return }
        let filter = try await ScreenCapturer.filterBehindOverlays(for: screen)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        self.stream = stream
        Diagnostics.log("Live feed started for display \(screen.displayID ?? 0) at \(configuration.width)×\(configuration.height)")
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        onFrame = nil
        Task {
            try? await stream.stopCapture()
        }
    }

    // MARK: - SCStreamOutput and SCStreamDelegate (called on the frame queue)

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.isComplete(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer,
              let image = Self.image(from: pixelBuffer)
        else { return }
        Task { @MainActor in
            self.onFrame?(image)
        }
    }

    nonisolated func stream(_ stopped: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            Diagnostics.log("Live feed stopped · \(error)")
            if self.stream === stopped { self.stream = nil }
        }
    }

    /// Only frames with new, complete content; idle and blank ones carry nothing to show.
    private nonisolated static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else { return false }
        return status == .complete
    }

    /// Copies the pixels out into an image of their own: the buffer goes back to the capture system afterwards.
    private nonisolated static func image(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
#endif
