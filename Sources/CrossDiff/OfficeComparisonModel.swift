import Foundation
import Combine
import CrossDiffCore

/// Imported OOXML snapshots remain immutable. Navigation and key choices rerun only
/// the restricted matching plugin; original files are reread on explicit reload.
@MainActor
final class OfficeComparisonModel: ObservableObject {
    enum Side { case left, right }
    typealias Execute = @Sendable ([PluginInput], [String: PluginJSONValue]) async throws -> PluginComparisonResult

    @Published var state: OfficeWorkspaceState {
        didSet {
            guard state != oldValue else { return }
            guard state.isValid else { state = oldValue; return }
            onStateChanged?()
            if !normalizingSelection,
               state.leftSectionID != oldValue.leftSectionID || state.rightSectionID != oldValue.rightSectionID ||
               state.keyColumns != oldValue.keyColumns {
                scheduleComparison()
            }
        }
    }
    var onStateChanged: (() -> Void)?
    @Published private(set) var leftDocument: OfficeDocument?
    @Published private(set) var rightDocument: OfficeDocument?
    @Published private(set) var comparison: OfficeComparisonResult?
    @Published private(set) var result: PluginComparisonResult?
    @Published private(set) var error: Error?
    @Published private(set) var isLoading = false
    @Published private(set) var isComparing = false
    private var identity: SourceIdentity?
    private var execution: Execute?
    private var sourceGeneration = UUID(), comparisonGeneration = UUID()
    private var comparisonTask: Task<Void, Never>?
    private var importTask: Task<(OfficeDocument, OfficeDocument), Error>?
    private var normalizingSelection = false

    private enum SourceError: LocalizedError {
        case mismatchedKinds
        var errorDescription: String? {
            L("请在两侧选择同类 Office 文件：Word、Excel 或 PowerPoint。旧格式请先转换为 .docx、.xlsx 或 .pptx。",
              "Choose the same Office format on both sides: Word, Excel or PowerPoint. Convert legacy files to .docx, .xlsx or .pptx first.")
        }
    }

    private struct SourceIdentity: Equatable {
        let left: Data, right: Data
        let executionID: String
    }

    init(state: OfficeWorkspaceState = .init()) { self.state = state.isValid ? state : .init() }
    deinit { importTask?.cancel(); comparisonTask?.cancel() }

    var leftSection: OfficeSection? { selected(in: leftDocument, id: state.leftSectionID) }
    var rightSection: OfficeSection? { selected(in: rightDocument, id: state.rightSectionID) }
    var diagnostics: [PluginLocalizedText] {
        var seen = Set<String>()
        var values: [PluginLocalizedText] = leftDocument?.diagnostics ?? []
        values.append(contentsOf: rightDocument?.diagnostics ?? [])
        values.append(contentsOf: result?.diagnostics ?? [])
        return values.filter { seen.insert($0.en + "\n" + $0.zhHans).inserted }
    }

    func load(left: URL, right: URL, execute: @escaping Execute, executionID: String) async {
        let requested = SourceIdentity(left: Data(left.absoluteString.utf8), right: Data(right.absoluteString.utf8), executionID: executionID)
        execution = execute
        if identity == requested, leftDocument != nil, rightDocument != nil {
            if comparison != nil, error == nil { return }
            scheduleComparison()
            await awaitComparison()
            return
        }
        let previousImport = importTask, previousComparison = comparisonTask
        cancel()
        let token = UUID(); sourceGeneration = token
        isLoading = true; error = nil
        leftDocument = nil; rightDocument = nil; comparison = nil; result = nil
        let worker = Task.detached(priority: .userInitiated) {
            _ = await previousImport?.result
            await previousComparison?.value
            try Task.checkCancellation()
            guard let kind = OfficeDocumentKind.from(fileExtension: left.pathExtension),
                  kind == OfficeDocumentKind.from(fileExtension: right.pathExtension) else {
                throw SourceError.mismatchedKinds
            }
            let first = try OfficeImporter.load(left)
            try Task.checkCancellation()
            let second = try OfficeImporter.load(right)
            try Task.checkCancellation()
            guard first.kind == second.kind, first.kind == kind else {
                throw SourceError.mismatchedKinds
            }
            return (first, second)
        }
        importTask = worker
        do {
            let documents = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard sourceGeneration == token else { return }
            importTask = nil; identity = requested
            leftDocument = documents.0; rightDocument = documents.1; isLoading = false
            normalizeSelection()
            scheduleComparison()
            await awaitComparison()
        } catch is CancellationError { if sourceGeneration == token { isLoading = false } }
        catch { if sourceGeneration == token, !Task.isCancelled { self.error = error; isLoading = false } }
    }

