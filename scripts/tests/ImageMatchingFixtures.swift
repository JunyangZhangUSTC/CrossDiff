import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Procedural, license-free fixtures shared by engine and full-window checks.
enum ImageMatchingFixtures {
    static func image(seed: UInt64 = 42, width: Int = 800, height: Int = 600) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.92, green: 0.95, blue: 0.98, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var state = seed
        func number(_ limit: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(limit))
        }
        for index in 0..<150 {
            let x = number(max(1, width - 60)) + 10, y = number(max(1, height - 60)) + 10
            let size = 7 + number(34)
            let rect = CGRect(x: x, y: y, width: size, height: size + number(15))
            let palette: [(CGFloat, CGFloat, CGFloat)] = [(0.16, 0.32, 0.51), (0.25, 0.58, 0.55), (0.86, 0.49, 0.24), (0.45, 0.4, 0.6)]
            let color = palette[number(palette.count)]
            context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
            if index % 3 == 0 { context.fillEllipse(in: rect) }
            else { context.fill(rect) }
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
            context.setLineWidth(2)
            context.move(to: CGPoint(x: x + 2, y: y + 3))
            context.addLine(to: CGPoint(x: x + size - 2, y: y + size - 3))
            context.strokePath()
        }
        return context.makeImage()!
    }

    static func asset(_ image: CGImage) -> ImageComparisonAsset {
        .init(image: image, originalWidth: image.width, originalHeight: image.height, hasMultipleFrames: false)
    }

    static func sources(_ left: CGImage, _ right: CGImage) -> ImageComparisonSources {
        .init(left: asset(left), right: asset(right))
    }

    /// A known full-height edit splits the surviving shared content into two
    /// islands. Write source-order pixels directly so the expected occlusion
    /// coordinates do not depend on Core Graphics drawing orientation.
    static func occlusionBounds(in image: CGImage) -> CGRect {
        CGRect(x: image.width * 2 / 5, y: 0,
               width: max(1, image.width / 5), height: image.height)
    }

    static func occluded(_ image: CGImage) -> CGImage {
        replacingPixels(in: image, bounds: occlusionBounds(in: image))
    }

    /// A bounded central edit leaves a visible hole inside otherwise connected
    /// common content, rather than splitting it into separate left/right islands.
    static func localOcclusionBounds(in image: CGImage) -> CGRect {
        CGRect(x: image.width * 3 / 8, y: image.height * 3 / 8,
               width: max(1, image.width / 4), height: max(1, image.height / 4))
    }

    static func locallyOccluded(_ image: CGImage) -> CGImage {
        replacingPixels(in: image, bounds: localOcclusionBounds(in: image))
    }

    private static func replacingPixels(in image: CGImage, bounds: CGRect) -> CGImage {
        precondition(image.bitsPerPixel == 32 && image.bitsPerComponent == 8)
        var bytes = [UInt8](image.dataProvider!.data! as Data)
        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            for x in Int(bounds.minX)..<Int(bounds.maxX) {
                let offset = y * image.bytesPerRow + x * 4
                bytes[offset] = 201
                bytes[offset + 1] = 102
                bytes[offset + 2] = 120
                bytes[offset + 3] = 255
            }
        }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: image.bytesPerRow, space: image.colorSpace!, bitmapInfo: image.bitmapInfo,
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func solid(alpha: CGFloat = 1) -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        return context.makeImage()!
    }
}
