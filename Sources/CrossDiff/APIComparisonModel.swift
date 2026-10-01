import Foundation
import Combine
import CrossDiffCore

/// Keeps immutable imported records and selection state with the comparison tab.
/// Imported commands are data: no request is sent and no command is executed.
@MainActor
final class APIComparisonModel: ObservableObject {
    enum Side { case left, right }
    typealias Execute = @Sendable ([PluginInput], [String: PluginJSONValue]) async throws -> PluginComparisonResult

    @Published var state: APIWorkspaceState {
        didSet {
            guard state != oldValue else { return }
            onStateChanged?()
            scheduleComparison()
        }
    }
    var onStateChanged: (() -> Void)?
    @Published private(set) var leftDocument: APIImportDocument?
    @Published private(set) var rightDocument: APIImportDocument?
    @Published private(set) var comparison: APIComparisonResult?
    @Published private(set) var result: PluginComparisonResult?
    @Published private(set) var error: Error?
    @Published private(set) var isLoading = false
    @Published private(set) var isComparing = false
    private var identity: SourceIdentity?
    private var execution: Execute?
    private var generation = UUID()
    private var comparisonTask: Task<Void, Never>?
    private var importTask: Task<(APIImportDocument, APIImportDocument), Error>?

    private struct SourceIdentity: Equatable {
        let leftPath: Data?, rightPath: Data?
        let leftText: Data, rightText: Data
        let executionID: String
    }

    init(state: APIWorkspaceState = .init()) { self.state = state.isValid ? state : .init() }

    var leftExchange: APIExchange? { selected(in: leftDocument, id: state.leftEntryID) }
    var rightExchange: APIExchange? { selected(in: rightDocument, id: state.rightEntryID) }
    var diagnostics: [PluginLocalizedText] {
        var seen = Set<String>()
        var values: [PluginLocalizedText] = leftDocument?.diagnostics ?? []
        values.append(contentsOf: rightDocument?.diagnostics ?? [])
        values.append(contentsOf: leftExchange?.diagnostics ?? [])
        values.append(contentsOf: rightExchange?.diagnostics ?? [])
        values.append(contentsOf: result?.diagnostics ?? [])
        return values.filter { seen.insert($0.en + "\n" + $0.zhHans).inserted }
    }

    func load(left: StoredTextSide, right: StoredTextSide, execute: @escaping Execute, executionID: String) async {
        let requested = SourceIdentity(leftPath: left.path.map { Data($0.utf8) }, rightPath: right.path.map { Data($0.utf8) },
                                       leftText: Data(left.text.utf8), rightText: Data(right.text.utf8), executionID: executionID)
        execution = execute
        if identity == requested, leftDocument != nil, rightDocument != nil {
            if comparison != nil, error == nil { return }
            scheduleComparison()
            if let comparisonTask {
                await withTaskCancellationHandler { await comparisonTask.value } onCancel: { comparisonTask.cancel() }
            }
            return
        }
        let previousImport = importTask, previousComparison = comparisonTask
        cancel()
        let token = UUID(); generation = token
        isLoading = true; error = nil
        leftDocument = nil; rightDocument = nil; comparison = nil; result = nil
        let worker = Task.detached(priority: .userInitiated) {
            _ = await previousImport?.result
            await previousComparison?.value
            try Task.checkCancellation()
            func read(_ source: StoredTextSide) throws -> APIImportDocument {
                if let path = source.path { return try APIImporter.load(URL(fileURLWithPath: path)) }
                return try APIImporter.parse(source.text)
            }
            let first = try read(left)
            try Task.checkCancellation()
            let second = try read(right)
            try Task.checkCancellation()
            return (first, second)
        }
        importTask = worker
        do {
            let documents = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard generation == token else { return }
            importTask = nil; identity = requested
            leftDocument = documents.0; rightDocument = documents.1; isLoading = false
            scheduleComparison()
            if let comparisonTask {
                await withTaskCancellationHandler { await comparisonTask.value } onCancel: { comparisonTask.cancel() }
            }
        } catch is CancellationError { if generation == token { isLoading = false } }
        catch { if generation == token, !Task.isCancelled { self.error = error; isLoading = false } }
    }

    func selectEntry(_ id: String, side: Side) {
        let document = side == .left ? leftDocument : rightDocument
        guard document?.exchanges.contains(where: { $0.id == id }) == true else { return }
        if side == .left { state.leftEntryID = id } else { state.rightEntryID = id }
    }

    func applyRules(headers: [String], pointers: [String]) {
        var updated = state
        updated.ignoreHeaders = headers; updated.ignoreJSONPointers = pointers
        guard updated.isValid else { return }
        state = updated
    }

    func clearRules() { applyRules(headers: [], pointers: []) }
    func invalidateSources() { identity = nil }
    func cancel() {
        generation = UUID(); importTask?.cancel(); comparisonTask?.cancel()
        isLoading = false; isComparing = false
    }

    private func selected(in document: APIImportDocument?, id: String?) -> APIExchange? {
        document?.exchanges.first(where: { $0.id == id }) ?? document?.exchanges.first
    }

    private func scheduleComparison() {
        guard let leftExchange, let rightExchange, let execution else { return }
        let previous = comparisonTask
        previous?.cancel()
        let token = UUID(); generation = token
        let options: [String: PluginJSONValue] = [
            "ignoreHeaders": .array(state.ignoreHeaders.map(PluginJSONValue.string)),
            "ignoreJSONPointers": .array(state.ignoreJSONPointers.map(PluginJSONValue.string))
        ]
        let inputs = [PluginInput(id: "left", role: .left, name: leftExchange.name, content: leftExchange.pluginContent),
                      PluginInput(id: "right", role: .right, name: rightExchange.name, content: rightExchange.pluginContent)]
        isComparing = true; error = nil; comparison = nil; result = nil
        comparisonTask = Task { [weak self] in
            // Join even cancelled predecessors: a slow plugin must not overlap newer runs.
            await previous?.value
            do {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 100_000_000)
                let result = try await execution(inputs, options)
                let comparison = try APIComparisonResult.parse(result)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.result = result; self.comparison = comparison; self.isComparing = false
            } catch is CancellationError { if let self, self.generation == token { self.isComparing = false } }
            catch { if let self, self.generation == token, !Task.isCancelled { self.error = error; self.isComparing = false } }
        }
    }
}
