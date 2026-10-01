import AppKit
import ImageIO
import SwiftUI
import CrossDiffCore

/// Compares immutable, bounded previews. Opening or changing modes never writes to either file.
@MainActor
struct ImageComparisonView: View {
    let left: URL
    let right: URL

    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var model = ImageComparisonModel()
    @State private var mode = ImageComparisonMode.sideBySide
    @State private var zoom = ImageComparisonZoom.fit
    @State private var opacity = 0.5
    @State private var wipePosition = 0.5

    init(left: URL, right: URL) {
        self.left = left
        self.right = right
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let preview = model.preview {
                fileInformation(preview)
                Divider()
                comparison(preview)
                Divider()
                previewInformation(preview)
            } else if let error = model.error {
                ContentUnavailableView {
                    Label(L("无法打开图片", "Unable to Open Images"), systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(localizedErrorDescription(error))
                } actions: {
                    Button(L("重试", "Try Again")) {
                        Task { await model.load(left: left, right: right) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L("正在读取图片并计算差异…", "Loading images and calculating differences…"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: [left, right]) {
            await model.load(left: left, right: right)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                Picker(L("比较方式", "Comparison Mode"), selection: $mode) {
                    ForEach(ImageComparisonMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .id(settings.language)
                .frame(maxWidth: 420)
                Spacer(minLength: 8)
                Picker(L("缩放", "Zoom"), selection: $zoom) {
                    ForEach(ImageComparisonZoom.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .frame(width: 180)
                .id(settings.language)
                .help(L("百分比相对于解码后的预览像素；缩小预览不会加载完整原图。", "Zoom percentages refer to decoded preview pixels. Enlarging a downsampled preview does not load the full-resolution image."))
            }
            if mode == .overlay || mode == .wipe {
                HStack(spacing: 12) {
                    Text(mode == .overlay ? L("右图透明度", "Right Image Opacity") : L("分界位置", "Divider Position"))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 84, alignment: .leading)
                    if mode == .overlay {
                        Slider(value: $opacity, in: 0...1)
                            .accessibilityLabel(L("右图透明度", "Right Image Opacity"))
                        Text(opacity, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().frame(width: 42)
                    } else {
                        Slider(value: $wipePosition, in: 0...1)
                            .accessibilityLabel(L("左右图片分界位置", "Image Divider Position"))
                        Text(wipePosition, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().frame(width: 42)
                    }
                }
                .frame(maxWidth: 450)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .disabled(model.preview == nil)
    }

    private func fileInformation(_ preview: ImageComparisonPreview) -> some View {
        HStack(spacing: 16) {
            fileLabel(L("左侧", "Left"), url: left, image: preview.left)
            Divider().frame(height: 34)
            fileLabel(L("右侧", "Right"), url: right, image: preview.right)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func fileLabel(_ side: String, url: URL, image: ImageComparisonAsset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(side).font(.caption).foregroundStyle(.secondary)
                Text(url.lastPathComponent).fontWeight(.medium).lineLimit(1)
            }
            Text(L("\(image.originalWidth) × \(image.originalHeight) 像素", "\(image.originalWidth) × \(image.originalHeight) pixels"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(url.path)
    }

    private func comparison(_ preview: ImageComparisonPreview) -> some View {
        GeometryReader { geometry in
            let gap: CGFloat = mode == .sideBySide ? 20 : 0
            let columns: CGFloat = mode == .sideBySide ? 2 : 1
            let availableWidth = max(1, (geometry.size.width - 32 - gap) / columns)
            let availableHeight = max(1, geometry.size.height - 32)
            let fitScale = min(1, availableWidth / CGFloat(preview.width),
                               availableHeight / CGFloat(preview.height))
            let scale = zoom.scale ?? fitScale
            let size = CGSize(width: CGFloat(preview.width) * scale,
                              height: CGFloat(preview.height) * scale)

            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: gap) {
                    if mode == .sideBySide {
                        imageCanvas(preview.left.image, canvasSize: size, scale: scale)
                        imageCanvas(preview.right.image, canvasSize: size, scale: scale)
                    } else {
                        combinedCanvas(preview, size: size, scale: scale)
                    }
                }
                .padding(16)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private func imageCanvas(_ image: CGImage, canvasSize: CGSize, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ImageComparisonCheckerboard()
            renderedImage(image, scale: scale)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipped()
        .overlay(Rectangle().stroke(Color.primary.opacity(0.14), lineWidth: 1))
    }

    private func renderedImage(_ image: CGImage, scale: CGFloat) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(scale > 1 ? .none : .high)
            .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }

    private func combinedCanvas(_ preview: ImageComparisonPreview,
                                size: CGSize, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ImageComparisonCheckerboard()
            if mode == .difference {
                renderedImage(preview.difference, scale: scale)
            } else if mode == .overlay {
                renderedImage(preview.left.image, scale: scale)
                renderedImage(preview.right.image, scale: scale).opacity(opacity)
            } else {
                // Mask both sides, so transparent pixels on one side cannot reveal the other image.
                renderedImage(preview.left.image, scale: scale)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: size.width * wipePosition)
                    }
                renderedImage(preview.right.image, scale: scale)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: size.width * (1 - wipePosition))
                    }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: size.height)
                    .shadow(color: .black.opacity(0.65), radius: 2)
                    .offset(x: size.width * wipePosition - 1)
                Image(systemName: "arrow.left.and.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.7), in: Circle())
                    .offset(x: size.width * wipePosition - 15, y: max(0, size.height / 2 - 15))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay(Rectangle().stroke(Color.primary.opacity(0.14), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard mode == .wipe, size.width > 0 else { return }
            wipePosition = min(1, max(0, value.location.x / size.width))
        }, including: mode == .wipe ? .all : .none)
        .accessibilityLabel(mode == .wipe ? L("图片分界，可使用上方滑块调整", "Image divider. Use the slider above to adjust its position.") : mode.title)
    }

    private func previewInformation(_ preview: ImageComparisonPreview) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if preview.hasDifferentDimensions {
                Label(L("原图尺寸不同。保持相同比例，左上角对齐；空余区域透明，不拉伸。", "The original images have different dimensions. Both use the same scale and align at the top left. Extra space is transparent; neither image is stretched."),
                      systemImage: "rectangle.on.rectangle")
            }
            if preview.isDownsampled {
                Label(L("预览已缩小至最长边 1600 像素；缩放和差异统计均基于预览。", "Previews are reduced to at most 1,600 pixels on the longest edge. Zoom and difference counts refer to these previews."),
                      systemImage: "arrow.down.right.and.arrow.up.left")
            }
            if mode == .difference {
                Text(L("差异 \(preview.differentPixels.formatted()) / \((preview.width * preview.height).formatted()) 像素 · 亮色为 RGBA 或边界差异，深色为相同", "Different pixels: \(preview.differentPixels.formatted()) / \((preview.width * preview.height).formatted()) · Bright pixels show RGBA or boundary differences; dark pixels are identical."))
                Text(L("统一使用 8 位 sRGB 预览比较，包含透明度；不比较文件编码与元数据。", "Compares 8-bit sRGB previews, including transparency. File encoding and metadata are not compared."))
            }
            if preview.hasMultipleFrames {
                Text(L("动画或多帧图片仅比较第一帧。", "Only the first frame of animated or multi-frame images is compared."))
            }
            if !preview.isDownsampled && !preview.hasDifferentDimensions && mode != .difference {
                Text(L("透明区域显示为棋盘格 · 图片仅用于比较，原文件保持不变", "A checkerboard indicates transparency · Original image files are not modified"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

private enum ImageComparisonMode: String, CaseIterable, Identifiable {
    case sideBySide, overlay, wipe, difference
    var id: Self { self }
    var title: String {
        switch self {
        case .sideBySide: return L("并排", "Side by Side")
        case .overlay: return L("叠加", "Overlay")
        case .wipe: return L("滑动对比", "Wipe")
        case .difference: return L("像素差异", "Pixel Difference")
        }
    }
}

private enum ImageComparisonZoom: String, CaseIterable, Identifiable {
    case fit = "fit"
    case half = "50%"
    case actual = "100%"
    case double = "200%"
    case quadruple = "400%"
    var id: Self { self }
    var title: String { self == .fit ? L("适应窗口", "Fit to Window") : rawValue }
    var scale: CGFloat? {
        switch self {
        case .fit: return nil
        case .half: return 0.5
        case .actual: return 1
        case .double: return 2
        case .quadruple: return 4
        }
    }
}

private struct ImageComparisonCheckerboard: View {
    private static let tile = Image(size: CGSize(width: 24, height: 24), opaque: true) { context in
        context.fill(Path(CGRect(x: 0, y: 0, width: 24, height: 24)),
                     with: .color(Color(white: 0.91)))
        for rect in [CGRect(x: 0, y: 0, width: 12, height: 12),
                     CGRect(x: 12, y: 12, width: 12, height: 12)] {
            context.fill(Path(rect), with: .color(Color(white: 0.79)))
        }
    }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .tiledImage(Self.tile))
        }
        .accessibilityHidden(true)
    }
}

@MainActor
private final class ImageComparisonModel: ObservableObject {
    @Published private(set) var preview: ImageComparisonPreview?
    @Published private(set) var error: Error?
    private var requestID = UUID()

    func load(left: URL, right: URL) async {
        let request = UUID()
        requestID = request
        preview = nil
        error = nil
        let worker = Task.detached(priority: .userInitiated) {
            try ImageComparisonDecoder.load(left: left, right: right)
        }
        do {
            let value = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, requestID == request else { return }
            preview = value
        } catch is CancellationError {
            // A new pair or a closed tab makes this preview obsolete.
        } catch {
            guard !Task.isCancelled, requestID == request else { return }
            self.error = error
        }
    }
}

// The images are immutable and are only published after all background work has completed.
private struct ImageComparisonAsset: @unchecked Sendable {
    let image: CGImage
    let originalWidth: Int
    let originalHeight: Int
    let hasMultipleFrames: Bool
}

private struct ImageComparisonPreview: @unchecked Sendable {
    let left: ImageComparisonAsset
    let right: ImageComparisonAsset
    let difference: CGImage
    let differentPixels: Int
    var width: Int { max(left.image.width, right.image.width) }
    var height: Int { max(left.image.height, right.image.height) }
    var hasDifferentDimensions: Bool {
        left.originalWidth != right.originalWidth || left.originalHeight != right.originalHeight
    }
    var isDownsampled: Bool {
        left.image.width < left.originalWidth || left.image.height < left.originalHeight ||
        right.image.width < right.originalWidth || right.image.height < right.originalHeight
    }
    var hasMultipleFrames: Bool { left.hasMultipleFrames || right.hasMultipleFrames }
}

private enum ImageComparisonDecoder {
    private static let maximumEdge = 1600

    private struct Source {
        let url: URL
        let source: CGImageSource
        let width: Int
        let height: Int
    }

    static func load(left: URL, right: URL) throws -> ImageComparisonPreview {
        try Task.checkCancellation()
        let leftSource = try source(left)
        let rightSource = try source(right)
        let longestEdge = max(leftSource.width, leftSource.height, rightSource.width, rightSource.height)
        let scale = min(1, Double(maximumEdge) / Double(longestEdge))
        let leftImage = try thumbnail(leftSource, scale: scale)
        try Task.checkCancellation()
        let rightImage = try thumbnail(rightSource, scale: scale)
        try Task.checkCancellation()
        let difference = try pixelDifference(leftImage.image, rightImage.image)
        return ImageComparisonPreview(left: leftImage, right: rightImage,
                                      difference: difference.image, differentPixels: difference.count)
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

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        let rowBytes = image.width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * image.height)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes, space: space,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                            CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw ImageComparisonFailure.memory }
        return bytes
    }

    /// Coordinates are preview pixels, with a shared top-left origin. Extra bounds are differences,
    /// even when transparent. Premultiplied RGBA ignores hidden RGB in fully transparent pixels.
    static func pixelDifference(_ left: CGImage, _ right: CGImage) throws -> (image: CGImage, count: Int) {
        let width = max(left.width, right.width)
        let height = max(left.height, right.height)
        guard width > 0, height > 0, width <= maximumEdge, height <= maximumEdge else {
            throw ImageComparisonFailure.dimensions
        }
        let leftBytes = try rgba(left)
        let rightBytes = try rgba(right)
        var result = [UInt8](repeating: 255, count: width * height * 4)
        var count = 0
        for y in 0..<height {
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
            for x in 0..<width {
                let inLeft = x < left.width && y < left.height
                let inRight = x < right.width && y < right.height
                let leftOffset = (y * left.width + x) * 4
                let rightOffset = (y * right.width + x) * 4
                var delta = inLeft == inRight ? 0 : 64
                for channel in 0..<4 {
                    let a = inLeft ? Int(leftBytes[leftOffset + channel]) : 0
                    let b = inRight ? Int(rightBytes[rightOffset + channel]) : 0
                    delta = max(delta, abs(a - b))
                }
                let offset = (y * width + x) * 4
                if delta > 0 {
                    count += 1
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
        guard let provider = CGDataProvider(data: Data(result) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                                    CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw ImageComparisonFailure.difference
        }
        return (image, count)
    }
}

private enum ImageComparisonFailure: LocalizedError {
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
