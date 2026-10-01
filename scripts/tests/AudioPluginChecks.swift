import Foundation
import JavaScriptCore
import CrossDiffCore

@main enum AudioPluginChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }; count += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { count += 1; return }; throw Failure(description: message)
    }
    static func source(_ id: String, seconds: Double = 60, rate: Double = 48000, channels: Int = 2, format: String = "WAV") -> AudioSourceMetadata {
        .init(id: id, name: "\(id).wav", duration: seconds, sampleRate: rate, channelCount: channels,
              frameCount: String(Int(seconds * rate)), format: format)
    }
    static func pair(_ id: String, left: AudioRegion, right: AudioRegion, state: AudioCorrespondenceState = .candidate) -> AudioCorrespondence {
        .init(id: id, left: left, right: right, rateRatio: right.duration / left.duration,
              score: 42, method: "fixture-evidence", state: state)
    }
    static func request(_ left: AudioSourceMetadata, _ right: AudioSourceMetadata, pairs: [AudioCorrespondence] = [],
                        state: AudioAnalysisState = .complete) -> PluginComparisonRequest {
        .init(runID: "audio-check", inputs: [.init(id: "left", role: .left, name: left.name, content: left.pluginContent),
                                            .init(id: "right", role: .right, name: right.name, content: right.pluginContent)],
              options: AudioComparisonRequestOptions(correspondences: pairs, analysisState: state).pluginOptions)
    }
    static func changedResult(_ result: PluginComparisonResult, payload: [String: PluginJSONValue]) -> PluginComparisonResult {
        .init(runID: result.runID, schema: result.schema, status: result.status,
              summary: result.summary, diagnostics: result.diagnostics, payload: .object(payload))
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = root.appendingPathComponent("Plugins/Official/Audio")
        let script = try String(contentsOf: directory.appendingPathComponent("compare.js"), encoding: .utf8)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let package = PluginPackage(manifest: manifest, script: script, sha256: PluginPackage.digest(of: Data(script.utf8)))
        try package.validate()
        try check(manifest.id == "org.crossdiff.audio" && manifest.resultSchema == "crossdiff.audio/1", "Official audio package has a dedicated result schema")
        let context = JSContext()!; var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(script)
        func rawRun(_ req: PluginComparisonRequest) throws -> PluginComparisonResult {
            try req.validate(for: manifest)
            exception = nil
            let input = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req))
            guard let object = context.objectForKeyedSubscript("compare")?.call(withArguments: [input])?.toDictionary(), exception == nil else {
                throw Failure(description: exception ?? "Audio plugin returned no result")
            }
            let result = try JSONDecoder().decode(PluginComparisonResult.self, from: JSONSerialization.data(withJSONObject: object))
            try result.validate(for: req, manifest: manifest)
            try AudioContract.validateResult(result, request: req)
            return result
        }
        let left = source("A"), right = source("B")
        let reordered = [pair("c", left: .init(start: 40, end: 50), right: .init(start: 0, end: 10)),
                         pair("a1", left: .init(start: 0, end: 10), right: .init(start: 20, end: 30)),
                         pair("a2", left: .init(start: 0, end: 10), right: .init(start: 40, end: 50))]
        let req = request(left, right, pairs: reordered)
        let raw = try rawRun(req)
        let result = try AudioComparisonResult.parse(raw, leftDuration: 60, rightDuration: 60)
        try check(result.correspondences == reordered, "Reordered and repeated source segments survive without a forced global path")
        try check(result.leftCoveredDuration == 20 && result.rightCoveredDuration == 30, "Coverage counts a union separately on each side")
        try check(result.correspondences.allSatisfy { $0.pitchSemitones == nil }, "Unavailable pitch stays absent rather than becoming zero")
        try check(result.summary.zhHans.contains("候选") && result.diagnostics.contains { $0.en.contains("not probabilities") }, "Candidate summaries and raw-score limitations are explicit in both languages")
        let processRaw = try await PluginRunner.run(package: package, request: req,
            helperURL: root.appendingPathComponent(".build-audio-plugin-checks/CrossDiffPluginHost"))
        try check(try AudioComparisonResult.parse(processRaw, leftDuration: 60, rightDuration: 60) == result, "Restricted subprocess preserves real evidence and coverage")
        let none = try rawRun(request(left, right))
        try check(none.summary.en == "No reliable corresponding segments found", "No matches do not claim additions, removals, or identical audio")
        for state in [AudioAnalysisState.idle, .running, .partial, .failed, .cancelled] {
            let value = try rawRun(request(left, right, state: state))
            try check(value.status == .partial && value.payload["analysisState"]?.stringValue == state.rawValue, "Incomplete state \(state) never becomes completed")
        }
        let rejectPair = pair("rejected", left: .init(start: 0, end: 60), right: .init(start: 0, end: 60), state: .rejected)
        let rejected = try rawRun(request(left, right, pairs: [rejectPair]))
        try check(rejected.payload["leftCoveredDuration"]?.numberValue == 0, "Rejected evidence does not count toward coverage")
        let overlap = [pair("a", left: .init(start: 0, end: 10), right: .init(start: 0, end: 10)),
                       pair("b", left: .init(start: 5, end: 15), right: .init(start: 10, end: 20))]
        let overlapResult = try rawRun(request(left, right, pairs: overlap))
        try check(overlapResult.payload["leftCoveredDuration"]?.numberValue == 15 && overlapResult.payload["rightCoveredDuration"]?.numberValue == 20, "Partly overlapping matches do not double count")
        let resampled = source("R", rate: 24000)
        let sameTime = try rawRun(request(left, resampled, pairs: [reordered[0]]))
        try check(sameTime.payload["metadataDifferences"]?.arrayValue?.compactMap(\.stringValue) == ["sampleRate", "frameCount"], "Different sample rates remain source metadata differences, not inferred speed changes")
        let speed = pair("stretched", left: .init(start: 0, end: 10), right: .init(start: 0, end: 20))
        try check(try rawRun(request(left, right, pairs: [speed])).payload["correspondences"]?[0]?["rateRatio"]?.numberValue == 2, "Explicit source duration ratios retain their defined direction")
        try rejects("Out-of-source regions are rejected") {
            _ = try rawRun(request(left, right, pairs: [pair("bad", left: .init(start: 50, end: 70), right: .init(start: 0, end: 20))]))
        }
        try rejects("Repeated correspondence IDs are rejected") { _ = try rawRun(request(left, right, pairs: [reordered[0], reordered[0]])) }
        try rejects("Too many correspondences fail explicitly") {
            _ = try rawRun(request(left, right, pairs: (0...512).map { pair("p\($0)", left: .init(start: 0, end: 1), right: .init(start: 0, end: 1)) }))
        }
        try rejects("Incorrect source-time ratio cannot be presented as evidence") {
            _ = try rawRun(request(left, right, pairs: [.init(id: "ratio", left: .init(start: 0, end: 1), right: .init(start: 0, end: 2), rateRatio: 1, method: "test")]))
        }
        try rejects("Non-finite raw score is rejected") {
            _ = try rawRun(request(left, right, pairs: [.init(id: "score", left: .init(start: 0, end: 1), right: .init(start: 0, end: 1), rateRatio: 1, score: .infinity, method: "test")]))
        }
        try check(!AudioRegion(start: .nan, end: 1).isValid && !AudioRegion(start: 0, end: .infinity).isValid, "Non-finite source times never enter a workspace")
        try check(AudioRegion(start: 5, end: 20).clipped(to: 10) == .init(start: 5, end: 10) && AudioRegion(start: 10, end: 20).clipped(to: 10) == nil, "Shorter source clips a range or removes it when no samples remain")
        try check(!AudioSourceMetadata(id: "bad", name: "bad", duration: 60, sampleRate: 48000, channelCount: 2, frameCount: "1", format: "WAV").isValid, "Metadata frame duration contradictions are rejected")
        let savedPair = AudioRegionPair(name: "第一组 / First", left: .init(start: 0, end: 20), right: .init(start: 30, end: 50), rate: 1.25, pitchSemitones: -2)
        let workspace = AudioWorkspaceState(leftRegion: savedPair.left, rightRegion: savedPair.right, regions: [savedPair], selectedRegionID: savedPair.id,
                                            settings: .init(fftSize: 4096, hopSize: 1024), rate: 1.25, pitchSemitones: -2)
        try check(workspace.isValid && (try JSONDecoder().decode(AudioWorkspaceState.self, from: JSONEncoder().encode(workspace))) == workspace, "Named regions, FFT and audition settings round-trip without audio data")
        let restored = workspace.clamped(leftDuration: 10, rightDuration: 40)
        try check(restored.leftRegion?.end == 10 && restored.rightRegion?.end == 40 && restored.regions[0].right.end == 40, "Restored regions adapt to shorter sources")
        let removed = workspace.clamped(leftDuration: 10, rightDuration: 20)
        try check(removed.regions.isEmpty && removed.selectedRegionID == nil && removed.rightRegion == nil, "Unavailable saved region and selection are cleared together")
        for fft in [0, 255, 1000, 32768] { try check(!AudioAnalysisSettings(fftSize: fft).isValid, "Unsafe FFT size \(fft) is rejected") }
        try check(!AudioAnalysisSettings(hopSize: 4096).isValid && !AudioAnalysisSettings(minimumDB: .nan).isValid, "Hop and display dB settings are bounded")
        try check(!AudioWorkspaceState(rate: 0).isValid && !AudioWorkspaceState(pitchSemitones: 25).isValid, "Audition controls reject invalid restored settings")
        try check(!AudioWorkspaceState(regions: [savedPair, savedPair]).isValid, "Duplicate saved-region identity is rejected")
        var forged = raw.payload.objectValue!
        forged["leftCoveredDuration"] = .number(30)
        try rejects("Plugin cannot inflate coverage for repeated matches") { try AudioContract.validateResult(changedResult(raw, payload: forged), request: req) }
        forged = raw.payload.objectValue!
        forged["correspondences"] = .array([]); forged["leftCoveredDuration"] = .number(0); forged["rightCoveredDuration"] = .number(0)
        try rejects("Plugin cannot silently drop host evidence") { try AudioContract.validateResult(changedResult(raw, payload: forged), request: req) }
        forged = raw.payload.objectValue!; forged["metadataDifferences"] = .array([.string("duration")])
        try rejects("Plugin cannot invent source metadata differences") { try AudioContract.validateResult(changedResult(raw, payload: forged), request: req) }
        forged = raw.payload.objectValue!; forged["leftCoveredDuration"] = .number(.nan)
        try rejects("Non-finite result coverage is rejected") { try AudioContract.validateResult(changedResult(raw, payload: forged), request: req) }
        forged = raw.payload.objectValue!; forged["analysisState"] = .string("idle")
        try rejects("A completed response cannot claim incomplete analysis") { try AudioContract.validateResult(changedResult(raw, payload: forged), request: req) }
        forged = raw.payload.objectValue!; forged["metadataDifferences"] = .array([.string("sameRecording")])
        try rejects("Unknown metadata claims are rejected") { try AudioContract.validateResult(changedResult(raw, payload: forged), request: req) }
        let wrongSchema = PluginComparisonResult(runID: raw.runID, schema: "crossdiff.table/1", summary: raw.summary, payload: raw.payload)
        try rejects("Unrelated schemas cannot masquerade as audio evidence") { _ = try AudioComparisonResult.parse(wrongSchema, leftDuration: 60, rightDuration: 60) }
        let wrongRun = PluginComparisonResult(runID: "other-task", schema: raw.schema, summary: raw.summary, payload: raw.payload)
        try rejects("A result from another run is rejected") { try wrongRun.validate(for: req, manifest: manifest) }
        var malformed = left.pluginContent.objectValue!; malformed["frameCount"] = .string("48000.0")
        try rejects("Frame counts remain lossless integer strings") { try AudioContract.validateInput(.object(malformed)) }
        let warning = PluginLocalizedText(zhHans: "仅分析前一段", en: "Only the first section was analyzed")
        let partialRequest = PluginComparisonRequest(runID: "partial-warning", inputs: req.inputs,
            options: AudioComparisonRequestOptions(analysisState: .partial, diagnostics: [warning]).pluginOptions)
        let partialRaw = try rawRun(partialRequest)
        let hiddenWarning = PluginComparisonResult(runID: partialRaw.runID, schema: partialRaw.schema, status: .partial,
            summary: partialRaw.summary, diagnostics: [], payload: partialRaw.payload)
        try rejects("A plugin cannot conceal host analysis limitations") { try AudioContract.validateResult(hiddenWarning, request: partialRequest) }
        let storeURL = root.appendingPathComponent(".build-audio-plugin-checks/fixtures/store-\(UUID().uuidString)")
        let store = try PluginStore(root: storeURL)
        _ = try store.install(PluginPackage.decode(data: package.encoded()))
        try check(store.list().contains { $0.id == manifest.id }, "Base can install the independent audio package")
        print("Audio plugin checks: \(count) passed")
    }
}
