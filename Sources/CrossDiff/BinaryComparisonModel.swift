import Foundation
import Combine
import CrossDiffCore

/// Each tab owns a metadata-checked pair and one bounded viewport of bytes.
/// Native rendering never performs file I/O or allocates rows for the whole file.
@MainActor
final class BinaryComparisonModel: ObservableObject {
    @Published private(set) var result: BinaryComparisonResult?
    @Published private(set) var layout: BinaryRowLayout?
    @Published private(set) var page: BinaryPage?
    @Published private(set) var error: Error?
    @Published private(set) var isLoading = false
    @Published private(set) var isCancelled = false
    @Published private(set) var progress = 0.0
    @Published private(set) var selectedChange = 0
    @Published private(set) var requestedRow: Int64 = 0
    @Published private(set) var navigationID = UUID()
    @Published var bytesPerRow = 16 {
        didSet {
            guard bytesPerRow != oldValue else { return }
            guard bytesPerRow == 8 || bytesPerRow == 16 else { bytesPerRow = oldValue; return }
            rebuildLayout(previousWidth: oldValue)
        }
    }
    private(set) var changeIndices: [Int] = []
    var canNavigate: Bool { !isLoading && error == nil && !changeIndices.isEmpty }
    var selectedSpanIndex: Int? { changeIndices.indices.contains(selectedChange) ? changeIndices[selectedChange] : nil }

    private struct Sources: Sendable {
        let left: BinaryFileSource
        let right: BinaryFileSource
    }
    private var sources: Sources?
    private var loadedPair: [URL]?
    private var generation = UUID()
    private var pageGeneration = UUID()
    private var compareWorker: Task<(Sources, BinaryComparisonResult), Error>?
    private var pageTask: Task<Void, Never>?
    private var pendingRows: Range<Int64>?
    private var visibleRow: Int64 = 0

    deinit { compareWorker?.cancel(); pageTask?.cancel() }

    func load(left: URL, right: URL, force: Bool = false) async {
        let pair = [left, right]
        if !force, loadedPair == pair, let sources, result != nil {
            let token = generation
            do {
                try await Task.detached(priority: .utility) {
                    try sources.left.verifyUnchanged(); try sources.right.verifyUnchanged()
                }.value
            } catch { if generation == token { invalidate(error) } }
            return
        }
        compareWorker?.cancel(); pageTask?.cancel()
        let token = UUID(); generation = token; pageGeneration = UUID()
        loadedPair = nil; sources = nil; result = nil; layout = nil; page = nil
        changeIndices = []; selectedChange = 0; pendingRows = nil
        error = nil; isCancelled = false; isLoading = true; progress = 0
        requestedRow = 0; visibleRow = 0
        let progressGate = BinaryProgressGate()
        let reportProgress: @MainActor @Sendable (Double) -> Void = { [weak self] value in
            guard let self, self.generation == token, self.isLoading else { return }
            self.progress = min(1, max(self.progress, value))
        }
        let worker = Task.detached(priority: .userInitiated) {
            let sources = try Sources(left: BinaryFileSource(url: left), right: BinaryFileSource(url: right))
            let result = try BinaryDiffEngine.compare(left: sources.left, right: sources.right) { value in
                guard progressGate.shouldPublish(value) else { return }
                Task { @MainActor in reportProgress(value) }
            }
            try Task.checkCancellation()
            return (sources, result)
        }
        compareWorker = worker
        do {
            let (sources, result) = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard generation == token, !Task.isCancelled else {
                if generation == token { finishCancellation() }
                return
            }
            self.sources = sources; self.loadedPair = pair
            self.result = result
            self.changeIndices = result.spans.indices.filter { result.spans[$0].kind != .equal }
            self.layout = BinaryRowLayout(result: result, bytesPerRow: bytesPerRow)
            progress = 1; isLoading = false; compareWorker = nil
            if let first = changeIndices.first, let row = layout?.row(forSpanIndex: first) { reveal(row) }
            else { reveal(0) }
        } catch is CancellationError {
            if generation == token { finishCancellation() }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            isLoading = false; compareWorker = nil; self.error = error
        }
    }

    func cancel() {
        let wasLoading = isLoading
        generation = UUID(); pageGeneration = UUID()
        compareWorker?.cancel(); compareWorker = nil
        pageTask?.cancel(); pageTask = nil; pendingRows = nil
        isLoading = false
        if wasLoading { isCancelled = true }
    }

    private func finishCancellation() {
        isLoading = false; isCancelled = true; compareWorker = nil
    }

