import CoreGraphics
import Foundation
import ImageIO
import CrossDiffCore

/// Coordinates are decoded preview pixels, with positive x/y pointing right/down.
/// Scaling and rotation use each image's center; a positive angle rotates clockwise.
struct ImageComparisonTransform: Equatable, Sendable {
    static let scaleRange = 0.1...4.0
    static let rotationRange = -180.0...180.0
    static let offsetRange = -3200.0...3200.0
    static let identity = Self()

    var scaleX: Double
    var scaleY: Double
    var rotationDegrees: Double
    var offsetX: Double
    var offsetY: Double
    var flipHorizontal: Bool
    var flipVertical: Bool

    init(scale: Double = 1, rotationDegrees: Double = 0, offsetX: Double = 0, offsetY: Double = 0,
         scaleX: Double? = nil, scaleY: Double? = nil,
         flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.scaleX = scaleX ?? scale
        self.scaleY = scaleY ?? scale
        self.rotationDegrees = rotationDegrees
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    /// The overall scale control changes both axes proportionally, including stretched images.
    /// If either axis reaches its supported limit, stop both axes to preserve that shape.
    var scale: Double {
        get { max(scaleX, scaleY) }
        set {
            let current = normalized
            let requested = newValue.isFinite ? newValue : 1
            let minimum = max(Self.scaleRange.lowerBound / current.scaleX, Self.scaleRange.lowerBound / current.scaleY)
            let maximum = min(Self.scaleRange.upperBound / current.scaleX, Self.scaleRange.upperBound / current.scaleY)
            let multiplier = min(maximum, max(minimum, requested / max(current.scaleX, current.scaleY)))
            scaleX = current.scaleX * multiplier
            scaleY = current.scaleY * multiplier
        }
    }

    var normalized: Self {
        var value = self
        value.scaleX = scaleX.isFinite ? min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, scaleX)) : 1
        value.scaleY = scaleY.isFinite ? min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, scaleY)) : 1
        value.rotationDegrees = rotationDegrees.isFinite ? rotationDegrees.truncatingRemainder(dividingBy: 360) : 0
        if value.rotationDegrees > 180 { value.rotationDegrees -= 360 }
        if value.rotationDegrees < -180 { value.rotationDegrees += 360 }
        value.offsetX = offsetX.isFinite ? min(Self.offsetRange.upperBound, max(Self.offsetRange.lowerBound, offsetX)) : 0
        value.offsetY = offsetY.isFinite ? min(Self.offsetRange.upperBound, max(Self.offsetRange.lowerBound, offsetY)) : 0
        return value
    }

    var isIdentity: Bool { normalized == .identity }
}

// CGImages are immutable and only published after background work finishes.
struct ImageComparisonAsset: @unchecked Sendable {
    let image: CGImage
    let originalWidth: Int
    let originalHeight: Int
    let hasMultipleFrames: Bool

    fileprivate func replacingImage(_ image: CGImage) -> Self {
        Self(image: image, originalWidth: originalWidth, originalHeight: originalHeight,
             hasMultipleFrames: hasMultipleFrames)
    }
}

struct ImageComparisonSources: Sendable {
    let left: ImageComparisonAsset
    let right: ImageComparisonAsset

    var isDownsampled: Bool {
        left.image.width < left.originalWidth || left.image.height < left.originalHeight ||
        right.image.width < right.originalWidth || right.image.height < right.originalHeight
    }
}

struct ImageComparisonPreview: Sendable {
    /// Both images and the difference have exactly the same pixel dimensions and origin.
    let left: ImageComparisonAsset
    let right: ImageComparisonAsset
    let difference: CGImage
    let differentPixels: Int
    let comparedPixels: Int
    let overlapPixels: Int
    let overlapDifferentPixels: Int
    /// Converts decoded preview coordinates to output canvas coordinates.
    let canvasScale: Double
    /// Origin of the output canvas in decoded preview world coordinates.
    let canvasOrigin: CGPoint
    let leftSourceSize: CGSize
    let rightSourceSize: CGSize
    /// Source corner order follows ImageTransformCorner; points are output canvas pixels.
    let leftCorners: [CGPoint]
    let rightCorners: [CGPoint]
    let isDownsampled: Bool
    let leftTransform: ImageComparisonTransform
    let rightTransform: ImageComparisonTransform
    let overlapOnly: Bool

    var width: Int { difference.width }
    var height: Int { difference.height }
    var isCanvasDownsampled: Bool { canvasScale < 1 }
    var hasDifferentDimensions: Bool {
        left.originalWidth != right.originalWidth || left.originalHeight != right.originalHeight
    }
    var hasMultipleFrames: Bool { left.hasMultipleFrames || right.hasMultipleFrames }
}

enum ImageComparisonDecoder {
    static let maximumEdge = 1600

