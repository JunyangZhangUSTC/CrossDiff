import Foundation

/// Only captured tree metadata crosses the restricted-plugin boundary. Repository URLs,
/// paths on disk, credentials, process execution and file bytes remain in the native host.
public struct GitPluginEntry: Equatable, Sendable {
    public let path: String
    public let objectID: String
    public let mode: String
    public init(path: String, objectID: String, mode: String) {
        self.path = path; self.objectID = objectID; self.mode = mode
    }
    public var value: PluginJSONValue {
        .object(["path": .string(path), "objectID": .string(objectID), "mode": .string(mode)])
    }
}

public struct GitPluginRename: Equatable, Sendable {
    public let left: String
    public let right: String
    public init(left: String, right: String) { self.left = left; self.right = right }
    public var value: PluginJSONValue { .object(["left": .string(left), "right": .string(right)]) }
}

public enum GitPluginSource: String, Codable, Sendable { case commit, index, workingTree }

private struct GitPluginSnapshotDescriptor {
    let source: GitPluginSource
    let snapshot: String
    let commit: String?
    let emptyBaseline: Bool
    var value: PluginJSONValue {
        .object(["source": .string(source.rawValue), "snapshot": .string(snapshot),
                 "commit": commit.map(PluginJSONValue.string) ?? .null, "emptyBaseline": .bool(emptyBaseline)])
    }
    func matches(_ value: PluginJSONValue) -> Bool {
        guard let object = value.objectValue,
              Set(object.keys) == ["source", "snapshot", "commit", "emptyBaseline"],
              value["source"]?.stringValue == source.rawValue,
              let identity = value["snapshot"]?.stringValue,
              Data(identity.utf8) == Data(snapshot.utf8),
              value["commit"] == (commit.map(PluginJSONValue.string) ?? .null),
              value["emptyBaseline"]?.boolValue == emptyBaseline else { return false }
        return true
    }
}

public enum GitPluginState: String, CaseIterable, Codable, Sendable {
    case unchanged, added, deleted, modified, renamed, typeChanged
}

public struct GitPluginRow: Equatable, Sendable {
    public let left: String?
    public let right: String?
    public let state: GitPluginState
    public var path: String { right ?? left ?? "" }
    public init(left: String?, right: String?, state: GitPluginState) {
        self.left = left; self.right = right; self.state = state
    }
}

public struct GitPluginValidatedResult: Sendable {
    public let rows: [GitPluginRow]
    public let counts: [String: Int]
    public let summary: PluginLocalizedText
    public var changedCount: Int { rows.count - (counts[GitPluginState.unchanged.rawValue] ?? 0) }

    /// Called after the host has validated every batch and global source coverage.
    /// There is deliberately no repository-wide count or serialized-JSON limit here.
    public static func aggregate(_ rows: [GitPluginRow]) -> GitPluginValidatedResult {
        var counts = Dictionary(uniqueKeysWithValues: GitPluginState.allCases.map { ($0.rawValue, 0) })
        for row in rows { counts[row.state.rawValue, default: 0] += 1 }
        let changes = rows.count - (counts[GitPluginState.unchanged.rawValue] ?? 0)
        return GitPluginValidatedResult(rows: rows, counts: counts,
            summary: PluginLocalizedText(zhHans: "\(rows.count) 个文件中有 \(changes) 项变化。",
                                         en: "\(changes) changes across \(rows.count) files."))
    }

    /// The runner validates against the originating request before this projection is used.
    public static func parse(_ result: PluginComparisonResult) throws -> GitPluginValidatedResult {
        guard result.schema == "crossdiff.git-tree/1", let values = result.payload["rows"]?.arrayValue,
              values.count <= GitPluginContract.maximumBatchEntries * 2,
              let counts = result.payload["counts"]?.objectValue,
              Set(counts.keys) == Set(GitPluginState.allCases.map(\.rawValue)) else {
            throw PluginValidationError.invalidField("Git result")
        }
        let rows = try values.map { value -> GitPluginRow in
            guard let state = value["state"]?.stringValue.flatMap(GitPluginState.init),
                  let leftValue = value["left"], let rightValue = value["right"],
                  leftValue == .null || leftValue.stringValue != nil,
                  rightValue == .null || rightValue.stringValue != nil else {
                throw PluginValidationError.invalidField("Git row")
            }
            return GitPluginRow(left: leftValue.stringValue, right: rightValue.stringValue, state: state)
        }
        var parsedCounts: [String: Int] = [:]
        for (name, value) in counts {
            guard let count = value.intValue, (0...GitPluginContract.maximumBatchEntries * 2).contains(count) else {
                throw PluginValidationError.invalidField("Git counts")
            }
            parsedCounts[name] = count
        }
        return GitPluginValidatedResult(rows: rows, counts: parsedCounts, summary: result.summary)
    }
}

