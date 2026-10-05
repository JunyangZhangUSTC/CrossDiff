import Foundation
import CryptoKit
import Darwin

// These stamps are not a replacement for content verification. Working-tree previews
// verify both the captured identity and a freshly calculated Git blob digest.
struct GitFileStamp: Equatable, Sendable {
    let device: UInt64, inode: UInt64, size: Int64, mode: UInt32
    let modifiedSeconds: Int64, modifiedNanos: Int64, changedSeconds: Int64, changedNanos: Int64
    init(_ info: stat) {
        device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size); mode = UInt32(info.st_mode)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanos = Int64(info.st_ctimespec.tv_nsec)
    }
    var type: UInt32 { mode & UInt32(S_IFMT) }
    func sameNode(as other: GitFileStamp) -> Bool { device == other.device && inode == other.inode && type == other.type }
}
struct GitWorkingFileRecord: Sendable {
    let path: String
    let stamp: GitFileStamp
    let objectID: String
}
private struct GitIndexCapture {
    let all: [GitTreeEntry]
    let staged: [GitTreeEntry]
    let skipPaths: Set<Data>
    let indexURL: URL
    let indexStamp: GitFileStamp?
}

extension GitRepository {
    /// Captures commit, stage-0 index and on-disk working sources without writing an
    /// index, temporary tree, object, or checkout into the selected repository.
    public func compareSources(left: GitComparisonSource, right: GitComparisonSource,
                               options: GitComparisonOptions = .init(), includeUntracked: Bool = true,
                               isCancelled: () -> Bool = { false },
                               progress: @Sendable (GitScanProgress) -> Void = { _ in }) throws -> GitSourceComparison {
        if options.useMergeBase && (!left.isCommit || !right.isCommit) { throw GitError.localMergeBase }
        if case .commit(let l) = left, case .commit(let r) = right {
            do {
                let comparison = try compare(left: l, right: r, options: options, isCancelled: isCancelled)
                return GitSourceComparison(leftSnapshot: commitSnapshot(source: options.useMergeBase ? .commit(comparison.leftCommit.objectID) : left, commit: comparison.leftCommit, entries: comparison.leftTree),
                    rightSnapshot: commitSnapshot(source: right, commit: comparison.rightCommit, entries: comparison.rightTree),
                    files: comparison.files, mergeBaseObjectID: comparison.mergeBaseObjectID)
            } catch GitError.invalidRevision {
                // Only an unborn HEAD is an empty baseline; a misspelled or missing
                // historical revision still fails rather than becoming an empty tree.
                guard (l == "HEAD" || r == "HEAD"), try hasUnbornHEAD(isCancelled: isCancelled) else { throw GitError.invalidRevision }
                if options.useMergeBase { throw GitError.noMergeBase }
            }
        }
        guard (left.isCommit && right.isCommit) || !isBare else { throw GitError.bareLocalSource }
        let format = try objectFormat(isCancelled: isCancelled)
        let index = (!left.isCommit || !right.isCommit) ? try captureIndex(format: format, isCancelled: isCancelled) : nil
        var capturedWorktree: GitComparisonSnapshot?
        func capture(_ source: GitComparisonSource) throws -> GitComparisonSnapshot {
            switch source {
            case .commit(let revision):
                do {
                    let oid = try resolve(revision, isCancelled: isCancelled)
                    guard let commit = try commits(revision: oid, limit: 1, isCancelled: isCancelled).first else { throw GitError.invalidRevision }
                    return try commitSnapshot(source: source, commit: commit, entries: tree(objectID: oid, isCancelled: isCancelled))
                } catch GitError.invalidRevision {
                    guard revision == "HEAD", try hasUnbornHEAD(isCancelled: isCancelled) else { throw GitError.invalidRevision }
                    return GitComparisonSnapshot(source: source, commit: nil, identity: "empty-head", entries: [], isEmptyBaseline: true,
                        repositoryPath: url.path, workingFiles: [:], rootStamp: nil, indexBackedPaths: [])
                }
            case .index:
                guard let index else { throw GitError.invalidOutput }
                return GitComparisonSnapshot(source: source, commit: nil, identity: try snapshotIdentity(index.staged, prefix: "index", isCancelled: isCancelled),
                    entries: index.staged, isEmptyBaseline: false, repositoryPath: url.path, workingFiles: [:], rootStamp: nil, indexBackedPaths: [])
            case .workingTree:
                if let capturedWorktree { return capturedWorktree }
                guard let index else { throw GitError.invalidOutput }
                let snapshot = try captureWorkingTree(index: index, format: format, includeUntracked: includeUntracked, isCancelled: isCancelled, progress: progress)
                capturedWorktree = snapshot
                return snapshot
            }
        }
        let l = try capture(left), r = try capture(right)
        if let index { try verifyIndex(index) }
        if let capturedWorktree { try verifyWorkingTree(capturedWorktree, isCancelled: isCancelled) }
        let files = try exactChanges(left: l.entries, right: r.entries, detectRenames: options.detectRenames, isCancelled: isCancelled)
        return GitSourceComparison(leftSnapshot: l, rightSnapshot: r, files: files, mergeBaseObjectID: nil)
    }

