import CoreGraphics
import Foundation
import CrossDiffCore
import PhotoCVBridge

/// Evidence is in the immutable, EXIF-oriented decoded source coordinates, never
/// in the transformed output canvas. A match is not a judgement about edits.
struct ImageMatchingResult: Sendable {
    enum Status: Int32, Sendable {
        case accepted = 0, insufficientFeatures, insufficientMatches, unreliable, unsupportedTransform, cancelled, failure

        var explanation: String {
            switch self {
            case .accepted:
                return L("已将右图对齐到左图，可继续手动微调。", "The right image is aligned to the left. You can still fine-tune it.")
            case .insufficientFeatures:
                return L("可辨识细节不足，请使用手动对齐。", "Not enough distinctive detail. Try manual alignment.")
            case .insufficientMatches:
                return L("没有找到足够的可靠对应，已保留原有对齐。", "Not enough reliable matches. Your alignment is unchanged.")
            case .unreliable:
                return L("对应位置不够可靠，可能存在重复纹理或多个变换，已保留原有对齐。", "The match is uncertain, possibly due to repeated patterns or multiple transforms. Your alignment is unchanged.")
            case .unsupportedTransform:
                return L("所需变换超出当前支持范围，已保留原有对齐。", "The required transform is outside the supported range. Your alignment is unchanged.")
            case .cancelled:
                return L("已取消智能对齐。", "Smart alignment cancelled.")
            case .failure:
                return L("未能完成智能对齐，请重试或手动调整。", "Smart alignment could not finish. Try again or align manually.")
            }
        }
    }

    struct Correspondence: Sendable {
        let left: CGPoint
        let right: CGPoint
    }

    let status: Status
    let rightTransform: ImageComparisonTransform?
    let points: [Correspondence]
    let leftFeatureCount: Int
    let rightFeatureCount: Int
    let candidateCount: Int
    let inlierCount: Int
    let medianResidual: Double
    let leftCoverage: Double
    let rightCoverage: Double
    let duration: TimeInterval
}

/// Content verified at the accepted registration in the immutable left source,
/// including near-identical flat cells supported by surrounding texture.
/// Unmarked pixels may be changed, transparent or unverified.
struct ImageSimilarityResult: Sendable {
    struct Edge: Sendable {
        let start: CGPoint
        let end: CGPoint
    }

    struct Region: Identifiable, Sendable {
        let id: Int
        let cells: [CGRect]
        /// Only exposed cell sides, including hole boundaries. A bounding box
        /// would incorrectly label enclosed edits as similar.
        let boundary: [Edge]
        /// A real cell center near the area centroid, never inside a hole.
        let anchor: CGPoint
    }

    let regions: [Region]
    /// Geometric intersection of the two registered source rectangles. This
    /// continuous outline describes overlap, not proof of similar content.
    let overlap: [CGPoint]
    let leftToRight: CGAffineTransform
    let comparedCellCount: Int
    let duration: TimeInterval

    var matchedCellCount: Int { regions.reduce(0) { $0 + $1.cells.count } }
}

enum ImageSimilarityFailure: LocalizedError {
    case unavailable, analysis

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L("请先完成智能对齐，再查看相似区域。", "Complete smart alignment before showing similar regions.")
        case .analysis:
            return L("未能完成相似区域分析，请重试。", "Similar-region analysis could not finish. Please try again.")
        }
    }
}

