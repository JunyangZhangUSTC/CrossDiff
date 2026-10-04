import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin
import CrossDiffCore
import PhotoCVBridge

/// Retains the oriented, color-managed source separately from the display thumbnail.
struct PhotoDecodedImage: @unchecked Sendable {
    let preview: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let metadata: [PhotoMetadataItem]
    let diagnostics: [PluginLocalizedText]
    let recordedCurves: [PhotoRecordedCurve]
    let curveWarning: Error?
    fileprivate let image: CIImage
    init(preview: CGImage, pixelWidth: Int, pixelHeight: Int, metadata: [PhotoMetadataItem],
         diagnostics: [PluginLocalizedText], image: CIImage,
         recordedCurves: [PhotoRecordedCurve] = [], curveWarning: Error? = nil) {
        self.preview = preview; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.metadata = metadata; self.diagnostics = diagnostics; self.image = image
        self.recordedCurves = recordedCurves; self.curveWarning = curveWarning
    }
}

enum PhotoAnalysisError: LocalizedError {
    case invalidFile, fileTooLarge, pixelBudget, unsupportedRAW, decode, invalidRegion, invalidRange, noPixels, statistics
    var errorDescription: String? {
        switch self {
        case .invalidFile: return L("请选择本地图片文件。", "Choose a local image file.")
        case .fileTooLarge: return L("摄影分析目前支持最大 256 MiB 的文件。", "Photography analysis currently supports files up to 256 MiB.")
        case .pixelBudget: return L("摄影分析目前支持最大 6400 万像素的图片。", "Photography analysis currently supports images up to 64 megapixels.")
        case .unsupportedRAW: return L("此 RAW 无法由当前 macOS 完整解码，未使用内嵌预览代替。请尝试受支持的 RAW 或导出 TIFF。", "This RAW cannot be fully decoded by this macOS version. No embedded preview was substituted. Try a supported RAW or export TIFF.")
        case .decode: return L("无法解码此图片。", "This image could not be decoded.")
        case .invalidRegion: return L("分析选区超出了图片范围。", "The analysis region is outside the image.")
        case .invalidRange: return L("请选择单一通道的有效直方图区间。", "Choose a valid histogram range for one channel.")
        case .noPixels: return L("选区内没有可分析的有效可见像素。", "The region contains no valid visible pixels to analyze.")
        case .statistics: return L("专业分析库无法完成此次统计。", "The analysis library could not compute these statistics.")
        }
    }
}

