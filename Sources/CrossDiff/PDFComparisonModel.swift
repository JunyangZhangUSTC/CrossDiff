import Foundation
import Combine
import CrossDiffCore

enum PDFComparisonMode: String, CaseIterable, Identifiable {
    case pages, text
    var id: Self { self }
    var title: String { self == .pages ? L("页面对照", "Pages") : L("文字差异", "Text Differences") }
}

enum PDFComparisonZoom: String, CaseIterable, Identifiable {
    case fit, half, actual, double
    var id: Self { self }
    var title: String {
        switch self {
        case .fit: return L("适应窗口", "Fit to Window")
        case .half: return "50%"
        case .actual: return "100%"
        case .double: return "200%"
        }
    }
    var scale: CGFloat? {
        switch self { case .fit: return nil; case .half: return 0.5; case .actual: return 1; case .double: return 2 }
    }
}

struct PDFPagePair: Identifiable, Sendable {
    enum Kind: String, Sendable { case same, changed, added, removed, unknown }
    let id: Int
    let left: Int?
    let right: Int?
    let kind: Kind
    var title: String {
        switch kind {
        case .same: return L("文字与预览匹配", "Text and Preview Match")
        case .changed: return L("有变化", "Changed")
        case .added: return L("新增页面", "Added Page")
        case .removed: return L("删除页面", "Removed Page")
        case .unknown: return L("需查看页面", "Review Page")
        }
    }

    static func validated(_ result: PluginComparisonResult, leftCount: Int, rightCount: Int) throws -> [PDFPagePair] {
        guard result.schema == "crossdiff.document-pages/1", let values = result.payload["pairs"]?.arrayValue,
              values.count <= leftCount + rightCount else { throw PDFComparisonFailure.invalidResult }
        var seenLeft = Set<Int>(), seenRight = Set<Int>()
        let pairs = try values.enumerated().map { index, value -> PDFPagePair in
            guard let object = value.objectValue, let raw = object["kind"]?.stringValue,
                  let kind = Kind(rawValue: raw), let leftValue = object["left"], let rightValue = object["right"] else {
                throw PDFComparisonFailure.invalidResult
            }
            func pageIndex(_ value: PluginJSONValue, count: Int) throws -> Int? {
                if value == .null { return nil }
                guard let number = value.intValue, number >= 0, number < count else { throw PDFComparisonFailure.invalidResult }
                return number
            }
            let left = try pageIndex(leftValue, count: leftCount), right = try pageIndex(rightValue, count: rightCount)
            if let left, !seenLeft.insert(left).inserted { throw PDFComparisonFailure.invalidResult }
            if let right, !seenRight.insert(right).inserted { throw PDFComparisonFailure.invalidResult }
            switch kind {
            case .added: guard left == nil, right != nil else { throw PDFComparisonFailure.invalidResult }
            case .removed: guard left != nil, right == nil else { throw PDFComparisonFailure.invalidResult }
            default: guard left != nil, right != nil else { throw PDFComparisonFailure.invalidResult }
            }
            return PDFPagePair(id: index, left: left, right: right, kind: kind)
        }
        guard seenLeft.count == leftCount, seenRight.count == rightCount else { throw PDFComparisonFailure.invalidResult }
        return pairs
    }
}

private struct PDFLoadedComparison: @unchecked Sendable {
    let left: PDFComparisonDocument
    let right: PDFComparisonDocument
    let result: PluginComparisonResult
    let pairs: [PDFPagePair]
}

@MainActor
final class PDFComparisonModel: ObservableObject {
    @Published private(set) var leftDocument: PDFComparisonDocument?
    @Published private(set) var rightDocument: PDFComparisonDocument?
    @Published private(set) var pairs: [PDFPagePair] = []
    @Published private(set) var result: PluginComparisonResult?
    @Published private(set) var error: Error?
    @Published private(set) var isLoading = false
    @Published private(set) var textDiff: TextDiffResult?
    @Published var mode = PDFComparisonMode.pages
    @Published var zoom = PDFComparisonZoom.fit
    @Published var selectedIndex = 0 { didSet { if selectedIndex != oldValue { updateTextDiff() } } }
    private var loadedURLs: [URL]?
    private var loadedExecutionID: String?
    private var generation = UUID()
    private var loadTask: Task<PDFLoadedComparison, Error>?
    private var textTask: Task<Void, Never>?
    private var textGeneration = UUID()

