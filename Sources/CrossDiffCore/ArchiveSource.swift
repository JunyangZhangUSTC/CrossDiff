import Foundation
import Darwin
import CryptoKit

struct ArchiveSourceStamp: @unchecked Sendable {
    let url: URL
    let info: stat
    func matches(_ value: stat) -> Bool {
        value.st_dev == info.st_dev && value.st_ino == info.st_ino && value.st_mode == info.st_mode &&
        value.st_size == info.st_size && value.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec &&
        value.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec && value.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec &&
        value.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec
    }
    func verify(descriptor: Int32? = nil) throws {
        try Task.checkCancellation()
        var current = stat()
        guard lstat(url.path, &current) == 0, matches(current) else { throw ArchiveError.changed(url.lastPathComponent) }
        if let descriptor {
            guard fstat(descriptor, &current) == 0, matches(current) else { throw ArchiveError.changed(url.lastPathComponent) }
        }
    }
}

final class ArchiveInput {
    let descriptor: Int32
    let stamp: ArchiveSourceStamp
    var size: Int64 { Int64(stamp.info.st_size) }
    init(url: URL, directory: Bool = false, parent: Int32? = nil, name: String? = nil) throws {
        try Task.checkCancellation()
        guard url.isFileURL else { throw ArchiveError.unreadable(url.lastPathComponent) }
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
        let fd = parent.map { openat($0, name!, flags) } ?? open(url.path, flags)
        guard fd >= 0 else { throw ArchiveError.unreadable(url.lastPathComponent) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG) else {
            close(fd); throw ArchiveError.unreadable(url.lastPathComponent)
        }
        descriptor = fd; stamp = ArchiveSourceStamp(url: url, info: info)
        try stamp.verify(descriptor: fd)
    }
    deinit { close(descriptor) }
    func read(offset: Int64, count: Int) throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, offset <= size, count >= 0, count <= 1024 * 1024 else { throw ArchiveError.damaged }
        let length = Int(min(Int64(count), size - offset))
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < length {
                try Task.checkCancellation()
                let read = pread(descriptor, buffer.baseAddress!.advanced(by: done), length - done, off_t(offset + Int64(done)))
                if read < 0, errno == EINTR { continue }
                guard read > 0 else { throw ArchiveError.changed(stamp.url.lastPathComponent) }
                done += read
            }
        }
        try stamp.verify(descriptor: descriptor)
        return data
    }
}

final class ArchiveBuilder {
    var entries: [String: ArchiveEntry] = [:]
    var explicit = Set<String>()
    var totalBytes: Int64 = 0
    var discoveredFolderEntries = 0
    var stamps: [ArchiveSourceStamp] = []

    static func normalize(_ raw: String, directory: Bool) throws -> String? {
        guard raw.utf8.count <= ArchiveCatalog.maximumPathBytes, !raw.isEmpty, !raw.contains("\0"),
              !raw.hasPrefix("/"), !raw.contains("\\") else { throw ArchiveError.invalidPath }
        let bytes = Array(raw.utf8)
        if bytes.count >= 2, bytes[1] == 58, (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]) { throw ArchiveError.invalidPath }
        let pieces = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard !pieces.contains(".."), directory || !raw.hasSuffix("/") else { throw ArchiveError.invalidPath }
        let components = pieces.filter { $0 != "." }
        guard components.count <= 128 else { throw ArchiveError.limit }
        if components.isEmpty {
            guard directory else { throw ArchiveError.invalidPath }
            return nil
        }
        return components.joined(separator: "/")
    }
    func add(rawPath: String, kind: ArchiveEntryKind, size: Int64?, digest: String?, issue: ArchiveEntryIssue?) throws {
        guard let path = try Self.normalize(rawPath, directory: kind == .directory) else { return }
        guard explicit.insert(path).inserted else { throw ArchiveError.duplicatePath(path) }
        if let old = entries[path], old.kind != .directory || kind != .directory { throw ArchiveError.duplicatePath(path) }
        let components = path.split(separator: "/")
        if components.count > 1 {
            var parent = ""
            for component in components.dropLast() {
                parent = parent.isEmpty ? String(component) : parent + "/" + component
                if let old = entries[parent] {
                    guard old.kind == .directory else { throw ArchiveError.duplicatePath(parent) }
                } else { entries[parent] = ArchiveEntry(path: parent, kind: .directory, size: 0, sha256: nil) }
            }
        }
        entries[path] = ArchiveEntry(path: path, kind: kind, size: size, sha256: digest, issue: issue)
        guard entries.count <= ArchiveCatalog.maximumEntries else { throw ArchiveError.limit }
    }
    func account(_ amount: Int64, fileBytes: Int64) throws {
        guard amount >= 0, fileBytes <= ArchiveCatalog.maximumFileBytes,
              amount <= ArchiveCatalog.maximumExpandedBytes - totalBytes else { throw ArchiveError.limit }
        totalBytes += amount
    }
    func finish(url: URL, kind: ArchiveSourceKind) throws -> ArchiveSnapshot {
        let result = ArchiveSnapshot(sourceURL: url, sourceKind: kind,
                                     entries: entries.values.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) },
                                     totalExpandedBytes: totalBytes, stamps: stamps)
        try result.verifyUnchanged()
        return result
    }
}

