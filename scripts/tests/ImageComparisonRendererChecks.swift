import CoreGraphics
import Foundation
import ImageIO

@main
struct ImageComparisonRendererChecks {
    static var assertions = 0

    static func main() async {
        do {
            let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try identityAndDirection()
            try scaleAndCrop()
            try stretchAndFlip()
            try cornerResizing()
            try transparencyAndBounds()
            try boundedCanvas()
            try decoderFixtures(in: fixtures)
            try await cancellation()
            print("Image comparison checks passed (\(assertions) assertions): identity, rotation, proportional/free resizing, flips, fixed corners, crop alignment, overlap, transparency, EXIF, frames, bounded previews and cancellation.")
        } catch {
            fputs("Image comparison checks failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        guard try condition() else { throw CheckFailure(message: message) }
    }

    private struct CheckFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func pixel(_ index: Int, alpha: UInt8 = 255) -> [UInt8] {
        [UInt8((index * 29) % 256), UInt8((index * 47) % 256), UInt8((index * 61) % 256), alpha]
    }

    private static func image(width: Int, height: Int, bytes: [UInt8]) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CheckFailure(message: "Could not create fixture image")
        }
        return image
    }

    private static func solid(_ width: Int, _ height: Int, alpha: UInt8 = 255) throws -> CGImage {
        try image(width: width, height: height, bytes: (0..<(width * height)).flatMap { _ in [UInt8(70), 100, 130, alpha] })
    }

    private static func asset(_ image: CGImage) -> ImageComparisonAsset {
        ImageComparisonAsset(image: image, originalWidth: image.width, originalHeight: image.height, hasMultipleFrames: false)
    }

    private static func sources(_ left: CGImage, _ right: CGImage) -> ImageComparisonSources {
        ImageComparisonSources(left: asset(left), right: asset(right))
    }

    private static func bytes(_ image: CGImage) -> [UInt8] {
        Array(image.dataProvider!.data! as Data)
    }

    private static func identityAndDirection() throws {
        let pattern = try image(width: 4, height: 2, bytes: (1...8).flatMap { pixel($0) })
        let identity = try ImageComparisonRenderer.render(sources: sources(pattern, pattern))
        try require(identity.differentPixels == 0 && identity.comparedPixels == 8, "Identity must compare all pixels without differences")
        try require(identity.overlapPixels == 8 && identity.width == 4 && identity.height == 2, "Identity canvas and overlap must retain source dimensions")
        try require(bytes(identity.left.image) == (1...8).flatMap { pixel($0) }, "Identity must preserve top-down pixel rows")
        let clockwise = try image(width: 2, height: 4, bytes: [5, 1, 6, 2, 7, 3, 8, 4].flatMap { pixel($0) })
        let rotated = try ImageComparisonRenderer.render(sources: sources(pattern, clockwise),
                                                         leftTransform: .init(rotationDegrees: 90),
                                                         rightTransform: .init(offsetX: 1, offsetY: -1))
        try require(rotated.width == 2 && rotated.height == 4, "Quarter turn must not add rounding slivers")
        try require(rotated.differentPixels == 0 && rotated.overlapPixels == 8, "Positive 90° must be visually clockwise around the center")
        try require(bytes(rotated.left.image) == [5, 1, 6, 2, 7, 3, 8, 4].flatMap { pixel($0) }, "Rotated image must match independently specified clockwise pixels")
        let bothRotated = try ImageComparisonRenderer.render(sources: sources(pattern, pattern),
                                                             leftTransform: .init(rotationDegrees: 37),
                                                             rightTransform: .init(rotationDegrees: 37))
        try require(bothRotated.differentPixels == 0, "Equal non-quarter rotations must have no differences")
        try require(bothRotated.comparedPixels < bothRotated.width * bothRotated.height, "Empty canvas corners must not count as compared pixels")
        try require(bytes(bothRotated.difference).enumerated().contains { $0.offset % 4 == 3 && $0.element == 0 }, "Empty canvas corners must remain transparent")
    }