    func navigate(_ delta: Int) {
        guard canNavigate, let layout else { return }
        selectedChange = (selectedChange + delta % changeIndices.count + changeIndices.count) % changeIndices.count
        if let row = layout.row(forSpanIndex: changeIndices[selectedChange]) {
            reveal(row)
        }
    }

    func jump(to offset: Int64, side: BinaryDataSide) {
        guard let layout, let row = layout.row(containingOffset: offset, side: side) else { return }
        // The address field uses actual source positions, including after insertions.
        if let span = result?.spans.firstIndex(where: {
            let start = side == .left ? $0.leftOffset : $0.rightOffset
            let count = side == .left ? $0.leftCount : $0.rightCount
            return offset >= start && offset - start < count
        }), let change = changeIndices.firstIndex(of: span) { selectedChange = change }
        reveal(row)
    }

    private func reveal(_ row: Int64) {
        requestedRow = max(0, row); visibleRow = requestedRow
        navigationID = UUID()
        requestRows(start: row, count: 128)
    }

    private func rebuildLayout(previousWidth: Int) {
        guard let result else { return }
        // Preserve logical byte position as the window changes its column count.
        let position = visibleRow * Int64(previousWidth)
        layout = BinaryRowLayout(result: result, bytesPerRow: bytesPerRow)
        pageGeneration = UUID(); pageTask?.cancel(); page = nil; pendingRows = nil
        reveal(position / Int64(bytesPerRow))
    }

    /// `start` is the actual first visible row; prefetch extends forward only.
    func requestRows(start: Int64, count: Int) {
        guard let layout, let sources, error == nil else { return }
        let first = min(max(0, start), max(0, layout.totalRows - 1))
        let rowCount = min(max(1, count), 512)
        let end = min(layout.totalRows, first + Int64(rowCount))
        visibleRow = first
        // New native views restore the current scroll position when switching
        // tabs. Only navigationID asks an existing view to actively jump.
        requestedRow = first
        let requested = first..<end
        if let page, first >= page.startRow, end <= page.startRow + Int64(page.rows.count) {
            // Returning to a cached viewport must supersede an in-flight read
            // elsewhere, otherwise that old read can evict the visible page.
            pageGeneration = UUID(); pageTask?.cancel(); pageTask = nil; pendingRows = nil
            return
        }
        if let pendingRows, requested.lowerBound >= pendingRows.lowerBound, requested.upperBound <= pendingRows.upperBound { return }
        pageTask?.cancel()
        let token = UUID(); pageGeneration = token
        let comparisonToken = generation
        pendingRows = requested
        pageTask = Task { [weak self] in
            // Wheel events may arrive faster than storage can service. Only the
            // latest viewport may replace the visible bytes.
            await Task.yield()
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                try sources.left.verifyUnchanged(); try sources.right.verifyUnchanged()
                try Task.checkCancellation()
                let rows = layout.rows(start: first, count: rowCount)
                func read(_ side: BinaryDataSide) throws -> (Int64, Data) {
                    let offsets = rows.flatMap(\.cells).compactMap { side == .left ? $0.leftOffset : $0.rightOffset }
                    guard let low = offsets.min(), let high = offsets.max() else { return (0, Data()) }
                    let source = side == .left ? sources.left : sources.right
                    return (low, try source.read(offset: low, count: Int(high - low + 1)))
                }
                let (leftOffset, leftBytes) = try read(.left)
                let (rightOffset, rightBytes) = try read(.right)
                try Task.checkCancellation()
                try sources.left.verifyUnchanged(); try sources.right.verifyUnchanged()
                return BinaryPage(startRow: first, rows: rows, leftOffset: leftOffset, leftBytes: leftBytes,
                                  rightOffset: rightOffset, rightBytes: rightBytes)
            }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, self.generation == comparisonToken, self.pageGeneration == token else { return }
                self.page = value; self.pendingRows = nil; self.pageTask = nil
            } catch is CancellationError {
                // A newer viewport request owns the loading state.
            } catch {
                guard !Task.isCancelled, let self, self.generation == comparisonToken, self.pageGeneration == token else { return }
                self.invalidate(error)
            }
        }
    }

    private func invalidate(_ error: Error) {
        cancel()
        sources = nil; loadedPair = nil; result = nil; layout = nil; page = nil
        changeIndices = []; self.error = error
    }
}

/// A fixed upper bound on queued UI updates even when there are many tiny edits.
private final class BinaryProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    func shouldPublish(_ value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value >= last + 0.005 || value == 1 && last < 1 else { return false }
        last = value
        return true
    }
}
