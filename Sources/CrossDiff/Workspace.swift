import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CrossDiffCore

extension Notification.Name {
    static let crossDiffFocusSearch = Notification.Name("CrossDiff.focusSearch")
}

enum ComparisonKind: String, CaseIterable {
    case text, folder, image, binary, plugin
    var title: String { switch self { case .text: return L("文本比较", "Text Comparison"); case .folder: return L("文件夹比较", "Folder Comparison"); case .image: return L("图片比较", "Image Comparison"); case .binary: return L("二进制比较", "Binary Comparison"); case .plugin: return L("插件比较", "Plugin Comparison") } }
    var symbol: String { switch self { case .text: return "doc.text"; case .folder: return "folder"; case .image: return "photo"; case .binary: return "number.square"; case .plugin: return "puzzlepiece.extension" } }
}

enum Side: Hashable { case left, right }

struct SessionSearchMatch: Equatable {
    let side: Side
    let range: NSRange
}

enum ReplacementScope: String, CaseIterable, Identifiable {
    case left, right, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return L("左侧", "Left Side")
        case .right: return L("右侧", "Right Side")
        case .both: return L("两侧", "Both Sides")
        }
    }
    func includes(_ side: Side) -> Bool { self == .both || (side == .left ? self == .left : self == .right) }
}

private enum ReplacementInputError: LocalizedError {
    case compositionInProgress
    var errorDescription: String? {
        L("正在输入文字，本次替换已取消。请完成输入后重试。", "Text input is in progress. Finish typing, then try replacing again.")
    }
}

private struct UnsupportedDocumentError: LocalizedError {
    let fileName: String
    var errorDescription: String? {
        L("\(fileName)：尚未安装支持此文档格式的比较器。", "\(fileName): No comparison provider is installed for this document format.")
    }
}

@MainActor
final class ComparisonSession: ObservableObject, Identifiable {
    let id: UUID
    let kind: ComparisonKind
    let pluginID: String?
    @Published var left: StoredTextSide
    @Published var right: StoredTextSide
    @Published var result: TextDiffResult?
    @Published var calculating = false
    @Published var selectedHunk = 0
    @Published var characterHighlights = true
    @Published var showDeletions = false {
        didSet { if showDeletions != oldValue { updateDeletionPreview() } }
    }
    @Published private(set) var deletionPreview: DeletionPreview?
    @Published var ignoreWhitespace = false { didSet { compare() } }
    @Published var ignoreCase = false { didSet { compare() } }
    @Published var synchronizedScrolling = true
    @Published var alignDifferences = true
    @Published var wrapLines = true
    @Published var searchQuery = "" {
        didSet { if !searchQuery.utf16.elementsEqual(oldValue.utf16) { updateSearch() } }
    }
    @Published var searchIgnoreCase = false { didSet { if searchIgnoreCase != oldValue { updateSearch() } } }
    @Published var isSearchVisible = false {
        didSet {
            // Hiding Find keeps its query and position available to ⌘G/⇧⌘G.
            if isSearchVisible && !oldValue { updateSearch() }
        }
    }
    @Published var isReplaceVisible = false { didSet { if isReplaceVisible != oldValue { updateSearch() } } }
    @Published var replacementText = "" {
        didSet { if !replacementText.utf16.elementsEqual(oldValue.utf16) { cancelReplacement(); replacementCount = nil; replacementFailure = nil } }
    }
    @Published var replacementScope: ReplacementScope = .left {
        didSet { if replacementScope != oldValue { updateSearch() } }
    }
    @Published private(set) var replacing = false
    @Published private(set) var replacementCount: Int?
    @Published private var replacementFailure: Error?
    var replacementError: String? { replacementFailure.map { localizedErrorDescription($0) } }
    @Published private(set) var searchMatches: [SessionSearchMatch] = []
    @Published private(set) var currentMatch: Int?
    @Published private(set) var searching = false
    @Published private(set) var searchLimited = false
    @Published private(set) var searchNavigationID = UUID()
    @Published var focusSide: Side = .left
    @Published var navigationID = UUID()
    @Published var leftSourceID = UUID()
    @Published var rightSourceID = UUID()
    var changed: (() -> Void)?
    private var task: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var replacementTask: Task<Void, Never>?
    private var replacementGeneration = 0
    private var applyingReplacement = false
    private var deletionPreviewTask: Task<Void, Never>?
    private(set) var previewGeneration = 0
    private var generation = 0
    private(set) var leftRevision = 0
    private(set) var rightRevision = 0
    var leftLoadID = UUID()
    var rightLoadID = UUID()
    // Retain the actual text views across tab switches, including selections and undo targets.
    var leftEditorState: TextEditorState?
    var rightEditorState: TextEditorState?
    // Keep image alignment and decoded previews when switching comparison tabs.
    lazy var imageComparisonModel = ImageComparisonModel()
    lazy var binaryComparisonModel = BinaryComparisonModel()
    lazy var pdfComparisonModel = PDFComparisonModel()
    lazy var pluginTableModel = PluginTableModel()
    lazy var archiveComparisonModel = ArchiveComparisonModel()
    private var storedPhotoState: PhotoWorkspaceState?
    lazy var photoComparisonModel: PhotoComparisonModel = {
        let model = PhotoComparisonModel(state: storedPhotoState ?? .init())
        model.onStateChanged = { [weak self, weak model] in
            guard let self, let model else { return }
            self.storedPhotoState = model.state
            self.changed?()
        }
        return model
    }()
    private var storedAPIState: APIWorkspaceState?
    lazy var apiComparisonModel: APIComparisonModel = {
        let model = APIComparisonModel(state: storedAPIState ?? .init())
        model.onStateChanged = { [weak self, weak model] in
            guard let self, let model else { return }
            self.storedAPIState = model.state
            self.changed?()
        }
        return model
    }()
    private struct ClearedText {
        let left: String
        let right: String
        let showDeletions: Bool
    }
    @Published private var clearedText: ClearedText?
    private var changingClearAction = false