public enum GitPluginContract {
    /// Per helper request, never a repository/file-count limit. Hosts send complete pairs in batches.
    public static let maximumBatchEntries = 128

    public static func content(commit: String, entries: [GitPluginEntry]) -> PluginJSONValue {
        .object(["commit": .string(commit), "entries": .array(entries.map(\.value))])
    }

    public static func content(source: GitPluginSource, snapshot: String, commit: String?,
                               emptyBaseline: Bool = false, entries: [GitPluginEntry]) -> PluginJSONValue {
        var result = GitPluginSnapshotDescriptor(source: source, snapshot: snapshot, commit: commit,
            emptyBaseline: emptyBaseline).value.objectValue!
        result["entries"] = .array(entries.map(\.value))
        return .object(result)
    }

    public static func validateRequest(_ request: PluginComparisonRequest) throws {
        _ = try catalogs(request)
    }

    public static func validateResult(_ result: PluginComparisonResult, request: PluginComparisonRequest) throws {
        let (leftCatalog, rightCatalog, renames) = try catalogs(request)
        let left = leftCatalog.entries, right = rightCatalog.entries
        guard let snapshots = result.payload["snapshots"]?.objectValue,
              Set(snapshots.keys) == ["left", "right"],
              leftCatalog.descriptor.matches(snapshots["left"]!),
              rightCatalog.descriptor.matches(snapshots["right"]!) else {
            throw PluginValidationError.invalidField("Git result snapshot identity")
        }
        guard result.status == .completed else { throw PluginValidationError.invalidField("Git result completeness") }
        let parsed = try GitPluginValidatedResult.parse(result)
        let renamedDestinations = Set(renames.values)
        var seenLeft = Set<Data>(), seenRight = Set<Data>()
        var expectedCounts = Dictionary(uniqueKeysWithValues: GitPluginState.allCases.map { ($0.rawValue, 0) })
        for row in parsed.rows {
            let l = row.left.map { Data($0.utf8) }, r = row.right.map { Data($0.utf8) }
            guard l != nil || r != nil,
                  l.map({ left[$0] != nil && seenLeft.insert($0).inserted }) ?? true,
                  r.map({ right[$0] != nil && seenRight.insert($0).inserted }) ?? true else {
                throw PluginValidationError.invalidField("Git row source identity")
            }
            let expected: GitPluginState
            switch (l, r) {
            case (.some(let l), .some(let r)):
                if l != r {
                    guard renames[l] == r else { throw PluginValidationError.invalidField("Git rename identity") }
                    expected = .renamed
                } else {
                    guard renames[l] == nil else { throw PluginValidationError.invalidField("Git rename omitted") }
                    let a = left[l]!, b = right[r]!
                    expected = kind(a.mode) != kind(b.mode) ? .typeChanged
                        : a.objectID == b.objectID && a.mode == b.mode ? .unchanged : .modified
                }
            case (.some(let l), .none):
                guard right[l] == nil, renames[l] == nil else { throw PluginValidationError.invalidField("Git false deletion") }
                expected = .deleted
            case (.none, .some(let r)):
                guard left[r] == nil, !renamedDestinations.contains(r) else { throw PluginValidationError.invalidField("Git false addition") }
                expected = .added
            default: throw PluginValidationError.invalidField("Git empty row")
            }
            guard row.state == expected else { throw PluginValidationError.invalidField("Git row classification") }
            expectedCounts[expected.rawValue, default: 0] += 1
        }
        guard seenLeft == Set(left.keys), seenRight == Set(right.keys), parsed.counts == expectedCounts else {
            throw PluginValidationError.invalidField("Git result coverage / counts")
        }
    }

    private struct Catalog {
        let descriptor: GitPluginSnapshotDescriptor
        let entries: [Data: GitPluginEntry]
        let objectIDLength: Int?
    }

