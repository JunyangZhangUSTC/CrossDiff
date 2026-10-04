import Foundation
import Combine
import CrossDiffCore

/// A comparison session owns this model, so tab changes never restart disk I/O.
/// Results are snapshots; only an explicit refresh reads subsequent file changes.
@MainActor
final class FolderComparisonModel: ObservableObject {
    typealias ScanOperation = @Sendable (URL, URL, FolderScanOptions, @escaping @Sendable (FolderScanUpdate) -> Void) async throws -> FolderComparisonResult
    struct ProjectionInput: Sendable {
        let entries: [FolderEntry]
        let mode: FolderBrowserMode
        let filter: FolderBrowserFilter
        let query: String
        let scope: String
        let sort: FolderBrowserSort
        let expanded: Set<String>
        func project() throws -> FolderBrowserProjection {
            try FolderBrowser.project(entries: entries, mode: mode, filter: filter, query: query,
                                      scopePath: scope, sort: sort, expandedPaths: expanded)
        }
    }
    typealias ProjectionOperation = @Sendable (ProjectionInput) throws -> FolderBrowserProjection
    private let scanOperation: ScanOperation
    private let projectionOperation: ProjectionOperation

    init(scan: @escaping ScanOperation = { left, right, options, update in
        try await FolderComparison.scanIncrementally(left: left, right: right, options: options, onUpdate: update)
    }, project: @escaping ProjectionOperation = { try $0.project() }) {
        scanOperation = scan
        projectionOperation = project
    }

    @Published private(set) var result: FolderComparisonResult?
    @Published private(set) var visibleEntries: [FolderEntry] = []
    @Published private(set) var browserProjection: FolderBrowserProjection = .empty
    @Published var browserMode: FolderBrowserMode = .tree { didSet { if browserMode != oldValue { filterEntries() } } }
    @Published var statusFilter: FolderBrowserFilter = .differences {
        didSet {
            guard statusFilter != oldValue else { return }
            updatingFilter = true; differencesOnly = statusFilter != .all; updatingFilter = false
            filterEntries()
        }
    }
    @Published var sortOrder = FolderBrowserSort() { didSet { if sortOrder != oldValue { filterEntries() } } }
    @Published var expandedPaths = Set<String>() { didSet { if expandedPaths != oldValue { filterEntries() } } }
    @Published var scopePath = "" { didSet { if scopePath != oldValue { filterEntries() } } }
    @Published var showModifiedDates = false
    @Published private(set) var displayingPreviousScan = false
    @Published private(set) var progress: FolderScanProgress?
    @Published var preview: FolderCopyPlan?
    @Published private(set) var busy = false
    @Published private(set) var scanning = false
    @Published private(set) var filtering = false
    @Published var error: Error?
    @Published private(set) var completedAt: Date?
    @Published private(set) var ignoredNames = FolderComparison.ignoredNames
    @Published var selection = Set<String>()
    // Kept for session callers; the visible control uses the richer status filter.
    @Published var differencesOnly = true {
        didSet {
            if differencesOnly != oldValue && !updatingFilter { statusFilter = differencesOnly ? .differences : .all }
        }
    }
    @Published var query = "" { didSet { if query != oldValue { filterEntries(debounce: true) } } }
    @Published private var statusText: () -> String = { L("按文件内容比较", "Compare by file contents") }
    var status: String {
        if scanning {
            return progress?.stage == .comparing
                ? L("正在核验文件内容…", "Verifying file contents…")
                : L("正在扫描目录…", "Scanning folders…")
        }
        return statusText()
    }
    private(set) var scanCount = 0
    private var roots: [URL]?
    private var previousResult: FolderComparisonResult?
    private var task: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var generation = UUID()
    private var filterGeneration = UUID()
    private var resultRevision = UUID()
    private var publishedResultRevision: UUID?
    private var publishedFilterGeneration: UUID?
    private struct ProjectionRequest: Sendable {
        let input: ProjectionInput
        let resultRevision: UUID
    }
    private var pendingProjection: ProjectionRequest?
    private var resultIndex: [String: FolderEntry] = [:]
    private var visiblePaths = Set<String>()
    private var updatingFilter = false

    var displayedResult: FolderComparisonResult? { result ?? (displayingPreviousScan ? previousResult : nil) }