    private static func scaleAndCrop() throws {
        let small = try solid(4, 4), large = try solid(8, 8)
        let enlarged = try ImageComparisonRenderer.render(sources: sources(small, large),
                                                          leftTransform: .init(scale: 2, offsetX: 2, offsetY: 2))
        try require(enlarged.width == 8 && enlarged.height == 8 && enlarged.differentPixels == 0, "Centered 200% scale and offset must align with a larger image")
        let reduced = try ImageComparisonRenderer.render(sources: sources(large, small),
                                                         leftTransform: .init(scale: 0.5, offsetX: -2, offsetY: -2))
        try require(reduced.width == 4 && reduced.height == 4 && reduced.differentPixels == 0, "Centered 50% scale must align with a smaller image")
        let original = try image(width: 8, height: 6, bytes: (0..<48).flatMap { pixel($0) })
        let cropIndices = (1..<4).flatMap { y in (2..<6).map { y * 8 + $0 } }
        let crop = try image(width: 4, height: 3, bytes: cropIndices.flatMap { pixel($0) })
        let full = try ImageComparisonRenderer.render(sources: sources(original, crop),
                                                      rightTransform: .init(offsetX: 2, offsetY: 1))
        try require(full.width == 8 && full.height == 6, "Crop translation must retain union canvas")
        try require(full.overlapPixels == 12 && full.overlapDifferentPixels == 0, "Crop offset must use right/down-positive coordinates")
        try require(full.comparedPixels == 48 && full.differentPixels == 36, "Full comparison must include unmatched image boundaries")
        let overlap = try ImageComparisonRenderer.render(sources: sources(original, crop),
                                                         rightTransform: .init(offsetX: 2, offsetY: 1), overlapOnly: true)
        try require(overlap.comparedPixels == 12 && overlap.differentPixels == 0, "Overlap-only mode must compare just the aligned crop")
        try require(bytes(overlap.difference)[3] == 0, "Pixels outside overlap must be transparent in overlap-only difference")
        let misplaced = try ImageComparisonRenderer.render(sources: sources(original, crop),
                                                            rightTransform: .init(offsetX: 3, offsetY: 1), overlapOnly: true)
        try require(misplaced.differentPixels == 12, "A misplaced crop must report differences rather than pretend to be aligned")
        let separated = try ImageComparisonRenderer.render(sources: sources(original, crop),
                                                            rightTransform: .init(offsetX: 20), overlapOnly: true)
        try require(separated.overlapPixels == 0 && separated.comparedPixels == 0 && separated.differentPixels == 0, "No overlap must have a zero denominator, not identical-image statistics")
        try require(bytes(separated.difference).allSatisfy { $0 == 0 }, "No overlap must generate a fully transparent difference")
    }

    private static func near(_ first: Double, _ second: Double, tolerance: Double = 1e-8) -> Bool {
        abs(first - second) <= tolerance
    }

    private static func near(_ first: CGPoint, _ second: CGPoint) -> Bool {
        near(first.x, second.x) && near(first.y, second.y)
    }

    private static func stretchAndFlip() throws {
        let original = try image(width: 4, height: 2, bytes: (1...8).flatMap { pixel($0) })
        for (horizontal, vertical, pixels) in [
            (true, false, [4, 3, 2, 1, 8, 7, 6, 5]),
            (false, true, [5, 6, 7, 8, 1, 2, 3, 4]),
            (true, true, [8, 7, 6, 5, 4, 3, 2, 1])
        ] {
            let expected = try image(width: 4, height: 2, bytes: pixels.flatMap { pixel($0) })
            let preview = try ImageComparisonRenderer.render(sources: sources(original, expected),
                                                             leftTransform: .init(flipHorizontal: horizontal, flipVertical: vertical))
            try require(preview.differentPixels == 0, "Horizontal/vertical flips must match independent source pixels")
            try require(bytes(preview.left.image) == pixels.flatMap { pixel($0) }, "Flips must preserve source-row orientation")
        }
        let flippedClockwise = try image(width: 2, height: 4, bytes: [8, 4, 7, 3, 6, 2, 5, 1].flatMap { pixel($0) })
        let combined = try ImageComparisonRenderer.render(sources: sources(original, flippedClockwise),
                                                          leftTransform: .init(rotationDegrees: 90, flipHorizontal: true),
                                                          rightTransform: .init(offsetX: 1, offsetY: -1))
        try require(combined.differentPixels == 0, "Reflection must precede rotation in local source axes")
        try require(combined.canvasOrigin == CGPoint(x: 1, y: -1), "Preview must report the shared world-space origin")
        try require(combined.leftSourceSize == CGSize(width: 4, height: 2) && combined.rightSourceSize == CGSize(width: 2, height: 4), "Preview must retain decoded source sizes, not substituted canvas dimensions")
        try require(combined.leftCorners == [CGPoint(x: 2, y: 4), CGPoint(x: 2, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 4)], "Canvas handles must follow reflected source corners through rotation")
        let stretched = try ImageComparisonRenderer.render(sources: sources(try solid(4, 2), try solid(8, 6)),
                                                            leftTransform: .init(offsetX: 2, offsetY: 2, scaleX: 2, scaleY: 3))
        try require(stretched.width == 8 && stretched.height == 6 && stretched.differentPixels == 0, "Independent scales must resize width and height without aspect locking")
        var value = ImageComparisonTransform(scaleX: 2, scaleY: 0.5)
        value.scale = 3
        try require(near(value.scaleX, 3) && near(value.scaleY, 0.75), "Overall scale must preserve an existing stretch ratio")
        value.scale = 0.2
        try require(near(value.scaleX, 0.4) && near(value.scaleY, 0.1), "Overall scale must stop both axes when one reaches its limit")
        let invalid = ImageComparisonTransform(scaleX: .nan, scaleY: -2, flipHorizontal: true).normalized
        try require(invalid.scaleX == 1 && invalid.scaleY == 0.1 && invalid.flipHorizontal, "Scale sanitization must not erase explicit reflections")
    }