    private struct Source {
        let url: URL
        let source: CGImageSource
        let width: Int
        let height: Int
    }

    /// Decode both originals once, at the same scale, preserving relative dimensions.
    static func load(left: URL, right: URL) throws -> ImageComparisonSources {
        try Task.checkCancellation()
        let leftSource = try source(left)
        let rightSource = try source(right)
        let longestEdge = max(leftSource.width, leftSource.height, rightSource.width, rightSource.height)
        let scale = min(1, Double(maximumEdge) / Double(longestEdge))
        let leftImage = try thumbnail(leftSource, scale: scale)
        try Task.checkCancellation()
        let rightImage = try thumbnail(rightSource, scale: scale)
        try Task.checkCancellation()
        return ImageComparisonSources(left: leftImage, right: rightImage)
    }

    private static func source(_ url: URL) throws -> Source {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                     [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              rawWidth > 0, rawHeight > 0 else {
            throw ImageComparisonFailure.unreadable(url.lastPathComponent)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        return Source(url: url, source: source,
                      width: swapsAxes ? rawHeight : rawWidth, height: swapsAxes ? rawWidth : rawHeight)
    }

    private static func thumbnail(_ source: Source, scale: Double) throws -> ImageComparisonAsset {
        let edge = min(maximumEdge, max(1, Int((Double(max(source.width, source.height)) * scale).rounded())))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source.source, 0, options as CFDictionary),
              image.width <= maximumEdge, image.height <= maximumEdge else {
            throw ImageComparisonFailure.decoding(source.url.lastPathComponent)
        }
        return ImageComparisonAsset(image: image, originalWidth: source.width, originalHeight: source.height,
                                    hasMultipleFrames: CGImageSourceGetCount(source.source) > 1)
    }
}

enum ImageComparisonRenderer {
    static let maximumEdge = ImageComparisonDecoder.maximumEdge
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    private struct Placement {
        let transform: CGAffineTransform
        let bounds: CGRect

        init(image: CGImage, adjustment: ImageComparisonTransform) {
            transform = ImageTransformGeometry.affine(
                sourceSize: CGSize(width: image.width, height: image.height), transform: adjustment)
            bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height).applying(transform)
        }
    }

    private struct Raster {
        let rgba: [UInt8]
        /// The transformed rectangle's coverage, independent of the image's alpha channel.
        let coverage: [UInt8]
    }

    static func render(sources: ImageComparisonSources,
                       leftTransform: ImageComparisonTransform = .identity,
                       rightTransform: ImageComparisonTransform = .identity,
                       overlapOnly: Bool = false,
                       maximumEdge requestedMaximumEdge: Int = ImageComparisonRenderer.maximumEdge) throws -> ImageComparisonPreview {
        try Task.checkCancellation()
        let leftTransform = leftTransform.normalized
        let rightTransform = rightTransform.normalized
        for image in [sources.left.image, sources.right.image] {
            guard image.width > 0, image.height > 0,
                  image.width <= maximumEdge, image.height <= maximumEdge else {
                throw ImageComparisonFailure.dimensions
            }
        }
        let leftPlacement = Placement(image: sources.left.image, adjustment: leftTransform)
        let rightPlacement = Placement(image: sources.right.image, adjustment: rightTransform)
        // Integral bounds preserve the original pixel grid for integer offsets and quarter turns.
        let union = leftPlacement.bounds.union(rightPlacement.bounds).integral
        guard union.width.isFinite, union.height.isFinite, union.width > 0, union.height > 0 else {
            throw ImageComparisonFailure.dimensions
        }
        let outputMaximumEdge = min(maximumEdge, max(1, requestedMaximumEdge))
        let canvasScale = min(1, Double(outputMaximumEdge) / max(union.width, union.height))
        let width = min(outputMaximumEdge, max(1, Int(ceil(union.width * canvasScale))))
        let height = min(outputMaximumEdge, max(1, Int(ceil(union.height * canvasScale))))
        let left = try raster(sources.left.image, placement: leftPlacement, union: union,
                              canvasScale: canvasScale, width: width, height: height)
        try Task.checkCancellation()
        let right = try raster(sources.right.image, placement: rightPlacement, union: union,
                               canvasScale: canvasScale, width: width, height: height)
        try Task.checkCancellation()
        let difference = try pixelDifference(left, right, width: width, height: height, overlapOnly: overlapOnly)
        return ImageComparisonPreview(
            left: sources.left.replacingImage(try image(left.rgba, width: width, height: height)),
            right: sources.right.replacingImage(try image(right.rgba, width: width, height: height)),
            difference: try image(difference.bytes, width: width, height: height),
            differentPixels: difference.different, comparedPixels: difference.compared,
            overlapPixels: difference.overlap, overlapDifferentPixels: difference.overlapDifferent,
            canvasScale: canvasScale, canvasOrigin: union.origin,
            leftSourceSize: CGSize(width: sources.left.image.width, height: sources.left.image.height),
            rightSourceSize: CGSize(width: sources.right.image.width, height: sources.right.image.height),
            leftCorners: canvasCorners(image: sources.left.image, transform: leftTransform, origin: union.origin, scale: canvasScale),
            rightCorners: canvasCorners(image: sources.right.image, transform: rightTransform, origin: union.origin, scale: canvasScale),
            isDownsampled: sources.isDownsampled,
            leftTransform: leftTransform, rightTransform: rightTransform, overlapOnly: overlapOnly)
    }

