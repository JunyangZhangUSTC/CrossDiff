import Foundation
import Combine
import CrossDiffCore

@MainActor
final class AudioComparisonModel: ObservableObject {
    typealias Side = AudioComparisonSide
    typealias Execute = @Sendable ([PluginInput], [String: PluginJSONValue]) async throws -> PluginComparisonResult
    @Published var state: AudioWorkspaceState {
        didSet {
            guard state != oldValue else { return }
            guard state.isValid else { state = oldValue; return }
            if !suppressHistory {
                history.append(oldValue); if history.count > 64 { history.removeFirst() }
                future = []; refreshHistory()
            }
            onStateChanged?()
            if state.leftRegion != oldValue.leftRegion || state.rightRegion != oldValue.rightRegion ||
                state.rate != oldValue.rate || state.pitchSemitones != oldValue.pitchSemitones { playback.stop() }
            if state.leftRegion != oldValue.leftRegion || state.rightRegion != oldValue.rightRegion ||
                state.settings.fftSize != oldValue.settings.fftSize || state.settings.hopSize != oldValue.settings.hopSize {
                scheduleAnalysis()
            }
        }
    }
    var onStateChanged: (() -> Void)?
    @Published private(set) var leftSource: AudioDecodedSource?
    @Published private(set) var rightSource: AudioDecodedSource?
    @Published private(set) var leftSpectrum: AudioSpectrumAnalysis?
    @Published private(set) var rightSpectrum: AudioSpectrumAnalysis?
    @Published private(set) var isLoading = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isMatching = false
    @Published private(set) var error: Error?
    @Published private(set) var comparison: AudioComparisonResult?
    @Published private(set) var result: PluginComparisonResult?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var cacheMessage: String?
    @Published private(set) var isClearingCache = false
    let playback = AudioPlaybackController()
    private var history: [AudioWorkspaceState] = [], future: [AudioWorkspaceState] = []
    private var suppressHistory = false
    private var execution: Execute?
    private var identity: [String]?
    private var sourceGeneration = UUID(), spectrumGeneration = UUID(), matchingGeneration = UUID(), pluginGeneration = UUID()
    private var loadTask: Task<(AudioDecodedSource, AudioDecodedSource), Error>?
    private var spectrumTask: Task<Void, Never>?
    private var matchingTask: Task<Void, Never>?
    private var pluginTask: Task<Void, Never>?
    private var evidence: [AudioCorrespondence] = []
    private var analysisState: AudioAnalysisState = .idle
    private var analysisDiagnostics: [PluginLocalizedText] = []
    var correspondences: [AudioCorrespondence] { comparison?.correspondences ?? [] }

    init(state: AudioWorkspaceState = .init()) { self.state = state.isValid ? state : .init() }

    func load(left: URL, right: URL, execute: @escaping Execute, executionID: String) async {
        execution = execute
        let requested = [left.absoluteString, right.absoluteString, executionID]
        if identity == requested, let leftSource, let rightSource,
           (try? AudioAnalysisEngine.validate(leftSource)) != nil, (try? AudioAnalysisEngine.validate(rightSource)) != nil {
            if leftSpectrum == nil || rightSpectrum == nil { scheduleAnalysis() }
            if comparison == nil { refreshPlugin() }
            return
        }
        let previous = loadTask
        cancel()
        let token = UUID(); sourceGeneration = token
        isLoading = true; error = nil; comparison = nil; result = nil
        leftSource = nil; rightSource = nil; leftSpectrum = nil; rightSpectrum = nil
        evidence = []; analysisState = .idle; analysisDiagnostics = []
        let worker = Task.detached(priority: .userInitiated) {
            _ = await previous?.result
            try Task.checkCancellation()
            let first = try AudioAnalysisEngine.load(left)
            try Task.checkCancellation()
            let second = try AudioAnalysisEngine.load(right)
            return (first, second)
        }
        loadTask = worker
        do {
            let sources = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            guard sourceGeneration == token else { return }
            leftSource = sources.0; rightSource = sources.1; identity = requested; loadTask = nil
            suppressHistory = true
            state = state.clamped(leftDuration: sources.0.duration, rightDuration: sources.1.duration)
            suppressHistory = false; history = []; future = []; refreshHistory()
            // A playback-device/graph failure must not block read-only visual analysis.
            do { try playback.prepare(left: sources.0, right: sources.1) } catch { /* Published by the playback controller. */ }
            isLoading = false
            scheduleAnalysis(); refreshPlugin()
        } catch is CancellationError { if sourceGeneration == token { isLoading = false } }
        catch { if sourceGeneration == token, !Task.isCancelled { self.error = error; isLoading = false } }
    }

