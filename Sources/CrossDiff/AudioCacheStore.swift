import Foundation
import Darwin
import CrossDiffCore

/// Keeps an advisory lock for the whole comparison, including its native helper.
/// Each job owns only its generated directory; source audio is never placed here.
final class AudioCacheJob: @unchecked Sendable {
    let directory: URL
    private let mutex = NSLock()
    private var parentFD: Int32
    private var directoryFD: Int32
    private var leaseFD: Int32
    private let name: String

    fileprivate init(directory: URL, name: String, parentFD: Int32, directoryFD: Int32, leaseFD: Int32) {
        self.directory = directory; self.name = name; self.parentFD = parentFD
        self.directoryFD = directoryFD; self.leaseFD = leaseFD
    }
    fileprivate func finish() {
        mutex.lock(); defer { mutex.unlock() }
        guard leaseFD >= 0 else { return }
        // Hold the lock until unlinking is finished. A failed cleanup remains
        // marked and becomes eligible for a later inactive-cache sweep.
        try? AudioCacheStore.removeDirectory(parentFD: parentFD, name: name, directoryFD: directoryFD)
        close(leaseFD); close(directoryFD); close(parentFD)
        leaseFD = -1; directoryFD = -1; parentFD = -1
    }
    deinit { finish() }
}

