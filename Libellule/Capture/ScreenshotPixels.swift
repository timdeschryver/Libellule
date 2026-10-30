#if os(macOS)
import CoreGraphics
import Foundation

/// Pixel operations are independent of windows and run away from the main actor.
nonisolated enum ScreenshotPixels {
    struct Difference: Sendable {
        let image: CGImage
        let changedPixels: Int
        let totalPixels: Int
    }

    static func rgba(_ image: CGImage, width: Int? = nil, height: Int? = nil) throws -> [UInt8] {
        let width = width ?? image.width
        let height = height ?? image.height
        guard width > 0, height > 0, width <= 32_768, height <= 32_768, width * height <= 100_000_000 else { throw WorkspaceError.imageTooLarge }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WorkspaceError.invalidImage }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    static func difference(_ first: CGImage, _ second: CGImage, tolerance: Int = 12) throws -> Difference {
        guard first.width == second.width, first.height == second.height else { throw WorkspaceError.incompatibleImages }
        let a = try rgba(first)
        let b = try rgba(second)
        var output = [UInt8](repeating: 255, count: a.count)
        var changed = 0
        for offset in stride(from: 0, to: a.count, by: 4) {
            if offset % 16_384 == 0 { try Task.checkCancellation() }
            let delta = max(abs(Int(a[offset]) - Int(b[offset])), abs(Int(a[offset + 1]) - Int(b[offset + 1])),
                            abs(Int(a[offset + 2]) - Int(b[offset + 2])), abs(Int(a[offset + 3]) - Int(b[offset + 3])))
            if delta > min(255, max(0, tolerance)) {
                output[offset] = 255
                output[offset + 1] = 40
                output[offset + 2] = 70
                changed += 1
            } else {
                let gray = UInt8((Int(a[offset]) + Int(a[offset + 1]) + Int(a[offset + 2])) / 6 + 127)
                output[offset] = gray
                output[offset + 1] = gray
                output[offset + 2] = gray
            }
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData),
              let image = CGImage(width: first.width, height: first.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: first.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw WorkspaceError.invalidImage }
        return Difference(image: image, changedPixels: changed, totalPixels: first.width * first.height)
    }

    /// Compare the bottom of the old section with the top of the new one. Ambiguous flat or repeating
    /// content is rejected so the user can choose the join rather than silently lose content.
    static func detectOverlap(_ first: CGImage, _ second: CGImage) throws -> Int {
        guard first.width == second.width else { throw WorkspaceError.incompatibleImages }
        let scale = min(1, 4096.0 / Double(max(first.height, second.height)))
        let firstHeight = max(1, Int(Double(first.height) * scale))
        let secondHeight = max(1, Int(Double(second.height) * scale))
        let width = min(48, first.width)
        let a = try rgba(first, width: width, height: firstHeight)
        let b = try rgba(second, width: width, height: secondHeight)
        guard firstHeight != secondHeight || a != b else { throw WorkspaceError.noOverlap }
        let minimum = max(4, min(firstHeight, secondHeight) / 30)
        let maximum = min(firstHeight, secondHeight) - 1
        guard maximum > minimum else { throw WorkspaceError.noOverlap }

        func score(_ overlap: Int) -> Double {
            var error = 0
            var count = 0
            for sample in 0..<20 {
                let row = min(overlap - 1, sample * overlap / 20)
                for column in 0..<width {
                    let oldOffset = ((firstHeight - overlap + row) * width + column) * 4
                    let newOffset = (row * width + column) * 4
                    for channel in 0..<3 {
                        error += abs(Int(a[oldOffset + channel]) - Int(b[newOffset + channel]))
                        count += 1
                    }
                }
            }
            return Double(error) / Double(count)
        }

        var candidates: [(overlap: Int, score: Double)] = []
        for overlap in minimum...maximum {
            try Task.checkCancellation()
            candidates.append((overlap, score(overlap)))
        }
        candidates.sort { $0.score < $1.score }
        guard let best = candidates.first, best.score < 8 else { throw WorkspaceError.noOverlap }
        let alternative = candidates.first { abs($0.overlap - best.overlap) > 4 }
        guard alternative.map({ $0.score - best.score > 0.75 }) ?? true else { throw WorkspaceError.noOverlap }
        return Int((Double(best.overlap) / scale).rounded())
    }

    static func stitch(_ images: [CGImage], overlaps: [Int]) throws -> CGImage {
        guard let first = images.first, overlaps.count == images.count - 1,
              images.allSatisfy({ $0.width == first.width }) else { throw WorkspaceError.incompatibleImages }
        var height = first.height
        for index in overlaps.indices {
            guard overlaps[index] >= 0, overlaps[index] < min(images[index].height, images[index + 1].height) else { throw WorkspaceError.noOverlap }
            height += images[index + 1].height - overlaps[index]
        }
        guard height <= 32_768, first.width * height <= 100_000_000 else { throw WorkspaceError.imageTooLarge }
        guard let context = CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WorkspaceError.invalidImage }
        var top = 0
        for (index, image) in images.enumerated() {
            context.draw(image, in: CGRect(x: 0, y: height - top - image.height, width: image.width, height: image.height))
            if index < overlaps.count { top += image.height - overlaps[index] }
        }
        guard let result = context.makeImage() else { throw WorkspaceError.invalidImage }
        return result
    }
}
#endif