    private static func canvasCorners(image: CGImage, transform: ImageComparisonTransform,
                                      origin: CGPoint, scale: Double) -> [CGPoint] {
        ImageTransformGeometry.corners(sourceSize: CGSize(width: image.width, height: image.height), transform: transform)
            .map { CGPoint(x: ($0.x - origin.x) * scale, y: ($0.y - origin.y) * scale) }
    }

    private static func raster(_ image: CGImage, placement: Placement, union: CGRect,
                               canvasScale: Double, width: Int, height: Int) throws -> Raster {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorRendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: bitmapInfo) else { return false }
            configure(context, placement: placement, union: union, scale: canvasScale, height: height)
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            // Drawing CGImage uses bottom-left coordinates. Undo that locally while keeping
            // the shared placement transform in top-left, clockwise-positive coordinates.
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard colorRendered else { throw ImageComparisonFailure.memory }
        try Task.checkCancellation()
        var coverage = [UInt8](repeating: 0, count: width * height)
        let coverageRendered = coverage.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            configure(context, placement: placement, union: union, scale: canvasScale, height: height)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard coverageRendered else { throw ImageComparisonFailure.memory }
        return Raster(rgba: bytes, coverage: coverage)
    }

    private static func configure(_ context: CGContext, placement: Placement, union: CGRect,
                                  scale: Double, height: Int) {
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -union.minX, y: -union.minY)
        context.concatenate(placement.transform)
    }

    /// Compare premultiplied 8-bit sRGB, so invisible RGB in fully transparent pixels is ignored.
    /// Coverage stays separate: a transparent source rectangle still has meaningful boundaries.
    private static func pixelDifference(_ left: Raster, _ right: Raster, width: Int, height: Int,
                                        overlapOnly: Bool) throws -> (bytes: [UInt8], different: Int,
                                                                     compared: Int, overlap: Int, overlapDifferent: Int) {
        var result = [UInt8](repeating: 0, count: width * height * 4)
        var different = 0, compared = 0, overlap = 0, overlapDifferent = 0
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let pixel = y * width + x, offset = pixel * 4
                let inLeft = left.coverage[pixel] > 0, inRight = right.coverage[pixel] > 0
                guard inLeft || inRight else { continue }
                let inOverlap = inLeft && inRight
                if inOverlap { overlap += 1 }
                var delta = max(inLeft == inRight ? 0 : 64,
                                abs(Int(left.coverage[pixel]) - Int(right.coverage[pixel])))
                for channel in 0..<4 {
                    delta = max(delta, abs(Int(left.rgba[offset + channel]) - Int(right.rgba[offset + channel])))
                }
                if inOverlap && delta > 0 { overlapDifferent += 1 }
                guard !overlapOnly || inOverlap else { continue }
                compared += 1
                result[offset + 3] = 255
                if delta > 0 {
                    different += 1
                    result[offset] = UInt8(min(255, 100 + delta * 3))
                    result[offset + 1] = UInt8(min(225, 55 + delta * 2))
                    result[offset + 2] = 45
                } else {
                    result[offset] = 25
                    result[offset + 1] = 27
                    result[offset + 2] = 31
                }
            }
        }
        return (result, different, compared, overlap, overlapDifferent)
    }

    private static func image(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ImageComparisonFailure.difference
        }
        return image
    }
}

enum ImageComparisonFailure: LocalizedError {
    case unreadable(String), decoding(String), memory, dimensions, difference
    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return L("无法读取“\(name)”。请确认文件可访问，且是受支持的图片格式。", "Unable to read “\(name)”. Check that the file is accessible and uses a supported image format.")
        case .decoding(let name):
            return L("无法解码“\(name)”的图片预览。文件可能已损坏或格式不受支持。", "Unable to decode a preview of “\(name)”. The file may be damaged or its format unsupported.")
        case .memory:
            return L("无法分配图片预览所需的内存。", "Unable to allocate memory for the image preview.")
        case .dimensions:
            return L("图片预览超出允许的尺寸。", "The image preview exceeds the supported dimensions.")
        case .difference:
            return L("无法生成像素差异预览。", "Unable to generate the pixel difference preview.")
        }
    }
}