enum AudioCacheStore {
    static let markerName = ".crossdiff-audio-lease"
    private static let marker = Data("CrossDiff audio temporary job\nversion=1\n".utf8)
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// `base` is the app's AudioCache directory. Startup sweeping never deletes a live lease.
    static func createJob(in base: URL) throws -> AudioCacheJob {
        let parent = try openDirectory(base, create: true)
        var ownsParent = true
        defer { if ownsParent { close(parent) } }
        _ = try clearInactive(parentFD: parent)
        let name = UUID().uuidString.lowercased()
        guard mkdirat(parent, name, 0o700) == 0 else { throw systemError() }
        let directory = openat(parent, name, directoryFlags)
        guard directory >= 0 else { _ = unlinkat(parent, name, AT_REMOVEDIR); throw systemError() }
        var ownsDirectory = true
        defer { if ownsDirectory { close(directory) } }
        let lock = openat(directory, markerName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { _ = unlinkat(parent, name, AT_REMOVEDIR); throw systemError() }
        var ownsLock = true
        defer { if ownsLock { close(lock) } }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let failure = systemError()
            _ = unlinkat(directory, markerName, 0); _ = unlinkat(parent, name, AT_REMOVEDIR)
            throw failure
        }
        do {
            try marker.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let amount = Darwin.write(lock, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { throw systemError() }
                    written += amount
                }
            }
        } catch {
            _ = unlinkat(directory, markerName, 0); _ = unlinkat(parent, name, AT_REMOVEDIR)
            throw error
        }
        ownsParent = false; ownsDirectory = false; ownsLock = false
        return AudioCacheJob(directory: base.appendingPathComponent(name, isDirectory: true), name: name,
                             parentFD: parent, directoryFD: directory, leaseFD: lock)
    }

    static func removeJob(_ job: AudioCacheJob) { job.finish() }

    /// Returns the number of removed jobs. Unknown files, malformed markers and active jobs are retained.
    @discardableResult static func clearInactive(in base: URL) throws -> Int {
        let parent: Int32
        do { parent = try openDirectory(base, create: false) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return 0 }
        defer { close(parent) }
        return try clearInactive(parentFD: parent)
    }

    private static func clearInactive(parentFD: Int32) throws -> Int {
        var removed = 0
        for name in try names(in: parentFD) {
            guard let uuid = UUID(uuidString: name), uuid.uuidString.lowercased() == name.lowercased() else { continue }
            let directory = openat(parentFD, name, directoryFlags)
            guard directory >= 0 else { continue }
            defer { close(directory) }
            let lease = openat(directory, markerName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard lease >= 0 else { continue }
            defer { close(lease) }
            var directoryInfo = stat(), leaseInfo = stat()
            guard fstat(directory, &directoryInfo) == 0, directoryInfo.st_uid == geteuid(),
                  fstat(lease, &leaseInfo) == 0, leaseInfo.st_mode & S_IFMT == S_IFREG,
                  leaseInfo.st_uid == geteuid(), leaseInfo.st_nlink == 1, leaseInfo.st_size == marker.count,
                  flock(lease, LOCK_EX | LOCK_NB) == 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: marker.count)
            let amount = bytes.withUnsafeMutableBytes { pread(lease, $0.baseAddress, $0.count, 0) }
            guard amount == marker.count, Data(bytes) == marker else { continue }
            // Ensure the locked marker still belongs to the opened directory.
            var currentMarker = stat()
            guard fstatat(directory, markerName, &currentMarker, AT_SYMLINK_NOFOLLOW) == 0,
                  currentMarker.st_dev == leaseInfo.st_dev, currentMarker.st_ino == leaseInfo.st_ino else { continue }
            try removeDirectory(parentFD: parentFD, name: name, directoryFD: directory)
            removed += 1
        }
        return removed
    }

    /// Walk components through file descriptors so no directory symlink is followed, including ancestors.
    private static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw cacheError("请选择本地缓存目录。", "Choose a local cache directory.") }
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw cacheError("音频缓存路径无效。", "The audio cache path is invalid.")
        }
        var current = open("/", directoryFlags)
        guard current >= 0 else { throw systemError() }
        do {
            for component in components {
                var next = openat(current, component, directoryFlags)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(current, component, 0o700) == 0 || errno == EEXIST else { throw systemError() }
                    next = openat(current, component, directoryFlags)
                }
                guard next >= 0 else { throw systemError() }
                close(current); current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_uid == geteuid() else {
                throw cacheError("音频缓存目录不属于当前用户。", "The audio cache directory is not owned by the current user.")
            }
            return current
        } catch { close(current); throw error }
    }

    private static func names(in descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw systemError() }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw systemError() }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
            guard result.count <= 10_000 else { throw cacheError("缓存目录项目过多，清理已停止。", "The cache contains too many entries; cleanup stopped.") }
        }
        return result
    }

    fileprivate static func removeDirectory(parentFD: Int32, name: String, directoryFD: Int32) throws {
        var budget = 10_000
        try removeChildren(directoryFD, depth: 0, budget: &budget)
        var opened = stat(), current = stat()
        guard fstat(directoryFD, &opened) == 0,
              fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == current.st_dev, opened.st_ino == current.st_ino, current.st_mode & S_IFMT == S_IFDIR else {
            throw cacheError("缓存目录已变化，清理已停止。", "The cache directory changed; cleanup stopped.")
        }
        guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else { throw systemError() }
    }

    private static func removeChildren(_ descriptor: Int32, depth: Int, budget: inout Int) throws {
        guard depth <= 32 else { throw cacheError("缓存目录层级过深，清理已停止。", "The cache is nested too deeply; cleanup stopped.") }
        // Keep the marker until all contents are removed, allowing a failed sweep to retry.
        let entries = try names(in: descriptor).sorted { ($0 == markerName ? 1 : 0) < ($1 == markerName ? 1 : 0) }
        for name in entries {
            budget -= 1
            guard budget >= 0 else { throw cacheError("缓存目录项目过多，清理已停止。", "The cache contains too many entries; cleanup stopped.") }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }; throw systemError()
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = openat(descriptor, name, directoryFlags)
                guard child >= 0 else { throw systemError() }
                defer { close(child) }
                try removeChildren(child, depth: depth + 1, budget: &budget)
                var opened = stat(), current = stat()
                guard fstat(child, &opened) == 0, fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { throw systemError() }
                guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw systemError() }
            } else {
                // unlinkat removes a symlink itself without reading or modifying its target.
                guard unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else { throw systemError() }
            }
        }
    }

    private static func systemError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private static func cacheError(_ zh: String, _ en: String) -> Error {
        NSError(domain: "CrossDiff.AudioCache", code: 1, userInfo: [NSLocalizedDescriptionKey: L(zh, en)])
    }
}
