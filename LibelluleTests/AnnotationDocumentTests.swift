import CoreGraphics
import Testing
@testable import Libellule

struct AnnotationDocumentTests {
    /// A plain white picture, one pixel per point.
    private func whitePicture(width: Int = 40, height: Int = 20) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// The red, green and blue of one pixel, counted from the top-left.
    private func rgb(of image: CGImage, x: Int, y: Int) -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Array(pixel.prefix(3))
    }

    @Test func blackOutCoversWithSolidBlack() throws {
        let document = AnnotationDocument(image: whitePicture(), scale: 1)
        document.layer.addRedactions([CGRect(x: 10, y: 5, width: 10, height: 10)], style: .blackout)
        let flattened = try #require(document.flattenedImage())
        #expect(rgb(of: flattened, x: 15, y: 10) == [0, 0, 0])
        #expect(rgb(of: flattened, x: 2, y: 2) == [255, 255, 255])
        #expect(document.layer.isRedacted(CGRect(x: 12, y: 7, width: 4, height: 4)))
    }

    @Test func changesAreUnsavedUntilTheyLeaveTheApp() {
        let document = AnnotationDocument(image: whitePicture(), scale: 1)
        #expect(!document.hasUnsavedChanges)
        document.layer.addRedactions([CGRect(x: 2, y: 2, width: 10, height: 5)], style: .pixelate)
        #expect(document.hasUnsavedChanges)
        document.markSaved()
        #expect(!document.hasUnsavedChanges)
        document.layer.dimsLights = true
        #expect(document.hasUnsavedChanges)
    }

    @Test func liveFramesKeepThePictureHiddenAreasWereMadeFrom() {
        let first = whitePicture()
        let backdrop = AnnotationRenderer.Backdrop(original: first, pointSize: CGSize(width: 40, height: 20), scale: 1)
        let pixelated = backdrop.pixelated
        let next = whitePicture()
        let followed = backdrop.replacingPicture(with: next, scale: 1)
        #expect(followed.original === next)
        #expect(followed.pixelated === pixelated)
        #expect(followed.refreshingEffects().pixelated !== pixelated)
        let blurred = backdrop.blurred(radius: 6)
        #expect(followed.blurred(radius: 6) === blurred)
        #expect(backdrop.blurred(radius: 3) !== blurred)
    }

    @Test func blurStrengthFollowsTheSize() throws {
        // Black on the left half, white on the right: a stronger blur carries the dark further across the edge.
        let context = CGContext(data: nil, width: 80, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 20))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let picture = try #require(context.makeImage())

        func brightnessNextToTheEdge(blurredAt width: StrokeWidth) throws -> UInt8 {
            let document = AnnotationDocument(image: picture, scale: 1)
            document.layer.toolbox.tool = .blur
            document.layer.toolbox.strokeWidth = width
            document.layer.updateDrag(from: .zero, to: CGPoint(x: 80, y: 20), constrained: false)
            document.layer.endDrag()
            let flattened = try #require(document.flattenedImage())
            return rgb(of: flattened, x: 44, y: 10)[0]
        }

        let thin = try brightnessNextToTheEdge(blurredAt: .thin)
        let medium = try brightnessNextToTheEdge(blurredAt: .medium)
        let thick = try brightnessNextToTheEdge(blurredAt: .thick)
        #expect(thin > medium)
        #expect(medium > thick)
    }

    @Test func redactionsBlurAtFullStrength() throws {
        let document = AnnotationDocument(image: whitePicture(), scale: 1)
        document.layer.toolbox.strokeWidth = .thin
        document.layer.addRedactions([CGRect(x: 2, y: 2, width: 10, height: 5)], style: .blur)
        let redaction = try #require(document.layer.annotations.last)
        #expect(redaction.lineWidth == StrokeWidth.thick.rawValue)
    }
}