    private static func cornerResizing() throws {
        let sourceSize = CGSize(width: 120, height: 80)
        for degrees in [0.0, 37, 90, -113] {
            for flipX in [false, true] {
                for flipY in [false, true] {
                    for corner in ImageTransformCorner.allCases {
                        let initial = ImageComparisonTransform(rotationDegrees: degrees, offsetX: 25, offsetY: -15,
                                                               scaleX: 1.2, scaleY: 0.8,
                                                               flipHorizontal: flipX, flipVertical: flipY)
                        let before = ImageTransformGeometry.corners(sourceSize: sourceSize, transform: initial)
                        let anchor = before[corner.opposite.rawValue]
                        let moving = before[corner.rawValue]
                        let lockedTranslation = CGSize(width: (moving.x - anchor.x) / 2,
                                                       height: (moving.y - anchor.y) / 2)
                        let locked = ImageTransformGeometry.resize(initial: initial, sourceSize: sourceSize,
                                                                   corner: corner, translation: lockedTranslation,
                                                                   lockAspectRatio: true)
                        let lockedCorners = ImageTransformGeometry.corners(sourceSize: sourceSize, transform: locked)
                        try require(near(locked.scaleX, 1.8) && near(locked.scaleY, 1.2), "Locked corner drag must preserve the current stretched aspect ratio")
                        try require(near(lockedCorners[corner.opposite.rawValue], anchor), "Locked resize must preserve the opposite corner after rotation/reflection")
                        try require(near(lockedCorners[corner.rawValue], CGPoint(x: moving.x + lockedTranslation.width, y: moving.y + lockedTranslation.height)), "Locked handle must reach the projected pointer position")
                        // Specify a free-resize movement using independent analytic local axes.
                        let radians = degrees * .pi / 180
                        let xDirection = (corner == .topLeft || corner == .bottomLeft ? -1.0 : 1.0) * (flipX ? -1 : 1)
                        let yDirection = (corner == .topLeft || corner == .topRight ? -1.0 : 1.0) * (flipY ? -1 : 1)
                        let localX = xDirection * sourceSize.width * (1.65 - initial.scaleX)
                        let localY = yDirection * sourceSize.height * (1.3 - initial.scaleY)
                        let freeTranslation = CGSize(width: localX * cos(radians) - localY * sin(radians),
                                                     height: localX * sin(radians) + localY * cos(radians))
                        let free = ImageTransformGeometry.resize(initial: initial, sourceSize: sourceSize,
                                                                 corner: corner, translation: freeTranslation,
                                                                 lockAspectRatio: false)
                        let freeCorners = ImageTransformGeometry.corners(sourceSize: sourceSize, transform: free)
                        try require(near(free.scaleX, 1.65) && near(free.scaleY, 1.3), "Unlocked resize must project movement onto the reflected, rotated local axes")
                        try require(near(freeCorners[corner.opposite.rawValue], anchor), "Unlocked resize must preserve the opposite corner")
                        try require(near(freeCorners[corner.rawValue], CGPoint(x: moving.x + freeTranslation.width, y: moving.y + freeTranslation.height)), "Unlocked handle must reach the actual pointer position")
                        let crossed = ImageTransformGeometry.resize(initial: initial, sourceSize: sourceSize, corner: corner,
                                                                    translation: CGSize(width: (anchor.x - moving.x) * 2, height: (anchor.y - moving.y) * 2),
                                                                    lockAspectRatio: false)
                        try require(near(crossed.scaleX, 0.1) && near(crossed.scaleY, 0.1) && crossed.flipHorizontal == flipX && crossed.flipVertical == flipY,
                                    "Crossing a corner must reach minimum size without an implicit flip")
                        try require(near(ImageTransformGeometry.corners(sourceSize: sourceSize, transform: crossed)[corner.opposite.rawValue], anchor), "Minimum-size clamping must not move the opposite corner")
                    }
                }
            }
        }
        let edgeInitial = ImageComparisonTransform(offsetX: 3190)
        let edgeSize = CGSize(width: 100, height: 60)
        let edgeResize = ImageTransformGeometry.resize(initial: edgeInitial, sourceSize: edgeSize, corner: .bottomRight,
                                                       translation: CGSize(width: 300, height: 180), lockAspectRatio: true)
        let edgeBefore = ImageTransformGeometry.corners(sourceSize: edgeSize, transform: edgeInitial)
        let edgeAfter = ImageTransformGeometry.corners(sourceSize: edgeSize, transform: edgeResize)
        try require(near(edgeResize.offsetX, 3200) && near(edgeResize.scaleX, edgeResize.scaleY), "Offset bounds must stop proportional resizing without changing aspect")
        try require(near(edgeBefore[0], edgeAfter[0]), "Offset bounds must not move the fixed opposite corner")
        let invalid = ImageTransformGeometry.resize(initial: edgeInitial, sourceSize: edgeSize, corner: .bottomRight,
                                                    translation: CGSize(width: Double.infinity, height: 0), lockAspectRatio: false)
        try require(invalid == edgeInitial, "Invalid drag coordinates must leave the transform unchanged")
    }

