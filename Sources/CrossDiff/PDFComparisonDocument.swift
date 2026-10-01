import Foundation
import PDFKit
import CryptoKit
import CrossDiffCore

struct PDFPageDescriptor: Sendable {
    let index: Int
    let text: String
    let width: Double
    let height: Double
    let fingerprint: String
    let textTruncated: Bool

    var pluginValue: PluginJSONValue {
        .object(["index": .number(Double(index)), "text": .string(text),
                 "width": .number(width), "height": .number(height),
                 "fingerprint": .string(fingerprint), "textTruncated": .bool(textTruncated)])
    }
}

/// PDFKit is used by one worker during extraction, then exclusively by the main
/// thread for presentation. Data owns the immutable source snapshot throughout.
struct PDFComparisonDocument: @unchecked Sendable {
    let data: Data
    let document: PDFDocument
    let pages: [PDFPageDescriptor]
    let totalPageCount: Int
    let truncated: Bool

    var pluginContent: PluginJSONValue {
        .object(["pages": .array(pages.map(\.pluginValue)), "truncated": .bool(truncated)])
    }
}

enum PDFComparisonDecoder {
    static let maximumBytes = 48 * 1024 * 1024
    static let maximumPages = 200
    static let maximumPageText = 32_768
    static let maximumDocumentText = 262_144
    static let fingerprintEdge = 384

    static func load(_ url: URL) throws -> PDFComparisonDocument {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw PDFComparisonFailure.unreadable(url.lastPathComponent) }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw PDFComparisonFailure.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw PDFComparisonFailure.tooLarge }
        try Task.checkCancellation()
        guard let document = PDFDocument(data: data) else { throw PDFComparisonFailure.unreadable(url.lastPathComponent) }
        guard !document.isLocked else { throw PDFComparisonFailure.locked(url.lastPathComponent) }
        guard document.pageCount > 0 else { throw PDFComparisonFailure.noPages }
        // Honor copy restrictions instead of bypassing them via extracted text.
        let canExtractText = document.allowsCopying
        var remaining = maximumDocumentText
        var descriptors: [PDFPageDescriptor] = []
        var truncated = document.pageCount > maximumPages || !canExtractText
        for index in 0..<min(document.pageCount, maximumPages) {
            try Task.checkCancellation()
            let descriptor = try autoreleasepool { () throws -> PDFPageDescriptor in
                guard let page = document.page(at: index) else { throw PDFComparisonFailure.unreadable(url.lastPathComponent) }
                let bounds = page.bounds(for: .cropBox)
                let rotated = abs(page.rotation % 180) == 90
                let width = rotated ? bounds.height : bounds.width
                let height = rotated ? bounds.width : bounds.height
                guard width.isFinite, height.isFinite, width > 0, height > 0,
                      width < 1_000_000, height < 1_000_000 else { throw PDFComparisonFailure.invalidPage }
                let extracted = canExtractText ? page.string ?? "" : ""
                let budget = min(maximumPageText, remaining)
                let prefix = Array(extracted.utf16.prefix(budget))
                let limited = prefix.count < extracted.utf16.count
                // A truncated representation is expressly partial, never saved.
                let text = String(decoding: prefix, as: UTF16.self)
                remaining -= prefix.count
                return PDFPageDescriptor(index: index, text: text, width: Double(width), height: Double(height),
                                         fingerprint: try fingerprint(page: page, width: width, height: height),
                                         textTruncated: limited || !canExtractText)
            }
            truncated = truncated || descriptor.textTruncated
            descriptors.append(descriptor)
        }
        try Task.checkCancellation()
        return PDFComparisonDocument(data: data, document: document, pages: descriptors,
                                     totalPageCount: document.pageCount, truncated: truncated)
    }

    private static func fingerprint(page: PDFPage, width: CGFloat, height: CGFloat) throws -> String {
        let scale = CGFloat(fingerprintEdge) / max(width, height)
        let pixelWidth = max(1, Int(ceil(width * scale)))
        let pixelHeight = max(1, Int(ceil(height * scale)))
        var bytes = [UInt8](repeating: 255, count: pixelWidth * pixelHeight * 4)
        try bytes.withUnsafeMutableBytes { storage in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: storage.baseAddress, width: pixelWidth, height: pixelHeight,
                                          bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw PDFComparisonFailure.invalidPage
            }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
        }
        try Task.checkCancellation()
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}

enum PDFComparisonFailure: LocalizedError {
    case unreadable(String), locked(String), tooLarge, noPages, invalidPage, invalidResult
    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return L("无法读取“\(name)”的 PDF 内容。文件可能已损坏或不是 PDF。", "Unable to read the PDF contents of “\(name)”. The file may be damaged or not a PDF.")
        case .locked(let name):
            return L("“\(name)”受密码保护。当前版本不支持输入密码；请先在其他工具中解锁并另存副本。", "“\(name)” is password protected. Password entry is not supported yet; unlock it in another tool and save a separate copy first.")
        case .tooLarge:
            return L("单个 PDF 超过 48 MB 读取上限。请先提取需要比较的页面。", "The PDF exceeds the 48 MB reading limit. Extract the pages you need to compare first.")
        case .noPages:
            return L("PDF 中没有可读取的页面。", "The PDF contains no readable pages.")
        case .invalidPage:
            return L("无法绘制 PDF 页面预览，页面尺寸可能无效。", "Unable to render a PDF page preview; its dimensions may be invalid.")
        case .invalidResult:
            return L("PDF 插件返回了无效的页面对应关系，无法安全显示结果。", "The PDF plugin returned invalid page mappings, so its result cannot be displayed safely.")
        }
    }
}
