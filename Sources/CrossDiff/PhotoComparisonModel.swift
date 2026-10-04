import AppKit
import Combine
import CrossDiffCore
import UniformTypeIdentifiers

/// Owns photograph inputs and analysis independently of the SwiftUI view lifetime.
/// Regions, explicit XMP paths and viewing preferences are persisted. Rendered
/// pixels, histogram brushing and distributions never become source-file edits.
@MainActor
final class PhotoComparisonModel: ObservableObject {
    enum Side { case left, right }
    typealias Execute = @Sendable ([PluginInput]) async throws -> PluginComparisonResult

    @Published var state: PhotoWorkspaceState {
        didSet {
            guard state != oldValue else { return }
            onStateChanged?()
            let regionChanged = state.leftRegion != oldValue.leftRegion || state.rightRegion != oldValue.rightRegion
            if regionChanged
                || state.leftXMPPath != oldValue.leftXMPPath || state.rightXMPPath != oldValue.rightXMPPath {
                scheduleAnalysis()
            }
            if state.histogramChannel != oldValue.histogramChannel, highlightedRange != nil {
                highlightedRange = nil
            } else if regionChanged || state.previewChannel != oldValue.previewChannel {
                schedulePreview()
            }
        }
    }
    var onStateChanged: (() -> Void)?
    @Published private(set) var leftImage: PhotoDecodedImage?
    @Published private(set) var rightImage: PhotoDecodedImage?
    @Published private(set) var leftStatistics: PhotoStatistics?
    @Published private(set) var rightStatistics: PhotoStatistics?
    @Published private(set) var leftCurves: [PhotoRecordedCurve] = []
    @Published private(set) var rightCurves: [PhotoRecordedCurve] = []
    @Published private(set) var curveWarnings: [Error] = []
    @Published private(set) var findings: [PluginLocalizedText] = []
    @Published private(set) var diagnostics: [PluginLocalizedText] = []
    @Published private(set) var resultStatus: PluginResultStatus?
    @Published private(set) var error: Error?
    @Published private(set) var isLoading = false
    @Published private(set) var isAnalyzing = false
    @Published var highlightedRange: PhotoHistogramRange? {
        didSet {
            guard highlightedRange != oldValue else { return }
            if let highlightedRange, !highlightedRange.isValid { self.highlightedRange = nil }
            schedulePreview()
        }
    }
    @Published private(set) var leftDisplayImage: CGImage?
    @Published private(set) var rightDisplayImage: CGImage?
    @Published private(set) var isPreviewing = false
    @Published private(set) var previewError: Error?
    private var sourceURLs: (URL, URL)?
    private var execution: Execute?
    private var loadedIdentity: [String]?
    private var generation = UUID()
    private var analysisTask: Task<Void, Never>?
    private var decodeTask: Task<(PhotoDecodedImage, PhotoDecodedImage), Error>?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration = UUID()

    init(state: PhotoWorkspaceState = .init()) {
        self.state = state.isValid ? state : .init()
    }

