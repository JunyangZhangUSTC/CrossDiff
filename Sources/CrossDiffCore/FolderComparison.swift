import Foundation
import CryptoKit
import Darwin

public enum FolderEntryStatus: String, CaseIterable, Sendable {
    case same, changed, leftOnly, rightOnly, typeMismatch, unreadable
    public var title: String {
        switch self {
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
    fileprivate let digest: String
    fileprivate let identity: UInt64
    fileprivate let device: Int32
    fileprivate let modifiedSeconds: Int
    fileprivate let modifiedNanoseconds: Int
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
        return source?.kind == .file && (target == nil || target?.kind == .file) && status != .unreadable && status != .same
    }
}

public struct FolderComparisonResult: Sendable {
    public let leftRoot: URL
    public let rightRoot: URL
    public let entries: [FolderEntry]
    /// Number of ignored entries (an ignored directory counts once, without traversing its contents).
    public let ignoredCount: Int
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

public enum FolderComparison {
    public static let ignoredNames: Set<String> = [".git", ".DS_Store", ".build", "node_modules"]

    public static func scan(left: URL, right: URL) throws -> FolderComparisonResult {
        let leftRoot = try canonicalURL(left)
        let rightRoot = try canonicalURL(right)
        guard let leftIdentity = try snapshot(leftRoot), leftIdentity.kind == .directory,
              let rightIdentity = try snapshot(rightRoot), rightIdentity.kind == .directory else {
            throw FolderComparisonError.invalidFolders
        }
        var ignoredCount = 0
        var leftItems: [String: FolderSnapshot] = [:], rightItems: [String: FolderSnapshot] = [:]
        var failures: [String: FolderComparisonError] = [:]
        try walk(root: leftRoot, relative: "", items: &leftItems, failures: &failures, ignored: &ignoredCount)
        try walk(root: rightRoot, relative: "", items: &rightItems, failures: &failures, ignored: &ignoredCount)
        let paths = Set(leftItems.keys).union(rightItems.keys).union(failures.keys)
        var entries = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
            let a = leftItems[path], b = rightItems[path]
            let status: FolderEntryStatus
            if failures[path] != nil { status = .unreadable }
            else if a == nil { status = .rightOnly }
            else if b == nil { status = .leftOnly }
            else if a?.kind != b?.kind { status = .typeMismatch }
            else { status = a?.digest == b?.digest ? .same : .changed }
            return FolderEntry(path: path, status: status, left: a, right: b, failure: failures[path])
        }
        var changedParents = Set<String>()
        for entry in entries where entry.status != .same {
            var components = entry.path.split(separator: "/")
            while components.count > 1 {
                components.removeLast()
                changedParents.insert(components.joined(separator: "/"))
            }
        }
        for index in entries.indices where entries[index].status == .same && entries[index].isDirectory {
            if changedParents.contains(entries[index].path) { entries[index].status = .changed }
        }
        return FolderComparisonResult(leftRoot: leftRoot, rightRoot: rightRoot, entries: entries,
                                      ignoredCount: ignoredCount, leftIdentity: leftIdentity, rightIdentity: rightIdentity)
    }