    var effectiveSortOrder: FolderBrowserSort {
        // Statuses change continuously during verification. Apply that ordering
        // once verification stops, rather than moving the row under the pointer.
        scanning && sortOrder.key == .status ? .init() : sortOrder
    }

    func setSort(_ sort: FolderBrowserSort) { sortOrder = sort }
    func toggleFolder(_ path: String) {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if expandedPaths.contains(path) { expandedPaths.remove(path) } else { expandedPaths.insert(path) }
    }
    func openFolder(_ path: String) {
        guard path.isEmpty || displayedResult?.entries.contains(where: { $0.path == path && $0.isDirectory }) == true else { return }
        selection.removeAll()
        scopePath = path
    }
    func goUp() { openFolder(scopePath.split(separator: "/").dropLast().joined(separator: "/")) }
    func collapseAll() { expandedPaths.removeAll() }

    deinit { task?.cancel(); filterTask?.cancel() }

    func loadIfNeeded(left: URL, right: URL) {
        guard roots != [left, right] else { return }
        scan(left: left, right: right)
    }

    func scan(left: URL, right: URL) {
        task?.cancel()
        generation = UUID()
        let current = generation
        let sameRoots = roots == [left, right]
        previousResult = sameRoots ? displayedResult : nil
        roots = [left, right]
        scanCount += 1
        displayingPreviousScan = previousResult != nil
        result = nil; progress = nil; completedAt = nil; error = nil; preview = nil
        resultRevision = UUID(); publishedResultRevision = nil
        resultIndex.removeAll()
        if !sameRoots {
            scopePath = ""; expandedPaths.removeAll(); selection.removeAll()
            browserProjection = .empty; visibleEntries = []; visiblePaths.removeAll()
        }
        filterTask?.cancel(); filterTask = nil; pendingProjection = nil
        filterGeneration = UUID(); filtering = false
        busy = true; scanning = true
        statusText = { L("正在扫描目录…", "Scanning folders…") }
        let options = FolderScanOptions(ignoredNames: ignoredNames)
        let scanOperation = scanOperation
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                try await scanOperation(left, right, options) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current, self.scanning else { return }
                        self.progress = update.progress
                        if let partial = update.result {
                            self.result = partial
                            self.resultRevision = UUID()
                            self.displayingPreviousScan = false
                            self.previousResult = nil
                            self.filterEntries(coalescing: true)
                        }
                    }
                }
            }
            do {
                let scanned = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                self.result = scanned; self.progress = scanned.progress
                self.resultRevision = UUID()
                self.displayingPreviousScan = false
                self.previousResult = nil
                // A refreshed scope may have disappeared from both inputs.
                if !self.scopePath.isEmpty && !scanned.entries.contains(where: { $0.path == self.scopePath && $0.isDirectory }) {
                    self.scopePath = ""
                }
                self.resultIndex = Dictionary(uniqueKeysWithValues: scanned.entries.map { ($0.path, $0) })
                self.completedAt = Date()
                let changed = scanned.entries.filter { !$0.isDirectory && $0.status != .same }.count
                self.statusText = { L("\(scanned.entries.count) 项 · \(changed) 个文件有差异或需要处理", "\(scanned.entries.count) items · \(changed) files with differences or issues") }
            } catch is CancellationError {
                guard let self, self.generation == current else { return }
                self.statusText = { L("已取消 · 比较未完成", "Canceled · Comparison incomplete") }
            } catch {
                guard let self, self.generation == current else { return }
                self.error = error
                self.statusText = { L("比较未完成", "Comparison incomplete") }
            }
            guard let self, self.generation == current else { return }
            self.busy = false; self.scanning = false
            self.filterEntries(coalescing: true)
        }
    }

    func applyIgnoredNames(_ names: Set<String>, left: URL, right: URL) {
        guard !busy else { return }
        ignoredNames = names
        scan(left: left, right: right)
    }

    func cancel() {
        task?.cancel()
        generation = UUID() // Discard any already-queued progress or completion.
        if scanning { statusText = { L("已取消 · 比较未完成", "Canceled · Comparison incomplete") } }
        busy = false; scanning = false
        filterEntries()
    }

    func canCopy(toRight: Bool) -> Bool {
        guard !busy, !filtering, publishedResultRevision == resultRevision, publishedFilterGeneration == filterGeneration,
              completedAt != nil, result?.isComplete == true, !selection.isEmpty else { return false }
        return selection.isSubset(of: visiblePaths) && selection.allSatisfy { resultIndex[$0]?.canCopy(toRight: toRight) == true }
    }

    private func filterEntries(debounce: Bool = false, coalescing: Bool = false) {
        let input = ProjectionInput(entries: displayedResult?.entries ?? [], mode: browserMode,
                                    filter: statusFilter, query: query, scope: scopePath,
                                    sort: effectiveSortOrder, expanded: expandedPaths)
        let request = ProjectionRequest(input: input, resultRevision: resultRevision)
        filtering = true
        if coalescing, filterTask != nil {
            // A slow projection must get a chance to finish while scan snapshots
            // arrive every 100 ms. Keep only the newest pending snapshot.
            pendingProjection = request
            return
        }
        filterTask?.cancel()
        pendingProjection = nil
        filterGeneration = UUID()
        startProjection(request, generation: filterGeneration, debounce: debounce)
    }

    private func startProjection(_ request: ProjectionRequest, generation current: UUID, debounce: Bool = false) {
        let projectionOperation = projectionOperation
        filterTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(nanoseconds: 100_000_000) }
                let worker = Task.detached(priority: .userInitiated) { try projectionOperation(request.input) }
                let projection = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.filterGeneration == current else { return }
                let paths = Set(projection.rows.map(\.id))
                self.visiblePaths = paths
                self.selection.formIntersection(paths)
                self.visibleEntries = projection.matchingEntries
                self.browserProjection = projection
                self.publishedResultRevision = request.resultRevision
                self.publishedFilterGeneration = current
            } catch {
                // Root/query changes have their own generation and replacement
                // task. An unexpected projection failure cannot enable copying.
            }
            guard let self, self.filterGeneration == current else { return }
            self.filterTask = nil
            if let pending = self.pendingProjection {
                self.pendingProjection = nil
                self.startProjection(pending, generation: current)
            } else { self.filtering = false }
        }
    }

    func prepare(paths: Set<String>, toRight: Bool) {
        guard let result, !busy, !filtering, publishedResultRevision == resultRevision, publishedFilterGeneration == filterGeneration,
              completedAt != nil, result.isComplete,
              !paths.isEmpty, paths.isSubset(of: visiblePaths) else { return }
        busy = true; statusText = { L("正在核验复制预览…", "Verifying files for copy preview…") }
        let current = generation
        let projectionGeneration = filterGeneration
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try FolderComparison.prepareCopy(result, paths: paths, toRight: toRight)
            }
            do {
                let plan = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                if self.filterGeneration == projectionGeneration && !self.filtering && paths.isSubset(of: self.visiblePaths) {
                    self.preview = plan
                    self.statusText = { L("请核对待复制的文件", "Review the files to be copied") }
                } else {
                    self.statusText = { L("浏览范围已改变，请重新选择要复制的文件", "The view changed. Select the files to copy again.") }
                }
            } catch is CancellationError {} catch {
                guard let self, self.generation == current else { return }
                self.error = error; self.statusText = { L("无法准备复制", "Unable to prepare copy") }
            }
            guard let self, self.generation == current else { return }
            self.busy = false
        }
    }

    /// Scans are read-only and can be replaced; copy review and writes cannot.
    var canReplaceRoots: Bool { (!busy || scanning) && preview == nil }

    func execute(_ plan: FolderCopyPlan, left: URL, right: URL) {
        guard !busy, preview?.id == plan.id else { return }
        preview = nil; busy = true; statusText = { L("正在复制文件…", "Copying files…") }
        let current = generation
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try FolderComparison.execute(plan) }
            do {
                _ = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                self.busy = false
                self.scan(left: left, right: right)
            } catch is CancellationError {} catch {
                guard let self, self.generation == current else { return }
                self.error = FolderCopyFailure(underlying: error)
                self.statusText = { L("复制已停止，请重新比较", "Copying stopped. Compare again to check the result.") }
                self.busy = false
            }
        }
    }
}

private struct FolderCopyFailure: LocalizedError {
    let underlying: Error
    var errorDescription: String? {
        localizedErrorDescription(underlying) + "\n" + L("已完成的复制可能已保留，请重新比较确认。", "Some files may already have been copied. Compare again to check the result.")
    }
}
