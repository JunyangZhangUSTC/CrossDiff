import Foundation
import Combine
import CrossDiffCore

enum ArchiveComparisonState: String, Sendable {
    case same, changed, added, removed, unknown, typeChanged
    var title: String {
        switch self {
        case .same: return L("相同", "Same")
        case .changed: return L("内容不同", "Changed")
        case .added: return L("仅右侧", "Right Only")
        case .removed: return L("仅左侧", "Left Only")
        case .unknown: return L("未验证", "Unverified")
        case .typeChanged: return L("类型不同", "Different Types")
        }
    }
    var symbol: String {
        switch self {
        case .same: return "equal.circle"
        case .changed: return "circle.lefthalf.filled"
        case .added: return "plus.circle"
        case .removed: return "minus.circle"
        case .unknown: return "questionmark.circle"
        case .typeChanged: return "exclamationmark.triangle"
        }
    }
}

struct ArchiveComparisonRow: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let left: ArchiveEntry?
    let right: ArchiveEntry?
    let state: ArchiveComparisonState
}

struct ArchiveContentGroup: Identifiable, Sendable {
    let id: String
    let sha256: String
    let size: Int64
    let left: [ArchiveEntry]
    let right: [ArchiveEntry]
}

enum ArchiveComparisonPhase: Sendable {
    case left, right, comparing
    var title: String {
        switch self {
        case .left: return L("正在校验左侧文件内容…", "Verifying Left File Contents…")
        case .right: return L("正在校验右侧文件内容…", "Verifying Right File Contents…")
        case .comparing: return L("正在匹配目录和相同内容…", "Matching Paths and Identical Contents…")
        }
    }
}

/// Plugin paths are display identifiers only. This module never resolves an
/// output path on disk; the result can reference only entries read by the host.
enum ArchivePluginResultValidator {
    static func content(_ snapshot: ArchiveSnapshot) -> PluginJSONValue {
        .object([
            "listingComplete": .bool(true),
            "entries": .array(snapshot.entries.map { entry in
                .object(["id": .string(entry.path), "path": .string(entry.path),
                         "kind": .string(entry.kind.rawValue),
                         "size": entry.kind == .directory ? .number(0) : entry.size.map { .number(Double($0)) } ?? .null,
                         "sha256": entry.sha256.map(PluginJSONValue.string) ?? .null,
                         "contentState": .string(entry.kind == .directory || entry.isContentVerified ? "verified" : "unverified")])
            })
        ])
    }