    private static func walk(root: URL, relative: String, items: inout [String: FolderSnapshot],
                             failures: inout [String: FolderComparisonError], ignored: inout Int) throws {
        try Task.checkCancellation()
        let directory = relative.isEmpty ? root : root.appendingPathComponent(relative)
        do {
            try validateParent(root: root, relative: relative.isEmpty ? "placeholder" : relative + "/placeholder")
            let descriptor = try parentDescriptor(root: root, path: relative.isEmpty ? "placeholder" : relative + "/placeholder", create: false)
            defer { close(descriptor) }
            let names = try childNames(descriptor, path: directory.path)
            for name in names {
                let url = directory.appendingPathComponent(name)
                try Task.checkCancellation()
                if ignoredNames.contains(url.lastPathComponent) { ignored += 1; continue }
                let path = relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent
                do {
                    guard let value = try snapshot(url, parent: descriptor) else { throw FolderComparisonError.stale(path) }
                    items[path] = value
                    if value.kind == .directory { try walk(root: root, relative: path, items: &items, failures: &failures, ignored: &ignored) }
                } catch is CancellationError { throw CancellationError() }
                catch { failures[path] = (error as? FolderComparisonError) ?? .filesystem(path) }
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            if relative.isEmpty { throw error }
            failures[relative] = (error as? FolderComparisonError) ?? .filesystem(relative)
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

    fileprivate static func snapshot(_ url: URL, parent: Int32? = nil) throws -> FolderSnapshot? {
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
        let digest: String
        if kind == .file {
            let descriptor = parent.map { openat($0, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? open(name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw FolderComparisonError.filesystem(url.path) }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino,
                  opened.st_dev == info.st_dev, opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw FolderComparisonError.stale(url.path)
            }
            var hash = SHA256(), bytes = [UInt8](repeating: 0, count: 256 * 1024)
            while true {
                try Task.checkCancellation()
                let count = read(descriptor, &bytes, bytes.count)
                guard count >= 0 else { throw FolderComparisonError.filesystem(url.path) }
                if count == 0 { break }
                hash.update(data: Data(bytes[0..<count]))
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, unchanged(info, after) else { throw FolderComparisonError.stale(url.path) }
            digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        } else if kind == .symbolicLink {
            if let parent {
                var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
                let count = readlinkat(parent, name, &bytes, bytes.count)
                guard count >= 0 else { throw FolderComparisonError.filesystem(url.path) }
                digest = String(decoding: bytes[0..<count], as: UTF8.self)
            } else { digest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path) }
        } else { digest = kind.rawValue }
        return FolderSnapshot(kind: kind, size: Int64(info.st_size), digest: digest, identity: UInt64(info.st_ino),
                              device: info.st_dev, modifiedSeconds: info.st_mtimespec.tv_sec,
                              modifiedNanoseconds: info.st_mtimespec.tv_nsec)
    }

    private static func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_ino == b.st_ino && a.st_dev == b.st_dev && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        guard let resolved = realpath(url.path, nil) else { throw FolderComparisonError.filesystem(url.path) }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    fileprivate static func validateParent(root: URL, relative: String) throws {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw FolderComparisonError.unsafe(relative)
        }
        guard try canonicalURL(root).path == root.path else { throw FolderComparisonError.unsafe(root.path) }
        var path = root
        let components = relative.split(separator: "/").dropLast()
        for component in components {
            path.appendPathComponent(String(component))
            if let item = try snapshot(path), item.kind != .directory { throw FolderComparisonError.unsafe(path.path) }
        }
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
        let entries = comparison.entries.filter { paths.contains($0.path) }
        guard entries.count == paths.count else { throw FolderComparisonError.selectionChanged }
        let actions = try entries.map { entry -> FolderCopyAction in
            guard entry.canCopy(toRight: toRight), let source = toRight ? entry.left : entry.right else {
                throw FolderComparisonError.unsupported(entry.path)
            }
            let target = toRight ? entry.right : entry.left
            return FolderCopyAction(path: entry.path, operation: target == nil ? .add : .overwrite, source: source, target: target)
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
        try validateParent(root: plan.sourceRoot, relative: action.path)
        try validateParent(root: plan.targetRoot, relative: action.path)
        guard try snapshot(plan.sourceRoot.appendingPathComponent(action.path)) == action.source,
              try snapshot(plan.targetRoot.appendingPathComponent(action.path)) == action.target else {
            throw FolderComparisonError.stale(action.path)
        }
    }

    /// Traverses each parent with O_NOFOLLOW so replacing a directory by a link cannot redirect a write.
    private static func parentDescriptor(root: URL, path: String, create: Bool, expectedRoot: FolderSnapshot? = nil) throws -> Int32 {
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
            hash.update(data: Data(bytes[0..<count]))
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < count {
                    let written = write(destination, buffer.baseAddress!.advanced(by: offset), count - offset)
                    guard written > 0 else { throw FolderComparisonError.filesystem(action.path) }
                    offset += written
                }
            }
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
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
