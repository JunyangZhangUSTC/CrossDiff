import Foundation

/// Immutable handle to an object database. Local handles never fetch, check out, stage,
/// or write configuration. A downloaded bare cache is the only refreshable handle.
public struct GitRepository: Sendable {
    public static let maximumCacheBytes = 2 * 1024 * 1024 * 1024
    public static let maximumBlobBytes = 20 * 1024 * 1024
    public let url: URL
    public let isBare: Bool
    public let isRemoteCache: Bool
    private let cacheRemote: GitRemote?
    private struct CacheMarker: Codable { let formatVersion: Int; let remote: String }
    private static let markerName = "crossdiff-cache.json"

    /// The caller supplies an application-owned cache location. The marker prevents a
    /// normal local/bare repository from becoming writable merely because it was opened.
    public static func openCache(_ url: URL, remote: GitRemote, isCancelled: () -> Bool = { false }) throws -> GitRepository {
        guard url.isFileURL, url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw GitError.readOnlyRepository }
        let markerURL = url.appendingPathComponent(markerName)
        let values = try? markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true, (values?.fileSize ?? Int.max) < 8192,
              let data = try? Data(contentsOf: markerURL), let marker = try? JSONDecoder().decode(CacheMarker.self, from: data),
              marker.formatVersion == 1, marker.remote == remote.url else { throw GitError.readOnlyRepository }
        let opened = try open(url, isCancelled: isCancelled)
        guard opened.isBare else { throw GitError.readOnlyRepository }
        return GitRepository(url: opened.url, isBare: true, isRemoteCache: true, cacheRemote: remote)
    }

    public static func open(_ url: URL, isCancelled: () -> Bool = { false }) throws -> GitRepository {
        guard url.isFileURL else { throw GitError.notRepository }
        let directory = url.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw GitError.notRepository }
        do {
            let bare = try string(GitProcess.run(at: directory, arguments: ["rev-parse", "--is-bare-repository"], isCancelled: isCancelled)) == "true"
            let root = try string(GitProcess.run(at: directory, arguments: ["rev-parse", bare ? "--absolute-git-dir" : "--show-toplevel"], isCancelled: isCancelled))
            return GitRepository(url: URL(fileURLWithPath: root, isDirectory: true), isBare: bare, isRemoteCache: false, cacheRemote: nil)
        } catch GitError.commandFailed { throw GitError.notRepository }
    }

    public func references(isCancelled: () -> Bool = { false }) throws -> [GitReference] {
        var result: [GitReference] = []
        try GitProcess.streamRecords(at: url, arguments: ["for-each-ref", "--sort=-committerdate", "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)%00%(*objecttype)", "refs/heads/", "refs/remotes/", "refs/tags/"], separator: 10, isCancelled: isCancelled) { record in
            let parts = record.split(separator: 0, omittingEmptySubsequences: false)
            guard parts.count == 5, let fullName = String(data: Data(parts[0]), encoding: .utf8) else { throw GitError.invalidOutput }
            let directType = String(decoding: parts[2], as: UTF8.self), peeledType = String(decoding: parts[4], as: UTF8.self)
            guard directType == "commit" || peeledType == "commit" else { return }
            let oid = String(decoding: peeledType == "commit" ? parts[3] : parts[1], as: UTF8.self)
            guard Self.validObjectID(oid) else { throw GitError.invalidOutput }
            let prefix: String, kind: GitReferenceKind
            if fullName.hasPrefix("refs/heads/") { prefix = "refs/heads/"; kind = .branch }
            else if fullName.hasPrefix("refs/remotes/") { prefix = "refs/remotes/"; kind = .remoteBranch }
            else { prefix = "refs/tags/"; kind = .tag }
            result.append(GitReference(fullName: fullName, name: String(fullName.dropFirst(prefix.count)), objectID: oid, kind: kind))
        }
        return result
    }

    /// Resolve user input once, before any tree or blob reads. All subsequent commands
    /// receive full immutable object IDs, so branch movement cannot mix snapshots.
    public func resolve(_ revision: String, isCancelled: () -> Bool = { false }) throws -> String {
        guard !revision.isEmpty, revision.utf8.count <= 1024, !revision.hasPrefix("-"),
              !revision.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              !revision.contains(":"), !revision.contains(".."), !revision.contains("@{"), !revision.contains("\\") else { throw GitError.invalidRevision }
        do {
            let value = try Self.string(run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], maximumBytes: 512, isCancelled: isCancelled))
            guard Self.validObjectID(value) else { throw GitError.invalidRevision }
            return value
        } catch GitError.commandFailed { throw GitError.invalidRevision }
    }

    public func commits(revision: String = "HEAD", limit: Int = 200, isCancelled: () -> Bool = { false }) throws -> [GitCommit] {
        let oid: String
        do { oid = try resolve(revision, isCancelled: isCancelled) }
        catch GitError.invalidRevision {
            if revision == "HEAD", try references(isCancelled: isCancelled).isEmpty { return [] }
            throw GitError.invalidRevision
        }
        let data = try run(["log", "--no-show-signature", "--no-notes", "--no-decorate", "--no-mailmap", "-z", "--max-count=\(max(1, min(limit, 2000)))", "--format=%H%x00%ct%x00%an%x00%s", oid, "--"], isCancelled: isCancelled)
        return try Self.parseCommits(data)
    }

    public func compare(left: String, right: String, options: GitComparisonOptions = .init(),
                        isCancelled: () -> Bool = { false }) throws -> GitComparison {
        var leftID = try resolve(left, isCancelled: isCancelled)
        let rightID = try resolve(right, isCancelled: isCancelled)
        var mergeBase: String?
        if options.useMergeBase {
            let bases: String
            do { bases = try Self.string(run(["merge-base", "--all", leftID, rightID], isCancelled: isCancelled)) }
            catch GitError.commandFailed { throw GitError.noMergeBase }
            let ids = bases.split(separator: "\n").map(String.init)
            guard ids.count == 1, let base = ids.first, Self.validObjectID(base) else { throw GitError.ambiguousMergeBase }
            mergeBase = base; leftID = base
        }
        guard let leftCommit = try commits(revision: leftID, limit: 1, isCancelled: isCancelled).first,
              let rightCommit = try commits(revision: rightID, limit: 1, isCancelled: isCancelled).first else { throw GitError.emptyRepository }
        let leftTree = try tree(objectID: leftID, isCancelled: isCancelled)
        let rightTree = try tree(objectID: rightID, isCancelled: isCancelled)
        var remainingLeft: [Data: GitTreeEntry] = [:], remainingRight: [Data: GitTreeEntry] = [:]
        for entry in leftTree { if isCancelled() { throw GitError.cancelled }; remainingLeft[Data(entry.path.utf8)] = entry }
        for entry in rightTree { if isCancelled() { throw GitError.cancelled }; remainingRight[Data(entry.path.utf8)] = entry }
        var files: [GitFileChange] = []
        if options.detectRenames {
            let threshold = max(1, min(options.renameThreshold, 100))
            var status: String?, renameLeft: Data?, similarity: Int?
            try GitProcess.streamRecords(at: url, arguments: ["diff-tree", "--no-commit-id", "--raw", "-r", "-z", "--no-abbrev", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--find-renames=\(threshold)%", "-l1000", leftID, rightID, "--"], isCancelled: isCancelled) { record in
                if status == nil {
                    let header = String(decoding: record, as: UTF8.self).split(separator: " ")
                    guard header.count == 5, header[0].hasPrefix(":") else { throw GitError.invalidOutput }
                    status = String(header[4])
                    if status!.hasPrefix("R") {
                        guard let value = Int(status!.dropFirst()), (0...100).contains(value) else { throw GitError.invalidOutput }
                        similarity = value
                    }
                } else if status!.hasPrefix("R") {
                    if let path = renameLeft {
                        guard let l = remainingLeft.removeValue(forKey: path), let r = remainingRight.removeValue(forKey: record) else { throw GitError.invalidOutput }
                        files.append(GitFileChange(left: l, right: r, kind: .renamed, similarity: similarity))
                        status = nil; renameLeft = nil; similarity = nil
                    } else { renameLeft = record }
                } else { status = nil }
            }
            guard status == nil else { throw GitError.invalidOutput }
        }
        for path in Set(remainingLeft.keys).union(remainingRight.keys) {
            if isCancelled() { throw GitError.cancelled }
            let l = remainingLeft[path], r = remainingRight[path]
            let kind: GitChangeKind
            if l == nil { kind = .added }
            else if r == nil { kind = .deleted }
            else if l!.kind != r!.kind { kind = .typeChanged }
            else if l!.objectID == r!.objectID && l!.mode == r!.mode { kind = .unchanged }
            else { kind = .modified }
            files.append(GitFileChange(left: l, right: r, kind: kind, similarity: nil))
        }
        files = try GitCatalogSort.sorted(files, isCancelled: isCancelled, by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) })
        return GitComparison(leftCommit: leftCommit, rightCommit: rightCommit, leftTree: leftTree, rightTree: rightTree,
                             files: files, mergeBaseObjectID: mergeBase)
    }

    public func tree(objectID: String, isCancelled: () -> Bool = { false }) throws -> [GitTreeEntry] {
        guard Self.validObjectID(objectID) else { throw GitError.invalidRevision }
        var result: [GitTreeEntry] = [], seen = Set<Data>()
        try GitProcess.streamRecords(at: url, arguments: ["ls-tree", "--full-tree", "-r", "-l", "-z", objectID], isCancelled: isCancelled) { record in
            if isCancelled() { throw GitError.cancelled }
            guard let tab = record.firstIndex(of: 9) else { throw GitError.invalidOutput }
            let metadata = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            let pathData = Data(record[record.index(after: tab)...])
            guard let path = String(data: pathData, encoding: .utf8), Data(path.utf8) == pathData else { throw GitError.unsupportedPath }
            guard metadata.count == 4, !path.isEmpty, seen.insert(pathData).inserted else { throw GitError.invalidOutput }
            let mode = String(metadata[0]), type = String(metadata[1]), oid = String(metadata[2])
            guard Self.validObjectID(oid) else { throw GitError.invalidOutput }
            let kind: GitObjectKind
            switch (mode, type) {
            case ("100644", "blob"), ("100755", "blob"): kind = .blob
            case ("120000", "blob"): kind = .symbolicLink
            case ("160000", "commit"): kind = .submodule
            default: throw GitError.invalidOutput
            }
            let size = Int(metadata[3])
            guard kind == .submodule || (size != nil && size! >= 0) else { throw GitError.invalidOutput }
            result.append(GitTreeEntry(path: path, objectID: oid, mode: mode, size: size, kind: kind))
        }
        return result
    }

    /// Reads stored blob bytes; deliberately does not apply textconv, LFS smudge,
    /// .gitattributes filters, symlink traversal, or submodule recursion.
    public func readBlob(entry: GitTreeEntry, maximumBytes: Int = maximumBlobBytes,
                         isCancelled: () -> Bool = { false }) throws -> Data {
        guard entry.kind != .submodule, Self.validObjectID(entry.objectID) else { throw GitError.missingObject }
        let cap = max(0, min(maximumBytes, Self.maximumBlobBytes))
        guard let size = entry.size, size <= cap else { throw GitError.tooLarge }
        do {
            let data = try run(["cat-file", "blob", entry.objectID], maximumBytes: cap, isCancelled: isCancelled)
            guard data.count == size else { throw GitError.invalidOutput }
            return data
        } catch GitError.commandFailed { throw GitError.missingObject }
    }

    public static func clone(remote: GitRemote, to destination: URL, isCancelled: () -> Bool = { false }) throws -> GitRepository {
        guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path) else { throw GitError.destinationExists }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // Only delete the newly allocated temporary clone on failure, never an existing directory.
        let temporary = parent.appendingPathComponent(".crossdiff-clone-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try GitProcess.run(at: parent, arguments: ["clone", "--bare", "--no-local", "--no-hardlinks", "--no-recurse-submodules", "--template=", "--", remote.url, temporary.path], network: true, timeout: 300, isCancelled: isCancelled,
                               checkResources: { try enforceCacheLimit(temporary, isCancelled: isCancelled) })
        try enforceCacheLimit(temporary, isCancelled: isCancelled)
        try JSONEncoder().encode(CacheMarker(formatVersion: 1, remote: remote.url)).write(to: temporary.appendingPathComponent(markerName), options: .atomic)
        if isCancelled() { throw GitError.cancelled }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw GitError.destinationExists }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return GitRepository(url: destination.standardizedFileURL, isBare: true, isRemoteCache: true, cacheRemote: remote)
    }

    public func refresh(remote: GitRemote, isCancelled: () -> Bool = { false }) throws {
        guard isRemoteCache, isBare, cacheRemote == remote else { throw GitError.readOnlyRepository }
        // A cached handle may outlive external filesystem changes. Recheck ownership
        // and symlink boundaries immediately before a mutating fetch.
        _ = try Self.openCache(url, remote: remote, isCancelled: isCancelled)
        try Self.enforceCacheLimit(url, isCancelled: isCancelled)
        _ = try GitProcess.run(at: url, arguments: ["fetch", "--atomic", "--prune", "--no-recurse-submodules", "--no-write-fetch-head", "--no-auto-maintenance", "--", remote.url, "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"], network: true, timeout: 300, isCancelled: isCancelled,
                               checkResources: { try Self.enforceCacheLimit(url, isCancelled: isCancelled) })
        try Self.enforceCacheLimit(url, isCancelled: isCancelled)
    }

    private static func enforceCacheLimit(_ url: URL, isCancelled: () -> Bool) throws {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey]) else { return }
        var bytes = 0, count = 0
        for case let item as URL in enumerator {
            if isCancelled() { throw GitError.cancelled }
            count += 1
            guard count < 200_000 else { throw GitError.tooLarge }
            let values = try item.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true { throw GitError.readOnlyRepository }
            if values.isRegularFile == true {
                guard let size = values.fileSize, size >= 0, size <= maximumCacheBytes - bytes else { throw GitError.tooLarge }
                bytes += size
            }
        }
    }

    private func run(_ args: [String], maximumBytes: Int = GitProcess.maximumOutput,
                     isCancelled: () -> Bool) throws -> Data {
        try GitProcess.run(at: url, arguments: args, maximumBytes: maximumBytes, isCancelled: isCancelled)
    }
    private static func string(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else { throw GitError.invalidOutput }
        return value.hasSuffix("\n") ? String(value.dropLast()) : value
    }
    static func validObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func parseCommits(_ data: Data) throws -> [GitCommit] {
        if data.isEmpty { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count % 4 == 0 else { throw GitError.invalidOutput }
        return try stride(from: 0, to: fields.count, by: 4).map { index in
            let oid = String(decoding: fields[index], as: UTF8.self)
            guard validObjectID(oid), let timestamp = TimeInterval(String(decoding: fields[index + 1], as: UTF8.self)) else { throw GitError.invalidOutput }
            return GitCommit(objectID: oid, subject: String(decoding: fields[index + 3], as: UTF8.self),
                             author: String(decoding: fields[index + 2], as: UTF8.self), date: Date(timeIntervalSince1970: timestamp))
        }
    }
}
