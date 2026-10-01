import Foundation
import Darwin

public enum BinaryFileError: Error, LocalizedError, Sendable {
    case unreadable(String)
    case notRegularFile(String)
    case invalidRange
    case readTooLarge
    case changed(String)
    case comparisonTooLarge

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): return L("无法读取二进制文件：\(name)", "Unable to read binary file: \(name)")
        case .notRegularFile(let name): return L("二进制比较只支持普通文件：\(name)", "Binary comparison requires a regular file: \(name)")
        case .invalidRange: return L("二进制读取范围无效。", "The binary read range is invalid.")
        case .readTooLarge: return L("单次二进制读取不能超过 1 MiB。", "A binary read cannot exceed 1 MiB.")
        case .changed(let name): return L("比较期间文件已改变，请重新读取：\(name)", "The file changed during comparison. Reload it: \(name)")
        case .comparisonTooLarge: return L("当前二进制比较每侧最多支持 8 GiB。", "Binary comparison currently supports up to 8 GiB per side.")
        }
    }
}

/// An open regular-file descriptor, not an immutable content snapshot. Metadata
/// and path identity detect ordinary replacement/mutation; a hostile filesystem
/// that hides those changes cannot be made snapshot-consistent by these checks.
/// All descriptor access uses pread, so independent range reads may run concurrently.
public final class BinaryFileSource: @unchecked Sendable {
    public static let maximumReadBytes = 1024 * 1024
    public let url: URL
    public let size: Int64
    private let descriptor: Int32
    private let original: stat

    public init(url: URL) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { throw BinaryFileError.unreadable(url.lastPathComponent) }
        let path = url.standardizedFileURL
        let handle = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard handle >= 0 else { throw BinaryFileError.unreadable(path.lastPathComponent) }
        var metadata = stat()
        guard fstat(handle, &metadata) == 0 else { close(handle); throw BinaryFileError.unreadable(path.lastPathComponent) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_size >= 0 else {
            close(handle); throw BinaryFileError.notRegularFile(path.lastPathComponent)
        }
        self.url = path; self.size = Int64(metadata.st_size)
        self.descriptor = handle; self.original = metadata
        try verifyUnchanged()
    }

    deinit { close(descriptor) }

    /// Reads at most count bytes, returning a shorter range only at the captured EOF.
    public func read(offset: Int64, count: Int) throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, offset <= size, count >= 0 else { throw BinaryFileError.invalidRange }
        guard count <= Self.maximumReadBytes else { throw BinaryFileError.readTooLarge }
        try verifyUnchanged()
        let length = min(count, Int(min(Int64(count), size - offset)))
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { storage in
            var consumed = 0
            while consumed < length {
                try Task.checkCancellation()
                let amount = pread(descriptor, storage.baseAddress!.advanced(by: consumed), length - consumed, off_t(offset + Int64(consumed)))
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw BinaryFileError.unreadable(url.lastPathComponent)
                }
                guard amount > 0 else { throw BinaryFileError.changed(url.lastPathComponent) }
                consumed += amount
            }
        }
        try verifyUnchanged()
        return data
    }

    public func verifyUnchanged() throws {
        try Task.checkCancellation()
        var current = stat(), path = stat()
        guard fstat(descriptor, &current) == 0, lstat(url.path, &path) == 0,
              sameIdentity(current), sameIdentity(path) else { throw BinaryFileError.changed(url.lastPathComponent) }
    }

    private func sameIdentity(_ value: stat) -> Bool {
        value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && value.st_dev == original.st_dev &&
        value.st_ino == original.st_ino && value.st_size == original.st_size &&
        value.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec && value.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec &&
        value.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec && value.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec
    }
}
