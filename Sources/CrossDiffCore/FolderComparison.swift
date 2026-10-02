import Foundation
import CryptoKit
import Darwin

public enum FolderEntryStatus: String, CaseIterable, Sendable {
    case same, changed, leftOnly, rightOnly, typeMismatch, unreadable, pending
    public var title: String {
        switch self {
        case .pending: return L("待校验", "Pending")
        case .same: return L("相同", "Identical")
        case .changed: return L("已改动", "Modified")
        case .leftOnly: return L("仅左侧", "Left Only")
        case .rightOnly: return L("仅右侧", "Right Only")
        case .typeMismatch: return L("类型不同", "Type Mismatch")
        case .unreadable: return L("读取失败", "Unreadable")
        }
    }
}

public enum FolderItemKind: String, Sendable { case file, directory, symbolicLink, other }

public struct FolderSnapshot: Equatable, Sendable {
    public let kind: FolderItemKind
    public let size: Int64
    fileprivate let digest: String?
    fileprivate let identity: UInt64
    fileprivate let device: Int32
    fileprivate let modifiedSeconds: Int
    fileprivate let modifiedNanoseconds: Int
    fileprivate let changedSeconds: Int
    fileprivate let changedNanoseconds: Int

    fileprivate func hasSameMetadata(as other: FolderSnapshot) -> Bool {
        kind == other.kind && size == other.size && identity == other.identity && device == other.device &&
        modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds &&
        changedSeconds == other.changedSeconds && changedNanoseconds == other.changedNanoseconds
    }
}

public struct FolderEntry: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public var status: FolderEntryStatus
    public let left: FolderSnapshot?
    public let right: FolderSnapshot?
    private let failure: FolderComparisonError?
    public var problem: String? { failure?.errorDescription }

    fileprivate init(path: String, status: FolderEntryStatus, left: FolderSnapshot?, right: FolderSnapshot?, failure: FolderComparisonError?) {
        self.path = path; self.status = status; self.left = left; self.right = right; self.failure = failure
    }
    public var isDirectory: Bool { left?.kind == .directory || right?.kind == .directory }
    public var canOpenPair: Bool { left?.kind == .file && right?.kind == .file && status != .unreadable }
    public func canCopy(toRight: Bool) -> Bool {
        let source = toRight ? left : right, target = toRight ? right : left
        return source?.kind == .file && (target == nil || target?.kind == .file) && status != .unreadable && status != .same && status != .pending
    }
}

public struct FolderComparisonResult: Sendable {
    public let leftRoot: URL
    public let rightRoot: URL
    public let entries: [FolderEntry]
    /// Number of ignored entries (an ignored directory counts once, without traversing its contents).
    public let ignoredCount: Int
    /// Partial inventories must never be used to prepare a copy.
    public let isComplete: Bool
    public let progress: FolderScanProgress
    fileprivate let leftIdentity: FolderSnapshot
    fileprivate let rightIdentity: FolderSnapshot
}

public enum FolderComparisonError: LocalizedError, Sendable {
    case invalidFolders
    case selectionChanged
    case filesystem(String)
    case stale(String)
    case unsafe(String)
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .invalidFolders: return L("请选择两个文件夹。", "Choose two folders to compare.")
        case .selectionChanged: return L("所选文件已变化，请重新比较。", "The selected files have changed. Compare again before copying.")
        case .filesystem(let path): return L("无法读取或写入：\(path)", "Unable to read or write: \(path)")
        case .stale(let path): return L("比较后文件已变化，已停止复制。请重新比较：\(path)", "The file has changed since the comparison. Copying stopped. Compare again: \(path)")
        case .unsafe(let path): return L("路径包含符号链接或不再是原来的目录，已停止操作：\(path)", "The path contains a symbolic link or is no longer the original folder. The operation stopped: \(path)")
        case .unsupported(let path): return L("只能复制常规文件；目录、符号链接与类型冲突需手动处理：\(path)", "Only regular files can be copied. Folders, symbolic links, and type conflicts require manual handling: \(path)")
        }
    }
}

