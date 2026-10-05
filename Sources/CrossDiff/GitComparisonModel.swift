import Foundation
import Combine
import CrossDiffCore

enum GitComparisonPreset: String, CaseIterable {
    case allChanges, staged, unstaged, custom
    var title: String {
        switch self {
        case .allChanges: return L("全部未提交", "All Uncommitted")
        case .staged: return L("已暂存", "Staged")
        case .unstaged: return L("未暂存", "Unstaged")
        case .custom: return L("自定义", "Custom")
        }
    }
    var description: String {
        switch self {
        case .allChanges: return L("HEAD → 工作区 · 相对上次提交的全部变化", "HEAD → Working Tree · All changes since the last commit")
        case .staged: return L("HEAD → 暂存区 · 下一次提交将包含的变化", "HEAD → Staging Area · Changes prepared for the next commit")
        case .unstaged: return L("暂存区 → 工作区 · 尚未 git add 的变化", "Staging Area → Working Tree · Changes not yet staged")
        case .custom: return L("自由选择两侧来源；点击比较后更新结果", "Choose either source freely, then click Compare")
        }
    }
}

@MainActor
final class GitComparisonModel: ObservableObject {
    static let pluginID = "org.crossdiff.git"
    @Published var state: GitWorkspaceState { didSet { onStateChanged?() } }
    @Published var pathFilter = ""
    @Published private(set) var repository: GitRepository?
    @Published private(set) var references: [GitReference] = []
    @Published private(set) var commits: [GitCommit] = []
    @Published private(set) var comparison: GitSourceComparison?
    @Published private(set) var selectedFile: GitFileChange?
    @Published private(set) var detailSession: ComparisonSession?
    @Published private var detailNote: DetailNote?
    @Published private var fileFailure: Error?
    var detailMessage: String? { fileFailure.map(localizedErrorDescription) ?? detailNote?.message }
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingFile = false
    @Published private(set) var needsConnection = false
    @Published private var failure: Error?
    var errorMessage: String? { failure.map(localizedErrorDescription) }
    private enum LoadingProgress {
        case scan(GitScanProgress)
        case verification(Int, Int)
    }
    @Published private var loadingProgress: LoadingProgress?
    var status: String {
        guard isLoading else { return L("只读比较 · 不修改仓库", "Read-only comparison · Repository unchanged") }
        switch loadingProgress {
        case .scan(let value):
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: value.bytesRead), countStyle: .file)
            return L("已扫描 \(value.filesScanned) 个文件 · 已读取 \(size)", "Scanned \(value.filesScanned) files · Read \(size)")
        case .verification(let done, let total):
            return L("正在核验文件 · \(done) / \(total)", "Verifying files · \(done) / \(total)")
        case nil: return L("正在读取 Git 仓库…", "Reading Git repository…")
        }
    }
    var allowInitialNetwork = false
    var onStateChanged: (() -> Void)?
    private var generation = UUID()
    private var fileGeneration = UUID()
    private var operation: Task<Void, Error>?
    private var fileOperation: Task<Detail, Error>?
    private var loadedExecutionID: String?
    private enum DetailNote: Sendable {
        case symbolicLink, submodule, binary
        var message: String {
            switch self {
            case .symbolicLink: return L("符号链接：仅显示目标文本，不跟随链接。", "Symbolic link: showing its target text without following it.")
            case .submodule: return L("子模块：比较固定提交编号，不递归读取子仓库。", "Submodule: comparing pinned commit IDs without opening the nested repository.")
            case .binary: return L("二进制预览 · 每侧显示前 64 KiB；目录状态依据完整 Git 对象。", "Binary preview · First 64 KiB per side; file status uses the complete Git object.")
            }
        }
    }
    private struct Detail: Sendable { let left: String; let right: String; let note: DetailNote? }

    init(state: GitWorkspaceState) { self.state = state }
    deinit { operation?.cancel(); fileOperation?.cancel() }
    var supportsLocalSources: Bool { repository?.isBare == false && !state.isRemote }
    var canCompare: Bool {
        repository != nil && !isLoading &&
        (state.leftKind != .commit || !state.leftRevision.isEmpty) &&
        (state.rightKind != .commit || !state.rightRevision.isEmpty)
        && (supportsLocalSources || (state.leftKind == .commit && state.rightKind == .commit))
    }
    var activePreset: GitComparisonPreset {
        guard !state.useMergeBase else { return .custom }
        if state.leftKind == .commit, state.leftRevision == "HEAD" {
            if state.rightKind == .workingTree { return .allChanges }
            if state.rightKind == .index { return .staged }
        }
        if state.leftKind == .index, state.rightKind == .workingTree { return .unstaged }
        return .custom
    }
    func applyPreset(_ preset: GitComparisonPreset) {
        guard supportsLocalSources, preset != .custom else { return }
        var next = state
        next.leftKind = preset == .unstaged ? .index : .commit
        next.rightKind = preset == .staged ? .index : .workingTree
        if next.leftKind == .commit { next.leftRevision = "HEAD" }
        next.useMergeBase = false
        state = next
    }
    func setSource(_ kind: GitRevisionSourceKind, side: Side) {
        guard kind == .commit || supportsLocalSources else { return }
        if side == .left { state.leftKind = kind } else { state.rightKind = kind }
        if state.leftKind != .commit || state.rightKind != .commit { state.useMergeBase = false }
    }
    var displayName: String {
        let tail = state.source.split(separator: "/").last.map(String.init) ?? state.source
        return tail.hasSuffix(".git") ? String(tail.dropLast(4)) : tail
    }
    var filteredFiles: [GitFileChange] {
        (comparison?.files ?? []).filter {
            (!state.differencesOnly || $0.kind != .unchanged) &&
            (pathFilter.isEmpty || $0.path.localizedCaseInsensitiveContains(pathFilter) || $0.left?.path.localizedCaseInsensitiveContains(pathFilter) == true)
        }
    }
    var cacheURL: URL {
        let root = ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CrossDiff")
        return root.appendingPathComponent("GitRepositories", isDirectory: true).appendingPathComponent(state.cacheID, isDirectory: true)
    }
    func setRevision(_ value: String, side: Side) {
        guard value.utf8.count <= 1024 else { failure = GitError.invalidRevision; return }
        if side == .left { state.leftRevision = value; state.leftKind = .commit }
        else { state.rightRevision = value; state.rightKind = .commit }
    }
    func swapRevisions() {
        var next = state
        (next.leftRevision, next.rightRevision) = (next.rightRevision, next.leftRevision)
        (next.leftKind, next.rightKind) = (next.rightKind, next.leftKind)
        state = next
    }
    func cancel() {
        generation = UUID(); fileGeneration = UUID(); operation?.cancel(); fileOperation?.cancel()
        if isLoadingFile { selectedFile = nil }
        isLoading = false; isLoadingFile = false; loadingProgress = nil
    }
    func open(execution: PluginExecution, allowNetwork: Bool = false, executionID: String = "") async {
        guard state.isValid else { failure = GitError.notRepository; return }
        if repository != nil, let comparison, loadedExecutionID == executionID {
            // A tab can disappear after the tree is ready but before its file finishes loading.
            if detailSession == nil, fileFailure == nil,
               let file = selectedFile ?? comparison.files.first(where: { $0.id == state.selectedPath }) ?? comparison.changedFiles.first ?? comparison.files.first {
                await selectFile(file)
            }
            return
        }
        let source = state.source, remote = state.isRemote, destination = cacheURL
        if remote, !FileManager.default.fileExists(atPath: destination.path), !allowNetwork {
            needsConnection = true; return
        }
        await perform {
            let worker = Task.detached(priority: .userInitiated) {
                if remote {
                    let address = try GitRemote.parse(source)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        return try GitRepository.openCache(destination, remote: address, isCancelled: { Task.isCancelled })
                    }
                    return try GitRepository.clone(remote: address, to: destination, isCancelled: { Task.isCancelled })
                }
                return try GitRepository.open(URL(fileURLWithPath: source), isCancelled: { Task.isCancelled })
            }
            let repo = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            self.repository = repo; self.needsConnection = false
            try await self.readReferences(repo)
            self.loadedExecutionID = executionID
            try await self.runComparison(repo, execution: execution)
        }
    }
    func compare(execution: PluginExecution) async {
        guard let repository else { return }
        await perform { try await self.runComparison(repository, execution: execution) }
    }
    /// Fetch is explicit and restricted to an application-owned remote cache.
    func refresh(execution: PluginExecution) async {
        guard let repository else { await open(execution: execution, allowNetwork: true); return }
        await perform {
            if self.state.isRemote {
                let remote = try GitRemote.parse(self.state.source)
                let worker = Task.detached(priority: .userInitiated) { try repository.refresh(remote: remote, isCancelled: { Task.isCancelled }) }
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            }
            try Task.checkCancellation()
            try await self.readReferences(repository)
            try await self.runComparison(repository, execution: execution)
        }
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) async {
        cancel(); let token = UUID(); generation = token
        failure = nil; isLoading = true
        // Clearing the old result prevents new selectors from labeling an old snapshot.
        comparison = nil; detailSession = nil; selectedFile = nil; detailNote = nil; fileFailure = nil
        let task = Task { try await work() }; operation = task
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch is CancellationError { }
        catch { if generation == token, !Task.isCancelled { failure = error } }
        if generation == token { isLoading = false; operation = nil }
    }
    private func readReferences(_ repo: GitRepository) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            let refs = try repo.references(isCancelled: { Task.isCancelled })
            let history: [GitCommit], initialRevision: String
            do { history = try repo.commits(limit: 200, isCancelled: { Task.isCancelled }); initialRevision = "HEAD" }
            catch GitError.invalidRevision {
                guard let first = refs.first else { throw GitError.emptyRepository }
                history = try repo.commits(revision: first.objectID, limit: 200, isCancelled: { Task.isCancelled })
                initialRevision = first.fullName
            }
            return (refs, history, initialRevision)
        }
        let (refs, history, initialRevision) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard !history.isEmpty || !repo.isBare else { throw GitError.emptyRepository }
        references = refs; commits = history
        let newLocalSession = !repo.isBare && state.leftRevision.isEmpty && state.rightRevision.isEmpty && state.leftKind == .commit && state.rightKind == .commit
        if state.rightRevision.isEmpty { state.rightRevision = initialRevision }
        if state.leftRevision.isEmpty { state.leftRevision = history.count > 1 ? history[1].objectID : initialRevision }
        if newLocalSession { applyPreset(.allChanges) }
    }
    private func runComparison(_ repo: GitRepository, execution: PluginExecution) async throws {
        func source(_ kind: GitRevisionSourceKind, revision: String) -> GitComparisonSource {
            switch kind {
            case .commit: return .commit(revision)
            case .index: return .index
            case .workingTree: return .workingTree
            }
        }
        let left = source(state.leftKind, revision: state.leftRevision), right = source(state.rightKind, revision: state.rightRevision)
        let includeUntracked = state.includeUntracked
        let options = GitComparisonOptions(detectRenames: state.detectRenames, useMergeBase: state.useMergeBase)
        let token = generation
        let gate = GitProgressGate()
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try repo.compareSources(left: left, right: right, options: options, includeUntracked: includeUntracked,
                isCancelled: { Task.isCancelled }, progress: { [weak self] value in
                    guard gate.accept() else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.isLoading else { return }
                        if case .verification = self.loadingProgress { return }
                        self.loadingProgress = .scan(value)
                    }
                })
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        loadingProgress = .verification(0, result.files.count)
        _ = try await GitPluginComparison.compare(result, execution: execution) { [weak self] done, total in
            guard done == total || gate.accept() else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isLoading else { return }
                self.loadingProgress = .verification(done, total)
            }
        }
        try Task.checkCancellation()
        comparison = result
        let selected = result.files.first { $0.id == state.selectedPath } ?? result.changedFiles.first ?? result.files.first
        if let selected { await selectFile(selected) }
    }
    func selectFile(_ file: GitFileChange) async {
        guard let repo = repository, let comparison else { return }
        fileOperation?.cancel(); let token = UUID(); fileGeneration = token
        selectedFile = file; state.selectedPath = file.id; detailSession = nil; detailNote = nil; fileFailure = nil; isLoadingFile = true
        let worker = Task.detached(priority: .userInitiated) { try Self.loadDetail(file, repo: repo, comparison: comparison) }
        fileOperation = worker
        do {
            let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, fileGeneration == token else { return }
            let session = ComparisonSession(left: .init(text: result.left, savedText: result.left), right: .init(text: result.right, savedText: result.right))
            session.characterHighlights = true
            detailSession = session; detailNote = result.note
        } catch {
            if fileGeneration == token, !Task.isCancelled { fileFailure = error }
        }
        if fileGeneration == token { isLoadingFile = false; fileOperation = nil }
    }
    private nonisolated static func loadDetail(_ file: GitFileChange, repo: GitRepository, comparison: GitSourceComparison) throws -> Detail {
        func bytes(_ entry: GitTreeEntry?, snapshot: GitComparisonSnapshot) throws -> Data {
            guard let entry else { return Data() }
            if entry.kind == .submodule { return Data(("Submodule commit: " + entry.objectID + "\n").utf8) }
            return try repo.readContent(entry: entry, in: snapshot, maximumBytes: 2 * 1024 * 1024, isCancelled: { Task.isCancelled })
        }
        let left = try bytes(file.left, snapshot: comparison.leftSnapshot), right = try bytes(file.right, snapshot: comparison.rightSnapshot)
        try Task.checkCancellation()
        if let l = GitBlobText.decode(left), let r = GitBlobText.decode(right) {
            let note: DetailNote? = file.left?.kind == .symbolicLink || file.right?.kind == .symbolicLink
                ? .symbolicLink : file.left?.kind == .submodule || file.right?.kind == .submodule ? .submodule : nil
            return Detail(left: l, right: r, note: note)
        }
        func hex(_ data: Data) -> String {
            let bytes = [UInt8](data.prefix(64 * 1024))
            return stride(from: 0, to: bytes.count, by: 16).map { offset in
                let row = bytes[offset..<min(offset + 16, bytes.count)]
                return String(format: "%08X  ", offset) + row.map { String(format: "%02X", $0) }.joined(separator: " ") + "  " + row.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined()
            }.joined(separator: "\n")
        }
        return Detail(left: hex(left), right: hex(right), note: .binary)
    }
}

/// Avoid queueing a UI update for each file/chunk in a large working tree.
private final class GitProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextUpdate: TimeInterval = 0
    func accept() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextUpdate else { return false }
        nextUpdate = now + 0.15
        return true
    }
}