    func selectRegion(_ region: AudioRegion, side: Side) {
        guard let first = leftSource, let second = rightSource else { return }
        guard let clipped = region.clipped(to: side == .left ? first.duration : second.duration) else { return }
        var updated = state
        if side == .left { updated.leftRegion = clipped } else { updated.rightRegion = clipped }
        if state.linkedRegions {
            if side == .left, let other = clipped.clipped(to: second.duration) { updated.rightRegion = other }
            if side == .right, let other = clipped.clipped(to: first.duration) { updated.leftRegion = other }
        }
        updated.selectedRegionID = nil; state = updated
    }

    func resetRegions() { var updated = state; updated.leftRegion = nil; updated.rightRegion = nil; updated.selectedRegionID = nil; state = updated }
    func saveRegion(name: String) {
        guard let leftSource, let rightSource, state.regions.count < 32 else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pair = AudioRegionPair(name: title,
            left: state.leftRegion ?? AudioRegion(start: 0, end: leftSource.duration),
            right: state.rightRegion ?? AudioRegion(start: 0, end: rightSource.duration),
            rate: state.rate, pitchSemitones: state.pitchSemitones)
        guard pair.isValid else { return }
        var updated = state; updated.regions.append(pair); updated.selectedRegionID = pair.id; state = updated
    }
    func applyRegion(id: UUID) {
        guard let pair = state.regions.first(where: { $0.id == id }) else { return }
        var updated = state; updated.leftRegion = pair.left; updated.rightRegion = pair.right
        updated.rate = pair.rate; updated.pitchSemitones = pair.pitchSemitones; updated.selectedRegionID = id; state = updated
    }
    func deleteRegion(id: UUID) {
        var updated = state; updated.regions.removeAll { $0.id == id }
        if updated.selectedRegionID == id { updated.selectedRegionID = nil }; state = updated
    }
    func selectCorrespondence(_ match: AudioCorrespondence) {
        guard let leftSource, let rightSource, match.validated(leftDuration: leftSource.duration, rightDuration: rightSource.duration) else { return }
        var updated = state; updated.leftRegion = match.left; updated.rightRegion = match.right; updated.selectedRegionID = nil
        // Selection shows the original signal. Compensation is an explicit user action.
        state = updated
    }
    func selectCorrespondence(id: String) { if let match = correspondences.first(where: { $0.id == id }) { selectCorrespondence(match) } }

    func play(side: Side) {
        guard let leftSource, let rightSource else { return }
        let left = state.leftRegion ?? AudioRegion(start: 0, end: leftSource.duration)
        let right = state.rightRegion ?? AudioRegion(start: 0, end: rightSource.duration)
        let selected = side == .left ? left : right
        if playback.isPlaying, playback.activeSide == side { playback.pause(); return }
        let old = playback.activeSide == .left ? left : right
        let fraction = max(0, min(1, (playback.playhead - old.start) / old.duration))
        let start = fraction < 1 ? selected.start + fraction * selected.duration : selected.start
        playback.play(side: side, region: selected, rate: side == .right ? state.rate : 1,
                      pitchSemitones: side == .right ? state.pitchSemitones : 0, from: start)
    }
    func stop() { playback.stop() }
    func invalidateSources() { identity = nil }
    func undo() {
        guard let previous = history.popLast() else { return }
        future.append(state); suppressHistory = true; state = previous; suppressHistory = false; refreshHistory()
    }
    func redo() {
        guard let next = future.popLast() else { return }
        history.append(state); suppressHistory = true; state = next; suppressHistory = false; refreshHistory()
    }
    private func refreshHistory() { canUndo = !history.isEmpty; canRedo = !future.isEmpty }

    func cancel() {
        sourceGeneration = UUID(); spectrumGeneration = UUID(); matchingGeneration = UUID(); pluginGeneration = UUID()
        loadTask?.cancel(); spectrumTask?.cancel(); matchingTask?.cancel(); pluginTask?.cancel()
        isLoading = false; isAnalyzing = false; isMatching = false; playback.stop()
        if analysisState == .running { analysisState = .cancelled; comparison = nil; result = nil }
    }