/// Bounded local SIFT + mutual matching + robust similarity estimation. OpenCV
/// owns the vision algorithms; this adapter only handles pixels and coordinates.
enum ImageMatchingEngine {
    static func match(sources: ImageComparisonSources) throws -> ImageMatchingResult {
        try Task.checkCancellation()
        let start = Date()
        let left = try rgba(sources.left.image)
        let right = try rgba(sources.right.image)
        var evidence = CrossDiffImageMatchResult()
        var points = [CrossDiffImageMatchPoint](repeating: .init(), count: 128)
        let rawStatus = left.withUnsafeBufferPointer { lhs in
            right.withUnsafeBufferPointer { rhs in
                points.withUnsafeMutableBufferPointer { output in
                    crossdiff_image_match_rgba(
                        lhs.baseAddress, lhs.count, Int32(sources.left.image.width), Int32(sources.left.image.height), sources.left.image.width * 4,
                        rhs.baseAddress, rhs.count, Int32(sources.right.image.width), Int32(sources.right.image.height), sources.right.image.width * 4,
                        { _ in Task.isCancelled ? 1 : 0 }, nil, &evidence, output.baseAddress, output.count)
                }
            }
        }
        try Task.checkCancellation()
        var status = ImageMatchingResult.Status(rawValue: rawStatus) ?? .failure
        if status == .cancelled { throw CancellationError() }
        var transform: ImageComparisonTransform?
        if status == .accepted {
            // The C matrix maps top-left pixel coordinates. The editor's controls
            // instead rotate/scale around the right image center.
            let cx = Double(sources.right.image.width) / 2
            let cy = Double(sources.right.image.height) / 2
            let scale = hypot(evidence.a, evidence.b)
            let rotation = atan2(evidence.b, evidence.a) * 180 / .pi
            let dx = evidence.tx - cx + evidence.a * cx - evidence.b * cy
            let dy = evidence.ty - cy + evidence.b * cx + evidence.a * cy
            if [scale, rotation, dx, dy].allSatisfy(\.isFinite),
               ImageComparisonTransform.scaleRange.contains(scale),
               ImageComparisonTransform.offsetRange.contains(dx), ImageComparisonTransform.offsetRange.contains(dy) {
                transform = ImageComparisonTransform(scale: scale, rotationDegrees: rotation, offsetX: dx, offsetY: dy)
            } else {
                // Silently clamping would apply a different registration than the
                // one whose evidence passed the geometric checks.
                status = .unsupportedTransform
            }
        }
        let count = max(0, min(points.count, Int(evidence.point_count)))
        return ImageMatchingResult(status: status, rightTransform: transform,
            points: status == .accepted ? points.prefix(count).map {
                .init(left: CGPoint(x: $0.left_x, y: $0.left_y), right: CGPoint(x: $0.right_x, y: $0.right_y))
            } : [], leftFeatureCount: Int(evidence.left_feature_count), rightFeatureCount: Int(evidence.right_feature_count),
            candidateCount: Int(evidence.candidate_count), inlierCount: Int(evidence.inlier_count),
            medianResidual: evidence.median_residual, leftCoverage: evidence.left_coverage, rightCoverage: evidence.right_coverage,
            duration: Date().timeIntervalSince(start))
    }

    /// Verification always uses the accepted registration and original decoded
    /// buffers. Later manual transforms affect overlay placement, not evidence.
    static func similarity(sources: ImageComparisonSources, match: ImageMatchingResult) throws -> ImageSimilarityResult {
        try Task.checkCancellation()
        guard match.status == .accepted, let transform = match.rightTransform,
              transform == transform.normalized, transform.scaleX == transform.scaleY,
              !transform.flipHorizontal, !transform.flipVertical else {
            throw ImageSimilarityFailure.unavailable
        }
        let start = Date()
        let rightToLeft = ImageTransformGeometry.affine(
            sourceSize: CGSize(width: sources.right.image.width, height: sources.right.image.height), transform: transform)
        guard [rightToLeft.a, rightToLeft.b, rightToLeft.tx, rightToLeft.ty].allSatisfy(\.isFinite),
              hypot(rightToLeft.a, rightToLeft.b) > 0 else { throw ImageSimilarityFailure.unavailable }
        let left = try rgba(sources.left.image)
        let right = try rgba(sources.right.image)
        var evidence = CrossDiffImageSimilarityResult()
        var cells = [CrossDiffImageSimilarityCell](repeating: .init(), count: 4096)
        let rawStatus = left.withUnsafeBufferPointer { lhs in
            right.withUnsafeBufferPointer { rhs in
                cells.withUnsafeMutableBufferPointer { output in
                    crossdiff_image_similarity_rgba(
                        lhs.baseAddress, lhs.count, Int32(sources.left.image.width), Int32(sources.left.image.height), sources.left.image.width * 4,
                        rhs.baseAddress, rhs.count, Int32(sources.right.image.width), Int32(sources.right.image.height), sources.right.image.width * 4,
                        Double(rightToLeft.a), Double(rightToLeft.b), Double(rightToLeft.tx), Double(rightToLeft.ty),
                        { _ in Task.isCancelled ? 1 : 0 }, nil, &evidence, output.baseAddress, output.count)
                }
            }
        }
        try Task.checkCancellation()
        if rawStatus == ImageMatchingResult.Status.cancelled.rawValue { throw CancellationError() }
        guard rawStatus == ImageMatchingResult.Status.accepted.rawValue else { throw ImageSimilarityFailure.analysis }
        let count = Int(evidence.cell_count), regionCount = Int(evidence.region_count)
        let compared = Int(evidence.compared_cell_count)
        guard (0...cells.count).contains(count), (0...count).contains(regionCount),
              compared >= count, compared <= sources.left.image.width * sources.left.image.height,
              (count == 0) == (regionCount == 0) else { throw ImageSimilarityFailure.analysis }
        let overlapCount = Int(evidence.overlap_point_count)
        guard overlapCount == 0 || (3...8).contains(overlapCount) else { throw ImageSimilarityFailure.analysis }
        let overlap = withUnsafeBytes(of: evidence.overlap) { bytes in
            bytes.bindMemory(to: CrossDiffImageSimilarityPoint.self).prefix(overlapCount).map {
                CGPoint(x: $0.x, y: $0.y)
            }
        }
        guard overlap.allSatisfy({ point in
            point.x.isFinite && point.y.isFinite && point.x >= 0 && point.y >= 0 &&
            point.x <= CGFloat(sources.left.image.width) && point.y <= CGFloat(sources.left.image.height)
        }) else { throw ImageSimilarityFailure.analysis }

        var grouped = [Int: [CGRect]]()
        var unique = Set<SimilarityCellKey>()
        for cell in cells.prefix(count) {
            let x = Int(cell.x), y = Int(cell.y), width = Int(cell.width), height = Int(cell.height)
            let id = Int(cell.region_id)
            guard (1...max(1, regionCount)).contains(id), x >= 0, y >= 0, width > 0, height > 0,
                  x + width <= sources.left.image.width, y + height <= sources.left.image.height,
                  unique.insert(.init(x: x, y: y, width: width, height: height)).inserted else {
                throw ImageSimilarityFailure.analysis
            }
            grouped[id, default: []].append(CGRect(x: x, y: y, width: width, height: height))
        }
        guard grouped.count == regionCount else { throw ImageSimilarityFailure.analysis }
        let regions = try grouped.keys.sorted().map { id -> ImageSimilarityResult.Region in
            try Task.checkCancellation()
            return try similarityRegion(id: id, cells: grouped[id]!)
        }
        try Task.checkCancellation()
        return ImageSimilarityResult(regions: regions, overlap: overlap, leftToRight: rightToLeft.inverted(),
            comparedCellCount: compared, duration: Date().timeIntervalSince(start))
    }