public struct FolderScanOptions: Equatable, Sendable {
    public let ignoredNames: Set<String>
    public let maxConcurrentReads: Int
    public init(ignoredNames: Set<String> = FolderComparison.ignoredNames, maxConcurrentReads: Int = 2) {
        self.ignoredNames = ignoredNames
        // Keep descriptor use and storage pressure bounded even for external callers.
        self.maxConcurrentReads = min(8, max(1, maxConcurrentReads))
    }
}

public enum FolderScanStage: String, Sendable { case enumerating, comparing }

public struct FolderScanProgress: Equatable, Sendable {
    public let stage: FolderScanStage
    /// Entries discovered on both sides, excluding ignored entries.
    public let discoveredItems: Int
    /// Only equal-size regular-file pairs require content verification.
    public let completedPairs: Int
    public let totalPairs: Int
    /// Actual bytes read for SHA-256, including reads that subsequently fail validation.
    public let bytesRead: Int64
    public init(stage: FolderScanStage = .enumerating, discoveredItems: Int = 0,
                completedPairs: Int = 0, totalPairs: Int = 0, bytesRead: Int64 = 0) {
        self.stage = stage; self.discoveredItems = discoveredItems
        self.completedPairs = completedPairs; self.totalPairs = totalPairs; self.bytesRead = bytesRead
    }
}

public struct FolderScanUpdate: Sendable {
    public let progress: FolderScanProgress
    /// A sorted partial result after enumeration, then throttled snapshots and the final result.
    /// A nil result is a lightweight progress-only update; retain the previous visible rows.
    public let result: FolderComparisonResult?
}

/// Serializes progress from the bounded readers. No callbacks can escape after a scan returns.
private final class ScanReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let onUpdate: (@Sendable (FolderScanUpdate) -> Void)?
    private var stage: FolderScanStage = .enumerating
    private var discovered = 0, completed = 0, total = 0
    private var bytes: Int64 = 0
    private var lastUpdate: UInt64 = 0
    init(onUpdate: (@Sendable (FolderScanUpdate) -> Void)?) { self.onUpdate = onUpdate }
    private var current: FolderScanProgress {
        FolderScanProgress(stage: stage, discoveredItems: discovered, completedPairs: completed,
                           totalPairs: total, bytesRead: bytes)
    }
    var progress: FolderScanProgress { lock.lock(); defer { lock.unlock() }; return current }
    func discoveredItem() { lock.lock(); defer { lock.unlock() }; discovered += 1; emit() }
    func readBytes(_ count: Int) { lock.lock(); defer { lock.unlock() }; bytes += Int64(count); emit() }
    func completedPair() { lock.lock(); defer { lock.unlock() }; completed += 1; emit() }
    func beginComparing(total: Int) {
        lock.lock(); defer { lock.unlock() }
        stage = .comparing; self.total = total; emit(force: true)
    }
    func publish(result: FolderComparisonResult? = nil, force: Bool = false) {
        lock.lock(); defer { lock.unlock() }; emit(result: result, force: force)
    }
    private func emit(result: FolderComparisonResult? = nil, force: Bool = false) {
        guard let onUpdate else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || now - lastUpdate >= 100_000_000 else { return }
        lastUpdate = now
        onUpdate(FolderScanUpdate(progress: current, result: result))
    }
}

public enum FolderComparison {
    public static let ignoredNames: Set<String> = [".git", ".DS_Store", ".build", "node_modules"]

    /// Synchronous callers retain the same API and strict content comparison. Use the incremental
    /// variant for UI work; it also allows a bounded number of concurrent file reads.
    public static func scan(left: URL, right: URL, options: FolderScanOptions = .init()) throws -> FolderComparisonResult {
        let reporter = ScanReporter(onUpdate: nil)
        let scan = try prepareScan(left: left, right: right, options: options, reporter: reporter)
        var entries = scan.entries
        reporter.beginComparing(total: scan.candidates.count)
        for index in scan.candidates {
            entries[index] = try compare(entries[index], scan: scan, reporter: reporter)
            reporter.completedPair()
        }
        try validateScanRoots(scan)
        return result(scan, entries: entries, complete: true, progress: reporter.progress)
    }