    static func parse(_ result: PluginComparisonResult, left: ArchiveSnapshot, right: ArchiveSnapshot) throws -> ([ArchiveComparisonRow], [ArchiveContentGroup]) {
        func invalid() -> PluginValidationError { .invalidField("archive result") }
        guard result.schema == "crossdiff.archive-tree/1",
              let pairs = result.payload["pairs"]?.arrayValue,
              let cohorts = result.payload["sameContentGroups"]?.arrayValue,
              pairs.count <= left.entries.count + right.entries.count,
              cohorts.count <= min(left.entries.count, right.entries.count) else { throw invalid() }
        let leftMap = Dictionary(uniqueKeysWithValues: left.entries.map { ($0.path, $0) })
        let rightMap = Dictionary(uniqueKeysWithValues: right.entries.map { ($0.path, $0) })
        let paths = Set(leftMap.keys).union(rightMap.keys)
        guard pairs.count == paths.count else { throw invalid() }
        var expected: [String: ArchiveComparisonState] = [:]
        for path in paths { expected[path] = state(leftMap[path], rightMap[path]) }
        // A same directory means its descendants matched too, not just its name.
        // Depth, rather than encoded length, remains valid when parent and child
        // names use canonically equivalent NFC/NFD spellings across sources.
        for path in paths.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            guard let slash = path.lastIndex(of: "/") else { continue }
            let parent = String(path[..<slash])
            guard leftMap[parent]?.kind == .directory, rightMap[parent]?.kind == .directory else { continue }
            if expected[path] == .unknown { expected[parent] = .unknown }
            else if expected[path] != .same, expected[parent] != .unknown { expected[parent] = .changed }
        }
        var seenLeft = Set<String>(), seenRight = Set<String>(), seenPaths = Set<String>()
        var rows: [ArchiveComparisonRow] = []
        for pair in pairs {
            guard let l = pair["left"], let r = pair["right"],
                  let rawState = pair["state"]?.stringValue, let status = ArchiveComparisonState(rawValue: rawState) else { throw invalid() }
            func resolve(_ value: PluginJSONValue, _ map: [String: ArchiveEntry], _ seen: inout Set<String>) throws -> ArchiveEntry? {
                if value == .null { return nil }
                guard let id = value.stringValue, let entry = map[id], seen.insert(id).inserted else { throw invalid() }
                return entry
            }
            let lEntry = try resolve(l, leftMap, &seenLeft), rEntry = try resolve(r, rightMap, &seenRight)
            guard let path = lEntry?.path ?? rEntry?.path, seenPaths.insert(path).inserted,
                  lEntry == nil || rEntry == nil || lEntry?.path == rEntry?.path,
                  status == expected[path] else { throw invalid() }
            rows.append(.init(path: path, left: lEntry, right: rEntry, state: status))
        }
        guard seenLeft.count == left.entries.count, seenRight.count == right.entries.count else { throw invalid() }
        let hasUnknown = rows.contains { $0.state == .unknown }
        guard result.status == (hasUnknown ? .partial : .completed) else { throw invalid() }
        func cohortsFor(_ entries: [ArchiveEntry]) -> [String: [ArchiveEntry]] {
            Dictionary(grouping: entries.filter { $0.kind == .file && $0.isContentVerified && $0.size != nil && $0.sha256 != nil },
                       by: { "\($0.size!):\($0.sha256!)" })
        }
        let lc = cohortsFor(left.entries), rc = cohortsFor(right.entries)
        let expectedGroups = Set(lc.keys).intersection(rc.keys).filter { key in
            Set(lc[key]!.map(\.path)).union(rc[key]!.map(\.path)).count >= 2
        }
        var seenGroups = Set<String>(), groups: [ArchiveContentGroup] = []
        for cohort in cohorts {
            func members(_ value: PluginJSONValue?, _ map: [String: ArchiveEntry]) throws -> [ArchiveEntry] {
                guard let ids = value?.arrayValue, !ids.isEmpty, ids.count <= map.count else { throw invalid() }
                var seen = Set<String>()
                return try ids.map {
                    guard let id = $0.stringValue, let entry = map[id], entry.kind == .file,
                          entry.isContentVerified, seen.insert(id).inserted else { throw invalid() }
                    return entry
                }
            }
            let l = try members(cohort["left"], leftMap), r = try members(cohort["right"], rightMap)
            guard let size = l.first?.size, let hash = l.first?.sha256 else { throw invalid() }
            let key = "\(size):\(hash)"
            guard expectedGroups.contains(key), seenGroups.insert(key).inserted,
                  Set(l.map(\.path)) == Set(lc[key]!.map(\.path)),
                  Set(r.map(\.path)) == Set(rc[key]!.map(\.path)) else { throw invalid() }
            groups.append(.init(id: key, sha256: hash, size: size,
                                left: l.sorted { $0.path < $1.path }, right: r.sorted { $0.path < $1.path }))
        }
        guard seenGroups == Set(expectedGroups) else { throw invalid() }
        return (rows.sorted { $0.path < $1.path }, groups.sorted { $0.id < $1.id })
    }

    private static func state(_ left: ArchiveEntry?, _ right: ArchiveEntry?) -> ArchiveComparisonState {
        if [left, right].compactMap({ $0 }).contains(where: { $0.kind != .directory && !$0.isContentVerified }) { return .unknown }
        guard let left else { return .added }
        guard let right else { return .removed }
        guard left.kind == right.kind else { return .typeChanged }
        if left.kind == .directory { return .same }
        return left.sha256 == right.sha256 && left.size == right.size ? .same : .changed
    }
}