    /// Reads the bytes belonging to the captured source, not whichever index or file
    /// happens to exist now. Working files that changed after capture require refresh.
    public func readContent(entry: GitTreeEntry, in snapshot: GitComparisonSnapshot,
                            maximumBytes: Int = maximumBlobBytes, isCancelled: () -> Bool = { false }) throws -> Data {
        guard snapshot.repositoryPath == url.path,
              let captured = snapshot.entries.first(where: { Data($0.path.utf8) == Data(entry.path.utf8) }),
              captured.objectID == entry.objectID, captured.mode == entry.mode else { throw GitError.snapshotChanged }
        guard snapshot.source == .workingTree, !snapshot.indexBackedPaths.contains(Data(entry.path.utf8)) else {
            return try readBlob(entry: entry, maximumBytes: maximumBytes, isCancelled: isCancelled)
        }
        guard let record = snapshot.workingFiles[Data(entry.path.utf8)], let rootStamp = snapshot.rootStamp else { throw GitError.missingObject }
        let root = try GitWorkingAccess(root: url)
        defer { root.close() }
        guard root.stamp.sameNode(as: rootStamp) else { throw GitError.snapshotChanged }
        let loaded = try root.read(record.path, expected: record.stamp, format: entry.objectID.count == 64 ? "sha256" : "sha1",
                                   maximumBytes: max(0, min(maximumBytes, Self.maximumBlobBytes)), collect: true, isCancelled: isCancelled)
        guard loaded?.objectID == entry.objectID, let content = loaded?.content else { throw GitError.snapshotChanged }
        return content
    }

