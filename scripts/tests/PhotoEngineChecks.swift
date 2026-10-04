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
        for histogram in [stats.red, stats.green, stats.blue, stats.lightness, stats.saturation, stats.perceptualLightness] {
            try expect(near(histogram.reduce(0, +), 1), "Finite endpoint samples are included in all distributions")
        }
        try expect(near(stats.red[255], 0.5) && near(stats.red[0], 0.5), "Pure red and pure white reach the last RGB bin")
        try expect(near(stats.saturation[255], 0.75), "Fully saturated RGB samples reach the last saturation bin")
        try expect(near(stats.lightness[255], 0.25), "White reaches the final HSL lightness bin")
        try expect(near(stats.lightness[128], 0.75), "HSL L=0.5 uses the exact central bin boundary")
        try expect(near(stats.neutralFraction, 0.25), "White is neutral; hue does not misclassify it as red")
        try expect(near(stats.hue.reduce(0, +), 0.75), "Hue distribution is normalized by valid samples, excluding neutrals")
        try expect(near(stats.perceptualLightness[136], 0.25) && near(stats.perceptualLightness[224], 0.25)
            && near(stats.perceptualLightness[82], 0.25) && near(stats.perceptualLightness[255], 0.25),
            "Lab L* distinguishes red/green/blue with equal HSL L and includes white at 100")
        try expect(stats.values(for: .perceptualLightness) == stats.perceptualLightness
            && stats.values(for: .rgb).isEmpty, "RGB overview is never a fabricated single distribution")
        try expect(stats.percentile(0.5, channel: .perceptualLightness) == 136.0 / 255
            && stats.percentile(0, channel: .perceptualLightness) == 82.0 / 255
            && stats.percentile(1, channel: .perceptualLightness) == 1,
            "Percentiles return bounded histogram estimates including endpoints")
        try expect(stats.percentile(.nan, channel: .red) == nil && stats.percentile(-0.1, channel: .red) == nil
            && stats.percentile(0.5, channel: .rgb) == nil, "Invalid percentile requests have no numerical result")
        let redRange = PhotoHistogramRange(channel: .red, lowerBin: 255, upperBin: 255)
        try expect(near(stats.fraction(in: redRange), 0.5), "Brush occupancy uses each image's valid-pixel denominator")
        let normalizedRange = PhotoHistogramRange(channel: .blue, lowerBin: 300, upperBin: -10)
        try expect(normalizedRange.lowerBin == 0 && normalizedRange.upperBin == 255,
                   "Range bins clamp and sort without trapping")
        let invalidRange = PhotoHistogramRange(channel: .rgb, lowerBin: 0, upperBin: 255)
        try expect(!invalidRange.isValid && stats.fraction(in: invalidRange) == 0,
                   "An overview cannot become a single-channel brush")
        let original = try PhotoAnalysisEngine.preview(decoded, channel: .original, highlight: nil, region: .full)
        try expect(original === decoded.preview, "Original preview reuses the decoded image")
        for (channel, expected) in [(PhotoPreviewChannel.red, [255, 0, 0, 255]), (.green, [0, 255, 0, 255]), (.blue, [0, 0, 255, 255])] {
            let preview = try PhotoAnalysisEngine.preview(decoded, channel: channel, highlight: nil, region: .full)
            let bytes = rgba(preview)
            for (index, value) in expected.enumerated() {
                try expect(bytes[index * 4] == value && bytes[index * 4 + 1] == value && bytes[index * 4 + 2] == value,
                    "Single-channel preview copies its component to gray, preserving source orientation")
            }
        }
        let brush = try PhotoAnalysisEngine.preview(decoded, channel: .original, highlight: redRange,
            region: .init(x: 0, y: 0, width: 0.5, height: 0.5))
        let brushed = rgba(brush)
        try expect(Array(brushed[0..<4]) == [255, 59, 4, 255] && Array(brushed[4..<16]) == Array(swatches[4..<16]),
            "Histogram brush highlights only matching pixels in the top-left ROI and leaves all others intact")
        let labBrush = try PhotoAnalysisEngine.preview(decoded, channel: .original,
            highlight: .init(channel: .perceptualLightness, lowerBin: 136, upperBin: 136), region: .full)
        try expect(rgba(labBrush) == brushed, "Lab brush shares the L* histogram's bin definition")
        let fullBrush = try PhotoAnalysisEngine.preview(decoded, channel: .original, highlight: redRange, region: .full)
        let fullBrushed = rgba(fullBrush)
        try expect(Array(fullBrushed[0..<4]) == [255, 59, 4, 255]
            && Array(fullBrushed[12..<16]) == [255, 232, 177, 255],
            "Amber highlight blends with both dark and bright source values instead of covering texture")
        let independent = try PhotoAnalysisEngine.preview(decoded, channel: .blue, highlight: redRange,
            region: .init(x: 0, y: 0, width: 0.5, height: 0.5))
        try expect(Array(rgba(independent)[0..<4]) == [82, 59, 4, 255]
            && Array(rgba(independent)[8..<12]) == [255, 255, 255, 255],
            "Brush metric is independent of the displayed grayscale channel")
        let unchanged = try PhotoAnalysisEngine.analyze(decoded, region: .full)
        try expect(unchanged == stats, "Rendering a brush cannot feed the mask into the source statistics")
        do {
            _ = try PhotoAnalysisEngine.preview(decoded, channel: .red, highlight: invalidRange, region: .full)
            throw NSError(domain: "PhotoChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid brush should fail"])
        } catch PhotoAnalysisError.invalidRange { checks += 1 }
        var oldState = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PhotoWorkspaceState())) as! [String: Any]
        for key in ["histogramChannel", "histogramLayout", "previewChannel"] { oldState.removeValue(forKey: key) }
        let recovered = try JSONDecoder().decode(PhotoWorkspaceState.self, from: JSONSerialization.data(withJSONObject: oldState))
        try expect(recovered.histogramChannel == .perceptualLightness && recovered.histogramLayout == .separated
            && recovered.previewChannel == .original, "Old sessions recover the new controls' defaults")
        var selectedState = recovered
        selectedState.histogramChannel = .blue; selectedState.histogramLayout = .difference; selectedState.previewChannel = .red
        let recoveredSelected = try JSONDecoder().decode(PhotoWorkspaceState.self, from: JSONEncoder().encode(selectedState))
        try expect(recoveredSelected == selectedState, "Selected preview and histogram controls round-trip in sessions")
        var oldStatistics = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stats)) as! [String: Any]
        oldStatistics.removeValue(forKey: "perceptualLightness")
        let recoveredStatistics = try JSONDecoder().decode(PhotoStatistics.self, from: JSONSerialization.data(withJSONObject: oldStatistics))
        try expect(recoveredStatistics.perceptualLightness.isEmpty
            && recoveredStatistics.percentile(0.5, channel: .perceptualLightness) == nil
            && recoveredStatistics.red == stats.red, "Legacy statistics remain decodable without invented L* values")
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
        let partialPreview = try PhotoAnalysisEngine.preview(PhotoAnalysisEngine.load(partialFile), channel: .red,
            highlight: nil, region: .full)
        try expect(rgba(partialPreview) == [255, 255, 255, 128], "Channel previews preserve straight color and partial alpha")
        let partialBrush = try PhotoAnalysisEngine.preview(PhotoAnalysisEngine.load(partialFile), channel: .original,
            highlight: redRange, region: .full)
        try expect(rgba(partialBrush) == [255, 59, 4, 128], "Blended highlighting retains the source alpha")
        for (bias, expected) in [(-1.0 / 3, "-0.33 EV"), (2.0 / 3, "+0.67 EV"), (1.0, "+1 EV"), (0.0, "+0 EV")] {
            let biasFile = directory.appendingPathComponent("bias-\(expected.prefix(1))\(abs(bias)).tiff")
            try saveData(Data(swatches), width: 2, height: 2, to: biasFile, bits: 8, orientation: 1,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, exposureBias: bias)
            let biasImage = try PhotoAnalysisEngine.load(biasFile)
            try expect(biasImage.metadata.first(where: { $0.id == "exposureBias" })?.value == expected,
                "Recorded exposure bias is signed and displayed with at most two decimal places")
        }
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
        let longPreview = try PhotoAnalysisEngine.preview(PhotoAnalysisEngine.load(longFile), channel: .red,
            highlight: nil, region: .full)
        try expect(longPreview.width == 2048 && longPreview.height == 1, "Channel previews use a bounded full-aspect image")
        let tallFile = directory.appendingPathComponent("tall-brush.png")
        try save(Array(repeating: [UInt8](arrayLiteral: 255, 0, 0, 255), count: 130).flatMap { $0 },
            width: 1, height: 130, to: tallFile)
        let tallPreview = try PhotoAnalysisEngine.preview(PhotoAnalysisEngine.load(tallFile), channel: .original,
            highlight: redRange, region: .init(x: 0, y: 0.5, width: 1, height: 0.5))
        let tallBytes = rgba(tallPreview)
        try expect(Array(tallBytes[64 * 4..<65 * 4]) == [255, 0, 0, 255]
            && Array(tallBytes[65 * 4..<66 * 4]) == [255, 59, 4, 255]
            && Array(tallBytes[129 * 4..<130 * 4]) == [255, 59, 4, 255],
            "Brush ROI row coordinates remain correct across bounded processing blocks")
        // Direct C boundary check covers malformed float buffers that normal ImageIO refuses to produce.
        var floats: [Float] = [1,0,0,1, .nan,0,0,1, 0,.infinity,0,1, 0,0,1,0, 2,0,0,1]
        var histograms = [Double](repeating: 0, count: 1640), neutral = 0.0
        var valid: Int32 = 0
        let status = crossdiff_photo_histograms(&floats, 5, 1, &histograms, 1640, &valid, &neutral)
        try expect(status == 0 && valid == 2 && near(histograms[255], 1), "Library excludes NaN/infinite/transparent samples and reports clamped SDR bins")
        var extended = [Double](repeating: 0, count: 1896)
        let extendedStatus = crossdiff_photo_histograms_v2(&floats, 5, 1, &extended, extended.count, &valid, &neutral)
        try expect(extendedStatus == 0 && valid == 2 && near(extended[1640 + 136], 1)
            && Array(extended[0..<1640]) == histograms, "Extended Lab statistics retain the legacy distributions and valid mask")
        var previewBytes = [UInt8](repeating: 0, count: 20)
        let previewStatus = crossdiff_photo_preview(&floats, 5, 1, 0, 1, 255, 255, 0, 0, 5, 1,
            &previewBytes, previewBytes.count)
        try expect(previewStatus == 0 && Array(previewBytes[0..<4]) == [255, 59, 4, 255]
            && previewBytes[7] == 0 && previewBytes[11] == 0 && previewBytes[15] == 0
            && Array(previewBytes[16..<20]) == [255, 59, 4, 255],
            "Preview mask excludes non-finite and transparent samples while including clamped white-end bins")
        var boundary: [Float] = [0.5, 0, 0, 1, 0.499, 0, 0, 1, 1, 1, 1, 1]
        var boundaryBytes = [UInt8](repeating: 0, count: 12)
        let boundaryStatus = crossdiff_photo_preview(&boundary, 3, 1, 0, 1, 128, 128, 0, 0, 3, 1,
            &boundaryBytes, boundaryBytes.count)
        try expect(boundaryStatus == 0 && Array(boundaryBytes[0..<4]) == [168, 59, 4, 255]
            && boundaryBytes[5] == 0 && boundaryBytes[9] == 255, "Brush bin boundaries match calcHist's half-open inner bins")
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

    private static func rgba(_ image: CGImage) -> [UInt8] {
        // Engine-generated previews explicitly use straight RGBA8 and packed rows.
        Array(image.dataProvider!.data! as Data)
    }

    private static func save(_ bytes: [UInt8], width: Int, height: Int, to url: URL, orientation: Int = 1,
                             colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws {
        try saveData(Data(bytes), width: width, height: height, to: url, bits: 8, orientation: orientation, colorSpace: colorSpace)
    }

    private static func saveData(_ data: Data, width: Int, height: Int, to url: URL, bits: Int,
                                 orientation: Int, colorSpace: CGColorSpace, exposureBias: Double? = nil) throws {
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
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if let exposureBias { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifExposureBiasValue: exposureBias] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoAnalysisError.decode }
    }
}