    private static func transparencyAndBounds() throws {
        let hiddenA = try image(width: 1, height: 1, bytes: [255, 0, 0, 0])
        let hiddenB = try image(width: 1, height: 1, bytes: [0, 255, 0, 0])
        let hidden = try ImageComparisonRenderer.render(sources: sources(hiddenA, hiddenB))
        try require(hidden.differentPixels == 0 && hidden.comparedPixels == 1, "Invisible RGB must not count as a visible difference")
        let boundaries = try ImageComparisonRenderer.render(sources: sources(try solid(4, 4, alpha: 0), try solid(2, 2, alpha: 0)))
        try require(boundaries.differentPixels == 12 && boundaries.overlapPixels == 4, "Transparent image boundaries must remain meaningful")
        let fractionalBoundary = try ImageComparisonRenderer.render(sources: sources(try solid(4, 4, alpha: 0), try solid(4, 4, alpha: 0)),
                                                                     rightTransform: .init(offsetX: 0.25))
        try require(fractionalBoundary.differentPixels > 0, "Subpixel transparent boundary shifts must remain detectable")
        let alpha = try ImageComparisonRenderer.render(sources: sources(try solid(2, 2, alpha: 100), try solid(2, 2, alpha: 150)))
        try require(alpha.differentPixels == 4, "Alpha changes must remain pixel differences")
        let normalized = ImageComparisonTransform(scale: .infinity, rotationDegrees: 450, offsetX: .nan, offsetY: 999999).normalized
        try require(normalized.scale == 1 && normalized.rotationDegrees == 90 && normalized.offsetX == 0 && normalized.offsetY == 3200, "Invalid and extreme controls must be normalized safely")
        try require(ImageComparisonTransform(scale: -1).normalized.scale == 0.1, "Negative scales must not mirror or invalidate the canvas")
    }