    private func commitSnapshot(source: GitComparisonSource, commit: GitCommit, entries: [GitTreeEntry]) -> GitComparisonSnapshot {
        GitComparisonSnapshot(source: source, commit: commit, identity: "commit:" + commit.objectID, entries: entries, isEmptyBaseline: false,
                              repositoryPath: url.path, workingFiles: [:], rootStamp: nil, indexBackedPaths: [])
    }
    private func hasUnbornHEAD(isCancelled: () -> Bool) throws -> Bool {
        do {
            _ = try localGit(["rev-parse", "--verify", "--quiet", "HEAD"], isCancelled: isCancelled)
            return false
        } catch GitError.commandFailed {
            do {
                let ref = String(decoding: try localGit(["symbolic-ref", "--quiet", "HEAD"], isCancelled: isCancelled), as: UTF8.self)
                return ref.hasPrefix("refs/heads/")
            } catch GitError.commandFailed { return false }
        }
    }
    private func objectFormat(isCancelled: () -> Bool) throws -> String {
        let bytes = try localGit(["rev-parse", "--show-object-format"], isCancelled: isCancelled)
        let value = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard value == "sha1" || value == "sha256" else { throw GitError.invalidOutput }
        return value
    }
    private func captureIndex(format: String, isCancelled: () -> Bool) throws -> GitIndexCapture {
        let indexPathData = try localGit(["rev-parse", "--path-format=absolute", "--git-path", "index"], isCancelled: isCancelled)
        guard var indexPath = String(data: indexPathData, encoding: .utf8) else { throw GitError.invalidOutput }
        if indexPath.hasSuffix("\n") { indexPath.removeLast() }
        let indexURL = URL(fileURLWithPath: indexPath)
        let before = try GitWorkingAccess.stamp(at: indexURL)
        var entries: [GitTreeEntry] = [], seen = Set<Data>()
        // The stable --stage protocol also works with older Apple Git versions;
        // ls-files --format objectsize and hex escapes are version-dependent.
        try localRecords(["ls-files", "--cached", "--stage", "--full-name", "-z"], isCancelled: isCancelled) { record in
            if isCancelled() { throw GitError.cancelled }
            guard let tab = record.firstIndex(of: 9) else { throw GitError.invalidOutput }
            let parts = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            guard parts.count == 3, let stage = Int(parts[2]) else { throw GitError.invalidOutput }
            guard stage == 0 else { throw GitError.unmergedIndex }
            let rawPath = Data(record[record.index(after: tab)...])
            let path = try GitWorkingAccess.path(rawPath)
            guard seen.insert(rawPath).inserted else { throw GitError.invalidOutput }
            let mode = String(parts[0]), oid = String(parts[1])
            guard Self.validObjectID(oid) else { throw GitError.invalidOutput }
            let kind: GitObjectKind
            switch mode {
            case "100644", "100755": kind = .blob
            case "120000": kind = .symbolicLink
            case "160000": kind = .submodule
            default: throw GitError.invalidOutput
            }
            entries.append(GitTreeEntry(path: path, objectID: oid, mode: mode, size: nil, kind: kind))
        }
        entries = try indexObjectSizes(entries, isCancelled: isCancelled)
        // Diff against Git's canonical empty tree does not require creating an object.
        // --ita-invisible excludes `git add -N` placeholders without parsing the index
        // format or unstable human-readable `ls-files --debug` flags.
        let emptyTree = GitObjectDigest.digest(Data("tree 0\0".utf8), format: format)
        var stagedPaths = Set<Data>(), expectingPath = false
        try localRecords(["diff", "--cached", "--raw", "-z", "--no-abbrev", "--no-renames", "--no-ext-diff", "--no-textconv",
            "--ignore-submodules=none", "--ita-invisible-in-index", emptyTree, "--"], isCancelled: isCancelled) { record in
            if expectingPath {
                guard seen.contains(record) else { throw GitError.snapshotChanged }
                stagedPaths.insert(record); expectingPath = false
            } else {
                let header = String(decoding: record, as: UTF8.self).split(separator: " ")
                guard header.count == 5, header[4] == "A" else { throw GitError.invalidOutput }
                expectingPath = true
            }
        }
        guard !expectingPath else { throw GitError.invalidOutput }
        var skipped = Set<Data>()
        try localRecords(["ls-files", "--cached", "--full-name", "-t", "-z"], isCancelled: isCancelled) { record in
            guard record.count >= 3, record[record.startIndex + 1] == 32 else { throw GitError.invalidOutput }
            if record.first == 83 { skipped.insert(Data(record.dropFirst(2))) }
        }
        var staged: [GitTreeEntry] = []
        for entry in entries {
            if isCancelled() { throw GitError.cancelled }
            if stagedPaths.contains(Data(entry.path.utf8)) { staged.append(entry) }
        }
        let result = GitIndexCapture(all: entries, staged: staged, skipPaths: skipped, indexURL: indexURL, indexStamp: before)
        try verifyIndex(result)
        return result
    }
    private func indexObjectSizes(_ entries: [GitTreeEntry], isCancelled: () -> Bool) throws -> [GitTreeEntry] {
        // Only inspect referenced blobs, never scan the whole object database or
        // spawn one process per file. Repeated content shares a single size lookup.
        var objectIDs: [String] = [], seen = Set<String>(), sizes: [String: Int] = [:]
        for entry in entries {
            if isCancelled() { throw GitError.cancelled }
            if entry.kind != .submodule, seen.insert(entry.objectID).inserted { objectIDs.append(entry.objectID) }
        }
        for start in stride(from: 0, to: objectIDs.count, by: 128) {
            if isCancelled() { throw GitError.cancelled }
            let batch = objectIDs[start..<min(start + 128, objectIDs.count)]
            let input = Data((batch.joined(separator: "\n") + "\n").utf8)
            let output = try GitProcess.run(at: url,
                arguments: ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
                input: input, maximumBytes: batch.count * 128, isCancelled: isCancelled)
            guard output.last == 10 else { throw GitError.invalidOutput }
            let records = output.dropLast().split(separator: 10, omittingEmptySubsequences: false)
            guard records.count == batch.count else { throw GitError.invalidOutput }
            for (oid, record) in zip(batch, records) {
                let fields = String(decoding: record, as: UTF8.self).split(separator: " ")
                guard fields.first.map(String.init) == oid else { throw GitError.invalidOutput }
                if fields.count == 2, fields[1] == "missing" { throw GitError.missingObject }
                guard fields.count == 3, fields[1] == "blob",
                      let size = Int(fields[2]), size >= 0 else { throw GitError.invalidOutput }
                sizes[oid] = size
            }
        }
        return try entries.map { entry in
            if isCancelled() { throw GitError.cancelled }
            let size = sizes[entry.objectID]
            guard entry.kind == .submodule || size != nil else { throw GitError.missingObject }
            return GitTreeEntry(path: entry.path, objectID: entry.objectID, mode: entry.mode, size: size, kind: entry.kind)
        }
    }
    private func verifyIndex(_ capture: GitIndexCapture) throws {
        guard try GitWorkingAccess.stamp(at: capture.indexURL) == capture.indexStamp else { throw GitError.snapshotChanged }
    }
    private func captureWorkingTree(index: GitIndexCapture, format: String, includeUntracked: Bool,
                                    isCancelled: () -> Bool, progress: @Sendable (GitScanProgress) -> Void) throws -> GitComparisonSnapshot {
        let access = try GitWorkingAccess(root: url)
        defer { access.close() }
        func cancelled() -> Bool { isCancelled() }
        func check() throws {
            if isCancelled() { throw GitError.cancelled }
        }
        let trustFileMode: Bool
        do {
            trustFileMode = String(decoding: try localGit(["config", "--bool", "--get", "core.filemode"], isCancelled: isCancelled), as: UTF8.self).trimmingCharacters(in: .newlines) != "false"
        } catch GitError.commandFailed { trustFileMode = true }
        var candidates: [Data: GitTreeEntry] = [:]
        for entry in index.all { try check(); candidates[Data(entry.path.utf8)] = entry }
        var untrackedHash = SHA256()
        if includeUntracked {
            try localRecords(["ls-files", "--others", "--exclude-standard", "--full-name", "-z"], isCancelled: isCancelled) { record in
                untrackedHash.update(data: record); untrackedHash.update(data: Data([0]))
                let path = try GitWorkingAccess.path(record)
                if candidates[record] == nil { candidates[record] = GitTreeEntry(path: path, objectID: "", mode: "", size: nil, kind: .blob) }
            }
        }
        let untrackedDigest = untrackedHash.finalize()
        var entries: [GitTreeEntry] = [], records: [Data: GitWorkingFileRecord] = [:], backed = Set<Data>(), missing = [String]()
        var bytesRead: UInt64 = 0, filesScanned = 0
        progress(GitScanProgress(bytesRead: 0, filesScanned: 0, currentPath: nil))
        for key in try GitCatalogSort.sorted(candidates.keys, isCancelled: isCancelled, by: { $0.lexicographicallyPrecedes($1) }) {
            try check()
            let candidate = candidates[key]!
            defer {
                filesScanned += 1
                progress(GitScanProgress(bytesRead: bytesRead, filesScanned: filesScanned, currentPath: candidate.path))
            }
            // Nested repository state is outside this snapshot. Keep the stage-0
            // gitlink without inspecting/following its directory or running nested Git.
            if candidate.kind == .submodule { entries.append(candidate); backed.insert(key); continue }
            guard let stat = try access.stat(candidate.path), stat.type != UInt32(S_IFDIR) else {
                if index.skipPaths.contains(key) {
                    entries.append(candidate); backed.insert(key)
                } else { missing.append(candidate.path) }
                continue
            }
            guard stat.size >= 0 else { throw GitError.invalidOutput }
            let read = try access.read(candidate.path, expected: stat, format: format, maximumBytes: nil, collect: false, isCancelled: cancelled, check: check) { amount in
                let (total, overflow) = bytesRead.addingReportingOverflow(UInt64(amount))
                guard !overflow else { throw GitError.invalidOutput }
                bytesRead = total
                progress(GitScanProgress(bytesRead: bytesRead, filesScanned: filesScanned, currentPath: candidate.path))
            }
            guard let read else { throw GitError.snapshotChanged }
            let kind: GitObjectKind = read.stamp.type == UInt32(S_IFLNK) ? .symbolicLink : .blob
            let mode: String
            if kind == .symbolicLink { mode = "120000" }
            else if !trustFileMode { mode = candidate.kind == .blob && !candidate.mode.isEmpty ? candidate.mode : "100644" }
            else { mode = read.stamp.mode & 0o100 == 0 ? "100644" : "100755" }
            entries.append(GitTreeEntry(path: candidate.path, objectID: read.objectID, mode: mode, size: Int(read.stamp.size), kind: kind))
            records[key] = GitWorkingFileRecord(path: candidate.path, stamp: read.stamp, objectID: read.objectID)
        }
        try verifyIndex(index)
        if includeUntracked {
            var verification = SHA256()
            try localRecords(["ls-files", "--others", "--exclude-standard", "--full-name", "-z"], isCancelled: isCancelled) { record in
                verification.update(data: record); verification.update(data: Data([0]))
            }
            guard verification.finalize() == untrackedDigest else { throw GitError.snapshotChanged }
        }
        for path in missing {
            try check()
            if let current = try access.stat(path), current.type != UInt32(S_IFDIR) { throw GitError.snapshotChanged }
        }
        let snapshot = GitComparisonSnapshot(source: .workingTree, commit: nil, identity: try snapshotIdentity(entries, prefix: "working-tree", isCancelled: isCancelled), entries: entries,
            isEmptyBaseline: false, repositoryPath: url.path, workingFiles: records, rootStamp: access.stamp, indexBackedPaths: backed)
        try verifyWorkingTree(snapshot, isCancelled: isCancelled)
        return snapshot
    }
    private func verifyWorkingTree(_ snapshot: GitComparisonSnapshot, isCancelled: () -> Bool) throws {
        let access = try GitWorkingAccess(root: url)
        defer { access.close() }
        guard let rootStamp = snapshot.rootStamp, access.stamp.sameNode(as: rootStamp) else { throw GitError.snapshotChanged }
        for record in snapshot.workingFiles.values {
            if isCancelled() { throw GitError.cancelled }
            guard try access.stat(record.path) == record.stamp else { throw GitError.snapshotChanged }
        }
    }
    private func localRecords(_ args: [String], isCancelled: () -> Bool, onRecord: (Data) throws -> Void) throws {
        try GitProcess.streamRecords(at: url, arguments: args, isCancelled: isCancelled, onRecord: onRecord)
    }
    private func localGit(_ args: [String], isCancelled: () -> Bool) throws -> Data {
        try GitProcess.run(at: url, arguments: args, isCancelled: isCancelled)
    }
    private func snapshotIdentity(_ entries: [GitTreeEntry], prefix: String, isCancelled: () -> Bool) throws -> String {
        var hash = SHA256()
        for entry in try GitCatalogSort.sorted(entries, isCancelled: isCancelled, by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            if isCancelled() { throw GitError.cancelled }
            hash.update(data: Data((entry.path + "\0" + entry.mode + "\0" + entry.objectID + "\0").utf8))
        }
        return prefix + ":" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func exactChanges(left: [GitTreeEntry], right: [GitTreeEntry], detectRenames: Bool,
                              isCancelled: () -> Bool) throws -> [GitFileChange] {
        var ls: [Data: GitTreeEntry] = [:], rs: [Data: GitTreeEntry] = [:]
        for entry in left { if isCancelled() { throw GitError.cancelled }; ls[Data(entry.path.utf8)] = entry }
        for entry in right { if isCancelled() { throw GitError.cancelled }; rs[Data(entry.path.utf8)] = entry }
        var changes: [GitFileChange] = []
        if detectRenames {
            var leftByHash: [String: [GitTreeEntry]] = [:], rightByHash: [String: [GitTreeEntry]] = [:]
            for (path, entry) in ls {
                if isCancelled() { throw GitError.cancelled }
                if rs[path] == nil {
                    let key = entry.kind.rawValue + ":" + entry.objectID
                    if (leftByHash[key]?.count ?? 0) < 2 { leftByHash[key, default: []].append(entry) }
                }
            }
            for (path, entry) in rs {
                if isCancelled() { throw GitError.cancelled }
                if ls[path] == nil {
                    let key = entry.kind.rawValue + ":" + entry.objectID
                    if (rightByHash[key]?.count ?? 0) < 2 { rightByHash[key, default: []].append(entry) }
                }
            }
            for (hash, originals) in leftByHash {
                if isCancelled() { throw GitError.cancelled }
                guard originals.count == 1, let targets = rightByHash[hash], targets.count == 1 else { continue }
                let l = originals[0], r = targets[0]
                changes.append(GitFileChange(left: l, right: r, kind: .renamed, similarity: 100))
                ls.removeValue(forKey: Data(l.path.utf8)); rs.removeValue(forKey: Data(r.path.utf8))
            }
        }
        for path in Set(ls.keys).union(rs.keys) {
            if isCancelled() { throw GitError.cancelled }
            let l = ls[path], r = rs[path], kind: GitChangeKind
            if l == nil { kind = .added }
            else if r == nil { kind = .deleted }
            else if l!.kind != r!.kind { kind = .typeChanged }
            else if l!.objectID == r!.objectID && l!.mode == r!.mode { kind = .unchanged }
            else { kind = .modified }
            changes.append(GitFileChange(left: l, right: r, kind: kind, similarity: nil))
        }
        return try GitCatalogSort.sorted(changes, isCancelled: isCancelled, by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) })
    }
}