enum ArchiveFolderReader {
    static func read(_ root: URL, builder: ArchiveBuilder) throws {
        let directory = try ArchiveInput(url: root, directory: true)
        try visit(directory, path: "", depth: 0, builder: builder)
    }
    private static func visit(_ directory: ArchiveInput, path: String, depth: Int, builder: ArchiveBuilder) throws {
        try Task.checkCancellation()
        guard depth <= 128 else { throw ArchiveError.limit }
        builder.stamps.append(directory.stamp)
        let copied = dup(directory.descriptor)
        guard copied >= 0 else { throw ArchiveError.unreadable(directory.stamp.url.lastPathComponent) }
        guard let stream = fdopendir(copied) else { close(copied); throw ArchiveError.unreadable(directory.stamp.url.lastPathComponent) }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            try Task.checkCancellation(); errno = 0
            guard let record = readdir(stream) else {
                guard errno == 0 else { throw ArchiveError.unreadable(directory.stamp.url.lastPathComponent) }; break
            }
            let bytes = withUnsafeBytes(of: record.pointee.d_name) { Data($0.prefix(Int(record.pointee.d_namlen))) }
            guard let name = String(data: bytes, encoding: .utf8) else { throw ArchiveError.invalidPath }
            if name == "." || name == ".." { continue }
            builder.discoveredFolderEntries += 1
            guard builder.discoveredFolderEntries <= ArchiveCatalog.maximumEntries else { throw ArchiveError.limit }
            names.append(name)
        }
        for name in names.sorted() {
            try Task.checkCancellation()
            let relative = path.isEmpty ? name : path + "/" + name
            _ = try ArchiveBuilder.normalize(relative, directory: false)
            let url = directory.stamp.url.appendingPathComponent(name)
            var info = stat()
            guard fstatat(directory.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ArchiveError.unreadable(relative) }
            let stamp = ArchiveSourceStamp(url: url, info: info)
            let type = info.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFDIR) {
                let child = try ArchiveInput(url: url, directory: true, parent: directory.descriptor, name: name)
                guard stamp.matches(child.stamp.info) else { throw ArchiveError.changed(relative) }
                try builder.add(rawPath: relative, kind: .directory, size: 0, digest: nil, issue: nil)
                try visit(child, path: relative, depth: depth + 1, builder: builder)
            } else if type == mode_t(S_IFREG), info.st_nlink == 1 {
                guard info.st_size <= ArchiveCatalog.maximumFileBytes else { throw ArchiveError.limit }
                let child = try ArchiveInput(url: url, parent: directory.descriptor, name: name)
                guard stamp.matches(child.stamp.info) else { throw ArchiveError.changed(relative) }
                var hash = SHA256(), position: Int64 = 0
                while position < child.size {
                    let data = try child.read(offset: position, count: 64 * 1024)
                    position += Int64(data.count); try builder.account(Int64(data.count), fileBytes: position); hash.update(data: data)
                }
                try child.stamp.verify(descriptor: child.descriptor)
                builder.stamps.append(child.stamp)
                try builder.add(rawPath: relative, kind: .file, size: position, digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), issue: nil)
            } else {
                builder.stamps.append(stamp)
                let kind: ArchiveEntryKind = type == mode_t(S_IFLNK) ? .symbolicLink : (type == mode_t(S_IFREG) ? .hardLink : .other)
                let issue: ArchiveEntryIssue = kind == .symbolicLink ? .symbolicLink : (kind == .hardLink ? .hardLink : .specialFile)
                try builder.add(rawPath: relative, kind: kind, size: nil, digest: nil, issue: issue)
            }
        }
        try directory.stamp.verify(descriptor: directory.descriptor)
    }
}
