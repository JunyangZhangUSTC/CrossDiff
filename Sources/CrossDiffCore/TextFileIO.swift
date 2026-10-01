import Foundation
import CryptoKit

public enum TextFileEncoding: String, Codable, Sendable {
    case utf8, utf8BOM, utf16LE, utf16BE

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        }
    }
}

public struct LoadedTextFile: Sendable {
    public let text: String
    public let encoding: TextFileEncoding
    public let signature: String
}

public enum TextFileError: LocalizedError {
    case unsupportedEncoding, tooLarge, changedOnDisk
    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: return L("无法作为文本打开。当前支持 UTF-8 和带 BOM 的 UTF-16；二进制文件不能用文本模式比较。", "This file cannot be opened as text. UTF-8 and UTF-16 with a BOM are supported; binary files cannot be compared in text mode.")
        case .tooLarge: return L("当前预览版支持最多 20 MB 的文本文件。文件未被修改。", "This preview supports text files up to 20 MB. The file has not been modified.")
        case .changedOnDisk: return L("文件已被其他应用修改或移走。为保留外部改动，请重新打开文件，或将当前内容另存为新文件。", "The file was changed or moved by another app. Reopen it to keep the external changes, or save your current text as a new file.")
        }
    }
}

public enum TextFileIO {
    public static let maximumBytes = 20 * 1024 * 1024
    public static func read(_ url: URL) throws -> LoadedTextFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw TextFileError.unsupportedEncoding }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw TextFileError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw TextFileError.tooLarge }
        let encoding: TextFileEncoding
        let payload: Data
        let stringEncoding: String.Encoding
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8BOM; payload = data.dropFirst(3); stringEncoding = .utf8
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LE; payload = data.dropFirst(2); stringEncoding = .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BE; payload = data.dropFirst(2); stringEncoding = .utf16BigEndian
        } else {
            encoding = .utf8; payload = data; stringEncoding = .utf8
            guard !data.contains(0) else { throw TextFileError.unsupportedEncoding }
        }
        guard let text = String(data: payload, encoding: stringEncoding) else { throw TextFileError.unsupportedEncoding }
        return LoadedTextFile(text: text, encoding: encoding, signature: signature(data))
    }

    public static func encoded(_ text: String, encoding: TextFileEncoding) throws -> Data {
        let format: String.Encoding = encoding == .utf16LE ? .utf16LittleEndian : encoding == .utf16BE ? .utf16BigEndian : .utf8
        guard let payload = text.data(using: format, allowLossyConversion: false) else { throw TextFileError.unsupportedEncoding }
        let prefix: [UInt8]
        switch encoding {
        case .utf8: prefix = []
        case .utf8BOM: prefix = [0xEF, 0xBB, 0xBF]
        case .utf16LE: prefix = [0xFF, 0xFE]
        case .utf16BE: prefix = [0xFE, 0xFF]
        }
        return Data(prefix) + payload
    }

    @discardableResult
    public static func write(_ text: String, to url: URL, encoding: TextFileEncoding, expectedSignature: String?) throws -> String {
        if let expectedSignature {
            guard let current = try? Data(contentsOf: url), signature(current) == expectedSignature else { throw TextFileError.changedOnDisk }
        } else if FileManager.default.fileExists(atPath: url.path) {
            throw TextFileError.changedOnDisk
        }
        let data = try encoded(text, encoding: encoding)
        try data.write(to: url, options: .atomic)
        return signature(data)
    }

    public static func signature(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct StoredTextSide: Codable, Sendable {
    public var text: String
    public var path: String?
    public var encoding: TextFileEncoding
    public var signature: String?
    public var savedText: String
    public init(text: String = "", path: String? = nil, encoding: TextFileEncoding = .utf8, signature: String? = nil, savedText: String = "") {
        self.text = text; self.path = path; self.encoding = encoding; self.signature = signature; self.savedText = savedText
    }
}

public struct StoredComparison: Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: String
    public var pluginID: String?
    public var photoState: PhotoWorkspaceState?
    public var apiState: APIWorkspaceState?
    public var left: StoredTextSide
    public var right: StoredTextSide
    public init(id: UUID = UUID(), kind: String, left: StoredTextSide, right: StoredTextSide, pluginID: String? = nil, photoState: PhotoWorkspaceState? = nil, apiState: APIWorkspaceState? = nil) {
        self.id = id; self.kind = kind; self.left = left; self.right = right; self.pluginID = pluginID
        self.photoState = photoState
        self.apiState = apiState
    }
}

public enum SessionFile {
    public static func load(from url: URL) throws -> [StoredComparison] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([StoredComparison].self, from: Data(contentsOf: url))
    }
    public static func save(_ sessions: [StoredComparison], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(sessions).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func clear(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