    private func scheduleAnalysis() {
        guard let leftSource, let rightSource else { return }
        let previous = spectrumTask; previous?.cancel()
        let token = UUID(); spectrumGeneration = token
        let snapshot = state
        leftSpectrum = nil; rightSpectrum = nil; isAnalyzing = true; error = nil
        spectrumTask = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 120_000_000)
                let worker = Task.detached(priority: .userInitiated) {
                    let left = try AudioAnalysisEngine.analyze(source: leftSource, region: snapshot.leftRegion, settings: snapshot.settings)
                    try Task.checkCancellation()
                    let right = try AudioAnalysisEngine.analyze(source: rightSource, region: snapshot.rightRegion, settings: snapshot.settings)
                    return (left, right)
                }
                let spectra = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.spectrumGeneration == token else { return }
                self.leftSpectrum = spectra.0; self.rightSpectrum = spectra.1; self.isAnalyzing = false
            } catch is CancellationError { if let self, self.spectrumGeneration == token { self.isAnalyzing = false } }
            catch { if let self, self.spectrumGeneration == token, !Task.isCancelled { self.error = error; self.isAnalyzing = false } }
        }
    }

    func runMatching() {
        guard let leftSource, let rightSource, !isMatching else { return }
        let previous = matchingTask
        let token = UUID(); matchingGeneration = token
        isMatching = true; error = nil; evidence = []; comparison = nil; result = nil
        analysisDiagnostics = []; analysisState = .running; refreshPlugin()
        matchingTask = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated) {
                    let lease = try AudioCacheStore.createJob(in: Self.cacheDirectory)
                    let job = lease.directory
                    defer { AudioCacheStore.removeJob(lease) }
                    try AudioAnalysisEngine.validate(leftSource); try AudioAnalysisEngine.validate(rightSource)
                    let leftPCM = job.appendingPathComponent("left.f32"), rightPCM = job.appendingPathComponent("right.f32")
                    try AudioAnalysisEngine.exportMonoPCM(url: leftSource.url, output: leftPCM, source: leftSource)
                    try Task.checkCancellation()
                    try AudioAnalysisEngine.exportMonoPCM(url: rightSource.url, output: rightPCM, source: rightSource)
                    let result = try await AudioMatchingEngine.compare(leftPCMURL: leftPCM, rightPCMURL: rightPCM, cacheDirectory: job)
                    try AudioAnalysisEngine.validate(leftSource); try AudioAnalysisEngine.validate(rightSource)
                    return result
                }
                let matched = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.matchingGeneration == token else { return }
                self.evidence = matched.correspondences.compactMap { match in
                    guard let left = match.left.clipped(to: leftSource.duration), let right = match.right.clipped(to: rightSource.duration) else { return nil }
                    return AudioCorrespondence(id: match.id, left: left, right: right, rateRatio: right.duration / left.duration,
                        pitchSemitones: match.pitchSemitones, score: match.score, method: match.method, state: match.state)
                }
                self.analysisState = matched.partial ? .partial : .complete
                self.analysisDiagnostics = [.init(zhHans: "自动匹配使用能量最高的源声道；候选边界为指纹覆盖范围，不代表精确剪辑点。", en: "Matching uses the highest-energy source channel. Candidate boundaries represent fingerprint coverage, not exact edit points.")]
                if matched.partial {
                    self.analysisDiagnostics.append(.init(zhHans: "此次分析未完全覆盖：可能包含不足 2 秒的输入，或候选数量达到上限。", en: "Analysis is incomplete: an input may be shorter than two seconds, or the candidate limit was reached."))
                }
                self.isMatching = false; self.refreshPlugin()
            } catch is CancellationError {
                if let self, self.matchingGeneration == token { self.isMatching = false; self.analysisState = .cancelled; self.refreshPlugin() }
            } catch {
                if let self, self.matchingGeneration == token, !Task.isCancelled { self.isMatching = false; self.error = error; self.analysisState = .failed; self.refreshPlugin() }
            }
        }
    }

    nonisolated private static var cacheDirectory: URL {
        let base = ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CrossDiff")
        return base.appendingPathComponent("AudioCache", isDirectory: true)
    }

    func clearTemporaryFiles() {
        guard !isClearingCache else { return }
        isClearingCache = true; cacheMessage = nil
        Task { [weak self] in
            do {
                let count = try await Task.detached(priority: .utility) {
                    try AudioCacheStore.clearInactive(in: Self.cacheDirectory)
                }.value
                self?.cacheMessage = L("已清理 \(count) 组临时文件；正在运行的分析不受影响。", "Cleared \(count) temporary jobs. Active analyses were preserved.")
            } catch { self?.error = error }
            self?.isClearingCache = false
        }
    }

    func cancelMatching() {
        guard isMatching else { return }
        matchingGeneration = UUID(); matchingTask?.cancel()
        isMatching = false; analysisState = .cancelled; refreshPlugin()
    }

    private func refreshPlugin() {
        guard let leftSource, let rightSource, let execution else { return }
        let previous = pluginTask; previous?.cancel()
        let token = UUID(); pluginGeneration = token
        let inputs = [PluginInput(id: "left", role: .left, name: leftSource.metadata.name, content: leftSource.metadata.pluginContent),
                      PluginInput(id: "right", role: .right, name: rightSource.metadata.name, content: rightSource.metadata.pluginContent)]
        let options = AudioComparisonRequestOptions(correspondences: evidence, analysisState: analysisState, diagnostics: analysisDiagnostics).pluginOptions
        pluginTask = Task { [weak self] in
            await previous?.value
            do {
                try Task.checkCancellation()
                let result = try await execution(inputs, options)
                let comparison = try AudioComparisonResult.parse(result, leftDuration: leftSource.duration, rightDuration: rightSource.duration)
                try Task.checkCancellation()
                guard let self, self.pluginGeneration == token else { return }
                self.result = result; self.comparison = comparison
            } catch is CancellationError {} catch { if let self, self.pluginGeneration == token, !Task.isCancelled { self.error = error } }
        }
    }
}
