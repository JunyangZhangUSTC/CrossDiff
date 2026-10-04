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