    private static func catalogs(_ request: PluginComparisonRequest) throws
        -> (Catalog, Catalog, [Data: Data]) {
        guard request.mode == .pairwise, request.inputs.count == 2,
              let leftInput = request.inputs.first(where: { $0.role == .left }),
              let rightInput = request.inputs.first(where: { $0.role == .right }),
              Set(request.options.keys).isSubset(of: ["renameHints"]) else {
            throw PluginValidationError.invalidField("Git pairwise sources / options")
        }
        let left = try catalog(leftInput.content), right = try catalog(rightInput.content)
        guard Set([left.objectIDLength, right.objectIDLength].compactMap { $0 }).count <= 1 else {
            throw PluginValidationError.invalidField("Git object formats")
        }
        let hints: [PluginJSONValue]
        if let value = request.options["renameHints"] {
            guard let values = value.arrayValue, values.count <= maximumBatchEntries else {
                throw PluginValidationError.invalidField("Git rename hints")
            }
            hints = values
        } else { hints = [] }
        var renames: [Data: Data] = [:], destinations = Set<Data>()
        for hint in hints {
            guard let a = hint["left"]?.stringValue, let b = hint["right"]?.stringValue else {
                throw PluginValidationError.invalidField("Git rename paths")
            }
            let l = Data(a.utf8), r = Data(b.utf8)
            guard l != r, let leftEntry = left.entries[l], let rightEntry = right.entries[r],
                  right.entries[l] == nil, left.entries[r] == nil, kind(leftEntry.mode) == kind(rightEntry.mode),
                  renames[l] == nil, destinations.insert(r).inserted else {
                throw PluginValidationError.invalidField("Git rename sources")
            }
            renames[l] = r
        }
        return (left, right, renames)
    }

    private static func catalog(_ value: PluginJSONValue) throws -> Catalog {
        guard let object = value.objectValue,
              let entries = value["entries"]?.arrayValue, entries.count <= maximumBatchEntries else {
            throw PluginValidationError.invalidField("Git tree")
        }
        let descriptor: GitPluginSnapshotDescriptor
        if value["source"] == nil {
            // Original commit-only input remains supported, without inventing an OID for local state.
            guard Set(object.keys) == ["commit", "entries"],
                  let commit = value["commit"]?.stringValue, validObjectID(commit) else {
                throw PluginValidationError.invalidField("Git commit source")
            }
            descriptor = GitPluginSnapshotDescriptor(source: .commit, snapshot: "commit:" + commit,
                commit: commit, emptyBaseline: false)
        } else {
            guard Set(object.keys) == ["source", "snapshot", "commit", "emptyBaseline", "entries"],
                  let source = value["source"]?.stringValue.flatMap(GitPluginSource.init),
                  let snapshot = value["snapshot"]?.stringValue, (1...256).contains(snapshot.utf8.count),
                  !snapshot.utf8.contains(where: { $0 < 32 || $0 == 127 }),
                  let commitValue = value["commit"],
                  commitValue == .null || commitValue.stringValue != nil,
                  let empty = value["emptyBaseline"]?.boolValue else {
                throw PluginValidationError.invalidField("Git snapshot metadata")
            }
            let commit = commitValue.stringValue
            if source == .commit {
                guard empty ? commit == nil && entries.isEmpty : commit.map(validObjectID) == true else {
                    throw PluginValidationError.invalidField("Git commit / empty baseline")
                }
            } else {
                guard commit == nil, !empty else { throw PluginValidationError.invalidField("Git local source is not a commit") }
            }
            descriptor = GitPluginSnapshotDescriptor(source: source, snapshot: snapshot, commit: commit, emptyBaseline: empty)
        }
        var objectIDLength = descriptor.commit?.utf8.count
        var result: [Data: GitPluginEntry] = [:]
        for value in entries {
            guard let path = value["path"]?.stringValue, validPath(path),
                  let objectID = value["objectID"]?.stringValue, validObjectID(objectID),
                  objectIDLength.map({ objectID.utf8.count == $0 }) ?? true,
                  let mode = value["mode"]?.stringValue, ["100644", "100755", "120000", "160000"].contains(mode) else {
                throw PluginValidationError.invalidField("Git tree entry")
            }
            objectIDLength = objectID.utf8.count
            let key = Data(path.utf8)
            guard result[key] == nil else { throw PluginValidationError.invalidField("Git duplicate path") }
            result[key] = GitPluginEntry(path: path, objectID: objectID, mode: mode)
        }
        // Directories are implicit. A tracked file or submodule cannot contain another tree entry.
        for entry in result.values {
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            for index in 1..<components.count {
                guard result[Data(components.prefix(index).joined(separator: "/").utf8)] == nil else {
                    throw PluginValidationError.invalidField("Git file ancestor")
                }
            }
        }
        return Catalog(descriptor: descriptor, entries: result, objectIDLength: objectIDLength)
    }

    private static func validPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 4096 && !path.utf8.contains(0) && components.count <= 128
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func validObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func kind(_ mode: String) -> String { mode == "100755" ? "100644" : mode }
}