    init(id: UUID = UUID(), kind: ComparisonKind = .text, left: StoredTextSide = .init(), right: StoredTextSide = .init(), pluginID: String? = nil, photoState: PhotoWorkspaceState? = nil, apiState: APIWorkspaceState? = nil) {
        self.id = id; self.kind = kind; self.left = left; self.right = right; self.pluginID = pluginID
        storedPhotoState = photoState?.isValid == true ? photoState : nil
        storedAPIState = apiState?.isValid == true ? apiState : nil
        if kind == .text { compare() }
    }
    deinit {
        task?.cancel()
        searchTask?.cancel()
        replacementTask?.cancel()
        deletionPreviewTask?.cancel()
    }
    var title: String {
        let l = left.path.map { URL(fileURLWithPath: $0).lastPathComponent }
        let r = right.path.map { URL(fileURLWithPath: $0).lastPathComponent }
        if pluginID == "org.crossdiff.api", l == nil, r == nil { return L("API 对比", "API Compare") }
        let unnamed = pluginID == "org.crossdiff.api" ? L("粘贴内容", "Pasted Input") : kind == .text ? L("临时文本", "Temporary Text") : L("待选择", "Not Selected")
        return l == nil && r == nil ? L("临时文本", "Untitled Comparison") : "\(l ?? unnamed) ↔ \(r ?? unnamed)"
    }
    var dirty: Bool { !left.text.utf16.elementsEqual(left.savedText.utf16) || !right.text.utf16.elementsEqual(right.savedText.utf16) }
    var snapshot: StoredComparison { .init(id: id, kind: kind.rawValue, left: left, right: right, pluginID: pluginID, photoState: storedPhotoState, apiState: storedAPIState) }
    var canClearText: Bool { kind == .text && (!left.text.isEmpty || !right.text.isEmpty) }
    var canRestoreClearedText: Bool { clearedText != nil && left.text.isEmpty && right.text.isEmpty }
    func value(_ side: Side) -> StoredTextSide { side == .left ? left : right }
    func setText(_ text: String, side: Side) {
        guard !text.utf16.elementsEqual(value(side).text.utf16) else { return }
        if !changingClearAction { clearedText = nil }
        if side == .left { left.text = text; leftRevision += 1 } else { right.text = text; rightRevision += 1 }
        compare(); updateSearch(navigate: false); changed?()
    }
    func replace(_ value: StoredTextSide, side: Side, resetUndo: Bool = false) {
        clearedText = nil
        if side == .left { left = value; leftRevision += 1 } else { right = value; rightRevision += 1 }
        if resetUndo {
            if side == .left { leftEditorState = nil; leftSourceID = UUID() }
            else { rightEditorState = nil; rightSourceID = UUID() }
        }
        compare(); updateSearch(navigate: false); changed?()
    }
    /// Clear the current pair without detaching files or replacing retained editors.
    /// The inline restore lasts until the next source edit; native per-side undo remains available.
    func clearText() {
        guard kind == .text else { return }
        finishTextInput()
        guard canClearText else { return }
        // Discard file-open results started before this action, including an
        // empty side whose text revision would otherwise remain unchanged.
        leftLoadID = UUID(); rightLoadID = UUID()
        let previous = ClearedText(left: left.text, right: right.text, showDeletions: showDeletions)
        changingClearAction = true
        defer { changingClearAction = false }
        showDeletions = false
        closeSearch()
        editSource("", side: .left, actionName: L("清空文本", "Clear Text"))
        editSource("", side: .right, actionName: L("清空文本", "Clear Text"))
        selectedHunk = 0
        clearedText = previous
    }
    func restoreClearedText() {
        // Finish composition before checking eligibility: a new input must never
        // be overwritten by an earlier clear snapshot.
        finishTextInput()
        guard canRestoreClearedText, let previous = clearedText else { return }
        changingClearAction = true
        defer { changingClearAction = false }
        clearedText = nil
        editSource(previous.left, side: .left, actionName: L("恢复清空", "Restore Cleared Text"))
        editSource(previous.right, side: .right, actionName: L("恢复清空", "Restore Cleared Text"))
        showDeletions = previous.showDeletions
    }
    private func finishTextInput() {
        for side in [Side.left, .right] {
            guard let state = side == .left ? leftEditorState : rightEditorState else { continue }
            if state.editor.hasMarkedText() {
                state.editor.unmarkText()
                state.editor.inputContext?.discardMarkedText()
                setText(state.editor.string, side: side)
            }
        }
    }
    private func editSource(_ text: String, side: Side, actionName: String) {
        if let state = side == .left ? leftEditorState : rightEditorState {
            let editor = state.editor
            if !editor.string.utf16.elementsEqual(text.utf16) {
                editor.breakUndoCoalescing()
                state.undoManager.beginUndoGrouping()
                editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                editor.breakUndoCoalescing()
                state.undoManager.setActionName(actionName)
                state.undoManager.endUndoGrouping()
            }
        }
        // Also supports a session whose editors have not been mounted yet.
        setText(text, side: side)
    }
    func compare() {
        guard kind == .text else { return }
        task?.cancel(); generation += 1
        let version = generation, l = left.text, r = right.text
        let options = TextDiffOptions(ignoreWhitespace: ignoreWhitespace, ignoreCase: ignoreCase)
        calculating = true
        updateDeletionPreview()
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            let work = Task.detached(priority: .userInitiated) { try? TextDiffEngine.compareCancellable(l, r, options: options) }
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, let self, self.generation == version, let result else { return }
            self.result = result; self.calculating = false
            self.selectedHunk = min(self.selectedHunk, max(0, result.hunks.count - 1))
            self.updateDeletionPreview()
        }
    }
    private func updateDeletionPreview() {
        deletionPreviewTask?.cancel(); previewGeneration += 1
        deletionPreview = nil
        guard showDeletions, !calculating, let result else { return }
        let version = previewGeneration, l = left.text, r = right.text
        let options = TextDiffOptions(ignoreWhitespace: ignoreWhitespace, ignoreCase: ignoreCase)
        deletionPreviewTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                DeletionPreview.make(left: l, right: r, result: result, options: options)
            }
            let preview = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, let self, self.showDeletions,
                  self.previewGeneration == version else { return }
            self.deletionPreview = preview
        }
    }
    func navigate(_ offset: Int) {
        guard let result, !result.hunks.isEmpty, !calculating else { return }
        selectedHunk = (selectedHunk + offset + result.hunks.count) % result.hunks.count
        navigationID = UUID()
    }
    /// Cursor and selection changes choose a merge target without causing navigation or scrolling.
    func selectHunk(atUTF16 offset: Int, side: Side) {
        guard !calculating, let result else { return }
        let length = value(side).text.utf16.count
        guard offset >= 0, offset <= length else { return }
        if let index = result.hunks.firstIndex(where: { hunk in
            let range = side == .left ? hunk.leftRange : hunk.rightRange
            return range.length == 0 ? offset == range.location
                : NSLocationInRange(offset, range) || (offset == length && NSMaxRange(range) == length)
        }), selectedHunk != index {
            selectedHunk = index
        }
    }
    var currentSearchMatch: SessionSearchMatch? {
        guard let currentMatch, searchMatches.indices.contains(currentMatch) else { return nil }
        return searchMatches[currentMatch]
    }
    var searchStatus: String {
        if searchQuery.isEmpty { return L("输入查找内容", "Enter text to find") }
        if searching { return L("正在查找…", "Finding…") }
        guard let currentMatch else { return L("无匹配", "No matches") }
        return "\(currentMatch + 1) / \(searchMatches.count)" + (searchLimited ? L(" · 已限量", " · Limited") : "")
    }
    var replacementStatus: String? {
        if let replacementError { return replacementError }
        if replacing { return L("正在替换…", "Replacing…") }
        guard let replacementCount else { return nil }
        return L("已替换 \(replacementCount) 处", "Replaced \(replacementCount) \(replacementCount == 1 ? "match" : "matches")")
    }
    var canReplaceCurrentMatch: Bool { kind == .text && isSearchVisible && isReplaceVisible && !searching && !replacing && currentSearchMatch != nil }
    var canReplaceAllMatches: Bool { kind == .text && isSearchVisible && isReplaceVisible && !searchQuery.isEmpty && !replacing && !searching && !searchMatches.isEmpty }
    func showSearch(replacing: Bool = false) {
        guard kind == .text else { return }
        if replacing && (!isReplaceVisible || !isSearchVisible) { replacementScope = focusSide == .left ? .left : .right }
        isReplaceVisible = replacing
        isSearchVisible = true
        NotificationCenter.default.post(name: .crossDiffFocusSearch, object: id)
    }
    func closeSearch() { isSearchVisible = false; cancelReplacement() }
    func navigateSearch(_ offset: Int) {
        guard !searching, !searchMatches.isEmpty else { return }
        let count = searchMatches.count
        let start = currentMatch ?? (offset >= 0 ? -1 : 0)
        currentMatch = ((start + offset) % count + count) % count
        if let match = currentSearchMatch {
            focusSide = match.side
            selectHunk(atUTF16: match.range.location, side: match.side)
        }
        searchNavigationID = UUID()
    }
    private func updateSearch(navigate: Bool = true, preferred: SessionSearchMatch? = nil) {
        if !applyingReplacement { cancelReplacement(); replacementCount = nil; replacementFailure = nil }
        searchTask?.cancel(); searchGeneration += 1
        let previous = currentSearchMatch
        searchMatches = []; currentMatch = nil; searching = false; searchLimited = false
        guard kind == .text, !searchQuery.isEmpty else { return }
        let version = searchGeneration, l = left.text, r = right.text
        let query = searchQuery, ignoreCase = searchIgnoreCase
        let scope = isReplaceVisible ? replacementScope : .both
        searching = true
        searchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            let work = Task.detached(priority: .userInitiated) { () -> (matches: [SessionSearchMatch], limited: Bool)? in
                do {
                    let left = try scope.includes(.left) ? TextSearch.matches(in: l, query: query, ignoreCase: ignoreCase,
                                                      limit: 10_001,
                                                      cancellationCheck: { try Task.checkCancellation() }) : []
                    let right = try scope.includes(.right) ? TextSearch.matches(in: r, query: query, ignoreCase: ignoreCase,
                                                       limit: 10_001,
                                                       cancellationCheck: { try Task.checkCancellation() }) : []
                    return (left.prefix(10_000).map { SessionSearchMatch(side: .left, range: $0) }
                        + right.prefix(10_000).map { SessionSearchMatch(side: .right, range: $0) }, left.count > 10_000 || right.count > 10_000)
                } catch { return nil }
            }
            let matches = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, let self, self.searchGeneration == version, let matches else { return }
            self.searching = false
            self.searchMatches = matches.matches; self.searchLimited = matches.limited
            self.currentMatch = preferred.flatMap { anchor in
                matches.matches.firstIndex { $0.side == anchor.side && $0.range.location >= anchor.range.location }
                    ?? matches.matches.firstIndex { $0.side == anchor.side }
            } ?? previous.flatMap { matches.matches.firstIndex(of: $0) } ?? (matches.matches.isEmpty ? nil : 0)
            // A search already in flight may finish after Esc. Refresh its
            // matches without moving the user's insertion point or selection.
            if navigate && self.isSearchVisible {
                if let match = self.currentSearchMatch {
                    self.focusSide = match.side
                    self.selectHunk(atUTF16: match.range.location, side: match.side)
                }
                self.searchNavigationID = UUID()
            }
        }
    }

    func replaceCurrentMatch() {
        guard canReplaceCurrentMatch else { return }
        finishTextInput()
        guard canReplaceCurrentMatch, let match = currentSearchMatch, replacementScope.includes(match.side) else { return }
        let source = value(match.side).text as NSString
        guard NSMaxRange(match.range) <= source.length else { return }
        let matchedText = source.substring(with: match.range)
        guard TextSearch.matches(in: matchedText, query: searchQuery, ignoreCase: searchIgnoreCase) == [NSRange(location: 0, length: match.range.length)] else { return }
        guard source.length - match.range.length <= TextReplacement.maximumUTF16Length - replacementText.utf16.count else {
            replacementFailure = TextReplacementError.resultTooLarge
            return
        }
        let newText = source.replacingCharacters(in: match.range, with: replacementText)
        let anchor = SessionSearchMatch(side: match.side, range: NSRange(location: match.range.location + replacementText.utf16.count, length: 0))
        applyingReplacement = true
        editSource(newText, side: match.side, actionName: L("替换", "Replace"))
        updateSearch(navigate: true, preferred: anchor)
        applyingReplacement = false
        replacementCount = 1; replacementFailure = nil
    }

    /// Compute the full replacement away from AppKit; the navigation match cap never limits edits.
    func replaceAllMatches() {
        guard canReplaceAllMatches else { return }
        finishTextInput()
        guard canReplaceAllMatches else { return }
        cancelReplacement()
        let version = replacementGeneration
        let l = left.text, r = right.text, lr = leftRevision, rr = rightRevision
        let query = searchQuery, replacement = replacementText, ignoreCase = searchIgnoreCase, scope = replacementScope
        replacing = true; replacementCount = nil; replacementFailure = nil
        replacementTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> Result<(TextReplacementResult?, TextReplacementResult?), Error> in
                do {
                    let left = try scope.includes(.left) ? TextReplacement.replacingAll(in: l, query: query, replacement: replacement, ignoreCase: ignoreCase, cancellationCheck: { try Task.checkCancellation() }) : nil
                    let right = try scope.includes(.right) ? TextReplacement.replacingAll(in: r, query: query, replacement: replacement, ignoreCase: ignoreCase, cancellationCheck: { try Task.checkCancellation() }) : nil
                    try Task.checkCancellation()
                    return .success((left, right))
                } catch { return .failure(error) }
            }
            let outcome = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, let self, self.replacementGeneration == version,
                  self.leftRevision == lr, self.rightRevision == rr,
                  self.searchQuery.utf16.elementsEqual(query.utf16),
                  self.replacementText.utf16.elementsEqual(replacement.utf16),
                  self.searchIgnoreCase == ignoreCase, self.replacementScope == scope,
                  self.isSearchVisible, self.isReplaceVisible else { return }
            self.replacing = false
            self.replacementTask = nil
            switch outcome {
            case .failure(let error):
                if !(error is CancellationError) { self.replacementFailure = error }
            case .success(let pair):
                // Do not interrupt fresh IME composition that started during background computation.
                @MainActor func inputIsCurrent(_ state: TextEditorState?, source: String) -> Bool {
                    guard let state else { return true }
                    return !state.editor.hasMarkedText() && !state.pendingNativeEdit
                        && state.editor.string.utf16.elementsEqual(source.utf16)
                }
                guard (!scope.includes(.left) || inputIsCurrent(self.leftEditorState, source: l)),
                      (!scope.includes(.right) || inputIsCurrent(self.rightEditorState, source: r)) else {
                    self.replacementFailure = ReplacementInputError.compositionInProgress
                    return
                }
                self.applyingReplacement = true
                if let left = pair.0 { self.editSource(left.text, side: .left, actionName: L("全部替换", "Replace All")) }
                if let right = pair.1 { self.editSource(right.text, side: .right, actionName: L("全部替换", "Replace All")) }
                self.updateSearch(navigate: false)
                self.applyingReplacement = false
                self.replacementCount = (pair.0?.count ?? 0) + (pair.1?.count ?? 0)
            }
        }
    }

    func cancelReplacement() {
        replacementTask?.cancel(); replacementTask = nil
        replacementGeneration += 1; replacing = false
    }
    func merge(fromLeft: Bool) {
        guard !calculating, let result, result.hunks.indices.contains(selectedHunk) else { return }
        let text = TextDiffEngine.applying(result.hunks[selectedHunk], fromLeft: fromLeft, left: left.text, right: right.text)
        setText(text, side: fromLeft ? .right : .left)
    }
}

