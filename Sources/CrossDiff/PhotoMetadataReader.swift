import Foundation
import ImageIO
import Darwin
import CrossDiffCore

enum PhotoMetadataFailure: Error, LocalizedError {
    case invalidFile, invalidXMP, invalidCurve(String)
    var errorDescription: String? {
        switch self {
        case .invalidFile: return L("无法读取曲线来源；请选择普通图片或 XMP 文件。", "Unable to read curve metadata; choose a regular image or XMP file.")
        case .invalidXMP: return L("XMP 文件无效或超出 8 MB 限制。", "The XMP file is invalid or exceeds the 8 MB limit.")
        case .invalidCurve(let name): return L("文件记录的曲线无效：\(name)。", "Invalid recorded curve: \(name).")
        }
    }
}

/// ImageIO parses the metadata. Only recorded Adobe CRS control points are displayed;
/// these are not inferred curves and no Adobe rendering interpolation is reproduced.
enum PhotoMetadataReader {
    static let maximumXMPBytes = 8 * 1024 * 1024

    /// Uses the same immutable bytes as image decoding, never a second read of its path.
    static func recordedCurves(imageData: Data, sourceName: String) throws -> [PhotoRecordedCurve] {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(imageData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { throw PhotoMetadataFailure.invalidFile }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        try Task.checkCancellation()
        return try curves(metadata, sourceName: sourceName)
    }

    static func recordedCurves(xmpURL: URL) throws -> [PhotoRecordedCurve] {
        try Task.checkCancellation()
        guard xmpURL.isFileURL, xmpURL.pathExtension.lowercased() == "xmp" else { throw PhotoMetadataFailure.invalidFile }
        let data = try readXMP(xmpURL)
        guard let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY"),
              let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { throw PhotoMetadataFailure.invalidXMP }
        try Task.checkCancellation()
        return try curves(metadata, sourceName: xmpURL.lastPathComponent)
    }

    private static func readXMP(_ url: URL) throws -> Data {
        // Validate the held descriptor, not a path that can be replaced between calls.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw PhotoMetadataFailure.invalidFile }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw PhotoMetadataFailure.invalidFile
        }
        guard info.st_size >= 0, info.st_size <= maximumXMPBytes else { throw PhotoMetadataFailure.invalidXMP }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let remaining = maximumXMPBytes + 1 - data.count
            let count = read(descriptor, &buffer, min(buffer.count, remaining))
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumXMPBytes else { throw PhotoMetadataFailure.invalidXMP }
        }
    }

    private static func curves(_ metadata: CGImageMetadata?, sourceName: String) throws -> [PhotoRecordedCurve] {
        try Task.checkCancellation()
        guard let metadata else { return [] }
        let namespace = "http://ns.adobe.com/camera-raw-settings/1.0/"
        let names = ["ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue",
                     "ToneCurve", "ToneCurveRed", "ToneCurveGreen", "ToneCurveBlue"]
        var fields: [String: Any] = [:]
        // Match namespace URI, not the file's freely chosen namespace prefix.
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            if Task.isCancelled { return false }
            guard let space = CGImageMetadataTagCopyNamespace(tag), space as String == namespace,
                  let name = CGImageMetadataTagCopyName(tag) as String?,
                  names.contains(name) || name == "ProcessVersion" || name == "ToneCurveName2012" else { return true }
            if let value = CGImageMetadataTagCopyValue(tag) { fields[name] = value }
            return true
        }
        try Task.checkCancellation()
        let version = (fields["ProcessVersion"] as? String).flatMap { $0.utf8.count <= 128 ? $0 : nil }
        let source = sourceName + (version.map { " · ProcessVersion=\($0)" } ?? "")
        var curves: [PhotoRecordedCurve] = []
        for (channel, suffix) in [("RGB", ""), ("Red", "Red"), ("Green", "Green"), ("Blue", "Blue")] {
            let modern = "ToneCurvePV2012" + suffix, legacy = "ToneCurve" + suffix
            let key = fields[modern] != nil ? modern : legacy
            guard let value = fields[key] else { continue }
            guard let items = value as? [Any], (2...256).contains(items.count) else {
                throw PhotoMetadataFailure.invalidCurve(key)
            }
            var points: [PhotoCurvePoint] = []
            for item in items {
                try Task.checkCancellation()
                let text: String?
                if let string = item as? String { text = string }
                else if CFGetTypeID(item as CFTypeRef) == CGImageMetadataTagGetTypeID() {
                    text = CGImageMetadataTagCopyValue(item as! CGImageMetadataTag) as? String
                } else { text = nil }
                guard let value = text else { throw PhotoMetadataFailure.invalidCurve(key) }
                let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let x = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                      let y = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                      x.isFinite, y.isFinite, (0...255).contains(x), (0...255).contains(y),
                      points.last.map({ x / 255 > $0.x }) ?? true else { throw PhotoMetadataFailure.invalidCurve(key) }
                points.append(PhotoCurvePoint(x: x / 255, y: y / 255))
            }
            curves.append(PhotoRecordedCurve(id: key, name: channel, points: points, source: source))
        }
        return curves
    }
}