    /// The callback runs on the scanning executor, never the main thread by contract. It is
    /// throttled, except for phase boundaries/final results, and must return promptly.
    public static func scanIncrementally(left: URL, right: URL, options: FolderScanOptions = .init(),
                                         onUpdate: @escaping @Sendable (FolderScanUpdate) -> Void) async throws -> FolderComparisonResult {
        let reporter = ScanReporter(onUpdate: onUpdate)
        let scan = try prepareScan(left: left, right: right, options: options, reporter: reporter)
        var entries = scan.entries
        reporter.beginComparing(total: scan.candidates.count)
        reporter.publish(result: result(scan, entries: entries, complete: false, progress: reporter.progress), force: true)
        try Task.checkCancellation()
        // Batch only small candidates to avoid one child task allocation per tiny file.
        // Large files remain individual jobs and the number of active readers stays bounded.
        var batches: [[Int]] = [], batch: [Int] = [], batchBytes: Int64 = 0
        for index in scan.candidates {
            let size = scan.entries[index].left?.size ?? 0
            if !batch.isEmpty && (batch.count >= 32 || size > 512 * 1024 - batchBytes) {
                batches.append(batch); batch = []; batchBytes = 0
            }
            batch.append(index); batchBytes += min(size, 512 * 1024)
        }
        if !batch.isEmpty { batches.append(batch) }
        var next = 0
        var lastResultTime = ProcessInfo.processInfo.systemUptime
        try await withThrowingTaskGroup(of: [(Int, FolderEntry)].self) { group in
            func enqueue(_ indices: [Int]) {
                group.addTask {
                    var completed: [(Int, FolderEntry)] = []
                    completed.reserveCapacity(indices.count)
                    for index in indices {
                        let entry = try compare(scan.entries[index], scan: scan, reporter: reporter)
                        reporter.completedPair()
                        completed.append((index, entry))
                    }
                    return completed
                }
            }
            for _ in 0..<min(options.maxConcurrentReads, batches.count) {
                enqueue(batches[next]); next += 1
            }
            for try await completed in group {
                try Task.checkCancellation()
                for (index, entry) in completed { entries[index] = entry }
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastResultTime >= 0.1 {
                    reporter.publish(result: result(scan, entries: entries, complete: false, progress: reporter.progress), force: true)
                    lastResultTime = now
                }
                if next < batches.count {
                    enqueue(batches[next]); next += 1
                }
            }
        }
        try Task.checkCancellation()
        try validateScanRoots(scan)
        let final = result(scan, entries: entries, complete: true, progress: reporter.progress)
        reporter.publish(result: final, force: true)
        return final
    }

    private struct Scan: Sendable {
        let left: ScanRoot
        let right: ScanRoot
        let entries: [FolderEntry]
        let candidates: [Int]
        let ignoredCount: Int
    }

    /// One rooted descriptor per side. Descendants are traversed with openat/O_NOFOLLOW;
    /// walking a deep directory no longer repeatedly reopens every ancestor from '/'.
    private final class ScanRoot: @unchecked Sendable {
        let url: URL
        let identity: FolderSnapshot
        let descriptor: Int32
        let items: [String: FolderSnapshot]
        init(url: URL, identity: FolderSnapshot, descriptor: Int32, items: [String: FolderSnapshot]) {
            self.url = url; self.identity = identity; self.descriptor = descriptor; self.items = items
        }
        deinit { close(descriptor) }
    }

