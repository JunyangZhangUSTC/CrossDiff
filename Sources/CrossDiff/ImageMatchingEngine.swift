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