struct OpenCandidate: Identifiable, Hashable {
    let url: URL
    let kind: ComparisonKind
    var pluginID: String? = nil
    var acceptsFolders = false
    func isCompatible(with other: OpenCandidate) -> Bool {
        if kind == .folder && other.kind == .plugin && other.acceptsFolders { return true }
        if other.kind == .folder && kind == .plugin && acceptsFolders { return true }
        if [.text, .binary].contains(kind), [.text, .binary].contains(other.kind) { return true }
        return kind == other.kind && pluginID == other.pluginID
    }
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct PendingPair: Identifiable {
    let id = UUID()
    let left: OpenCandidate
    let right: OpenCandidate
}

@MainActor
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()
    @Published var sessions: [ComparisonSession] = []
    @Published var selectedID: UUID?
    @Published var candidates: [OpenCandidate] = []
    @Published var pairing = false
    @Published var newComparison: NewComparisonModel?
    var showPluginsAfterNewComparison = false
    @Published var opening = false
    @Published private var messageProvider: (() -> String)?
    var message: String? {
        get { messageProvider?() }
        set { messageProvider = newValue.map { text in { text } } }
    }
    private func presentMessage(_ text: @escaping () -> String) { messageProvider = text }
    private func presentError(_ error: Error) { messageProvider = { localizedErrorDescription(error) } }
    private var persistenceTask: Task<Void, Never>?
    private let persistence: SessionPersistence
    private var persistenceGeneration = 0
    private let sessionURL: URL
    private var recoveryFailed = false
    private var openGeneration = 0
    private var openingBatches = 0
    private var pairingPluginID: String?
    private var pairingKind: ComparisonKind?
    private var deferredOpenRequests: [(urls: [URL], pluginID: String?, kind: ComparisonKind?)] = []