    private static func prepareScan(left: URL, right: URL, options: FolderScanOptions, reporter: ScanReporter) throws -> Scan {
        var ignored = 0, failures: [String: FolderComparisonError] = [:]
        func inventory(_ input: URL) throws -> ScanRoot {
            try Task.checkCancellation()
            let root = try canonicalURL(input)
            guard let identity = try snapshot(root, contents: false), identity.kind == .directory else {
                throw FolderComparisonError.invalidFolders
            }
            let descriptor = try parentDescriptor(root: root, path: "placeholder", create: false, expectedRoot: identity)
            do {
                var items: [String: FolderSnapshot] = [:]
                try walk(root: root, descriptor: descriptor, relative: "", items: &items, failures: &failures,
                         ignored: &ignored, ignoredNames: options.ignoredNames, reporter: reporter)
                return ScanRoot(url: root, identity: identity, descriptor: descriptor, items: items)
            } catch { close(descriptor); throw error }
        }
        reporter.publish(force: true)
        let lhs = try inventory(left), rhs = try inventory(right)
        let paths = Set(lhs.items.keys).union(rhs.items.keys).union(failures.keys)
        var candidates: [Int] = []
        let entries = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.enumerated().map { index, path in
            let a = lhs.items[path], b = rhs.items[path]
            let status: FolderEntryStatus
            if failures[path] != nil { status = .unreadable }
            else if a == nil { status = .rightOnly }
            else if b == nil { status = .leftOnly }
            else if a?.kind != b?.kind { status = .typeMismatch }
            else if a?.kind == .file {
                if a?.size != b?.size { status = .changed }
                else { status = .pending; candidates.append(index) }
            } else { status = a?.digest == b?.digest ? .same : .changed }
            return FolderEntry(path: path, status: status, left: a, right: b, failure: failures[path])
        }
        return Scan(left: lhs, right: rhs, entries: entries, candidates: candidates, ignoredCount: ignored)
    }

    private static func result(_ scan: Scan, entries original: [FolderEntry], complete: Bool,
                               progress: FolderScanProgress) -> FolderComparisonResult {
        var entries = original, changedParents = Set<String>(), pendingParents = Set<String>()
        for entry in entries where entry.status != .same {
            var components = entry.path.split(separator: "/")
            while components.count > 1 {
                components.removeLast()
                let parent = components.joined(separator: "/")
                if entry.status == .pending { pendingParents.insert(parent) }
                else { changedParents.insert(parent) }
            }
        }
        for index in entries.indices where entries[index].status == .same && entries[index].isDirectory {
            if changedParents.contains(entries[index].path) { entries[index].status = .changed }
            else if pendingParents.contains(entries[index].path) { entries[index].status = .pending }
        }
        return FolderComparisonResult(leftRoot: scan.left.url, rightRoot: scan.right.url, entries: entries,
                                      ignoredCount: scan.ignoredCount, isComplete: complete, progress: progress,
                                      leftIdentity: scan.left.identity, rightIdentity: scan.right.identity)
    }