    /// Left navigation pairs by exact section name, then source order. The right
    /// picker can override that choice without moving the left selection.
    func selectSection(_ id: String, side: Side) {
        let document = side == .left ? leftDocument : rightDocument
        guard document?.sections.contains(where: { $0.id == id }) == true else { return }
        var updated = state
        if side == .left {
            updated.leftSectionID = id
            updated.rightSectionID = correspondingSection(to: id)?.id
        } else { updated.rightSectionID = id }
        state = updated
    }

    func invalidateSources() { identity = nil }
    func cancel() {
        sourceGeneration = UUID(); comparisonGeneration = UUID()
        importTask?.cancel(); comparisonTask?.cancel()
        isLoading = false; isComparing = false
    }

    private func selected(in document: OfficeDocument?, id: String?) -> OfficeSection? {
        document?.sections.first(where: { $0.id == id }) ?? document?.sections.first
    }

    private func correspondingSection(to leftID: String?) -> OfficeSection? {
        guard let leftDocument, let rightDocument,
              let index = leftDocument.sections.firstIndex(where: { $0.id == leftID }) else { return rightDocument?.sections.first }
        let section = leftDocument.sections[index]
        if let sameName = rightDocument.sections.first(where: { Data($0.name.utf8) == Data(section.name.utf8) }) { return sameName }
        return rightDocument.sections.indices.contains(index) ? rightDocument.sections[index] : rightDocument.sections.first
    }

    private func normalizeSelection() {
        var updated = state
        updated.leftSectionID = leftSection?.id
        if rightDocument?.sections.contains(where: { $0.id == updated.rightSectionID }) != true {
            updated.rightSectionID = correspondingSection(to: updated.leftSectionID)?.id
        }
        normalizingSelection = true
        state = updated
        normalizingSelection = false
    }

    private func awaitComparison() async {
        if let comparisonTask {
            await withTaskCancellationHandler { await comparisonTask.value } onCancel: { comparisonTask.cancel() }
        }
    }

    private func scheduleComparison() {
        guard let leftDocument, let rightDocument, let execution, !isLoading else { return }
        let previous = comparisonTask
        previous?.cancel()
        let token = UUID(); comparisonGeneration = token
        // A document without sections still yields a completed, empty comparison.
        let left = leftSection ?? OfficeSection(id: "empty", name: "", rows: [])
        let right = rightSection ?? OfficeSection(id: "empty", name: "", rows: [])
        let options = leftDocument.kind == .spreadsheet ? state.pluginOptions : OfficeWorkspaceState().pluginOptions
        isComparing = true; error = nil; comparison = nil; result = nil
        comparisonTask = Task { [weak self] in
            // Cancelled predecessors must finish before a new plugin run starts.
            await previous?.value
            do {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 100_000_000)
                // Constructing a large worksheet payload and decoding the result
                // are also substantial work, not only the provider execution.
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let first = PluginInput(id: "left", role: .left, name: left.name,
                        content: left.pluginContent(kind: leftDocument.kind))
                    try Task.checkCancellation()
                    let second = PluginInput(id: "right", role: .right, name: right.name,
                        content: right.pluginContent(kind: rightDocument.kind))
                    try Task.checkCancellation()
                    let result = try await execution([first, second], options)
                    try Task.checkCancellation()
                    let comparison = try OfficeComparisonResult.parse(result)
                    try Task.checkCancellation()
                    return (result, comparison)
                }
                let (result, comparison) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.comparisonGeneration == token else { return }
                self.result = result; self.comparison = comparison; self.isComparing = false
            } catch is CancellationError { if let self, self.comparisonGeneration == token { self.isComparing = false } }
            catch { if let self, self.comparisonGeneration == token, !Task.isCancelled { self.error = error; self.isComparing = false } }
        }
    }
}
