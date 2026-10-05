import Foundation
import CrossDiffCore

/// The sole bridge from native Git snapshots to the restricted comparison plugin.
/// Complete file pairs are batched; no repository-wide tree JSON or result JSON is built.
/// File content, repository locations and Git execution never enter the JavaScript runtime.
enum GitPluginComparison {
    typealias Progress = @Sendable (_ verifiedFiles: Int, _ totalFiles: Int) -> Void

    static func compare(_ comparison: GitComparison, execution: PluginExecution,
                        progress: Progress? = nil) async throws -> GitPluginValidatedResult {
        try await compare(left: Source(commit: comparison.leftCommit), right: Source(commit: comparison.rightCommit),
            leftTree: comparison.leftTree, rightTree: comparison.rightTree, files: comparison.files,
            execution: execution, progress: progress)
    }

    static func compare(_ comparison: GitSourceComparison, execution: PluginExecution,
                        progress: Progress? = nil) async throws -> GitPluginValidatedResult {
        try await compare(left: Source(snapshot: comparison.leftSnapshot), right: Source(snapshot: comparison.rightSnapshot),
            leftTree: comparison.leftTree, rightTree: comparison.rightTree, files: comparison.files,
            execution: execution, progress: progress)
    }

    private struct Source {
        let source: GitPluginSource
        let identity: String
        let commit: String?
        let emptyBaseline: Bool
        let name: String
        init(commit: GitCommit) {
            source = .commit; identity = "commit:" + commit.objectID
            self.commit = commit.objectID; emptyBaseline = false; name = commit.shortID
        }
        init(snapshot: GitComparisonSnapshot) {
            switch snapshot.source {
            case .commit: source = .commit
            case .index: source = .index
            case .workingTree: source = .workingTree
            }
            identity = snapshot.identity; commit = snapshot.commit?.objectID
            emptyBaseline = snapshot.isEmptyBaseline; name = snapshot.displayName
        }
        func input(_ entries: [GitTreeEntry], role: PluginInputRole) -> PluginInput {
            PluginInput(id: role.rawValue, role: role, name: name,
                content: GitPluginContract.content(source: source, snapshot: identity, commit: commit,
                    emptyBaseline: emptyBaseline,
                    entries: entries.map { GitPluginEntry(path: $0.path, objectID: $0.objectID, mode: $0.mode) }))
        }
    }

    private struct Pair: Hashable {
        let left: Data?
        let right: Data?
        init(left: String?, right: String?) {
            self.left = left.map { Data($0.utf8) }; self.right = right.map { Data($0.utf8) }
        }
        init(_ change: GitFileChange) { self.init(left: change.left?.path, right: change.right?.path) }
        init(_ row: GitPluginRow) { self.init(left: row.left, right: row.right) }
    }

    private static func compare(left: Source, right: Source, leftTree: [GitTreeEntry], rightTree: [GitTreeEntry],
                                files: [GitFileChange], execution: PluginExecution,
                                progress: Progress?) async throws -> GitPluginValidatedResult {
        try Task.checkCancellation()
        guard execution.package.manifest.inputKind == .gitRepository else {
            throw PluginValidationError.invalidField("Git plugin input kind")
        }
        // Validate the full pairing graph before slicing, so omissions and a same-path
        // pair split into fake deletion/addition batches cannot be hidden by batching.
        try validateGlobalPairs(files, leftTree: leftTree, rightTree: rightTree, left: left, right: right)
        var rows: [GitPluginRow] = []
        rows.reserveCapacity(files.count)
        var start = 0
        repeat {
            try Task.checkCancellation()
            let end = min(start + GitPluginContract.maximumBatchEntries, files.count)
            let batch = files[start..<end]
            let inputs = [left.input(batch.compactMap(\.left), role: .left),
                          right.input(batch.compactMap(\.right), role: .right)]
            let hints = try batch.filter { $0.kind == .renamed }.map { change -> PluginJSONValue in
                guard let l = change.left?.path, let r = change.right?.path else {
                    throw PluginValidationError.invalidField("Git native rename sources")
                }
                return GitPluginRename(left: l, right: r).value
            }
            // Every batch, including an empty repository, uses the actual restricted helper.
            // Its request/output/memory/timeout limits remain unchanged.
            let result = try await execution.compare(inputs, options: ["renameHints": .array(hints)])
            try Task.checkCancellation()
            let validated = try GitPluginValidatedResult.parse(result)
            var byPair: [Pair: GitPluginRow] = [:]
            for row in validated.rows {
                guard byPair.updateValue(row, forKey: Pair(row)) == nil else {
                    throw PluginValidationError.invalidField("Git duplicate batch result")
                }
            }
            guard byPair.count == batch.count else { throw PluginValidationError.invalidField("Git batch result coverage") }
            // Preserve native tree order and require both independent classifications to agree.
            for change in batch {
                guard let row = byPair[Pair(change)], row.state.rawValue == change.kind.rawValue else {
                    throw PluginValidationError.invalidField("Git batch result pairing / classification")
                }
                rows.append(row)
            }
            start = end
            progress?(rows.count, files.count)
            try Task.checkCancellation()
        } while start < files.count
        guard rows.count == files.count else { throw PluginValidationError.invalidField("Git aggregate coverage") }
        let result = GitPluginValidatedResult.aggregate(rows)
        try Task.checkCancellation()
        return result
    }