    private static func walk(root: URL, descriptor: Int32, relative: String, items: inout [String: FolderSnapshot],
                             failures: inout [String: FolderComparisonError], ignored: inout Int,
                             ignoredNames: Set<String>, reporter: ScanReporter) throws {
        try Task.checkCancellation()
        let directory = relative.isEmpty ? root : root.appendingPathComponent(relative)
        let names = try childNames(descriptor, path: directory.path)
        for name in names {
            try Task.checkCancellation()
            if ignoredNames.contains(name) { ignored += 1; continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            let url = directory.appendingPathComponent(name)
            do {
                guard let value = try snapshot(url, parent: descriptor, contents: false) else { throw FolderComparisonError.stale(path) }
                items[path] = value
                reporter.discoveredItem()
                if value.kind == .directory {
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard child >= 0 else { throw FolderComparisonError.unsafe(path) }
                    defer { close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, UInt64(opened.st_ino) == value.identity,
                          opened.st_dev == value.device else { throw FolderComparisonError.stale(path) }
                    try walk(root: root, descriptor: child, relative: path, items: &items, failures: &failures,
                             ignored: &ignored, ignoredNames: ignoredNames, reporter: reporter)
                    guard let current = try snapshot(url, parent: descriptor, contents: false),
                          current.hasSameMetadata(as: value) else { throw FolderComparisonError.stale(path) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { failures[path] = (error as? FolderComparisonError) ?? .filesystem(path) }
        }
    }

    private static func scanParent(_ root: ScanRoot, path: String) throws -> Int32 {
        var descriptor = dup(root.descriptor)
        guard descriptor >= 0 else { throw FolderComparisonError.filesystem(path) }
        do {
            var relative = ""
            for component in path.split(separator: "/").dropLast() {
                let name = String(component)
                relative = relative.isEmpty ? name : relative + "/" + name
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw FolderComparisonError.unsafe(path) }
                close(descriptor); descriptor = child
                var info = stat()
                guard let expected = root.items[relative], fstat(descriptor, &info) == 0,
                      UInt64(info.st_ino) == expected.identity, info.st_dev == expected.device else {
                    throw FolderComparisonError.stale(path)
                }
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func compare(_ entry: FolderEntry, scan: Scan, reporter: ScanReporter) throws -> FolderEntry {
        do {
            try Task.checkCancellation()
            func read(_ root: ScanRoot, expected: FolderSnapshot?) throws -> FolderSnapshot {
                let parent = try scanParent(root, path: entry.path)
                defer { close(parent) }
                guard let value = try snapshot(root.url.appendingPathComponent(entry.path), parent: parent,
                                               expected: expected, onRead: { reporter.readBytes($0) }) else {
                    throw FolderComparisonError.stale(entry.path)
                }
                // The held descriptor may remain valid after its directory is moved away.
                // Re-resolve the rooted ancestor chain before accepting this content result.
                let currentParent = try scanParent(root, path: entry.path)
                defer { close(currentParent) }
                guard let current = try snapshot(root.url.appendingPathComponent(entry.path), parent: currentParent, contents: false),
                      current.hasSameMetadata(as: value) else { throw FolderComparisonError.stale(entry.path) }
                return value
            }
            let a = try read(scan.left, expected: entry.left)
            let b = try read(scan.right, expected: entry.right)
            return FolderEntry(path: entry.path, status: a.digest == b.digest ? .same : .changed,
                               left: a, right: b, failure: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            return FolderEntry(path: entry.path, status: .unreadable, left: entry.left, right: entry.right,
                               failure: (error as? FolderComparisonError) ?? .filesystem(entry.path))
        }
    }

    private static func validateScanRoots(_ scan: Scan) throws {
        for root in [scan.left, scan.right] {
            guard try canonicalURL(root.url).path == root.url.path,
                  let current = try snapshot(root.url, contents: false), current.hasSameMetadata(as: root.identity) else {
                throw FolderComparisonError.stale(root.url.path)
            }
        }
    }

    private static func childNames(_ descriptor: Int32, path: String) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw FolderComparisonError.filesystem(path) }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw FolderComparisonError.filesystem(path) }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw FolderComparisonError.filesystem(path) }
                break
            }
            var nameBytes = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: nameBytes)
            let name = withUnsafePointer(to: &nameBytes) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    fileprivate static func snapshot(_ url: URL, parent: Int32? = nil, contents: Bool = true,
                                     expected: FolderSnapshot? = nil, onRead: ((Int) -> Void)? = nil) throws -> FolderSnapshot? {
        var info = stat()
        let name = parent == nil ? url.path : url.lastPathComponent
        let status = parent.map { fstatat($0, name, &info, AT_SYMLINK_NOFOLLOW) } ?? lstat(name, &info)
        guard status == 0 else {
            if errno == ENOENT { return nil }
            throw FolderComparisonError.filesystem(url.path)
        }
        let kind: FolderItemKind
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): kind = .file
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }
        let metadata = FolderSnapshot(kind: kind, size: Int64(info.st_size), digest: nil, identity: UInt64(info.st_ino),
                                      device: info.st_dev, modifiedSeconds: info.st_mtimespec.tv_sec,
                                      modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                                      changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
        if let expected, !metadata.hasSameMetadata(as: expected) { throw FolderComparisonError.stale(url.path) }
        let digest: String?
        if kind == .file && !contents { return metadata }
        if kind == .file {
            let descriptor = parent.map { openat($0, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? open(name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw FolderComparisonError.filesystem(url.path) }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, unchanged(info, opened),
                  opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw FolderComparisonError.stale(url.path)
            }
            var hash = SHA256(), bytes = [UInt8](repeating: 0, count: max(4096, Int(min(info.st_size, 256 * 1024))))
            while true {
                try Task.checkCancellation()
                let count = read(descriptor, &bytes, bytes.count)
                guard count >= 0 else { throw FolderComparisonError.filesystem(url.path) }
                if count == 0 { break }
                bytes.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
                onRead?(count)
            }
            var after = stat(), named = stat()
            let namedStatus = parent.map { fstatat($0, name, &named, AT_SYMLINK_NOFOLLOW) } ?? lstat(name, &named)
            guard fstat(descriptor, &after) == 0, unchanged(info, after), namedStatus == 0,
                  unchanged(info, named), named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw FolderComparisonError.stale(url.path)
            }
            digest = hexDigest(hash.finalize())
        } else if kind == .symbolicLink {
            if let parent {
                var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
                // Pass the elements explicitly: older SDK imports can otherwise convert
                // &bytes to the Array value's address instead of its contiguous storage.
                let count = bytes.withUnsafeMutableBytes { buffer in
                    readlinkat(parent, name, buffer.baseAddress!, buffer.count)
                }
                guard count >= 0 else { throw FolderComparisonError.filesystem(url.path) }
                digest = String(decoding: bytes[0..<count], as: UTF8.self)
            } else { digest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path) }
        } else { digest = kind.rawValue }
        return FolderSnapshot(kind: kind, size: Int64(info.st_size), digest: digest, identity: UInt64(info.st_ino),
                              device: info.st_dev, modifiedSeconds: info.st_mtimespec.tv_sec,
                              modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                              changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }

    private static func hexDigest(_ digest: SHA256.Digest) -> String {
        let alphabet: [UInt8] = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(64)
        for byte in digest { bytes.append(alphabet[Int(byte >> 4)]); bytes.append(alphabet[Int(byte & 15)]) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_ino == b.st_ino && a.st_dev == b.st_dev && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw FolderComparisonError.filesystem(url.path) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }


}

public enum FolderCopyOperation: String, Sendable {
    case add, overwrite
    public var title: String { self == .add ? L("新增", "Add") : L("覆盖", "Overwrite") }
}

public struct FolderCopyAction: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let operation: FolderCopyOperation
    fileprivate let source: FolderSnapshot
    fileprivate let target: FolderSnapshot?
}

public struct FolderCopyPlan: Identifiable, Sendable {
    public let id = UUID()
    public let sourceRoot: URL
    public let targetRoot: URL
    public let actions: [FolderCopyAction]
    fileprivate let sourceIdentity: FolderSnapshot
    fileprivate let targetIdentity: FolderSnapshot
}

extension FolderComparison {
    public static func prepareCopy(_ comparison: FolderComparisonResult, paths: Set<String>, toRight: Bool) throws -> FolderCopyPlan {
        guard comparison.isComplete, !comparison.entries.contains(where: { $0.status == .pending }) else {
            throw FolderComparisonError.selectionChanged
        }
        let sourceRoot = toRight ? comparison.leftRoot : comparison.rightRoot
        let targetRoot = toRight ? comparison.rightRoot : comparison.leftRoot
        let sourceIdentity = toRight ? comparison.leftIdentity : comparison.rightIdentity
        let targetIdentity = toRight ? comparison.rightIdentity : comparison.leftIdentity
        for (root, expected) in [(sourceRoot, sourceIdentity), (targetRoot, targetIdentity)] {
            guard try canonicalURL(root).path == root.path,
                  let actual = try snapshot(root, contents: false), actual.kind == .directory,
                  actual.identity == expected.identity, actual.device == expected.device else {
                throw FolderComparisonError.unsafe(root.path)
            }
        }
        let entries = comparison.entries.filter { paths.contains($0.path) }
        guard entries.count == paths.count else { throw FolderComparisonError.selectionChanged }
        let actions = try entries.map { entry -> FolderCopyAction in
            guard entry.canCopy(toRight: toRight), let source = toRight ? entry.left : entry.right else {
                throw FolderComparisonError.unsupported(entry.path)
            }
            let target = toRight ? entry.right : entry.left
            // Full snapshots are acquired only for selected files. Metadata (including ctime)
            // must still match the scan, so restoring a modified file's mtime cannot bypass this.
            guard let currentSource = try copySnapshot(root: sourceRoot, path: entry.path,
                                                       rootIdentity: sourceIdentity, expected: source),
                  source.digest == nil || source.digest == currentSource.digest else {
                throw FolderComparisonError.stale(entry.path)
            }
            let currentTarget = try copySnapshot(root: targetRoot, path: entry.path, rootIdentity: targetIdentity, expected: target)
            guard (target == nil && currentTarget == nil) ||
                  (target != nil && currentTarget != nil && (target?.digest == nil || target?.digest == currentTarget?.digest)) else {
                throw FolderComparisonError.stale(entry.path)
            }
            return FolderCopyAction(path: entry.path, operation: target == nil ? .add : .overwrite,
                                    source: currentSource, target: currentTarget)
        }
        let plan = FolderCopyPlan(sourceRoot: toRight ? comparison.leftRoot : comparison.rightRoot,
                                  targetRoot: toRight ? comparison.rightRoot : comparison.leftRoot,
                                  actions: actions,
                                  sourceIdentity: toRight ? comparison.leftIdentity : comparison.rightIdentity,
                                  targetIdentity: toRight ? comparison.rightIdentity : comparison.leftIdentity)
        try validate(plan)
        return plan
    }

    /// Revalidates the entire preview before touching files, then revalidates each action at write time.
    /// A failure after earlier completed actions leaves those files copied; it never deletes source files.
    @discardableResult public static func execute(_ plan: FolderCopyPlan) throws -> Int {
        try validate(plan)
        var completed = 0
        for action in plan.actions {
            try Task.checkCancellation()
            try validateAction(action, plan: plan)
            try copyFile(action, plan: plan)
            completed += 1
        }
        return completed
    }

    private static func validate(_ plan: FolderCopyPlan) throws {
        for (root, expected) in [(plan.sourceRoot, plan.sourceIdentity), (plan.targetRoot, plan.targetIdentity)] {
            guard try canonicalURL(root).path == root.path,
                  let actual = try snapshot(root), actual.kind == .directory,
                  actual.identity == expected.identity, actual.device == expected.device else {
                throw FolderComparisonError.unsafe(root.path)
            }
        }
        for action in plan.actions { try validateAction(action, plan: plan) }
    }

    private static func validateAction(_ action: FolderCopyAction, plan: FolderCopyPlan) throws {
        try Task.checkCancellation()
        guard try copySnapshot(root: plan.sourceRoot, path: action.path, rootIdentity: plan.sourceIdentity,
                               expected: action.source) == action.source,
              try copySnapshot(root: plan.targetRoot, path: action.path, rootIdentity: plan.targetIdentity,
                               expected: action.target) == action.target else {
            throw FolderComparisonError.stale(action.path)
        }
    }

    private static func copySnapshot(root: URL, path: String, rootIdentity: FolderSnapshot,
                                     expected: FolderSnapshot?) throws -> FolderSnapshot? {
        let parent = try parentDescriptor(root: root, path: path, create: false, expectedRoot: rootIdentity, allowMissing: true)
        guard parent >= 0 else { return nil }
        defer { close(parent) }
        return try snapshot(root.appendingPathComponent(path), parent: parent, expected: expected)
    }

    /// Traverses each parent with O_NOFOLLOW so replacing a directory by a link cannot redirect a write.
    /// Missing destination parents are represented by -1 only for read-only copy validation.
    private static func parentDescriptor(root: URL, path: String, create: Bool, expectedRoot: FolderSnapshot? = nil,
                                         allowMissing: Bool = false) throws -> Int32 {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw FolderComparisonError.unsafe(path)
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw FolderComparisonError.unsafe(root.path) }
        do {
            for component in root.pathComponents.dropFirst() {
                let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw FolderComparisonError.unsafe(root.path) }
                close(descriptor)
                descriptor = child
            }
            if let expectedRoot {
                var info = stat()
                guard fstat(descriptor, &info) == 0, UInt64(info.st_ino) == expectedRoot.identity,
                      info.st_dev == expectedRoot.device else { throw FolderComparisonError.stale(root.path) }
            }
            for component in path.split(separator: "/").dropLast() {
                let name = String(component)
                var child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if child < 0 && errno == ENOENT && create {
                    guard mkdirat(descriptor, name, 0o755) == 0 || errno == EEXIST else { throw FolderComparisonError.filesystem(path) }
                    child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                }
                if child < 0 && errno == ENOENT && allowMissing { close(descriptor); return -1 }
                guard child >= 0 else { throw FolderComparisonError.unsafe(path) }
                close(descriptor)
                descriptor = child
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    private static func copyFile(_ action: FolderCopyAction, plan: FolderCopyPlan) throws {
        let sourceParent = try parentDescriptor(root: plan.sourceRoot, path: action.path, create: false, expectedRoot: plan.sourceIdentity)
        defer { close(sourceParent) }
        let targetParent = try parentDescriptor(root: plan.targetRoot, path: action.path, create: true, expectedRoot: plan.targetIdentity)
        defer { close(targetParent) }
        let name = (action.path as NSString).lastPathComponent
        let source = openat(sourceParent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard source >= 0 else { throw FolderComparisonError.stale(action.path) }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              UInt64(info.st_ino) == action.source.identity, info.st_dev == action.source.device else {
            throw FolderComparisonError.stale(action.path)
        }
        let temporary = ".crossdiff-copy-" + UUID().uuidString
        let destination = openat(targetParent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destination >= 0 else { throw FolderComparisonError.filesystem(action.path) }
        defer { close(destination); unlinkat(targetParent, temporary, 0) }
        var bytes = [UInt8](repeating: 0, count: 256 * 1024), hash = SHA256()
        while true {
            try Task.checkCancellation()
            let count = read(source, &bytes, bytes.count)
            guard count >= 0 else { throw FolderComparisonError.filesystem(action.path) }
            if count == 0 { break }
            bytes.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < count {
                    let written = write(destination, buffer.baseAddress!.advanced(by: offset), count - offset)
                    guard written > 0 else { throw FolderComparisonError.filesystem(action.path) }
                    offset += written
                }
            }
        }
        let digest = hexDigest(hash.finalize())
        guard digest == action.source.digest else { throw FolderComparisonError.stale(action.path) }
        try validateAction(action, plan: plan)
        guard fchmod(destination, info.st_mode & 0o777) == 0, fsync(destination) == 0 else {
            throw FolderComparisonError.filesystem(action.path)
        }
        // Additions use an exclusive link operation, so a concurrently created target is never overwritten.
        if action.operation == .add {
            guard linkat(targetParent, temporary, targetParent, name, 0) == 0 else { throw FolderComparisonError.stale(action.path) }
        } else {
            guard renameat(targetParent, temporary, targetParent, name) == 0 else { throw FolderComparisonError.filesystem(action.path) }
        }
    }
}