    private struct SimilarityCellKey: Hashable {
        let x: Int, y: Int, width: Int, height: Int
    }

    private struct SimilarityEdgeKey: Hashable {
        let x1: Int, y1: Int, x2: Int, y2: Int

        init(_ start: CGPoint, _ end: CGPoint) {
            // Direction is irrelevant to cancellation; retain it on the Edge
            // itself so outer and inner contours have opposite winding.
            x1 = Int(min(start.x, end.x)); y1 = Int(min(start.y, end.y))
            x2 = Int(max(start.x, end.x)); y2 = Int(max(start.y, end.y))
        }
    }

    private static func similarityRegion(id: Int, cells: [CGRect]) throws -> ImageSimilarityResult.Region {
        let ordered = cells.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
        var exposed = [SimilarityEdgeKey: ImageSimilarityResult.Edge]()
        var area: CGFloat = 0, weightedX: CGFloat = 0, weightedY: CGFloat = 0
        for (index, cell) in ordered.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            let weight = cell.width * cell.height
            area += weight; weightedX += weight * cell.midX; weightedY += weight * cell.midY
            let corners = [CGPoint(x: cell.minX, y: cell.minY), CGPoint(x: cell.maxX, y: cell.minY),
                           CGPoint(x: cell.maxX, y: cell.maxY), CGPoint(x: cell.minX, y: cell.maxY)]
            for index in 0..<4 {
                let edge = ImageSimilarityResult.Edge(start: corners[index], end: corners[(index + 1) % 4])
                let key = SimilarityEdgeKey(edge.start, edge.end)
                // The bridge returns a non-overlapping integer grid. Shared
                // sides are equal segments, even in a cropped final row/column.
                if let previous = exposed.removeValue(forKey: key) {
                    guard previous.start == edge.end, previous.end == edge.start else {
                        throw ImageSimilarityFailure.analysis
                    }
                } else {
                    exposed[key] = edge
                }
            }
        }
        guard area > 0, !exposed.isEmpty else { throw ImageSimilarityFailure.analysis }
        let center = CGPoint(x: weightedX / area, y: weightedY / area)
        func distance(_ cell: CGRect) -> CGFloat {
            let dx = cell.midX - center.x, dy = cell.midY - center.y
            return dx * dx + dy * dy
        }
        let labelCell = ordered.min { distance($0) < distance($1) }!
        let boundary = exposed.values.sorted {
            if $0.start.y != $1.start.y { return $0.start.y < $1.start.y }
            if $0.start.x != $1.start.x { return $0.start.x < $1.start.x }
            if $0.end.y != $1.end.y { return $0.end.y < $1.end.y }
            return $0.end.x < $1.end.x
        }
        return ImageSimilarityResult.Region(id: id, cells: ordered, boundary: boundary,
            anchor: CGPoint(x: labelCell.midX, y: labelCell.midY))
    }

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0,
              image.width <= ImageComparisonDecoder.maximumEdge, image.height <= ImageComparisonDecoder.maximumEdge else {
            throw ImageComparisonFailure.dimensions
        }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw ImageComparisonFailure.memory }
        try Task.checkCancellation()
        return bytes
    }
}