    private static func boundedCanvas() throws {
        let wide = try solid(1600, 80)
        let start = Date()
        let value = try ImageComparisonRenderer.render(sources: sources(wide, wide),
                                                       leftTransform: .init(scale: 4, rotationDegrees: 45, offsetX: -3200, offsetY: -3200),
                                                       rightTransform: .init(scale: 4, rotationDegrees: -45, offsetX: 3200, offsetY: 3200))
        try require(value.width <= 1600 && value.height <= 1600 && value.isCanvasDownsampled, "Extreme transforms must remain within the bounded preview")
        try require(value.left.image.width == value.right.image.width && value.left.image.height == value.difference.height, "All rendering modes must share pixel dimensions")
        print("Extreme 1600px canvas render: \(String(format: "%.3f", Date().timeIntervalSince(start))) s")
        let lowResolution = try ImageComparisonRenderer.render(sources: sources(wide, wide), maximumEdge: 800)
        try require(lowResolution.width == 800 && lowResolution.height == 40 && lowResolution.canvasScale == 0.5, "Interactive render limit must preserve shared geometry")
        let dense = try solid(1600, 1000)
        let denseStart = Date()
        let densePreview = try ImageComparisonRenderer.render(sources: sources(dense, dense))
        try require(densePreview.comparedPixels == 1_600_000 && densePreview.differentPixels == 0, "Dense previews must retain all pixels within the configured bound")
        print("Dense 1600×1000 canvas render: \(String(format: "%.3f", Date().timeIntervalSince(denseStart))) s")
        let interactiveStart = Date()
        let interactivePreview = try ImageComparisonRenderer.render(sources: sources(dense, dense), maximumEdge: 800)
        try require(interactivePreview.comparedPixels == 400_000 && interactivePreview.differentPixels == 0, "Interactive preview must recompute differences at its advertised resolution")
        print("Dense 800×500 interactive render: \(String(format: "%.3f", Date().timeIntervalSince(interactiveStart))) s")
        let clamped = try ImageComparisonRenderer.render(sources: sources(wide, wide), maximumEdge: Int.max)
        try require(clamped.width == 1600, "Caller must not bypass the renderer's memory bound")
    }

    private static func write(_ images: [CGImage], to url: URL, type: String = "public.png", properties: [CFString: Any] = [:]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil) else {
            throw CheckFailure(message: "Unable to write fixture \(url.lastPathComponent)")
        }
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure(message: "Unable to finish fixture") }
    }

    private static func decoderFixtures(in directory: URL) throws {
        let original = try image(width: 4, height: 2, bytes: (1...8).flatMap { pixel($0) })
        let clockwise = try image(width: 2, height: 4, bytes: [5, 1, 6, 2, 7, 3, 8, 4].flatMap { pixel($0) })
        let orientedURL = directory.appendingPathComponent("orientation-6.tiff")
        let uprightURL = directory.appendingPathComponent("upright.png")
        try write([original], to: orientedURL, type: "public.tiff", properties: [kCGImagePropertyOrientation: 6])
        try write([clockwise], to: uprightURL)
        let before = try Data(contentsOf: orientedURL)
        let decoded = try ImageComparisonDecoder.load(left: orientedURL, right: uprightURL)
        try require(decoded.left.originalWidth == 2 && decoded.left.originalHeight == 4, "EXIF orientation must swap original dimensions")
        let preview = try ImageComparisonRenderer.render(sources: decoded)
        try require(preview.differentPixels == 0, "EXIF orientation must be applied exactly once before user rotation")
        try require(try Data(contentsOf: orientedURL) == before, "Decoder and renderer must never alter original files")
        let animatedURL = directory.appendingPathComponent("two-frames.gif")
        try write([original, try solid(4, 2)], to: animatedURL, type: "com.compuserve.gif")
        let animated = try ImageComparisonDecoder.load(left: animatedURL, right: animatedURL)
        try require(animated.left.hasMultipleFrames && animated.right.hasMultipleFrames, "Multi-frame metadata must be preserved")
        try require(try ImageComparisonRenderer.render(sources: animated).hasMultipleFrames, "Rendered metadata must retain the first-frame warning")
        let largeURL = directory.appendingPathComponent("large.png")
        let smallURL = directory.appendingPathComponent("small.png")
        try write([try solid(2400, 120)], to: largeURL)
        try write([try solid(1200, 60)], to: smallURL)
        let downsized = try ImageComparisonDecoder.load(left: largeURL, right: smallURL)
        try require(downsized.left.image.width == 1600 && downsized.right.image.width == 800, "Decoder must use one shared scale across unequal original sizes")
        try require(downsized.isDownsampled, "Downsample metadata must survive canvas resizing")
        let invalidURL = directory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalidURL)
        do {
            _ = try ImageComparisonDecoder.load(left: invalidURL, right: uprightURL)
            throw CheckFailure(message: "Invalid input must produce a readable failure")
        } catch ImageComparisonFailure.unreadable(let name) {
            try require(name == "invalid.png", "Failure should identify the invalid filename")
        }
    }

    private static func cancellation() async throws {
        let image = try solid(20, 20)
        let input = sources(image, image)
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ImageComparisonRenderer.render(sources: input)
        }
        do {
            _ = try await worker.value
            throw CheckFailure(message: "Canceled rendering must not publish a completed preview")
        } catch is CancellationError {
            try require(true, "Cancellation delivered")
        }
    }
}
