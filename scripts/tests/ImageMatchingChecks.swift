import AppKit
import Foundation
import ImageIO

@main
struct ImageMatchingChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static func require(_ value: Bool, _ message: String) throws {
        count += 1
        if !value { throw Failure(description: message) }
    }

    @MainActor
    static func main() async {
        do {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let original = ImageMatchingFixtures.image()
            let crop = original.cropping(to: CGRect(x: 103, y: 71, width: 540, height: 390))!
            let sources = ImageMatchingFixtures.sources(original, crop)
            let result = try ImageMatchingEngine.match(sources: sources)
            print("Crop matching: \(result.status), \(result.inlierCount) inliers, \(result.duration) seconds")
            try require(result.status == .accepted, "Distinctive crop must match")
            let transform = result.rightTransform!
            try require(abs(transform.offsetX - 103) < 0.5 && abs(transform.offsetY - 71) < 0.5,
                        "Coordinate conversion preserves top-down crop origin")
            try require(abs(transform.scale - 1) < 0.001 && abs(transform.rotationDegrees) < 0.1,
                        "Crop must not spuriously rotate or resize")
            let matrix = ImageTransformGeometry.affine(sourceSize: CGSize(width: crop.width, height: crop.height), transform: transform)
            for point in result.points {
                let predicted = point.right.applying(matrix)
                try require(hypot(predicted.x - point.left.x, predicted.y - point.left.y) < 3,
                            "Published correspondence uses the same coordinates as rendered transforms")
            }
            let before = try ImageComparisonRenderer.render(sources: sources, overlapOnly: true)
            let after = try ImageComparisonRenderer.render(sources: sources, rightTransform: transform, overlapOnly: true)
            try require(meanDifference(after) < meanDifference(before) * 0.08,
                        "Actual rendered overlap becomes aligned, not merely the matrix")
            try ImageMatchingFixtures.write(original, to: directory.appendingPathComponent("original.png"))
            try ImageMatchingFixtures.write(crop, to: directory.appendingPathComponent("crop.png"))
            try ImageMatchingFixtures.write(after.right.image, to: directory.appendingPathComponent("aligned.png"))

            // Build a clockwise 90-degree fixture independently, using source rows.
            let bytes = original.dataProvider!.data! as Data
            let input = [UInt8](bytes)
            var rotated = [UInt8](repeating: 0, count: original.width * original.height * 4)
            for y in 0..<original.height { for x in 0..<original.width {
                let target = (x * original.height + original.height - 1 - y) * 4
                let source = y * original.bytesPerRow + x * 4
                rotated.replaceSubrange(target..<target + 4, with: input[source..<source + 4])
            } }
            let clockwise = CGImage(width: original.height, height: original.width, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: original.height * 4, space: original.colorSpace!, bitmapInfo: original.bitmapInfo,
                provider: CGDataProvider(data: Data(rotated) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let rotatedSources = ImageMatchingFixtures.sources(original, clockwise)
            let rotation = try ImageMatchingEngine.match(sources: rotatedSources)
            try require(rotation.status == .accepted && abs(rotation.rightTransform!.rotationDegrees + 90) < 0.1,
                        "Automatic rotation has the correct clockwise-positive sign")
            let restored = try ImageComparisonRenderer.render(sources: rotatedSources, rightTransform: rotation.rightTransform!, overlapOnly: true)
            try require(meanDifference(restored) < 2, "Quarter-turn transform visually restores original pixels")

            for image in [ImageMatchingFixtures.solid(), ImageMatchingFixtures.solid(alpha: 0)] {
                let blank = try ImageMatchingEngine.match(sources: ImageMatchingFixtures.sources(image, image))
                try require(blank.status != .accepted && blank.rightTransform == nil, "Blank or transparent inputs cannot provide alignment evidence")
            }
            let task = Task.detached { try ImageMatchingEngine.match(sources: sources) }
            task.cancel()
            do { _ = try await task.value; throw Failure(description: "Cancelled matching returned a result") }
            catch is CancellationError { count += 1 }

            try await modelLifecycle(directory: directory)
            try upstreamScene()
            print("PASS: \(count) image matching Swift checks (coordinates, rendered alignment, rotation, cancellation, restore, stale results and reload).")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func upstreamScene() throws {
        // Real scene from the already checksum-pinned OpenCV source checkout.
        // Generated derivatives stay in memory and are never publication assets.
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/photo-deps/opencv-4.12.0/samples/data/graf1.png")
        let scenes = try ImageComparisonDecoder.load(left: path, right: path)
        let source = scenes.left.image
        let crop = source.cropping(to: CGRect(x: 117, y: 93, width: source.width - 240, height: source.height - 190))!
        let result = try ImageMatchingEngine.match(sources: ImageMatchingFixtures.sources(source, crop))
        try require(result.status == .accepted, "OpenCV real scene crop must register")
        try require(abs(result.rightTransform!.offsetX - 117) < 0.5 && abs(result.rightTransform!.offsetY - 93) < 0.5,
                    "Real scene crop has correct source position")
        let adjustment = ImageComparisonTransform(scale: 0.83, rotationDegrees: 22, offsetX: 30, offsetY: -20)
        let generated = try ImageComparisonRenderer.render(sources: scenes, rightTransform: adjustment)
        let rotatedSources = ImageMatchingFixtures.sources(source, generated.right.image)
        let rotated = try ImageMatchingEngine.match(sources: rotatedSources)
        try require(rotated.status == .accepted, "OpenCV real scene with rotation and scale must register")
        let forward = ImageTransformGeometry.affine(sourceSize: CGSize(width: source.width, height: source.height), transform: adjustment)
        let recovered = ImageTransformGeometry.affine(sourceSize: CGSize(width: generated.width, height: generated.height), transform: rotated.rightTransform!)
        for point in [CGPoint(x: 120, y: 110), CGPoint(x: 650, y: 120), CGPoint(x: 400, y: 450)] {
            let world = point.applying(forward)
            let canvas = CGPoint(x: (world.x - generated.canvasOrigin.x) * generated.canvasScale,
                                 y: (world.y - generated.canvasOrigin.y) * generated.canvasScale)
            let restored = canvas.applying(recovered)
            try require(hypot(restored.x - point.x, restored.y - point.y) < 1,
                        "Real scene rotation/scale has subpixel independent control-point error")
        }
        print("OpenCV graf scene: crop \(String(format: "%.3f", result.duration))s; rotation/scale \(String(format: "%.3f", rotated.duration))s; \(rotated.inlierCount) inliers")
    }

    static func meanDifference(_ preview: ImageComparisonPreview) -> Double {
        let lhs = [UInt8](preview.left.image.dataProvider!.data! as Data)
        let rhs = [UInt8](preview.right.image.dataProvider!.data! as Data)
        var sum = 0.0, samples = 0
        for pixel in 0..<(preview.width * preview.height) where lhs[pixel * 4 + 3] == 255 && rhs[pixel * 4 + 3] == 255 {
            for channel in 0..<3 { sum += Double(abs(Int(lhs[pixel * 4 + channel]) - Int(rhs[pixel * 4 + channel]))); samples += 1 }
        }
        return sum / Double(max(samples, 1))
    }

    @MainActor static func modelLifecycle(directory: URL) async throws {
        let lhs = directory.appendingPathComponent("original.png"), rhs = directory.appendingPathComponent("crop.png")
        let originalBytes = [try Data(contentsOf: lhs), try Data(contentsOf: rhs)]
        let model = ImageComparisonModel()
        await model.load(left: lhs, right: rhs)
        try await settle(model)
        model.leftTransform = .init(scale: 1.2, rotationDegrees: 8)
        model.rightTransform = .init(offsetX: 20)
        model.leftAspectLocked = false
        let priorLeft = model.leftTransform, priorRight = model.rightTransform
        model.alignAutomatically()
        try await settle(model)
        try require(model.matchingResult?.status == .accepted && model.leftTransform.isIdentity && model.canRestoreAlignment,
                    "Smart alignment applies a verified result to the decoded sources")
        try require(model.mode == .wipe && !model.matchingWasAdjusted, "Successful default comparison opens wipe mode")
        model.rightTransform.offsetX += 2
        try require(model.matchingWasAdjusted, "Manual fine-tuning is identified without changing original evidence")
        model.restoreAlignment()
        try await settle(model)
        try require(model.leftTransform == priorLeft && model.rightTransform == priorRight && !model.leftAspectLocked,
                    "Restore recovers independent transforms and locks")
        try require(model.mode == .sideBySide && !model.canRestoreAlignment && model.matchingResult == nil,
                    "Restore recovers display mode and clears applied-match evidence")
        model.alignAutomatically()
        model.cancelMatching()
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(model.leftTransform == priorLeft && model.rightTransform == priorRight && model.matchingNotice == .cancelled,
                    "Cancelled work cannot alter manual alignment")
        model.alignAutomatically()
        model.rightTransform = .init(offsetX: 33)
        try await Task.sleep(nanoseconds: 250_000_000)
        try require(model.rightTransform.offsetX == 33 && !model.isMatching, "Manual change invalidates pending alignment")
        model.alignAutomatically()
        await model.load(left: lhs, right: lhs, force: true)
        try await settle(model)
        try require(model.matchingResult == nil && !model.canRestoreAlignment && model.rightTransform.isIdentity,
                    "Changing pair cannot publish an obsolete estimate or restore another pair")
        try require(try Data(contentsOf: lhs) == originalBytes[0] && Data(contentsOf: rhs) == originalBytes[1],
                    "All automatic/manual actions leave source files intact")
    }

    @MainActor static func settle(_ model: ImageComparisonModel) async throws {
        let deadline = Date().addingTimeInterval(20)
        while model.isRendering || model.isMatching || model.preview == nil {
            if Date() > deadline { throw Failure(description: "Model did not settle") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if let error = model.error { throw error }
    }
}