    func load(left: URL, right: URL, execute: @escaping Execute, executionID: String) async {
        let identity = [left.absoluteString, right.absoluteString, executionID]
        execution = execute; sourceURLs = (left, right)
        if loadedIdentity == identity, leftImage != nil, rightImage != nil {
            if leftDisplayImage == nil || rightDisplayImage == nil { schedulePreview() }
            if leftStatistics != nil, rightStatistics != nil, error == nil { return }
            scheduleAnalysis()
            if let analysisTask {
                await withTaskCancellationHandler { await analysisTask.value } onCancel: { analysisTask.cancel() }
            }
            return
        }
        let previousAnalysis = analysisTask, previousDecode = decodeTask, previousPreview = previewTask
        cancel()
        let token = UUID(); generation = token
        isLoading = true; error = nil
        leftImage = nil; rightImage = nil; leftStatistics = nil; rightStatistics = nil
        leftDisplayImage = nil; rightDisplayImage = nil; previewError = nil
        highlightedRange = nil
        findings = []; diagnostics = []; resultStatus = nil; leftCurves = []; rightCurves = []; curveWarnings = []
        let worker = Task.detached(priority: .userInitiated) {
            // Cooperative library calls may finish after cancellation. Join them
            // before allocating another image or analysis buffer.
            await previousAnalysis?.value
            _ = await previousDecode?.result
            await previousPreview?.value
            try Task.checkCancellation()
            let first = try PhotoAnalysisEngine.load(left)
            try Task.checkCancellation()
            let second = try PhotoAnalysisEngine.load(right)
            try Task.checkCancellation()
            return (first, second)
        }
        decodeTask = worker
        do {
            let images = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard token == generation else { return }
            decodeTask = nil
            leftImage = images.0; rightImage = images.1
            loadedIdentity = identity; isLoading = false
            schedulePreview()
            scheduleAnalysis()
            if let analysisTask {
                await withTaskCancellationHandler { await analysisTask.value } onCancel: { analysisTask.cancel() }
            }
        } catch is CancellationError { if token == generation { isLoading = false } }
        catch { if token == generation, !Task.isCancelled { self.error = error; isLoading = false } }
    }

    func cancel() {
        generation = UUID(); analysisTask?.cancel()
        decodeTask?.cancel()
        previewGeneration = UUID(); previewTask?.cancel()
        isLoading = false; isAnalyzing = false; isPreviewing = false
    }

    func invalidateSources() { loadedIdentity = nil }

    func clearHighlight() { highlightedRange = nil }

