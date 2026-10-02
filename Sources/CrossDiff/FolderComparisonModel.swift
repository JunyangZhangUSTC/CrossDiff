import Foundation
import Combine
import CrossDiffCore

/// A comparison session owns this model, so tab changes never restart disk I/O.
/// Results are snapshots; only an explicit refresh reads subsequent file changes.
@MainActor
final class FolderComparisonModel: ObservableObject {
    @Published private(set) var result: FolderComparisonResult?
    @Published private(set) var visibleEntries: [FolderEntry] = []
    @Published private(set) var progress: FolderScanProgress?
    @Published var preview: FolderCopyPlan?
    @Published private(set) var busy = false
    @Published private(set) var scanning = false
    @Published private(set) var filtering = false
    @Published var error: Error?
    @Published private(set) var completedAt: Date?
    @Published private(set) var ignoredNames = FolderComparison.ignoredNames
    @Published var selection = Set<String>()
    @Published var differencesOnly = true { didSet { if differencesOnly != oldValue { filterEntries() } } }
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
    private var task: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var generation = UUID()
    private var filterGeneration = UUID()
    private var resultIndex: [String: FolderEntry] = [:]

    deinit { task?.cancel(); filterTask?.cancel() }

    func loadIfNeeded(left: URL, right: URL) {
        guard roots != [left, right] else { return }
        scan(left: left, right: right)
    }

    func scan(left: URL, right: URL) {
        task?.cancel()
        generation = UUID()
        let current = generation
        roots = [left, right]
        scanCount += 1
        result = nil; progress = nil; completedAt = nil; error = nil; preview = nil
        resultIndex.removeAll(); selection.removeAll()
        filterTask?.cancel(); filterGeneration = UUID(); visibleEntries = []; filtering = false
        busy = true; scanning = true
        statusText = { L("正在扫描目录…", "Scanning folders…") }
        let options = FolderScanOptions(ignoredNames: ignoredNames)
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { [weak self] in
                try await FolderComparison.scanIncrementally(left: left, right: right, options: options) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current, self.scanning else { return }
                        self.progress = update.progress
                        if let partial = update.result {
                            self.result = partial
                            self.filterEntries()
                        }
                    }
                }
            }
            do {
                let scanned = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                self.result = scanned; self.progress = scanned.progress
                self.resultIndex = Dictionary(uniqueKeysWithValues: scanned.entries.map { ($0.path, $0) })
                self.completedAt = Date()
                let changed = scanned.entries.filter { !$0.isDirectory && $0.status != .same }.count
                self.statusText = { L("\(scanned.entries.count) 项 · \(changed) 个文件有差异或需要处理", "\(scanned.entries.count) items · \(changed) files with differences or issues") }
                self.filterEntries()
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
    }

    func canCopy(toRight: Bool) -> Bool {
        guard !busy, completedAt != nil, result?.isComplete == true, !selection.isEmpty else { return false }
        return selection.allSatisfy { resultIndex[$0]?.canCopy(toRight: toRight) == true }
    }

    private func filterEntries(debounce: Bool = false) {
        filterTask?.cancel()
        let current = UUID(); filterGeneration = current
        let entries = result?.entries ?? [], query = query, differencesOnly = differencesOnly
        filtering = true
        filterTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(nanoseconds: 100_000_000) }
                let worker = Task.detached(priority: .userInitiated) {
                    var filtered: [FolderEntry] = []
                    for (index, entry) in entries.enumerated() {
                        if index % 1024 == 0 { try Task.checkCancellation() }
                        if (!differencesOnly || entry.status != .same) && (query.isEmpty || entry.path.localizedCaseInsensitiveContains(query)) {
                            filtered.append(entry)
                        }
                    }
                    return filtered
                }
                let filtered = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.filterGeneration == current else { return }
                self.visibleEntries = filtered; self.filtering = false
            } catch { /* A newer query or result owns the next publication. */ }
        }
    }

    func prepare(paths: Set<String>, toRight: Bool) {
        guard let result, !busy, completedAt != nil, result.isComplete else { return }
        busy = true; statusText = { L("正在核验复制预览…", "Verifying files for copy preview…") }
        let current = generation
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try FolderComparison.prepareCopy(result, paths: paths, toRight: toRight)
            }
            do {
                let plan = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                self.preview = plan
                self.statusText = { L("请核对待复制的文件", "Review the files to be copied") }
            } catch is CancellationError {} catch {
                guard let self, self.generation == current else { return }
                self.error = error; self.statusText = { L("无法准备复制", "Unable to prepare copy") }
            }
            guard let self, self.generation == current else { return }
            self.busy = false
        }
    }

    func execute(_ plan: FolderCopyPlan, left: URL, right: URL) {
        guard !busy else { return }
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