enum PhotoAnalysisEngine {
    static let maximumFileBytes = 256 * 1024 * 1024
    static let maximumPixels = 64_000_000
    static let maximumSampleSide = 4096
    static let maximumPreviewSide = 2048
    static let analysisSpace = "sRGB · SDR [0, 1] · Lab L* [0, 100] (D65) · HSL L · OpenCV 4.12.0"
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputColorSpace: srgb, .workingFormat: CIFormat.RGBAf,
        .outputPremultiplied: false, .cacheIntermediates: false
    ])
    private static let rawExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "braw", "cap", "cr2", "cr3", "crw", "dcr", "dng", "eip", "erf",
        "fff", "gpr", "iiq", "k25", "kdc", "mdc", "mef", "mos", "mrw", "nef", "nrw", "obm", "orf",
        "pef", "ptx", "pxn", "r3d", "raf", "raw", "rwl", "rw2", "rwz", "sr2", "srf", "srw", "x3f"
    ]

    static func load(_ url: URL) throws -> PhotoDecodedImage {
        try Task.checkCancellation()
        guard url.isFileURL else { throw PhotoAnalysisError.invalidFile }
        // A path can change between metadata lookup and open. Open without blocking
        // on a substituted FIFO, then validate the held descriptor before reading.
        // User-selected symlinks are allowed, provided their opened target is regular.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG else { throw PhotoAnalysisError.invalidFile }
        guard attributes.st_size > 0, attributes.st_size <= maximumFileBytes else { throw PhotoAnalysisError.fileTooLarge }
        // Keep a bounded immutable snapshot: lazy CI decoding must not re-read a changed source file.
        var data = Data()
        while let chunk = try handle.read(upToCount: min(8 * 1024 * 1024, maximumFileBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumFileBytes else { throw PhotoAnalysisError.fileTooLarge }
            try Task.checkCancellation()
        }
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        let type = source.flatMap { CGImageSourceGetType($0) }.map { $0 as String }
        let isRAW = rawExtensions.contains(url.pathExtension.lowercased()) || type.flatMap(UTType.init)?.conforms(to: .rawImage) == true
        var properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any] ?? [:]
        var diagnostics: [PluginLocalizedText] = []
        let decoded: CIImage
        if isRAW {
            // Some camera RAW containers are reported as public.tiff by ImageIO.
            // Preserve the camera type hint: otherwise CIRAWFilter may accept only
            // the TIFF thumbnail and report decoder "None" instead of decoding RAW.
            let extensionType = UTType(filenameExtension: url.pathExtension.lowercased())
            let rawHint = extensionType?.conforms(to: .rawImage) == true ? extensionType?.identifier : type
            guard let raw = CIRAWFilter(imageData: data, identifierHint: rawHint),
                  raw.decoderVersion != .none, !raw.decoderVersion.rawValue.isEmpty,
                  raw.supportedDecoderVersions.contains(where: { $0 != .none && !$0.rawValue.isEmpty }),
                  raw.nativeSize.width >= 1, raw.nativeSize.height >= 1 else { throw PhotoAnalysisError.unsupportedRAW }
            try validateSize(raw.nativeSize)
            raw.isDraftModeEnabled = false
            raw.scaleFactor = 1
            guard let output = raw.outputImage else { throw PhotoAnalysisError.unsupportedRAW }
            decoded = output
            properties.merge(raw.properties as? [String: Any] ?? [:]) { _, new in new }
            // TIFF-compatible RAW containers can expose the thumbnail's bit depth.
            // Do not present that value as the sensor's recording precision.
            properties.removeValue(forKey: kCGImagePropertyDepth as String)
            diagnostics.append(.init(zhHans: "RAW 使用 Apple 默认显影（\(raw.decoderVersion.rawValue)），不是相机原始采样值或原作者的调色结果。", en: "RAW uses Apple's default rendering (\(raw.decoderVersion.rawValue)), not sensor samples or the original author's edit."))
        } else {
            guard source != nil,
                  let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else { throw PhotoAnalysisError.decode }
            try validateSize(CGSize(width: width.doubleValue, height: height.doubleValue))
            let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
            guard let output = CIImage(data: data, options: options) else { throw PhotoAnalysisError.decode }
            // ImageIO also understands HEIF NCLX/CICP and format-specific color tags.
            // An absent ICC profile name must not overwrite an existing P3/Rec.2020 interpretation.
            if output.colorSpace == nil {
                guard let assumed = CIImage(data: data, options: [.applyOrientationProperty: true, .colorSpace: srgb])
                else { throw PhotoAnalysisError.decode }
                decoded = assumed
                diagnostics.append(.init(zhHans: "未发现嵌入的颜色配置，按 sRGB 解释。", en: "No embedded color profile was found; interpreted as sRGB."))
            } else {
                decoded = output
                if properties[kCGImagePropertyProfileName as String] == nil {
                    diagnostics.append(.init(zhHans: "颜色空间由 Apple 解码器解释（可包含格式颜色标签）；文件没有提供 ICC 配置名称。", en: "Color space is interpreted by Apple's decoder, including format color tags; the file provides no ICC profile name."))
                }
            }
            if let source, CGImageSourceGetCount(source) > 1 {
                diagnostics.append(.init(zhHans: "多帧文件仅分析第一帧。", en: "Only the first frame of this multi-frame file is analyzed."))
            }
        }
        try validateSize(decoded.extent.size)
        let oriented = decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.minX, y: -decoded.extent.minY))
        let width = Int(oriented.extent.width.rounded()), height = Int(oriented.extent.height.rounded())
        let thumbnail = resample(oriented, maximumSide: maximumPreviewSide)
        guard let preview = context.createCGImage(thumbnail, from: thumbnail.extent, format: .RGBA8, colorSpace: srgb) else {
            throw isRAW ? PhotoAnalysisError.unsupportedRAW : PhotoAnalysisError.decode
        }
        try Task.checkCancellation()
        diagnostics.append(.init(zhHans: "统计在 sRGB 浮点数据的 SDR 0–1 范围内进行；超出范围的值会截至端点，不据此判断 RAW 过曝。感知明度为 Lab L*（D65，0–100）；HSL 明度 L 单独保留，两者均非物理亮度。", en: "Statistics use floating-point sRGB in the SDR 0–1 range. Out-of-range values are clamped; endpoints do not establish RAW overexposure. Perceptual lightness is Lab L* (D65, 0–100); HSL lightness L is retained separately. Neither is physical luminance."))
        diagnostics.append(.init(zhHans: "有效像素等权统计；完全透明和非有限值不参与。HSL 饱和度低于 2% 归为中性色。", en: "Valid pixels have equal weight; fully transparent and non-finite samples are excluded. HSL saturation below 2% is classified as neutral."))
        var recordedCurves: [PhotoRecordedCurve] = []
        var curveWarning: Error?
        do { recordedCurves = try PhotoMetadataReader.recordedCurves(imageData: data, sourceName: url.lastPathComponent) }
        catch is CancellationError { throw CancellationError() }
        catch { curveWarning = error }
        try Task.checkCancellation()
        return PhotoDecodedImage(preview: preview, pixelWidth: width, pixelHeight: height,
                                 metadata: metadata(properties, width: width, height: height),
                                 diagnostics: diagnostics, image: oriented,
                                 recordedCurves: recordedCurves, curveWarning: curveWarning)
    }

    static func analyze(_ image: PhotoDecodedImage, region: PhotoRegion) throws -> PhotoStatistics {
        try Task.checkCancellation()
        let sourceRect = try sourceRect(for: image, region: region)
        let cropped = image.image.cropped(to: sourceRect).transformed(by:
            CGAffineTransform(translationX: -sourceRect.minX, y: -sourceRect.minY))
        let sample = resample(cropped, maximumSide: maximumSampleSide)
        let width = Int(sample.extent.width), height = Int(sample.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(sample, toBitmap: bytes.baseAddress!, rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: sample.extent, format: .RGBAf, colorSpace: srgb)
        }
        try Task.checkCancellation()
        var histograms = [Double](repeating: 0, count: 256 * 6 + 360)
        var count: Int32 = 0
        var neutral = 0.0
        let result = crossdiff_photo_histograms_v2(&pixels, Int32(width), Int32(height), &histograms, histograms.count, &count, &neutral)
        if result == 2 { throw PhotoAnalysisError.noPixels }
        guard result == 0 else { throw PhotoAnalysisError.statistics }
        try Task.checkCancellation()
        return PhotoStatistics(red: Array(histograms[0..<256]), green: Array(histograms[256..<512]),
            blue: Array(histograms[512..<768]), lightness: Array(histograms[768..<1024]),
            hue: Array(histograms[1280..<1640]), saturation: Array(histograms[1024..<1280]),
            neutralFraction: neutral, analyzedPixels: Int(count), sampleWidth: width, sampleHeight: height,
            sampled: width < Int(sourceRect.width) || height < Int(sourceRect.height), analysisSpace: analysisSpace,
            perceptualLightness: Array(histograms[1640..<1896]))
    }

    /// Channel and brush affect this bounded display only, never the ROI or statistics.
    static func preview(_ image: PhotoDecodedImage, channel: PhotoPreviewChannel,
                        highlight: PhotoHistogramRange?, region: PhotoRegion) throws -> CGImage {
        try Task.checkCancellation()
        let selectedSource = try sourceRect(for: image, region: region)
        guard highlight?.isValid != false else { throw PhotoAnalysisError.invalidRange }
        if channel == .original && highlight == nil { return image.preview }
        let sample = resample(image.image, maximumSide: maximumPreviewSide)
        let width = Int(sample.extent.width), height = Int(sample.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(sample, toBitmap: bytes.baseAddress!, rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: sample.extent, format: .RGBAf, colorSpace: srgb)
        }
        try Task.checkCancellation()
        let horizontalScale = Double(width) / Double(image.pixelWidth)
        let verticalScale = Double(height) / Double(image.pixelHeight)
        // CIContext bitmap rows and CGImage provider rows start at the visual top.
        let roi = CGRect(x: selectedSource.minX * horizontalScale,
                         y: (Double(image.pixelHeight) - selectedSource.maxY) * verticalScale,
                         width: selectedSource.width * horizontalScale, height: selectedSource.height * verticalScale)
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let displayChannel: Int32
        switch channel {
        case .original: displayChannel = 0
        case .red: displayChannel = 1
        case .green: displayChannel = 2
        case .blue: displayChannel = 3
        }
        let brushChannel: Int32
        switch highlight?.channel {
        case .perceptualLightness: brushChannel = 0
        case .red: brushChannel = 1
        case .green: brushChannel = 2
        case .blue: brushChannel = 3
        default: brushChannel = -1
        }
        var output = Data(count: width * height * 4)
        try pixels.withUnsafeBufferPointer { source in
            try output.withUnsafeMutableBytes { bytes in
                for row in stride(from: 0, to: height, by: 64) {
                    try Task.checkCancellation()
                    let rows = min(64, height - row)
                    let block = CGRect(x: 0, y: row, width: width, height: rows)
                    let intersection = roi.intersection(block)
                    let selected = intersection.isNull ? CGRect.zero : intersection.offsetBy(dx: 0, dy: -Double(row))
                    let result = crossdiff_photo_preview(source.baseAddress! + row * width * 4,
                        Int32(width), Int32(rows), displayChannel, brushChannel,
                        Int32(highlight?.lowerBin ?? 0), Int32(highlight?.upperBin ?? 255),
                        Int32(selected.minX), Int32(selected.minY), Int32(selected.width), Int32(selected.height),
                        bytes.baseAddress!.assumingMemoryBound(to: UInt8.self) + row * width * 4, rows * width * 4)
                    guard result == 0 else { throw PhotoAnalysisError.statistics }
                }
            }
        }
        try Task.checkCancellation()
        // Preserve unpremultiplied channel values and alpha without a second color conversion.
        guard let provider = CGDataProvider(data: output as CFData),
              let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: srgb,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                  decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw PhotoAnalysisError.decode }
        try Task.checkCancellation()
        return result
    }

    private static func sourceRect(for image: PhotoDecodedImage, region: PhotoRegion) throws -> CGRect {
        guard region.isValid else { throw PhotoAnalysisError.invalidRegion }
        let full = CGRect(x: 0, y: 0, width: image.pixelWidth, height: image.pixelHeight)
        // User regions have a top-left origin; Core Image uses bottom-left.
        let rect = CGRect(x: Double(image.pixelWidth) * region.x,
            y: Double(image.pixelHeight) * (1 - region.y - region.height),
            width: Double(image.pixelWidth) * region.width,
            height: Double(image.pixelHeight) * region.height).integral.intersection(full)
        guard !rect.isEmpty else { throw PhotoAnalysisError.invalidRegion }
        return rect
    }

    private static func validateSize(_ size: CGSize) throws {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= 100_000, size.height <= 100_000, size.width * size.height <= Double(maximumPixels)
        else { throw PhotoAnalysisError.pixelBudget }
    }

    private static func resample(_ image: CIImage, maximumSide: Int) -> CIImage {
        let ratio = min(1, CGFloat(maximumSide) / max(image.extent.width, image.extent.height))
        guard ratio < 1 else { return image }
        let output = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: ratio, kCIInputAspectRatioKey: 1])
        return output.cropped(to: CGRect(x: 0, y: 0,
            width: max(1, floor(image.extent.width * ratio)), height: max(1, floor(image.extent.height * ratio))))
    }

    private static func metadata(_ properties: [String: Any], width: Int, height: Int) -> [PhotoMetadataItem] {
        var items = [PhotoMetadataItem(id: "dimensions", label: .init(zhHans: "像素尺寸", en: "Pixel dimensions"), value: "\(width) × \(height)")]
        func add(_ id: String, _ zh: String, _ en: String, _ value: Any?) {
            guard let value else { return }
            let string = String(describing: value)
            guard !string.isEmpty else { return }
            items.append(.init(id: id, label: .init(zhHans: zh, en: en), value: String(string.prefix(512))))
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        add("cameraMake", "厂商", "Manufacturer", tiff[kCGImagePropertyTIFFMake as String])
        add("camera", "相机", "Camera", tiff[kCGImagePropertyTIFFModel as String])
        add("lens", "镜头", "Lens", exif[kCGImagePropertyExifLensModel as String])
        if let exposure = exif[kCGImagePropertyExifExposureTime as String] as? NSNumber {
            let seconds = exposure.doubleValue
            let value = seconds > 0 && seconds < 1 ? String(format: "1/%.4g s", 1 / seconds) : String(format: "%.4g s", seconds)
            add("shutter", "快门", "Shutter", value)
        }
        if let aperture = exif[kCGImagePropertyExifFNumber as String] as? NSNumber { add("aperture", "光圈", "Aperture", "ƒ/\(aperture)") }
        if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber] { add("iso", "ISO", "ISO", iso.map(\.stringValue).joined(separator: ", ")) }
        if let focal = exif[kCGImagePropertyExifFocalLength as String] as? NSNumber { add("focalLength", "焦距", "Focal length", "\(focal) mm") }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue as String] as? NSNumber, bias.doubleValue.isFinite {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.maximumFractionDigits = 2
            formatter.positivePrefix = "+"
            formatter.negativePrefix = "-"
            if let value = formatter.string(from: bias) { add("exposureBias", "曝光补偿", "Exposure bias", "\(value) EV") }
        }
        if let balance = exif[kCGImagePropertyExifWhiteBalance as String] as? NSNumber {
            add("whiteBalance", "白平衡模式（0 自动 / 1 手动）", "White balance (0 auto / 1 manual)", balance.stringValue)
        }
        add("profile", "颜色配置", "Color profile", properties[kCGImagePropertyProfileName as String])
        add("depth", "源文件位深", "Source bit depth", properties[kCGImagePropertyDepth as String])
        return items
    }
}