    private static func validateGlobalPairs(_ files: [GitFileChange], leftTree: [GitTreeEntry], rightTree: [GitTreeEntry],
                                            left: Source, right: Source) throws {
        func index(_ tree: [GitTreeEntry]) throws -> [Data: GitTreeEntry] {
            var result: [Data: GitTreeEntry] = [:]
            result.reserveCapacity(tree.count)
            for (offset, entry) in tree.enumerated() {
                if offset % 256 == 0 { try Task.checkCancellation() }
                guard result.updateValue(entry, forKey: Data(entry.path.utf8)) == nil else {
                    throw PluginValidationError.invalidField("Git duplicate snapshot entry")
                }
            }
            // A file/child collision must not become invisible when they fall in different batches.
            for (offset, entry) in tree.enumerated() {
                if offset % 256 == 0 { try Task.checkCancellation() }
                let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
                for length in 1..<max(components.count, 1) {
                    guard result[Data(components.prefix(length).joined(separator: "/").utf8)] == nil else {
                        throw PluginValidationError.invalidField("Git snapshot file ancestor")
                    }
                }
            }
            return result
        }
        let l = try index(leftTree), r = try index(rightTree)
        var formats = Set([left.commit?.utf8.count, right.commit?.utf8.count].compactMap { $0 })
        for (offset, entry) in leftTree.enumerated() {
            if offset % 256 == 0 { try Task.checkCancellation() }
            formats.insert(entry.objectID.utf8.count)
        }
        for (offset, entry) in rightTree.enumerated() {
            if offset % 256 == 0 { try Task.checkCancellation() }
            formats.insert(entry.objectID.utf8.count)
        }
        guard formats.count <= 1, (!left.emptyBaseline || leftTree.isEmpty), (!right.emptyBaseline || rightTree.isEmpty) else {
            throw PluginValidationError.invalidField("Git snapshot object format / baseline")
        }
        var usedLeft = Set<Data>(), usedRight = Set<Data>()
        for (offset, file) in files.enumerated() {
            if offset % 256 == 0 { try Task.checkCancellation() }
            let pair = Pair(file)
            if let key = pair.left {
                guard l[key] == file.left, usedLeft.insert(key).inserted else {
                    throw PluginValidationError.invalidField("Git global left coverage")
                }
            }
            if let key = pair.right {
                guard r[key] == file.right, usedRight.insert(key).inserted else {
                    throw PluginValidationError.invalidField("Git global right coverage")
                }
            }
            switch (pair.left, pair.right) {
            case (.some(let a), .some(let b)):
                guard a == b || (file.kind == .renamed && r[a] == nil && l[b] == nil) else {
                    throw PluginValidationError.invalidField("Git global rename pairing")
                }
            case (.some(let a), .none):
                guard r[a] == nil, file.kind == .deleted else { throw PluginValidationError.invalidField("Git split deletion") }
            case (.none, .some(let b)):
                guard l[b] == nil, file.kind == .added else { throw PluginValidationError.invalidField("Git split addition") }
            default: throw PluginValidationError.invalidField("Git empty native pair")
            }
        }
        guard usedLeft.count == l.count, usedRight.count == r.count else {
            throw PluginValidationError.invalidField("Git global source coverage")
        }
    }
}
