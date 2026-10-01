import CoreGraphics
import Foundation

/// Corners are named in source-image coordinates, before rotation and reflection.
/// Their stable identity keeps a dragged corner attached when an image is flipped.
enum ImageTransformCorner: Int, CaseIterable, Identifiable, Sendable {
    case topLeft, topRight, bottomRight, bottomLeft
    var id: Self { self }
    var opposite: Self { Self(rawValue: (rawValue + 2) % 4)! }

    fileprivate var horizontalSign: Double { self == .topLeft || self == .bottomLeft ? -1 : 1 }
    fileprivate var verticalSign: Double { self == .topLeft || self == .topRight ? -1 : 1 }

    fileprivate func point(in size: CGSize) -> CGPoint {
        CGPoint(x: horizontalSign < 0 ? 0 : size.width, y: verticalSign < 0 ? 0 : size.height)
    }
}

/// Shared by pixel rendering and handles. World coordinates are decoded preview pixels,
/// right/down positive; transforms never modify originals or store projected pixel data.
enum ImageTransformGeometry {
    static func affine(sourceSize: CGSize, transform: ImageComparisonTransform) -> CGAffineTransform {
        let value = transform.normalized
        let halfWidth = sourceSize.width / 2, halfHeight = sourceSize.height / 2
        let radians = value.rotationDegrees * .pi / 180
        // Snap quarter turns so a floating-point sliver cannot add an output pixel.
        let rawCosine = cos(radians), rawSine = sin(radians)
        let cosine = abs(rawCosine) < 1e-12 ? 0 : rawCosine
        let sine = abs(rawSine) < 1e-12 ? 0 : rawSine
        let signedX = value.scaleX * (value.flipHorizontal ? -1 : 1)
        let signedY = value.scaleY * (value.flipVertical ? -1 : 1)
        let a = signedX * cosine, b = signedX * sine
        let c = -signedY * sine, d = signedY * cosine
        return CGAffineTransform(a: a, b: b, c: c, d: d,
                                 tx: halfWidth + value.offsetX - a * halfWidth - c * halfHeight,
                                 ty: halfHeight + value.offsetY - b * halfWidth - d * halfHeight)
    }

    /// Results follow ImageTransformCorner.allCases, in decoded preview world coordinates.
    static func corners(sourceSize: CGSize, transform: ImageComparisonTransform) -> [CGPoint] {
        let matrix = affine(sourceSize: sourceSize, transform: transform)
        return ImageTransformCorner.allCases.map { $0.point(in: sourceSize).applying(matrix) }
    }

    /// Resize from a fixed gesture-start snapshot and cumulative world-pixel translation.
    /// The opposite source corner remains fixed even after rotation or either reflection.
    /// Crossing it reaches the minimum scale instead of implicitly flipping the image.
    static func resize(initial: ImageComparisonTransform, sourceSize: CGSize,
                       corner: ImageTransformCorner, translation: CGSize,
                       lockAspectRatio: Bool) -> ImageComparisonTransform {
        let initial = initial.normalized
        guard sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0,
              translation.width.isFinite, translation.height.isFinite else { return initial }
        let matrix = affine(sourceSize: sourceSize, transform: initial)
        let xAxis = CGPoint(x: matrix.a / initial.scaleX, y: matrix.b / initial.scaleX)
        let yAxis = CGPoint(x: matrix.c / initial.scaleY, y: matrix.d / initial.scaleY)
        let signedWidth = corner.horizontalSign * sourceSize.width
        let signedHeight = corner.verticalSign * sourceSize.height
        let diagonal = CGPoint(x: xAxis.x * signedWidth * initial.scaleX + yAxis.x * signedHeight * initial.scaleY,
                               y: xAxis.y * signedWidth * initial.scaleX + yAxis.y * signedHeight * initial.scaleY)
        let target = CGPoint(x: diagonal.x + translation.width, y: diagonal.y + translation.height)
        var result = initial
        if lockAspectRatio {
            let squaredLength = diagonal.x * diagonal.x + diagonal.y * diagonal.y
            guard squaredLength.isFinite, squaredLength > 0 else { return initial }
            let projectedScale = (target.x * diagonal.x + target.y * diagonal.y) / squaredLength
            let minimum = max(ImageComparisonTransform.scaleRange.lowerBound / initial.scaleX,
                              ImageComparisonTransform.scaleRange.lowerBound / initial.scaleY)
            let maximum = min(ImageComparisonTransform.scaleRange.upperBound / initial.scaleX,
                              ImageComparisonTransform.scaleRange.upperBound / initial.scaleY)
            let factor = min(maximum, max(minimum, projectedScale))
            result.scaleX = initial.scaleX * factor
            result.scaleY = initial.scaleY * factor
        } else {
            let projectedX = (target.x * xAxis.x + target.y * xAxis.y) / signedWidth
            let projectedY = (target.x * yAxis.x + target.y * yAxis.y) / signedHeight
            result.scaleX = min(ImageComparisonTransform.scaleRange.upperBound,
                                max(ImageComparisonTransform.scaleRange.lowerBound, projectedX))
            result.scaleY = min(ImageComparisonTransform.scaleRange.upperBound,
                                max(ImageComparisonTransform.scaleRange.lowerBound, projectedY))
        }
        // Moving the center by half of the diagonal change keeps the opposite corner fixed.
        let widthChange = Double(signedWidth) * (result.scaleX - initial.scaleX)
        let heightChange = Double(signedHeight) * (result.scaleY - initial.scaleY)
        let dx: Double = (Double(xAxis.x) * widthChange + Double(yAxis.x) * heightChange) / 2
        let dy: Double = (Double(xAxis.y) * widthChange + Double(yAxis.y) * heightChange) / 2
        guard dx.isFinite, dy.isFinite else { return initial }
        // Stop resizing when the center reaches an offset bound, instead of clamping
        // the center independently and silently moving the supposedly fixed corner.
        let progress = min(1, permittedProgress(offset: initial.offsetX, delta: dx),
                           permittedProgress(offset: initial.offsetY, delta: dy))
        result.scaleX = initial.scaleX + (result.scaleX - initial.scaleX) * progress
        result.scaleY = initial.scaleY + (result.scaleY - initial.scaleY) * progress
        result.offsetX = initial.offsetX + dx * progress
        result.offsetY = initial.offsetY + dy * progress
        return result.normalized
    }

    private static func permittedProgress(offset: Double, delta: Double) -> Double {
        if delta > 0 { return max(0, (ImageComparisonTransform.offsetRange.upperBound - offset) / delta) }
        if delta < 0 { return max(0, (ImageComparisonTransform.offsetRange.lowerBound - offset) / delta) }
        return 1
    }
}