    private func schedulePreview() {
        let previous = previewTask
        previous?.cancel()
        let token = UUID(); previewGeneration = token
        leftDisplayImage = nil; rightDisplayImage = nil; previewError = nil
        guard let leftImage, let rightImage else { isPreviewing = false; return }
        let snapshot = state, highlight = highlightedRange
        if snapshot.previewChannel == .original, highlight == nil {
            leftDisplayImage = leftImage.preview; rightDisplayImage = rightImage.preview
            isPreviewing = false
            // Retain the predecessor so a later request still joins any worker.
            return
        }
        isPreviewing = true
        previewTask = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 90_000_000)
                let worker = Task.detached(priority: .userInitiated) {
                    let left = try PhotoAnalysisEngine.preview(leftImage, channel: snapshot.previewChannel,
                        highlight: highlight, region: snapshot.leftRegion)
                    try Task.checkCancellation()
                    let right = try PhotoAnalysisEngine.preview(rightImage, channel: snapshot.previewChannel,
                        highlight: highlight, region: snapshot.rightRegion)
                    try Task.checkCancellation()
                    return (left, right)
                }
                let previews = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.previewGeneration == token else { return }
                self.leftDisplayImage = previews.0; self.rightDisplayImage = previews.1
                self.isPreviewing = false
            } catch is CancellationError {
                if let self, self.previewGeneration == token { self.isPreviewing = false }
            } catch {
                if let self, self.previewGeneration == token, !Task.isCancelled {
                    self.previewError = error; self.isPreviewing = false
                }
            }
        }
    }

    func selectRegion(_ region: PhotoRegion, side: Side) {
        guard region.isValid else { return }
        var updated = state
        if side == .left || state.linkedRegions { updated.leftRegion = region }
        if side == .right || state.linkedRegions { updated.rightRegion = region }
        state = updated
    }

    func resetRegions() {
        var updated = state; updated.leftRegion = .full; updated.rightRegion = .full; state = updated
    }

    func saveRegion(name: String) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256, state.regions.count < 32 else { return }
        state.regions.append(PhotoRegionPair(name: value, left: state.leftRegion, right: state.rightRegion))
    }

    func applyRegion(id: UUID) {
        guard let pair = state.regions.first(where: { $0.id == id }) else { return }
        var updated = state; updated.leftRegion = pair.left; updated.rightRegion = pair.right; state = updated
    }

    func deleteRegion(id: UUID) { state.regions.removeAll { $0.id == id } }

    func selectXMP(side: Side) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = L("选择这张照片对应的 XMP 记录。只读取曲线，不修改照片。", "Choose this photograph’s XMP record. Curves are read without changing the photograph.")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, url.pathExtension.lowercased() == "xmp" else { return }
            guard let self else { return }
            let existing = side == .left ? self.state.leftXMPPath : self.state.rightXMPPath
            if side == .left { self.state.leftXMPPath = url.path }
            else { self.state.rightXMPPath = url.path }
            if existing == url.path { self.scheduleAnalysis() }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    func clearXMP(side: Side) {
        if side == .left { state.leftXMPPath = nil } else { state.rightXMPPath = nil }
    }

    private func scheduleAnalysis() {
        guard let leftImage, let rightImage, let sourceURLs, let execution else { return }
        let previous = analysisTask
        previous?.cancel()
        let token = UUID(); generation = token
        let snapshot = state
        isAnalyzing = true; error = nil
        // Old distributions must not appear under the new selection while work runs.
        leftStatistics = nil; rightStatistics = nil; findings = []; diagnostics = []; resultStatus = nil
        leftCurves = []; rightCurves = []; curveWarnings = []
        analysisTask = Task { [weak self] in
            // Always join the predecessor, even if this queued request was itself
            // cancelled. Otherwise rapid changes could bypass a still-running worker.
            await previous?.value
            do {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 180_000_000)
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let first = try PhotoAnalysisEngine.analyze(leftImage, region: snapshot.leftRegion)
                    try Task.checkCancellation()
                    let second = try PhotoAnalysisEngine.analyze(rightImage, region: snapshot.rightRegion)
                    try Task.checkCancellation()
                    var warnings: [Error] = []
                    func curves(_ image: PhotoDecodedImage, _ path: String?) throws -> [PhotoRecordedCurve] {
                        guard let path else {
                            if let warning = image.curveWarning { warnings.append(warning) }
                            return image.recordedCurves
                        }
                        do { return try PhotoMetadataReader.recordedCurves(xmpURL: URL(fileURLWithPath: path)) }
                        catch is CancellationError { throw CancellationError() }
                        catch { warnings.append(error); return [] }
                    }
                    let leftCurves = try curves(leftImage, snapshot.leftXMPPath)
                    let rightCurves = try curves(rightImage, snapshot.rightXMPPath)
                    return (first, second, leftCurves, rightCurves, warnings)
                }
                let analyzed = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                let inputs = [PluginInput(id: "left", role: .left, name: sourceURLs.0.lastPathComponent, content: analyzed.0.pluginContent),
                              PluginInput(id: "right", role: .right, name: sourceURLs.1.lastPathComponent, content: analyzed.1.pluginContent)]
                let result = try await execution(inputs)
                let findings = try Self.parse(result)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.leftStatistics = analyzed.0; self.rightStatistics = analyzed.1
                self.leftCurves = analyzed.2; self.rightCurves = analyzed.3; self.curveWarnings = analyzed.4
                self.findings = findings; self.diagnostics = result.diagnostics; self.resultStatus = result.status
                self.isAnalyzing = false
            } catch is CancellationError { if let self, self.generation == token { self.isAnalyzing = false } }
            catch { if let self, self.generation == token, !Task.isCancelled { self.error = error; self.isAnalyzing = false } }
        }
    }

    static func parse(_ result: PluginComparisonResult) throws -> [PluginLocalizedText] {
        guard result.schema == "crossdiff.photography/1", let values = result.payload["findings"]?.arrayValue,
              values.count <= 8 else { throw PluginValidationError.invalidField("photography findings") }
        return try values.map {
            guard let zh = $0["zhHans"]?.stringValue, let en = $0["en"]?.stringValue,
                  !zh.isEmpty, !en.isEmpty, zh.utf8.count <= 2_048, en.utf8.count <= 2_048 else {
                throw PluginValidationError.invalidField("photography finding")
            }
            return PluginLocalizedText(zhHans: zh, en: en)
        }
    }
}
