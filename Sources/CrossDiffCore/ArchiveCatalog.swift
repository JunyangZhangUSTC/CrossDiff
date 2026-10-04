import Foundation
import Darwin

public enum ArchiveSourceKind: String, Codable, Sendable { case archive, folder }
public enum ArchiveEntryKind: String, Codable, Sendable { case file, directory, symbolicLink, hardLink, other }
public enum ArchiveEntryIssue: String, Codable, Sendable {
    case symbolicLink, hardLink, specialFile
    public var localizedDescription: String {
        switch self {
        case .symbolicLink: return L("未跟随符号链接，内容未验证。", "Symbolic links are not followed; content is unverified.")
        case .hardLink: return L("未读取硬链接目标，内容未验证。", "Hard-link targets are not read; content is unverified.")
        case .specialFile: return L("不支持此类特殊文件，内容未验证。", "This special file type is unsupported; content is unverified.")
        }
    }
}
public struct ArchiveEntry: Sendable, Equatable, Codable {
    public let path: String
    public let kind: ArchiveEntryKind
    public let size: Int64?
    public let sha256: String?
    public let issue: ArchiveEntryIssue?
    public init(path: String, kind: ArchiveEntryKind, size: Int64?, sha256: String?, issue: ArchiveEntryIssue? = nil) {
        self.path = path; self.kind = kind; self.size = size; self.sha256 = sha256; self.issue = issue
    }
    public var isContentVerified: Bool { issue == nil && (kind == .directory || (kind == .file && sha256 != nil)) }
}
public struct ArchiveSnapshot: Sendable {
    public let sourceURL: URL
    public let sourceKind: ArchiveSourceKind
    public let entries: [ArchiveEntry]
    public let totalExpandedBytes: Int64
    public var isComplete: Bool { entries.allSatisfy(\.isContentVerified) }
    let stamps: [ArchiveSourceStamp]
    public func verifyUnchanged() throws {
        for stamp in stamps { try Task.checkCancellation(); try stamp.verify() }
    }
}
public enum ArchiveCatalog {
    public static let maximumEntries = 10_000
    public static let maximumExpandedBytes: Int64 = 512 * 1024 * 1024
    public static let maximumFileBytes: Int64 = 256 * 1024 * 1024
    public static let maximumSourceBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let maximumPathBytes = 4096

    public static func snapshot(url: URL, nativeReaderURL: URL? = nil, progress: @Sendable (Double) -> Void = { _ in }) throws -> ArchiveSnapshot {
        try Task.checkCancellation()
        guard url.isFileURL else { throw ArchiveError.unreadable(url.lastPathComponent) }
        let url = url.standardizedFileURL
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ArchiveError.unreadable(url.lastPathComponent) }
        let builder = ArchiveBuilder()
        progress(0)
        if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            try ArchiveFolderReader.read(url, builder: builder)
            let result = try builder.finish(url: url, kind: .folder)
            progress(1); try Task.checkCancellation(); return result
        }
        let input = try ArchiveInput(url: url)
        guard input.size <= maximumSourceBytes else { throw ArchiveError.limit }
        builder.stamps.append(input.stamp)
        if url.lastPathComponent.lowercased().range(of: #"\.7z\.[0-9]{3,}$"#, options: .regularExpression) != nil {
            throw ArchiveError.multiVolume
        }
        let signature = try input.read(offset: 0, count: 8)
        if ArchiveNativeFormat.identify(signature) != nil {
            let result = try ArchiveReaderProcess.read(input, executable: nativeReaderURL)
            progress(1); try Task.checkCancellation(); return result
        }
        if url.pathExtension.lowercased() == "7z" || url.pathExtension.lowercased() == "rar" {
            throw ArchiveError.unsupported
        }
        if signature.starts(with: [0x1f, 0x8b]) { try ArchiveGZIP.validate(input) }
        if signature.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]) { try ArchiveXZ.validate(input) }
        if signature.starts(with: [0x50, 0x4b]) {
            try ArchiveZIPReader.read(input, builder: builder)
        } else {
            try ArchiveTARReader.read(input, builder: builder)
        }
        let result = try builder.finish(url: url, kind: .archive)
        progress(1); try Task.checkCancellation(); return result
    }
}
public enum ArchiveError: Error, LocalizedError, Sendable, Codable {
    case unavailable, unsupported, unreadable(String), changed(String), invalidPath, duplicatePath(String), damaged, encrypted, limit
    case multiVolume, readerUnavailable, readerFailed, timeout
    case unsupported7z, unsupportedRAR
    public var errorDescription: String? {
        switch self {
        case .unavailable: return L("系统归档读取库不可用。", "The system archive reader is unavailable.")
        case .unsupported: return L("不支持此归档格式或编码。", "This archive format or encoding is unsupported.")
        case .unreadable(let path): return L("无法完整读取：\(path)", "Unable to read completely: \(path)")
        case .changed(let path): return L("读取期间来源已改变，请重新比较：\(path)", "The source changed while reading. Compare again: \(path)")
        case .invalidPath: return L("归档包含不安全或无效的路径。", "The archive contains an unsafe or invalid path.")
        case .duplicatePath(let path): return L("归档路径重复或冲突：\(path)", "The archive path is duplicated or conflicting: \(path)")
        case .damaged: return L("归档损坏或不完整，未发布比较结果。", "The archive is damaged or incomplete. No comparison result was published.")
        case .encrypted: return L("当前预览不读取加密归档。", "This preview does not read encrypted archives.")
        case .limit: return L("归档或文件夹超出读取限制，未发布部分结果。", "The archive or folder exceeds reading limits. No partial result was published.")
        case .multiVolume: return L("暂不支持分卷归档，请选择完整的单卷压缩包。", "Multi-volume archives are not supported. Choose a complete single-volume archive.")
        case .readerUnavailable: return L("7z／RAR 读取组件不可用，请使用完整构建的应用。", "The 7z/RAR reader is unavailable. Use a complete application build.")
        case .readerFailed: return L("归档读取进程未能完成校验，未发布比较结果。", "The archive reader could not finish validation. No comparison result was published.")
        case .timeout: return L("归档读取超过时间限制，未发布部分结果。", "Archive reading exceeded the time limit. No partial result was published.")
        case .unsupported7z: return L("此 7z 使用了暂不支持的压缩方法或扩展。当前支持 Copy、LZMA、LZMA2 及常见 BCJ／Delta 过滤器。", "This 7z uses an unsupported method or extension. Copy, LZMA, LZMA2 and common BCJ/Delta filters are supported.")
        case .unsupportedRAR: return L("此 RAR 使用了暂不支持的特性。当前支持非固实 RAR4 和算法 v0 的 RAR5；注释、恢复记录等扩展尚不支持。", "This RAR uses an unsupported feature. Non-solid RAR4 and algorithm-v0 RAR5 are supported; extensions such as comments and recovery records are not yet supported.")
        }
    }
}