private enum GitObjectDigest {
    static func digest(_ bytes: Data, format: String) -> String {
        if format == "sha256" { return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        return Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Descriptor-relative access rejects symlinks in every parent component. This is
/// needed even after Git enumerates a safe path: a directory can change mid-scan.
private final class GitWorkingAccess {
    let descriptor: Int32
    let stamp: GitFileStamp
    init(root: URL) throws {
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw GitError.unsafeWorkingPath }
        // The repository handle stores a canonical absolute URL. Rewalk it with
        // descriptors too, so a replaced ancestor cannot redirect a later preview.
        for component in root.standardizedFileURL.path.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw GitError.unsafeWorkingPath }
            fd = next
        }
        descriptor = fd
        var info = Darwin.stat()
        guard fstat(descriptor, &info) == 0 else { Darwin.close(descriptor); throw GitError.unsafeWorkingPath }
        stamp = GitFileStamp(info)
    }
    func close() { Darwin.close(descriptor) }
    static func path(_ data: Data) throws -> String {
        guard let path = String(data: data, encoding: .utf8), Data(path.utf8) == data else { throw GitError.unsupportedPath }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".git" }),
              !path.utf8.contains(0) else { throw GitError.unsafeWorkingPath }
        return path
    }
    static func stamp(at url: URL) throws -> GitFileStamp? {
        var info = Darwin.stat()
        if lstat(url.path, &info) == 0 {
            let stamp = GitFileStamp(info)
            guard stamp.type == UInt32(S_IFREG) else { throw GitError.unsafeWorkingPath }
            return stamp
        }
        if errno == ENOENT { return nil }
        throw GitError.unsafeWorkingPath
    }
    private func parent(_ path: String) throws -> (Int32, String)? {
        _ = try Self.path(Data(path.utf8))
        let parts = path.split(separator: "/").map(String.init)
        var fd = dup(descriptor)
        guard fd >= 0 else { throw GitError.unsafeWorkingPath }
        for component in parts.dropLast() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            if next < 0 {
                var info = Darwin.stat()
                let isLink = fstatat(fd, component, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
                Darwin.close(fd)
                if isLink { throw GitError.unsafeWorkingPath }
                if code == ENOENT || code == ENOTDIR { return nil }
                throw GitError.unsafeWorkingPath
            }
            Darwin.close(fd)
            fd = next
        }
        return (fd, parts.last!)
    }
    func stat(_ path: String) throws -> GitFileStamp? {
        guard let (parent, name) = try parent(path) else { return nil }
        defer { Darwin.close(parent) }
        var info = Darwin.stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return GitFileStamp(info) }
        if errno == ENOENT || errno == ENOTDIR { return nil }
        throw GitError.unsafeWorkingPath
    }
    struct Read { let stamp: GitFileStamp; let objectID: String; let content: Data? }
    func read(_ path: String, expected: GitFileStamp, format: String, maximumBytes: Int?, collect: Bool,
              isCancelled: () -> Bool, check: () throws -> Void = {}, onRead: (Int) throws -> Void = { _ in }) throws -> Read? {
        if isCancelled() { throw GitError.cancelled }
        guard expected.size >= 0 else { throw GitError.invalidOutput }
        if let maximumBytes, expected.size > maximumBytes { throw GitError.tooLarge }
        guard let (parent, name) = try parent(path) else { throw GitError.snapshotChanged }
        defer { Darwin.close(parent) }
        var info = Darwin.stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, GitFileStamp(info) == expected else { throw GitError.snapshotChanged }
        var sha1 = Insecure.SHA1(), sha256 = SHA256()
        let header = Data("blob \(expected.size)\0".utf8)
        if format == "sha256" { sha256.update(data: header) } else { sha1.update(data: header) }
        var content = Data()
        if expected.type == UInt32(S_IFLNK) {
            guard expected.size <= 1024 * 1024 else { throw GitError.invalidOutput }
            var bytes = [UInt8](repeating: 0, count: Int(expected.size) + 1)
            let count = readlinkat(parent, name, &bytes, bytes.count)
            guard count == expected.size else { throw GitError.snapshotChanged }
            let data = Data(bytes.prefix(count))
            if format == "sha256" { sha256.update(data: data) } else { sha1.update(data: data) }
            if collect { content = data }
            try onRead(count)
        } else if expected.type == UInt32(S_IFREG) {
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw GitError.snapshotChanged }
            defer { Darwin.close(fd) }
            guard fstat(fd, &info) == 0, GitFileStamp(info) == expected else { throw GitError.snapshotChanged }
            var count = 0, buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                if isCancelled() { throw GitError.cancelled }; try check()
                let amount = Darwin.read(fd, &buffer, buffer.count)
                if amount == 0 { break }
                if amount < 0 { if errno == EINTR { continue }; throw GitError.snapshotChanged }
                guard amount <= Int.max - count else { throw GitError.invalidOutput }
                if let maximumBytes, amount > maximumBytes - count { throw GitError.tooLarge }
                count += amount
                let data = Data(buffer.prefix(amount))
                if format == "sha256" { sha256.update(data: data) } else { sha1.update(data: data) }
                if collect { content.append(data) }
                try onRead(amount)
            }
            guard count == expected.size, fstat(fd, &info) == 0, GitFileStamp(info) == expected else { throw GitError.snapshotChanged }
        } else { throw GitError.unsupportedWorkingFile }
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, GitFileStamp(info) == expected,
              try stat(path) == expected else { throw GitError.snapshotChanged }
        let oid = format == "sha256" ? sha256.finalize().map { String(format: "%02x", $0) }.joined() : sha1.finalize().map { String(format: "%02x", $0) }.joined()
        return Read(stamp: expected, objectID: oid, content: collect ? content : nil)
    }
}