    private init() {
        let directory = ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CrossDiff", isDirectory: true)
        sessionURL = directory.appendingPathComponent("sessions.json")
        persistence = SessionPersistence(url: sessionURL)
        do {
            for record in try SessionFile.load(from: sessionURL) {
                guard let kind = ComparisonKind(rawValue: record.kind) else { continue }
                attach(ComparisonSession(id: record.id, kind: kind, left: record.left, right: record.right, pluginID: record.pluginID, photoState: record.photoState, apiState: record.apiState))
            }
        } catch {
            recoveryFailed = true
            presentMessage { L("上次会话未能恢复，原记录已保留。\(localizedErrorDescription(error))", "The previous session could not be restored. Its saved data has been preserved. \(localizedErrorDescription(error))") }
        }
        if sessions.isEmpty { attach(ComparisonSession()) }
        selectedID = sessions.first?.id
    }

    var selected: ComparisonSession? { sessions.first { $0.id == selectedID } }
    func attach(_ session: ComparisonSession) {
        session.changed = { [weak self] in self?.schedulePersistence() }
        sessions.append(session)
    }
    func newText() { let session = ComparisonSession(); attach(session); selectedID = session.id; schedulePersistence() }
    func beginNewComparison(kind: ComparisonKind? = nil, pluginID: String? = nil) {
        guard !pairing, newComparison == nil else { return }
        let draft = NewComparisonModel(store: self)
        if let kind, let type = draft.types.first(where: { $0.kind == kind && $0.pluginID == pluginID }) { draft.select(type) }
        newComparison = draft
    }
    func newComparisonDidDismiss() {
        if showPluginsAfterNewComparison {
            showPluginsAfterNewComparison = false
            NativeMenuController.shared.showPlugins(nil)
        }
        resumeDeferredOpens()
    }
    func resumeDeferredOpens() {
        while newComparison == nil, !pairing, !deferredOpenRequests.isEmpty {
            let request = deferredOpenRequests.removeFirst()
            accept(request.urls, pluginID: request.pluginID, kind: request.kind)
        }
    }
    func close(_ session: ComparisonSession) {
        if session.dirty {
            let alert = NSAlert(); alert.messageText = L("关闭这个比较？", "Close this comparison?")
            alert.informativeText = L("此比较中的未保存编辑将被丢弃。原文件不会被修改。", "Unsaved changes in this comparison will be discarded. The original files will not be changed.")
            alert.addButton(withTitle: L("取消", "Cancel")); alert.addButton(withTitle: L("关闭并丢弃", "Discard Changes and Close"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        if session.kind == .binary { session.binaryComparisonModel.cancel() }
        sessions.removeAll { $0.id == session.id }
        if selectedID == session.id { selectedID = sessions.last?.id }
        if sessions.isEmpty { newText() }
        schedulePersistence()
    }
    func openPanel(kind: ComparisonKind? = nil, pluginID: String? = nil) {
        let panel = NSOpenPanel()
        panel.title = L("打开要比较的文件或文件夹", "Open Files or Folders to Compare")
        panel.prompt = L("打开", "Open")
        panel.canChooseFiles = kind != .folder
        let archivePlugin = PluginManager.shared.plugin(id: pluginID)?.package.manifest.inputKind == .archiveCatalog
        panel.canChooseDirectories = archivePlugin || pluginID == nil && (kind == nil || kind == .folder)
        panel.allowsMultipleSelection = true
        if kind == .image { panel.allowedContentTypes = [.image] }
        if let pluginID, let plugin = PluginManager.shared.plugin(id: pluginID), !archivePlugin {
            panel.allowedContentTypes = plugin.package.manifest.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        }
        if panel.runModal() == .OK { accept(panel.urls, pluginID: pluginID, kind: kind) }
    }
    func accept(_ urls: [URL], pluginID: String? = nil, kind: ComparisonKind? = nil) {
        // Finder can deliver URLs while a creation or pairing sheet is active.
        // Preserve its inputs and defer the independent open request until dismissal.
        if newComparison != nil || pairing {
            deferredOpenRequests.append((urls, pluginID, kind)); return
        }
        let packages = urls.filter { kind != .binary && $0.pathExtension.lowercased() == "crossdiffplugin" }
        if !packages.isEmpty {
            guard packages.count == 1, urls.count == 1 else {
                presentMessage { L("请一次安装一个插件，完成后再打开比较文件。", "Install one plugin at a time, then open comparison files.") }; return
            }
            PluginManager.shared.inspect(packages[0]); return
        }
        pairingPluginID = pluginID
        pairingKind = kind
        var unique: [OpenCandidate] = []
        do {
            for url in urls {
                guard !unique.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { continue }
                unique.append(try candidate(url, pluginID: pluginID, kind: kind))
            }
        } catch { presentError(error); return }
        guard !unique.isEmpty else { return }
        if unique.count == 2 && unique[0].isCompatible(with: unique[1]) {
            openPairs([.init(left: unique[0], right: unique[1])])
        } else {
            candidates = unique; pairing = true
        }
    }
    private func candidate(_ url: URL, pluginID: String? = nil, kind: ComparisonKind? = nil) throws -> OpenCandidate {
        let resource = try url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        if kind == .binary {
            // Validate without decoding or retaining the contents. An explicit
            // byte comparison also accepts image, document and plugin packages.
            _ = try BinaryFileSource(url: url)
            return .init(url: url, kind: .binary)
        }
        if let pluginID {
            guard let plugin = PluginManager.shared.plugin(id: pluginID), plugin.enabled else {
                throw PluginAppError(zh: "所选文件与插件不兼容，或插件已停用。", en: "The selected file is incompatible with this plugin, or the plugin is disabled.")
            }
            let acceptsFolder = plugin.package.manifest.inputKind == .archiveCatalog
            guard resource.isDirectory == true ? acceptsFolder : plugin.package.manifest.fileExtensions.contains(url.pathExtension.lowercased()) else {
                throw PluginAppError(zh: "所选文件与插件不兼容。", en: "The selected file is incompatible with this plugin.")
            }
            return .init(url: url, kind: .plugin, pluginID: pluginID, acceptsFolders: acceptsFolder)
        }
        // Existing native folder/image opening keeps its default route. A plugin
        // may still handle these extensions when explicitly chosen in Compare.
        if resource.isDirectory == true { return .init(url: url, kind: .folder) }
        if resource.contentType?.conforms(to: .image) == true { return .init(url: url, kind: .image) }
        if let plugin = PluginManager.shared.matching(url) {
            return .init(url: url, kind: .plugin, pluginID: plugin.id, acceptsFolders: plugin.package.manifest.inputKind == .archiveCatalog)
        }
        // Preserve PDF sessions even while their bundled plugin is disabled.
        if url.pathExtension.lowercased() == "pdf" { return .init(url: url, kind: .plugin, pluginID: "org.crossdiff.pdf") }
        if ArchiveComparisonModel.fileExtensions.contains(url.pathExtension.lowercased()) {
            return .init(url: url, kind: .plugin, pluginID: ArchiveComparisonModel.pluginID, acceptsFolders: true)
        }
        let inferredKind: ComparisonKind
        if ["doc", "docx", "xlsx", "xls", "pptx"].contains(url.pathExtension.lowercased()) {
            throw UnsupportedDocumentError(fileName: url.lastPathComponent)
        } else { inferredKind = try BinaryFileDetection.isLikelyBinary(url: url) ? .binary : .text }
        return .init(url: url, kind: inferredKind)
    }
    func addCandidates() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = pairingKind != .binary && (pairingPluginID == nil || PluginManager.shared.plugin(id: pairingPluginID)?.package.manifest.inputKind == .archiveCatalog)
        panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.title = L("添加要比较的文件或文件夹", "Add Files or Folders to Compare")
        panel.prompt = L("添加", "Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !candidates.contains(where: { $0.url == url }) {
            do { candidates.append(try candidate(url, pluginID: pairingPluginID, kind: pairingKind)) } catch { presentError(error) }
        }
    }
    func openPairs(_ pairs: [PendingPair]) {
        guard pairs.allSatisfy({ $0.left.isCompatible(with: $0.right) }) else { return }
        pairing = false; opening = true; openingBatches += 1
        let version = openGeneration
        Task {
            var errors: [(title: String, error: Error)] = []
            for pair in pairs {
                guard version == openGeneration else { return }
                let comparisonKind: ComparisonKind = pair.left.kind == .binary || pair.right.kind == .binary ? .binary :
                    (pair.left.kind == .plugin || pair.right.kind == .plugin ? .plugin : pair.left.kind)
                let comparisonPluginID = pair.left.pluginID ?? pair.right.pluginID
                do {
                    let record = try await Task.detached(priority: .userInitiated) {
                        if comparisonKind == .text {
                            let l = try TextFileIO.read(pair.left.url), r = try TextFileIO.read(pair.right.url)
                            return StoredComparison(kind: "text", left: .init(text: l.text, path: pair.left.url.path, encoding: l.encoding, signature: l.signature, savedText: l.text), right: .init(text: r.text, path: pair.right.url.path, encoding: r.encoding, signature: r.signature, savedText: r.text))
                        }
                        return StoredComparison(kind: comparisonKind.rawValue, left: .init(path: pair.left.url.path), right: .init(path: pair.right.url.path))
                    }.value
                    guard version == openGeneration else { return }
                    let session = ComparisonSession(kind: comparisonKind, left: record.left, right: record.right, pluginID: comparisonPluginID)
                    attach(session); selectedID = session.id
                } catch { errors.append(("\(pair.left.name) ↔ \(pair.right.name)", error)) }
            }
            guard version == openGeneration else { return }
            openingBatches -= 1; opening = openingBatches > 0; schedulePersistence()
            if !errors.isEmpty { presentMessage { [errors] in errors.map { "\($0.title): \(localizedErrorDescription($0.error))" }.joined(separator: "\n\n") } }
        }
    }
    func openPair(_ left: URL, _ right: URL) { accept([left, right]) }

    func chooseTextFile(for session: ComparisonSession, side: Side) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = side == .left ? L("打开左侧文本文件", "Open Left Text File") : L("打开右侧文本文件", "Open Right Text File")
        panel.prompt = L("打开", "Open")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { guard try candidate(url).kind == .text else { presentMessage { L("请为文本比较选择文本文件。", "Choose a text file for text comparison.") }; return } }
        catch { presentError(error); return }
        if !session.value(side).text.utf16.elementsEqual(session.value(side).savedText.utf16) {
            let alert = NSAlert(); alert.messageText = L("替换此侧的未保存内容？", "Replace the unsaved text on this side?"); alert.addButton(withTitle: L("取消", "Cancel")); alert.addButton(withTitle: L("替换", "Replace"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        let revision = side == .left ? session.leftRevision : session.rightRevision
        let loadID = UUID()
        if side == .left { session.leftLoadID = loadID } else { session.rightLoadID = loadID }
        Task {
            do {
                let file = try await Task.detached { try TextFileIO.read(url) }.value
                guard sessions.contains(where: { $0.id == session.id }),
                      revision == (side == .left ? session.leftRevision : session.rightRevision),
                      loadID == (side == .left ? session.leftLoadID : session.rightLoadID) else { return }
                session.replace(.init(text: file.text, path: url.path, encoding: file.encoding, signature: file.signature, savedText: file.text), side: side, resetUndo: true)
            } catch { presentError(error) }
        }
    }
    func save(_ session: ComparisonSession, side: Side, saveAs: Bool = false) {
        guard session.kind == .text, sessions.contains(where: { $0.id == session.id }) else { return }
        let revision = side == .left ? session.leftRevision : session.rightRevision
        var value = session.value(side)
        var destination = value.path.map { URL(fileURLWithPath: $0) }
        var expected = value.signature
        if destination == nil || saveAs {
            let panel = NSSavePanel(); panel.nameFieldStringValue = destination?.lastPathComponent ?? L("未命名.txt", "Untitled.txt")
            panel.title = side == .left ? L("保存左侧文本", "Save Left Text") : L("保存右侧文本", "Save Right Text")
            panel.prompt = L("保存", "Save")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard sessions.contains(where: { $0.id == session.id }),
                  revision == (side == .left ? session.leftRevision : session.rightRevision) else {
                presentMessage { L("此侧内容在选择保存位置时发生了变化，本次保存已取消。请确认当前内容后重新保存。", "The text changed while you were choosing a save location. Saving was canceled. Review the current text and save again.") }
                return
            }
            destination = url
            if FileManager.default.fileExists(atPath: url.path) {
                guard let data = try? Data(contentsOf: url) else { presentMessage { L("无法读取目标文件，保存已取消。", "The destination file could not be read. Saving was canceled.") }; return }
                expected = TextFileIO.signature(data)
            } else { expected = nil }
        }
        guard let destination else { return }
        do {
            value.signature = try TextFileIO.write(value.text, to: destination, encoding: value.encoding, expectedSignature: expected)
            value.path = destination.path; value.savedText = value.text
            session.replace(value, side: side)
        } catch { presentError(error) }
    }
    func schedulePersistence() {
        guard !recoveryFailed else { return }
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.persistInBackground()
        }
    }
    private func persistInBackground() {
        guard !recoveryFailed else { return }
        persistenceGeneration += 1
        let version = persistenceGeneration
        persistence.save(sessions.map(\.snapshot)) { [weak self] result in
            guard case .failure(let error) = result else { return }
            Task { @MainActor [weak self] in
                guard let self, self.persistenceGeneration == version else { return }
                self.presentMessage { L("会话自动保存失败：\(localizedErrorDescription(error))", "The session could not be saved automatically: \(localizedErrorDescription(error))") }
            }
        }
    }
    @discardableResult
    func persistNow() -> Bool {
        persistenceTask?.cancel()
        persistenceGeneration += 1
        guard !recoveryFailed else { presentMessage { L("原会话记录未能读取，当前编辑尚未自动保存。请先将重要文本另存为文件，或清除损坏的会话记录。", "The saved session could not be read, so current changes have not been saved automatically. Save important text to files, or clear the damaged session data.") }; return false }
        do { try persistence.saveAndWait(sessions.map(\.snapshot)); return true }
        catch { presentMessage { L("会话自动保存失败：\(localizedErrorDescription(error))", "The session could not be saved automatically: \(localizedErrorDescription(error))") }; return false }
    }
    func clearHistory() {
        let alert = NSAlert(); alert.messageText = L("清除本机会话记录？", "Clear saved sessions on this Mac?")
        alert.informativeText = L("将关闭所有比较并清除保存的临时文本。不会删除或修改原文件。", "All comparisons will close and saved temporary text will be cleared. The original files will not be deleted or changed.")
        alert.addButton(withTitle: L("取消", "Cancel")); alert.addButton(withTitle: L("清除记录", "Clear Saved Sessions"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        persistenceTask?.cancel()
        persistenceGeneration += 1
        do {
            try persistence.clearAndWait(); recoveryFailed = false
            openGeneration += 1; openingBatches = 0; opening = false; candidates = []; pairing = false
            sessions.forEach { $0.changed = nil }; sessions = []; newText()
        } catch { presentError(error) }
    }
}