    deinit { loadTask?.cancel(); textTask?.cancel() }

    var selectedPair: PDFPagePair? { pairs.indices.contains(selectedIndex) ? pairs[selectedIndex] : nil }
    var leftText: String { selectedPair?.left.flatMap { leftDocument?.pages[$0].text } ?? "" }
    var rightText: String { selectedPair?.right.flatMap { rightDocument?.pages[$0].text } ?? "" }
    var changedCount: Int { pairs.filter { $0.kind != .same && $0.kind != .unknown }.count }

    func load(left: URL, right: URL,
              execute: @escaping @Sendable ([PluginInput]) async throws -> PluginComparisonResult,
              force: Bool = false, executionID: String = "") async {
        if !force, loadedURLs == [left, right], loadedExecutionID == executionID, result != nil {
            if textDiff == nil { updateTextDiff() }
            return
        }
        cancel()
        let token = UUID(); generation = token
        isLoading = true; error = nil; result = nil; pairs = []; textDiff = nil
        leftDocument = nil; rightDocument = nil; loadedURLs = nil; loadedExecutionID = nil
        let task = Task.detached(priority: .userInitiated) {
            let leftDocument = try PDFComparisonDecoder.load(left)
            let rightDocument = try PDFComparisonDecoder.load(right)
            try Task.checkCancellation()
            let inputs = [PluginInput(id: "left", role: .left, name: left.lastPathComponent, content: leftDocument.pluginContent),
                          PluginInput(id: "right", role: .right, name: right.lastPathComponent, content: rightDocument.pluginContent)]
            let result = try await execute(inputs)
            try Task.checkCancellation()
            let pairs = try PDFPagePair.validated(result, leftCount: leftDocument.pages.count, rightCount: rightDocument.pages.count)
            return PDFLoadedComparison(left: leftDocument, right: rightDocument, result: result, pairs: pairs)
        }
        loadTask = task
        do {
            let loaded = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == token, !Task.isCancelled else { return }
            leftDocument = loaded.left; rightDocument = loaded.right; result = loaded.result; pairs = loaded.pairs
            selectedIndex = min(selectedIndex, max(0, pairs.count - 1))
            loadedURLs = [left, right]; loadedExecutionID = executionID
            isLoading = false; loadTask = nil
            updateTextDiff()
        } catch is CancellationError {
            if generation == token { isLoading = false; loadTask = nil }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = error; isLoading = false; loadTask = nil
        }
    }

    func cancel() {
        generation = UUID(); textGeneration = UUID()
        loadTask?.cancel(); loadTask = nil; textTask?.cancel(); textTask = nil
        isLoading = false
    }

    func move(by delta: Int, differencesOnly: Bool = false) {
        guard !pairs.isEmpty else { return }
        if !differencesOnly {
            selectedIndex = min(max(0, selectedIndex + delta), pairs.count - 1)
            return
        }
        let candidates = pairs.indices.filter { pairs[$0].kind != .same }
        if delta > 0 { selectedIndex = candidates.first(where: { $0 > selectedIndex }) ?? candidates.first ?? selectedIndex }
        else { selectedIndex = candidates.last(where: { $0 < selectedIndex }) ?? candidates.last ?? selectedIndex }
    }

    private func updateTextDiff() {
        textTask?.cancel(); textDiff = nil
        let token = UUID(); textGeneration = token
        let left = leftText, right = rightText
        textTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try TextDiffEngine.compareCancellable(left, right) }
            do {
                let diff = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.textGeneration == token, !Task.isCancelled else { return }
                self.textDiff = diff
            } catch { /* Cancellation drops obsolete page text only. */ }
        }
    }
}
