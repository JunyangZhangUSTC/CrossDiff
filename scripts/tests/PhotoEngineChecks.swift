import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CrossDiffCore
import PhotoCVBridge
import Darwin

@main
struct PhotoEngineChecks {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "PhotoChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.00001 }
        let swatches: [UInt8] = [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,255,255]
        let colors = directory.appendingPathComponent("colors.png")
        try save(swatches, width: 2, height: 2, to: colors)
        let decoded = try PhotoAnalysisEngine.load(colors)
        let stats = try PhotoAnalysisEngine.analyze(decoded, region: .full)
        try expect(stats.analyzedPixels == 4 && !stats.sampled, "Four source pixels are counted, not a display thumbnail")
        for histogram in [stats.red, stats.green, stats.blue, stats.lightness, stats.saturation] {
            try expect(near(histogram.reduce(0, +), 1), "Finite endpoint samples are included in all distributions")
        }
        try expect(near(stats.red[255], 0.5) && near(stats.red[0], 0.5), "Pure red and pure white reach the last RGB bin")
        try expect(near(stats.saturation[255], 0.75), "Fully saturated RGB samples reach the last saturation bin")
        try expect(near(stats.lightness[255], 0.25), "White reaches the final HSL lightness bin")
        try expect(near(stats.lightness[128], 0.75), "HSL L=0.5 uses the exact central bin boundary")
        try expect(near(stats.neutralFraction, 0.25), "White is neutral; hue does not misclassify it as red")
        try expect(near(stats.hue.reduce(0, +), 0.75), "Hue distribution is normalized by valid samples, excluding neutrals")
        let topLeft = try PhotoAnalysisEngine.analyze(decoded, region: .init(x: 0, y: 0, width: 0.5, height: 0.5))
        try expect(near(topLeft.red[255], 1) && near(topLeft.green[0], 1), "Top-left ROI refers to the red source pixel")
        let lowerLeft = try PhotoAnalysisEngine.analyze(decoded, region: .init(x: 0, y: 0.5, width: 0.5, height: 0.5))
        try expect(near(lowerLeft.blue[255], 1), "Top-left user coordinates are correctly mapped into Core Image")
        let orientedFile = directory.appendingPathComponent("oriented.tiff")
        try save(swatches, width: 2, height: 2, to: orientedFile, orientation: 6)
        let oriented = try PhotoAnalysisEngine.load(orientedFile)
        let orientedTop = try PhotoAnalysisEngine.analyze(oriented, region: .init(x: 0, y: 0, width: 0.5, height: 0.5))
        try expect(near(orientedTop.blue[255], 1), "EXIF orientation is applied before selecting and analyzing the ROI")
        let alphaFile = directory.appendingPathComponent("transparent.png")
        try save([255,0,0,255, 0,0,0,0], width: 2, height: 1, to: alphaFile)
        let alpha = try PhotoAnalysisEngine.analyze(PhotoAnalysisEngine.load(alphaFile), region: .full)
        try expect(alpha.analyzedPixels == 1 && near(alpha.red[255], 1), "Transparent padding cannot distort image statistics")
        let partialFile = directory.appendingPathComponent("partial-alpha.png")
        try save([255,0,0,128], width: 1, height: 1, to: partialFile)
        let partial = try PhotoAnalysisEngine.analyze(PhotoAnalysisEngine.load(partialFile), region: .full)
        try expect(near(partial.red[255], 1), "Partial alpha is unpremultiplied before color statistics")
        let p3File = directory.appendingPathComponent("display-p3.png")
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        try save([128,180,100,255], width: 1, height: 1, to: p3File, colorSpace: p3)
        let p3Stats = try PhotoAnalysisEngine.analyze(PhotoAnalysisEngine.load(p3File), region: .full)
        let converted = CGColor(colorSpace: p3, components: [128.0/255,180.0/255,100.0/255,1])!
            .converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .relativeColorimetric, options: nil)!.components!
        let expectedRed = min(255, max(0, Int(converted[0] * 256)))
        try expect(near(p3Stats.red[expectedRed], 1) && expectedRed != 128, "Display P3 profile is converted by Apple, not relabeled sRGB")
        let deepFile = directory.appendingPathComponent("sixteen-bit.tiff")
        let deepValues: [UInt16] = [32767,32767,32767,65535, 32768,32768,32768,65535]
        try deepValues.withUnsafeBytes { raw in
            try saveData(Data(raw), width: 2, height: 1, to: deepFile, bits: 16, orientation: 1,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        let deepImage = try PhotoAnalysisEngine.load(deepFile)
        let deep = try PhotoAnalysisEngine.analyze(deepImage, region: .full)
        try expect(deepImage.metadata.contains { $0.id == "depth" && $0.value == "16" }, "16-bit source depth remains identified")
        try expect(near(deep.red[127], 0.5) && near(deep.red[128], 0.5), "16-bit adjacent samples across a bin boundary survive the float analysis pipeline")
        do {
            _ = try PhotoAnalysisEngine.analyze(PhotoAnalysisEngine.load(alphaFile), region: .init(x: 0.5, y: 0, width: 0.5, height: 1))
            throw NSError(domain: "PhotoChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Transparent ROI should fail"])
        } catch PhotoAnalysisError.noPixels { checks += 1 }
        do {
            _ = try PhotoAnalysisEngine.analyze(decoded, region: .init(x: -0.1))
            throw NSError(domain: "PhotoChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Out-of-range ROI should fail"])
        } catch PhotoAnalysisError.invalidRegion { checks += 1 }
        let fifo = directory.appendingPathComponent("not-an-image.fifo")
        if !FileManager.default.fileExists(atPath: fifo.path) { _ = mkfifo(fifo.path, 0o600) }
        do {
            _ = try PhotoAnalysisEngine.load(fifo)
            throw NSError(domain: "PhotoChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "A FIFO must be rejected without waiting for a writer"])
        } catch PhotoAnalysisError.invalidFile { checks += 1 }
        let fakeRAW = directory.appendingPathComponent("invalid.nef")
        try Data("not a camera RAW".utf8).write(to: fakeRAW)
        do {
            _ = try PhotoAnalysisEngine.load(fakeRAW)
            throw NSError(domain: "PhotoChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid RAW should fail"])
        } catch PhotoAnalysisError.unsupportedRAW { checks += 1 }
        let disguised = directory.appendingPathComponent("ordinary-image.nef")
        try Data(contentsOf: orientedFile).write(to: disguised)
        do {
            _ = try PhotoAnalysisEngine.load(disguised)
            throw NSError(domain: "PhotoChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "A regular TIFF must not masquerade as decoded RAW"])
        } catch PhotoAnalysisError.unsupportedRAW { checks += 1 }
        let longFile = directory.appendingPathComponent("long.png")
        try save(Array(repeating: [UInt8](arrayLiteral: 255,255,255,255), count: 5000).flatMap { $0 }, width: 5000, height: 1, to: longFile)
        let sampled = try PhotoAnalysisEngine.analyze(PhotoAnalysisEngine.load(longFile), region: .full)
        try expect(sampled.sampled && sampled.sampleWidth == 4096 && sampled.sampleHeight == 1, "Long-edge budget is reflected in statistics")
        // Direct C boundary check covers malformed float buffers that normal ImageIO refuses to produce.
        var floats: [Float] = [1,0,0,1, .nan,0,0,1, 0,.infinity,0,1, 0,0,1,0, 2,0,0,1]
        var histograms = [Double](repeating: 0, count: 1640), neutral = 0.0
        var valid: Int32 = 0
        let status = crossdiff_photo_histograms(&floats, 5, 1, &histograms, 1640, &valid, &neutral)
        try expect(status == 0 && valid == 2 && near(histograms[255], 1), "Library excludes NaN/infinite/transparent samples and reports clamped SDR bins")
        try expect(String(cString: crossdiff_photo_opencv_version()) == "4.12.0", "Checks exercise the pinned upstream OpenCV implementation")
        for path in CommandLine.arguments.dropFirst(2) {
            let raw = try PhotoAnalysisEngine.load(URL(fileURLWithPath: path))
            let rawStats = try PhotoAnalysisEngine.analyze(raw, region: .full)
            fputs("RAW checking: \(URL(fileURLWithPath: path).lastPathComponent), source \(raw.pixelWidth) × \(raw.pixelHeight), preview \(raw.preview.width) × \(raw.preview.height)\n", stderr)
            try expect(raw.diagnostics.contains { $0.en.hasPrefix("RAW uses Apple's default rendering") }, "RAW sample is decoded by CIRAWFilter")
            try expect(raw.pixelWidth * raw.pixelHeight > raw.preview.width * raw.preview.height,
                       "RAW retains a full-resolution analysis source independent of its display preview")
            try expect(near(rawStats.red.reduce(0, +), 1) && near(rawStats.lightness.reduce(0, +), 1),
                       "Real RAW sample produces normalized float color and HSL distributions")
            print("RAW verified: \(URL(fileURLWithPath: path).lastPathComponent), \(raw.pixelWidth) × \(raw.pixelHeight), \(rawStats.analyzedPixels) samples")
        }
        print("Photography engine: \(checks) checks passed.")
    }

    private static func save(_ bytes: [UInt8], width: Int, height: Int, to url: URL, orientation: Int = 1,
                             colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws {
        try saveData(Data(bytes), width: width, height: height, to: url, bits: 8, orientation: orientation, colorSpace: colorSpace)
    }

    private static func saveData(_ data: Data, width: Int, height: Int, to url: URL, bits: Int,
                                 orientation: Int, colorSpace: CGColorSpace) throws {
        var bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        if bits == 16 { bitmap.insert(.byteOrder16Little) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
                bytesPerRow: width * 4 * bits / 8, space: colorSpace,
                bitmapInfo: bitmap, provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                (url.pathExtension == "tiff" ? UTType.tiff.identifier : UTType.png.identifier) as CFString, 1, nil) else {
            throw PhotoAnalysisError.decode
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoAnalysisError.decode }
    }
}
