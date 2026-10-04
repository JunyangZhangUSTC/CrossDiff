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
            let rotationEvidence = try ImageMatchingEngine.similarity(sources: rotatedSources, match: rotation)
            // This fixture rotates integer sample indices (y = height - 1 - x).
            // SIFT estimates their placement; geometric source edges use 0...N.
            // Allow one preview pixel here. Analytic transform fixtures below
            // verify polygon transport independently at 0.001-pixel precision.
            try requirePolygon(rotationEvidence.overlap,
                matches: rectangleCorners(CGRect(x: 0, y: 0, width: original.width, height: original.height)),
                tolerance: 1, message: "A registered quarter turn preserves the full geometric overlap")

            for image in [ImageMatchingFixtures.solid(), ImageMatchingFixtures.solid(alpha: 0)] {
                let blank = try ImageMatchingEngine.match(sources: ImageMatchingFixtures.sources(image, image))
                try require(blank.status != .accepted && blank.rightTransform == nil, "Blank or transparent inputs cannot provide alignment evidence")
            }
            let task = Task.detached { try ImageMatchingEngine.match(sources: sources) }
            task.cancel()
            do { _ = try await task.value; throw Failure(description: "Cancelled matching returned a result") }
            catch is CancellationError { count += 1 }

            try await modelLifecycle(directory: directory)
            try similarityEvidence(original: original, crop: crop, match: result)
            try overlapGeometry()
            let similarityTask = Task.detached { try ImageMatchingEngine.similarity(sources: sources, match: result) }
            similarityTask.cancel()
            do { _ = try await similarityTask.value; throw Failure(description: "Cancelled similarity analysis returned a result") }
            catch is CancellationError { count += 1 }
            try await similarityLifecycle(directory: directory)
            try await multiRegionNavigation(directory: directory)
            try upstreamScene()
            print("PASS: \(count) image matching Swift checks (coordinates, rendered alignment, complete crop overlap, swapped sides, rotated/scaled intersection, similarity regions, holes, occlusion, cancellation, restore, cache, stale results and reload).")
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

    static func similarityEvidence(original: CGImage, crop: CGImage, match: ImageMatchingResult) throws {
        let result = try ImageMatchingEngine.similarity(sources: ImageMatchingFixtures.sources(original, crop), match: match)
        try require(result.regions.count == 1 && result.matchedCellCount > 0,
                    "An unchanged crop remains one region instead of fragmenting at verified flat areas")
        try require(result.comparedCellCount >= result.matchedCellCount,
                    "The similarity result distinguishes inspected cells from matched cells")
        let cropBounds = CGRect(x: 103, y: 71, width: crop.width, height: crop.height)
        try requirePolygon(result.overlap, matches: rectangleCorners(cropBounds), tolerance: 0.5,
                           message: "An exact crop has one complete geometric outline, including its textureless edges")
        try requirePolygon(result.overlap.map { $0.applying(result.leftToRight) },
            matches: rectangleCorners(CGRect(x: 0, y: 0, width: crop.width, height: crop.height)),
            tolerance: 0.5, message: "The crop outline maps back to the complete right source boundary")
        let leftBounds = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        let rightBounds = CGRect(x: 0, y: 0, width: crop.width, height: crop.height).insetBy(dx: -1, dy: -1)
        for region in result.regions {
            try require(region.id > 0 && !region.cells.isEmpty && !region.boundary.isEmpty,
                        "Each published region has an identity, verified area and a visible boundary")
            try require(region.cells.contains { $0.contains(region.anchor) },
                        "A region label is anchored inside evidence, not a hole or its bounding rectangle")
            for cell in region.cells {
                try require(cell.width > 0 && cell.height > 0 && leftBounds.contains(cell),
                            "Similarity cells stay in left source coordinates")
                for corner in [CGPoint(x: cell.minX, y: cell.minY), CGPoint(x: cell.maxX, y: cell.minY),
                               CGPoint(x: cell.maxX, y: cell.maxY), CGPoint(x: cell.minX, y: cell.maxY)] {
                    try require(rightBounds.contains(corner.applying(result.leftToRight)),
                                "Every verified cell maps into the actual cropped right image")
                }
            }
        }

        let reversedSources = ImageMatchingFixtures.sources(crop, original)
        let reversedMatch = try ImageMatchingEngine.match(sources: reversedSources)
        try require(reversedMatch.status == .accepted, "Swapping a crop and its original still registers")
        let reversed = try ImageMatchingEngine.similarity(sources: reversedSources, match: reversedMatch)
        try require(reversed.regions.count == 1, "Swapped crop comparison also retains a single connected region")
        try requirePolygon(reversed.overlap,
            matches: rectangleCorners(CGRect(x: 0, y: 0, width: crop.width, height: crop.height)),
            tolerance: 0.5, message: "With the crop on the left, overlap is the complete left source")
        try requirePolygon(reversed.overlap.map { $0.applying(reversed.leftToRight) },
            matches: rectangleCorners(cropBounds), tolerance: 0.5,
            message: "Swapped overlap maps to the crop's correct location in the full right image")

        let occluded = ImageMatchingFixtures.occluded(original)
        let sources = ImageMatchingFixtures.sources(original, occluded)
        let alignment = try ImageMatchingEngine.match(sources: sources)
        try require(alignment.status == .accepted, "A large local edit still leaves enough global alignment evidence")
        let islands = try ImageMatchingEngine.similarity(sources: sources, match: alignment)
        try require(islands.regions.count >= 2, "A full-height occlusion separates surviving matching regions")
        let forbidden = ImageMatchingFixtures.occlusionBounds(in: occluded).insetBy(dx: 4, dy: 0)
        var evidenceBeforeEdit = false, evidenceAfterEdit = false
        for region in islands.regions {
            for cell in region.cells {
                let onRight = cell.applying(islands.leftToRight)
                try require(!onRight.intersects(forbidden), "Similarity fill never bridges the known central edit")
                evidenceBeforeEdit = evidenceBeforeEdit || onRight.maxX <= forbidden.minX
                evidenceAfterEdit = evidenceAfterEdit || onRight.minX >= forbidden.maxX
            }
        }
        try require(evidenceBeforeEdit && evidenceAfterEdit, "Both sides of the occlusion retain useful similarity evidence")
        try requirePolygon(islands.overlap, matches: rectangleCorners(leftBounds), tolerance: 0.5,
                           message: "Geometric overlap remains complete across an edit; it is separate from verified fill")

        let localEdit = ImageMatchingFixtures.locallyOccluded(original)
        let localSources = ImageMatchingFixtures.sources(original, localEdit)
        let localMatch = try ImageMatchingEngine.match(sources: localSources)
        try require(localMatch.status == .accepted, "A bounded local edit leaves reliable registration evidence")
        let aroundHole = try ImageMatchingEngine.similarity(sources: localSources, match: localMatch)
        try require(aroundHole.regions.count == 1, "Surviving content remains connected around a local edit")
        let hole = ImageMatchingFixtures.localOcclusionBounds(in: original).insetBy(dx: 4, dy: 4)
        let region = aroundHole.regions[0]
        let regionBounds = region.cells.reduce(CGRect.null) { $0.union($1) }
        try require(regionBounds.contains(hole), "The known edit is enclosed by the verified region's overall extent")
        for cell in region.cells {
            try require(!cell.applying(aroundHole.leftToRight).intersects(hole),
                        "Connecting unchanged flat areas must not fill a bounded edit")
        }
        let nearHole = hole.insetBy(dx: -40, dy: -40)
        try require(region.boundary.contains { edge in
            nearHole.contains(CGPoint(x: (edge.start.x + edge.end.x) / 2, y: (edge.start.y + edge.end.y) / 2))
        }, "The visible boundary includes the internal hole instead of only an outer rectangle")
        try require(region.cells.contains { $0.contains(region.anchor) } && !hole.contains(region.anchor),
                    "The region label stays inside verified content when its center lies in the edited hole")
        print("Similarity regions: crop \(result.regions.count) groups / \(result.matchedCellCount) cells; occluded \(islands.regions.count) groups")
    }

    /// Exercise polygon transport independently of feature estimation. These
    /// known registrations are fixtures for geometry, not matching assertions.
    static func overlapGeometry() throws {
        let rectangle = ImageMatchingFixtures.solid()
        let sources = ImageMatchingFixtures.sources(rectangle, rectangle)
        let transform = ImageComparisonTransform(scale: 0.5, rotationDegrees: 90, offsetX: 170, offsetY: 20)
        let partial = try ImageMatchingEngine.similarity(sources: sources, match: geometryOnlyMatch(transform))
        try requirePolygon(partial.overlap, matches: rectangleCorners(CGRect(x: 295, y: 70, width: 105, height: 200)),
                           tolerance: 0.001, message: "Rotated and scaled source bounds are clipped at the left image edge")
        try requirePolygon(partial.overlap.map { $0.applying(partial.leftToRight) },
            matches: rectangleCorners(CGRect(x: 0, y: 90, width: 400, height: 210)),
            tolerance: 0.001, message: "Partial overlap preserves the inverse source mapping after rotation and scaling")

        let square = ImageMatchingFixtures.image(width: 200, height: 200)
        let diamond = try ImageMatchingEngine.similarity(sources: ImageMatchingFixtures.sources(square, square),
            match: geometryOnlyMatch(.init(rotationDegrees: 45)))
        let low = CGFloat(200 - 100 * sqrt(2.0)), high = 200 - low
        let expected = [CGPoint(x: low, y: 0), CGPoint(x: high, y: 0), CGPoint(x: 200, y: low),
                        CGPoint(x: 200, y: high), CGPoint(x: high, y: 200), CGPoint(x: low, y: 200),
                        CGPoint(x: 0, y: high), CGPoint(x: 0, y: low)]
        try require(diamond.overlap.count == 8, "The maximum-size overlap polygon keeps all eight vertices")
        try requirePolygon(diamond.overlap, matches: expected, tolerance: 0.001,
                           message: "Oblique square intersection transports all eight boundary vertices")
        let squareBounds = CGRect(x: 0, y: 0, width: 200, height: 200).insetBy(dx: -0.001, dy: -0.001)
        try require(diamond.overlap.allSatisfy { squareBounds.contains($0.applying(diamond.leftToRight)) },
                    "Every oblique overlap corner also lies inside the right source")

        let apart = try ImageMatchingEngine.similarity(sources: sources,
            match: geometryOnlyMatch(.init(offsetX: 800)))
        try require(apart.overlap.isEmpty && apart.regions.isEmpty,
                    "A non-overlapping registration returns neither a geometric outline nor verified regions")
    }

    static func geometryOnlyMatch(_ transform: ImageComparisonTransform) -> ImageMatchingResult {
        .init(status: .accepted, rightTransform: transform, points: [], leftFeatureCount: 0, rightFeatureCount: 0,
              candidateCount: 0, inlierCount: 0, medianResidual: 0, leftCoverage: 0, rightCoverage: 0, duration: 0)
    }

    static func rectangleCorners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    static func requirePolygon(_ actual: [CGPoint], matches expected: [CGPoint], tolerance: CGFloat,
                               message: String) throws {
        try require((3...8).contains(actual.count), "\(message): valid closed polygon")
        // Small registration errors can split a nearly coincident edge into
        // several vertices. Compare the boundaries, not incidental point count.
        func boundaryDistance(_ point: CGPoint, polygon: [CGPoint]) -> CGFloat {
            polygon.indices.map { index in
                let start = polygon[index], end = polygon[(index + 1) % polygon.count]
                let dx = end.x - start.x, dy = end.y - start.y
                let lengthSquared = dx * dx + dy * dy
                let projection = lengthSquared > 0 ? ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared : 0
                let position = min(1, max(0, projection))
                return hypot(point.x - start.x - position * dx, point.y - start.y - position * dy)
            }.min()!
        }
        for (points, boundary) in [(actual, expected), (expected, actual)] {
            for point in points {
                try require(boundaryDistance(point, polygon: boundary) <= tolerance,
                            "\(message): boundary near \(point)")
            }
        }
    }

    @MainActor static func multiRegionNavigation(directory: URL) async throws {
        let left = directory.appendingPathComponent("original.png")
        let right = directory.appendingPathComponent("navigation-occluded.png")
        try ImageMatchingFixtures.write(ImageMatchingFixtures.occluded(ImageMatchingFixtures.image()), to: right)
        let model = ImageComparisonModel()
        await model.load(left: left, right: right)
        try await settle(model)
        model.alignAutomatically()
        try await settle(model)
        model.toggleSimilarRegions()
        try await settle(model)
        guard let regions = model.similarityResult?.regions, let first = regions.first, let last = regions.last else {
            throw Failure(description: "A known split edit produced no navigable regions")
        }
        try require(regions.count >= 2 && first.id != last.id,
                    "Region navigation is checked with genuinely separate surviving areas, not a fragmented crop")
        model.selectSimilarityRegion(last.id)
        try require(model.selectedSimilarityRegionID == last.id, "Selecting a distinct region updates its identity")
        model.navigateSimilarityRegion(1)
        try require(model.selectedSimilarityRegionID == first.id, "Next wraps across distinct region identities")
        model.navigateSimilarityRegion(-1)
        try require(model.selectedSimilarityRegionID == last.id, "Previous wraps across distinct region identities")
    }

    @MainActor static func similarityLifecycle(directory: URL) async throws {
        let lhs = directory.appendingPathComponent("original.png"), rhs = directory.appendingPathComponent("crop.png")
        let originalBytes = [try Data(contentsOf: lhs), try Data(contentsOf: rhs)]
        let model = ImageComparisonModel()
        await model.load(left: lhs, right: rhs)
        try await settle(model)
        try require(!model.showSimilarRegions && model.similarityResult == nil && model.selectedSimilarityRegionID == nil,
                    "A new comparison never starts region analysis or highlights without an explicit action")
        model.alignAutomatically()
        try await settle(model)
        try require(!model.showSimilarRegions && model.similarityResult == nil, "Smart alignment leaves similar regions off by default")
        model.leftTransform = .init(rotationDegrees: 9, offsetX: 12, scaleX: 1.1, scaleY: 0.8, flipHorizontal: true)
        model.rightTransform.offsetY += 17
        model.leftAspectLocked = false
        model.mode = .difference
        let manualLeft = model.leftTransform, manualRight = model.rightTransform
        model.toggleSimilarRegions()
        try await settle(model)
        guard let result = model.similarityResult, let first = result.regions.first, let last = result.regions.last else {
            throw Failure(description: "Similarity analysis returned no regions for a known crop")
        }
        try require(model.showSimilarRegions && !model.similarityFailed && model.selectedSimilarityRegionID == first.id,
                    "An explicit analysis reveals evidence and initially selects its first region")
        try require(model.leftTransform == manualLeft && model.rightTransform == manualRight && !model.leftAspectLocked && model.mode == .difference,
                    "Similarity analysis uses source evidence without changing manual transforms, locks or display mode")
        model.selectSimilarityRegion(last.id)
        try require(model.selectedSimilarityRegionID == last.id, "A region can be selected independently of the source images")
        model.navigateSimilarityRegion(1)
        try require(model.selectedSimilarityRegionID == first.id, "Next region wraps after the final region")
        model.navigateSimilarityRegion(-1)
        try require(model.selectedSimilarityRegionID == last.id, "Previous region wraps before the first region")
        model.toggleSimilarRegions()
        try require(!model.showSimilarRegions && model.similarityResult != nil && !model.isAnalyzingSimilarity,
                    "Hiding regions retains completed evidence for the current source pair")
        model.toggleSimilarRegions()
        try require(model.showSimilarRegions && !model.isAnalyzingSimilarity && model.similarityResult?.duration == result.duration &&
                    model.selectedSimilarityRegionID == last.id,
                    "Reopening regions uses the completed cache immediately and retains the selected region")
        model.rightTransform.offsetX += 13
        try await settle(model)
        try require(model.showSimilarRegions && model.similarityResult?.duration == result.duration,
                    "Manual fine-tuning retains source-coordinate evidence without recomputing it")
        model.restoreAlignment()
        try await settle(model)
        try require(!model.showSimilarRegions && model.similarityResult == nil && model.selectedSimilarityRegionID == nil,
                    "Restore clears evidence for the discarded automatic match")
        model.alignAutomatically()
        try await settle(model)
        model.toggleSimilarRegions()
        model.toggleSimilarRegions()
        try await Task.sleep(nanoseconds: 250_000_000)
        try require(!model.showSimilarRegions && !model.isAnalyzingSimilarity && model.similarityResult == nil,
                    "Closing pending analysis prevents cancelled work from publishing an obsolete result")
        model.toggleSimilarRegions()
        await model.load(left: lhs, right: lhs, force: true)
        try await settle(model)
        try await Task.sleep(nanoseconds: 250_000_000)
        try require(!model.showSimilarRegions && !model.isAnalyzingSimilarity && model.similarityResult == nil && model.selectedSimilarityRegionID == nil,
                    "Changing image pair discards pending region work and its selected identity")
        model.alignAutomatically()
        try await settle(model)
        model.toggleSimilarRegions()
        try await settle(model)
        try require(model.similarityResult?.regions.isEmpty == false, "A new pair can analyze successfully after cancellation")
        model.alignAutomatically()
        try require(!model.showSimilarRegions && model.similarityResult == nil && model.selectedSimilarityRegionID == nil,
                    "A new automatic alignment invalidates the previous similarity cache immediately")
        try await settle(model)
        model.toggleSimilarRegions()
        try await settle(model)
        await model.load(left: lhs, right: lhs, force: true)
        try await settle(model)
        try require(!model.showSimilarRegions && model.similarityResult == nil && !model.similarityFailed,
                    "Explicit reread clears completed similarity results even for unchanged paths")
        try require(try Data(contentsOf: lhs) == originalBytes[0] && Data(contentsOf: rhs) == originalBytes[1],
                    "Similarity analysis, visibility and navigation leave original files byte-for-byte intact")
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
        while model.isRendering || model.isMatching || model.isAnalyzingSimilarity || model.preview == nil {
            if Date() > deadline { throw Failure(description: "Model did not settle") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if let error = model.error { throw error }
    }
}