@MainActor
final class ArchiveComparisonModel: ObservableObject {
    static let pluginID = "org.crossdiff.archive"
    static let fileExtensions = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar"]
    private static var nativeReaderURL: URL {
        #if CROSSDIFF_UI_CHECKS
        if let path = ProcessInfo.processInfo.environment["CROSSDIFF_ARCHIVE_READER"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CrossDiffArchiveReader")
    }
    @Published private(set) var leftSnapshot: ArchiveSnapshot?
    @Published private(set) var rightSnapshot: ArchiveSnapshot?
    @Published private(set) var rows: [ArchiveComparisonRow] = []
    @Published private(set) var groups: [ArchiveContentGroup] = []
    @Published private(set) var result: PluginComparisonResult?
    @Published private(set) var error: Error?
    @Published private(set) var isLoading = false
    @Published private(set) var isCancelled = false
    @Published private(set) var progress = 0.0
    @Published private(set) var phase = ArchiveComparisonPhase.left
    private var generation = UUID()
    private var loadedIdentity: [String]?
    private struct Loaded: Sendable {
        let left: ArchiveSnapshot
        let right: ArchiveSnapshot
        let result: PluginComparisonResult
        let rows: [ArchiveComparisonRow]
        let groups: [ArchiveContentGroup]
    }
    private var worker: Task<Loaded, Error>?
    private var validationWorker: Task<Void, Error>?
    private var validationGeneration = UUID()
    deinit { worker?.cancel(); validationWorker?.cancel() }

    func load(left: URL, right: URL, execute: @escaping @Sendable ([PluginInput]) async throws -> PluginComparisonResult,
              force: Bool = false, executionID: String = "") async {
        let identity = [left.absoluteString, right.absoluteString, executionID]
        if !force, loadedIdentity == identity, let leftSnapshot, let rightSnapshot, result != nil {
            let token = generation
            let validationToken = UUID(); validationGeneration = validationToken
            let validation = Task.detached(priority: .utility) {
                try leftSnapshot.verifyUnchanged(); try rightSnapshot.verifyUnchanged()
            }
            validationWorker?.cancel(); validationWorker = validation
            do {
                try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
            } catch is CancellationError {
                // Leaving the view does not invalidate an otherwise valid result.
            } catch {
                if token == generation, validationGeneration == validationToken, !Task.isCancelled { clear(); self.error = error }
            }
            if token == generation, validationGeneration == validationToken { validationWorker = nil }
            return
        }
        cancel(); clear()
        let token = UUID(); generation = token
        isLoading = true; isCancelled = false; progress = 0; phase = .left; error = nil
        let publish: @MainActor @Sendable (Double, ArchiveComparisonPhase) -> Void = { [weak self] value, phase in
            guard let self, self.generation == token, self.isLoading else { return }
            self.phase = phase; self.progress = value
        }
        let progressGate = ArchiveProgressGate()
        let readerURL = Self.nativeReaderURL
        let task = Task.detached(priority: .userInitiated) {
            let l = try ArchiveCatalog.snapshot(url: left, nativeReaderURL: readerURL) { value in
                if progressGate.accept(value * 0.45) { Task { @MainActor in publish(value * 0.45, .left) } }
            }
            await publish(0.45, .right)
            let r = try ArchiveCatalog.snapshot(url: right, nativeReaderURL: readerURL) { value in
                if progressGate.accept(0.45 + value * 0.45) { Task { @MainActor in publish(0.45 + value * 0.45, .right) } }
            }
            try Task.checkCancellation()
            try l.verifyUnchanged(); try r.verifyUnchanged()
            await publish(0.92, .comparing)
            let inputs = [PluginInput(id: "left", role: .left, name: left.lastPathComponent, content: ArchivePluginResultValidator.content(l)),
                          PluginInput(id: "right", role: .right, name: right.lastPathComponent, content: ArchivePluginResultValidator.content(r))]
            let result = try await execute(inputs)
            try Task.checkCancellation()
            let (rows, groups) = try ArchivePluginResultValidator.parse(result, left: l, right: r)
            try l.verifyUnchanged(); try r.verifyUnchanged()
            return Loaded(left: l, right: r, result: result, rows: rows, groups: groups)
        }
        worker = task
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == token else { return }
            try Task.checkCancellation()
            leftSnapshot = value.left; rightSnapshot = value.right; rows = value.rows; groups = value.groups
            loadedIdentity = identity; result = value.result; progress = 1; isLoading = false; worker = nil
        } catch is CancellationError {
            if generation == token { isLoading = false; isCancelled = true; worker = nil }
        } catch {
            guard generation == token else { return }
            isLoading = false; worker = nil; self.error = error
        }
    }
    func cancel() {
        let loading = isLoading
        generation = UUID(); worker?.cancel(); worker = nil
        validationGeneration = UUID(); validationWorker?.cancel(); validationWorker = nil; isLoading = false
        if loading { isCancelled = true }
    }
    private func clear() {
        result = nil; leftSnapshot = nil; rightSnapshot = nil; rows = []; groups = []; loadedIdentity = nil
    }
}

private final class ArchiveProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    func accept(_ value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value >= last + 0.005 else { return false }; last = value; return true
    }
}
