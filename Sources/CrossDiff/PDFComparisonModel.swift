import Foundation
import Combine
import CrossDiffCore

enum PDFComparisonMode: String, CaseIterable, Identifiable {
    case pages, text
    var id: Self { self }
    var title: String { self == .pages ? L("页面对照", "Pages") : L("文字差异", "Text Differences") }
}

enum PDFPageAlignmentMode: String, CaseIterable, Identifiable {
    case pageNumber, smart, manual
    var id: Self { self }
    var title: String {
        switch self {
        case .pageNumber: return L("按页码", "By Page")
        case .smart: return L("智能匹配", "Smart Match")
        case .manual: return L("手动配对", "Manual Pairing")
        }
    }
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

    /// Classification is separate from correspondence: choosing two pages does
    /// not establish that they are revisions of the same original page.
    static func comparing(_ left: PDFPageDescriptor?, _ right: PDFPageDescriptor?, id: Int) -> PDFPagePair {
        let kind: Kind
        if let left, let right {
            let previewMatches = left.fingerprint == right.fingerprint && left.width == right.width && left.height == right.height
            if previewMatches && (left.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  right.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                kind = .unknown
            } else if previewMatches && left.text == right.text {
                kind = left.textTruncated || right.textTruncated ? .unknown : .same
            } else { kind = .changed }
        } else { kind = left == nil ? .added : .removed }
        return PDFPagePair(id: id, left: left?.index, right: right?.index, kind: kind)
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
    let positionalPairs: [PDFPagePair]
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
    @Published var alignmentMode = PDFPageAlignmentMode.pageNumber {
        didSet { if alignmentMode != oldValue { changeAlignment(from: oldValue) } }
    }
    @Published private(set) var manualLeftPage: Int?
    @Published private(set) var manualRightPage: Int?
    @Published var selectedIndex = 0 { didSet { if selectedIndex != oldValue { updateTextDiff() } } }
    private var automaticPairs: [PDFPagePair] = []
    private var positionalPairs: [PDFPagePair] = []
    private var loadedURLs: [URL]?
    private var loadedExecutionID: String?
    private var generation = UUID()
    private var loadTask: Task<PDFLoadedComparison, Error>?
    private var textTask: Task<Void, Never>?
    private var textGeneration = UUID()

    deinit { loadTask?.cancel(); textTask?.cancel() }

    var selectedPair: PDFPagePair? { pair(in: alignmentMode) }
    var leftText: String { selectedPair?.left.flatMap { leftDocument?.pages[$0].text } ?? "" }
    var rightText: String { selectedPair?.right.flatMap { rightDocument?.pages[$0].text } ?? "" }
    var changedCount: Int { (alignmentMode == .manual ? [selectedPair].compactMap { $0 } : pairs).filter { $0.kind != .same && $0.kind != .unknown }.count }

    private var acceptsSmartAlignment: Bool {
        guard let alignment = result?.payload["alignment"]?.objectValue,
              alignment["strategy"]?.stringValue == "smart",
              alignment["reason"] == nil,
              let reliable = alignment["reliablePairs"]?.intValue, reliable > 0,
              reliable <= min(leftDocument?.pages.count ?? 0, rightDocument?.pages.count ?? 0),
              reliable <= automaticPairs.filter({ $0.left != nil && $0.right != nil }).count else { return false }
        return true
    }
    var isSmartFallback: Bool { alignmentMode == .smart && result != nil && !acceptsSmartAlignment }
    var alignmentNotice: String {
        switch alignmentMode {
        case .pageNumber:
            return L("按原始页码依次比较，不推测页面对应关系。", "Compare original page numbers in order, without inferring correspondence.")
        case .manual:
            return L("左右独立选页，仅比较当前所选页面。", "Choose each side independently to compare the selected pages.")
        case .smart:
            if isSmartFallback {
                let alignment = result?.payload["alignment"]?.objectValue
                if alignment == nil {
                    return L("此插件未提供匹配可靠性信息，已按页码比较。", "This plugin provides no matching confidence information. Comparing by page number.")
                }
                if alignment?["reason"]?.stringValue == "ambiguousEvidence" {
                    return L("页面对应存在歧义，已按页码比较；也可手动选页。", "Page correspondence is ambiguous. Comparing by page number; manual pairing is available.")
                }
                return L("未找到足够可靠的对应关系，已按页码比较。", "Not enough evidence to match these documents. Comparing by page number.")
            }
            return L("已根据内容对齐页面；可切换按页码或手动调整。", "Pages aligned by content. Switch to page order or manual pairing at any time.")
        }
    }

    func presentationTitle(for pair: PDFPagePair) -> String {
        if alignmentMode != .smart || isSmartFallback {
            if pair.kind == .added { return L("仅右侧有此页", "Page Only on the Right") }
            if pair.kind == .removed { return L("仅左侧有此页", "Page Only on the Left") }
        }
        return pair.title
    }

    func selectAlignmentMode(_ mode: PDFPageAlignmentMode) { alignmentMode = mode }

    func selectManualPageNumber(_ number: Int, isLeft: Bool) {
        let count = (isLeft ? leftDocument : rightDocument)?.pages.count ?? 0
        guard number >= 1, number <= count else { return }
        selectManualPage(number - 1, isLeft: isLeft)
    }

    func selectManualPage(_ index: Int, isLeft: Bool) {
        let document = isLeft ? leftDocument : rightDocument
        guard document?.pages.indices.contains(index) == true else { return }
        if isLeft { manualLeftPage = index } else { manualRightPage = index }
        if alignmentMode == .manual { updateTextDiff() }
    }

    private func pair(in alignment: PDFPageAlignmentMode) -> PDFPagePair? {
        if alignment != .manual { return pairs.indices.contains(selectedIndex) ? pairs[selectedIndex] : nil }
        guard let left = leftDocument, let right = rightDocument,
              let leftIndex = manualLeftPage, left.pages.indices.contains(leftIndex),
              let rightIndex = manualRightPage, right.pages.indices.contains(rightIndex) else { return nil }
        return .comparing(left.pages[leftIndex], right.pages[rightIndex], id: 0)
    }

    private func changeAlignment(from previousMode: PDFPageAlignmentMode) {
        let previous = pair(in: previousMode)
        rebuildPairs(preserving: previous)
    }

    private func rebuildPairs(preserving previous: PDFPagePair?) {
        guard let left = leftDocument, let right = rightDocument else { return }
        if alignmentMode == .manual {
            manualLeftPage = min(manualLeftPage ?? previous?.left ?? 0, left.pages.count - 1)
            manualRightPage = min(manualRightPage ?? previous?.right ?? 0, right.pages.count - 1)
            pairs = []; selectedIndex = 0
        } else {
            pairs = alignmentMode == .smart && acceptsSmartAlignment ? automaticPairs : positionalPairs
            let match = pairs.firstIndex { $0.left == previous?.left && $0.right == previous?.right }
                ?? pairs.firstIndex { previous?.left != nil && $0.left == previous?.left }
                ?? pairs.firstIndex { previous?.right != nil && $0.right == previous?.right }
            selectedIndex = match ?? min(selectedIndex, max(0, pairs.count - 1))
        }
        updateTextDiff()
    }

    func load(left: URL, right: URL,
              execute: @escaping @Sendable ([PluginInput]) async throws -> PluginComparisonResult,
              force: Bool = false, executionID: String = "") async {
        if !force, loadedURLs == [left, right], loadedExecutionID == executionID, result != nil {
            if textDiff == nil { updateTextDiff() }
            return
        }
        let previous = selectedPair
        let sameInputs = loadedURLs == [left, right]
        if !sameInputs { manualLeftPage = nil; manualRightPage = nil; selectedIndex = 0 }
        cancel()
        let token = UUID(); generation = token
        isLoading = true; error = nil; result = nil; pairs = []; automaticPairs = []; positionalPairs = []; textDiff = nil
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
            let positional = (0..<max(leftDocument.pages.count, rightDocument.pages.count)).map { index in
                PDFPagePair.comparing(leftDocument.pages.indices.contains(index) ? leftDocument.pages[index] : nil,
                                      rightDocument.pages.indices.contains(index) ? rightDocument.pages[index] : nil, id: index)
            }
            return PDFLoadedComparison(left: leftDocument, right: rightDocument, result: result, pairs: pairs, positionalPairs: positional)
        }
        loadTask = task
        do {
            let loaded = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == token, !Task.isCancelled else { return }
            leftDocument = loaded.left; rightDocument = loaded.right; result = loaded.result
            automaticPairs = loaded.pairs; positionalPairs = loaded.positionalPairs
            rebuildPairs(preserving: sameInputs ? previous : nil)
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
        guard alignmentMode != .manual, !pairs.isEmpty else { return }
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
