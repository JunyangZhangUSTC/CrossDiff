import Foundation

/// Half-open seconds in the original decoded source timeline. These are not display pixels.
public struct AudioRegion: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var duration: Double { end - start }
    public var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start && end <= AudioContract.maximumDuration }
    public func validated(duration: Double) -> Bool {
        isValid && AudioContract.validDuration(duration) && end <= duration
    }
    public func clipped(to duration: Double) -> AudioRegion? {
        guard isValid, AudioContract.validDuration(duration), start < duration else { return nil }
        return AudioRegion(start: start, end: min(end, duration))
    }
}

public enum AudioFrequencyScale: String, Codable, Sendable, CaseIterable { case linear, logarithmic }

public struct AudioAnalysisSettings: Codable, Equatable, Sendable {
    public var fftSize: Int
    public var hopSize: Int
    public var frequencyScale: AudioFrequencyScale
    public var minimumDB: Double
    public var maximumDB: Double
    public init(fftSize: Int = 2048, hopSize: Int = 512, frequencyScale: AudioFrequencyScale = .logarithmic,
                minimumDB: Double = -100, maximumDB: Double = 0) {
        self.fftSize = fftSize; self.hopSize = hopSize; self.frequencyScale = frequencyScale
        self.minimumDB = minimumDB; self.maximumDB = maximumDB
    }
    public var isValid: Bool {
        (256...16384).contains(fftSize) && fftSize.nonzeroBitCount == 1 && (1...fftSize).contains(hopSize)
            && minimumDB.isFinite && maximumDB.isFinite && minimumDB >= -180 && maximumDB <= 24
            && minimumDB < maximumDB && maximumDB - minimumDB >= 6
    }
}

public typealias AudioAnalysisParameters = AudioAnalysisSettings

public struct AudioRegionPair: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var left: AudioRegion
    public var right: AudioRegion
    /// Right-side audition speed; unrelated to the slope of an automatically estimated source mapping.
    public var rate: Double
    /// Right-side audition adjustment in semitones; original source audio is never modified.
    public var pitchSemitones: Double
    public init(id: UUID = UUID(), name: String, left: AudioRegion, right: AudioRegion,
                rate: Double = 1, pitchSemitones: Double = 0) {
        self.id = id; self.name = name; self.left = left; self.right = right
        self.rate = rate; self.pitchSemitones = pitchSemitones
    }
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 256
            && left.isValid && right.isValid && AudioContract.validAudition(rate: rate, pitch: pitchSemitones)
    }
}

/// Persists only view/selection/audition settings, never transformed PCM or automatic recognition claims.
public struct AudioWorkspaceState: Codable, Equatable, Sendable {
    public var leftRegion: AudioRegion?
    public var rightRegion: AudioRegion?
    public var linkedRegions: Bool
    public var regions: [AudioRegionPair]
    public var selectedRegionID: UUID?
    public var settings: AudioAnalysisSettings
    public var rate: Double
    public var pitchSemitones: Double
    public init(leftRegion: AudioRegion? = nil, rightRegion: AudioRegion? = nil, linkedRegions: Bool = false,
                regions: [AudioRegionPair] = [], selectedRegionID: UUID? = nil, settings: AudioAnalysisSettings = .init(),
                rate: Double = 1, pitchSemitones: Double = 0) {
        self.leftRegion = leftRegion; self.rightRegion = rightRegion; self.linkedRegions = linkedRegions
        self.regions = regions; self.selectedRegionID = selectedRegionID; self.settings = settings
        self.rate = rate; self.pitchSemitones = pitchSemitones
    }
    public var isValid: Bool {
        (leftRegion?.isValid ?? true) && (rightRegion?.isValid ?? true) && settings.isValid
            && AudioContract.validAudition(rate: rate, pitch: pitchSemitones) && regions.count <= 32
            && Set(regions.map(\.id)).count == regions.count && regions.allSatisfy(\.isValid)
            && (selectedRegionID == nil || regions.contains { $0.id == selectedRegionID })
    }
    /// A replaced/shortened source cannot restore out-of-bounds selections. Invalid state resets as a unit.
    public func clamped(leftDuration: Double, rightDuration: Double) -> AudioWorkspaceState {
        guard isValid else { return .init() }
        var state = self
        state.leftRegion = leftRegion?.clipped(to: leftDuration)
        state.rightRegion = rightRegion?.clipped(to: rightDuration)
        state.regions = regions.compactMap { pair in
            guard let left = pair.left.clipped(to: leftDuration), let right = pair.right.clipped(to: rightDuration) else { return nil }
            return .init(id: pair.id, name: pair.name, left: left, right: right, rate: pair.rate, pitchSemitones: pair.pitchSemitones)
        }
        if !state.regions.contains(where: { $0.id == state.selectedRegionID }) { state.selectedRegionID = nil }
        return state
    }
}

public struct AudioSourceMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let duration: Double
    public let sampleRate: Double
    public let channelCount: Int
    /// Decimal string on the plugin wire, avoiding JavaScript's integer precision limit.
    public let frameCount: String
    public let format: String
    public init(id: String, name: String, duration: Double, sampleRate: Double, channelCount: Int,
                frameCount: String, format: String) {
        self.id = id; self.name = name; self.duration = duration; self.sampleRate = sampleRate
        self.channelCount = channelCount; self.frameCount = frameCount; self.format = format
    }
    public var isValid: Bool {
        guard !id.isEmpty, id.utf8.count <= 128, name.utf8.count <= 4096, AudioContract.validDuration(duration),
              sampleRate.isFinite, (1000...768000).contains(sampleRate), (1...64).contains(channelCount),
              !format.isEmpty, format.utf8.count <= 256, !frameCount.isEmpty, frameCount.utf8.count <= 20,
              frameCount.utf8.allSatisfy({ (48...57).contains($0) }), let frames = UInt64(frameCount), frames > 0 else { return false }
        return abs(Double(frames) / sampleRate - duration) <= max(1 / sampleRate, 0.000001)
    }
    public var pluginContent: PluginJSONValue {
        .object(["id": .string(id), "name": .string(name), "duration": .number(duration),
                 "sampleRate": .number(sampleRate), "channelCount": .number(Double(channelCount)),
                 "frameCount": .string(frameCount), "format": .string(format)])
    }
}

public enum AudioCorrespondenceState: String, Codable, Sendable, CaseIterable { case candidate, verified, manual, rejected }
public enum AudioAnalysisState: String, Codable, Sendable, CaseIterable { case idle, running, complete, partial, failed, cancelled }

public struct AudioCorrespondence: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let left: AudioRegion
    public let right: AudioRegion
    /// Source mapping tRight = rateRatio * tLeft + offset; calculated in seconds, not source frame counts.
    public let rateRatio: Double
    /// Estimated original right-minus-left pitch, in semitones. Nil means no estimate was made.
    public let pitchSemitones: Double?
    /// Method-specific raw evidence score, explicitly not a calibrated probability.
    public let score: Double?
    public let method: String
    public let state: AudioCorrespondenceState
    public init(id: String, left: AudioRegion, right: AudioRegion, rateRatio: Double,
                pitchSemitones: Double? = nil, score: Double? = nil, method: String,
                state: AudioCorrespondenceState = .candidate) {
        self.id = id; self.left = left; self.right = right; self.rateRatio = rateRatio
        self.pitchSemitones = pitchSemitones; self.score = score; self.method = method; self.state = state
    }
    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 128 && left.isValid && right.isValid && rateRatio.isFinite
            && (0.05...20).contains(rateRatio) && abs(right.duration / left.duration - rateRatio) <= 0.000001
            && (pitchSemitones.map { $0.isFinite && (-96...96).contains($0) } ?? true)
            && (score.map { $0.isFinite && (0...1e12).contains($0) } ?? true)
            && !method.isEmpty && method.utf8.count <= 256
    }
    public func validated(leftDuration: Double, rightDuration: Double) -> Bool {
        isValid && left.validated(duration: leftDuration) && right.validated(duration: rightDuration)
    }
    public var pluginContent: PluginJSONValue {
        func region(_ value: AudioRegion) -> PluginJSONValue { .object(["start": .number(value.start), "end": .number(value.end)]) }
        return .object(["id": .string(id), "left": region(left), "right": region(right), "rateRatio": .number(rateRatio),
                        "pitchSemitones": pitchSemitones.map(PluginJSONValue.number) ?? .null,
                        "score": score.map(PluginJSONValue.number) ?? .null, "method": .string(method), "state": .string(state.rawValue)])
    }
}

public struct AudioComparisonRequestOptions: Sendable {
    public let correspondences: [AudioCorrespondence]
    public let analysisState: AudioAnalysisState
    public let diagnostics: [PluginLocalizedText]
    public init(correspondences: [AudioCorrespondence] = [], analysisState: AudioAnalysisState = .idle,
                diagnostics: [PluginLocalizedText] = []) {
        self.correspondences = correspondences; self.analysisState = analysisState; self.diagnostics = diagnostics
    }
    public var pluginOptions: [String: PluginJSONValue] {
        ["correspondences": .array(correspondences.map(\.pluginContent)), "analysisState": .string(analysisState.rawValue),
         "diagnostics": .array(diagnostics.map { .object(["zhHans": .string($0.zhHans), "en": .string($0.en)]) })]
    }
}

public struct AudioComparisonResult: Equatable, Sendable {
    public let correspondences: [AudioCorrespondence]
    public let analysisState: AudioAnalysisState
    /// Union duration of non-rejected candidate/manual/verified ranges, independently for each source.
    public let leftCoveredDuration: Double
    public let rightCoveredDuration: Double
    public let metadataDifferences: [String]
    public let summary: PluginLocalizedText
    public let diagnostics: [PluginLocalizedText]
    public static func parse(_ result: PluginComparisonResult, leftDuration: Double, rightDuration: Double) throws -> AudioComparisonResult {
        guard result.schema == "crossdiff.audio/1", AudioContract.validDuration(leftDuration), AudioContract.validDuration(rightDuration),
              let raw = result.payload["correspondences"]?.arrayValue, raw.count <= AudioContract.maximumCorrespondences,
              let stateText = result.payload["analysisState"]?.stringValue, let state = AudioAnalysisState(rawValue: stateText),
              let leftCoverage = result.payload["leftCoveredDuration"]?.numberValue,
              let rightCoverage = result.payload["rightCoveredDuration"]?.numberValue,
              let fields = result.payload["metadataDifferences"]?.arrayValue, fields.count <= AudioContract.metadataFields.count,
              fields.allSatisfy({ $0.stringValue.map { AudioContract.metadataFields.contains($0) } == true }),
              Set(fields.compactMap(\.stringValue)).count == fields.count else { throw PluginValidationError.invalidField("audio result") }
        let pairs = try AudioContract.decodeCorrespondences(raw, leftDuration: leftDuration, rightDuration: rightDuration)
        guard leftCoverage.isFinite, rightCoverage.isFinite,
              abs(leftCoverage - AudioContract.coveredDuration(pairs.filter { $0.state != .rejected }.map(\.left))) <= 0.000001,
              abs(rightCoverage - AudioContract.coveredDuration(pairs.filter { $0.state != .rejected }.map(\.right))) <= 0.000001,
              result.status == (state == .complete ? .completed : .partial) else { throw PluginValidationError.invalidField("audio coverage / status") }
        return .init(correspondences: pairs, analysisState: state, leftCoveredDuration: leftCoverage,
                     rightCoveredDuration: rightCoverage, metadataDifferences: fields.compactMap(\.stringValue),
                     summary: result.summary, diagnostics: result.diagnostics)
    }
}

public enum AudioContract {
    public static let maximumDuration: Double = 24 * 60 * 60
    public static let maximumCorrespondences = 512
    public static let metadataFields = ["duration", "sampleRate", "channelCount", "frameCount", "format"]
    public static func validDuration(_ duration: Double) -> Bool { duration.isFinite && duration > 0 && duration <= maximumDuration }
    public static func validAudition(rate: Double, pitch: Double) -> Bool {
        rate.isFinite && pitch.isFinite && (0.25...4).contains(rate) && (-24...24).contains(pitch)
    }
    public static func metadata(_ content: PluginJSONValue) throws -> AudioSourceMetadata {
        let value = try JSONDecoder().decode(AudioSourceMetadata.self, from: JSONEncoder().encode(content))
        guard value.isValid else { throw PluginValidationError.invalidField("audio metadata") }
        return value
    }
    public static func validateInput(_ content: PluginJSONValue) throws { _ = try metadata(content) }
    public static func validateOptions(_ options: [String: PluginJSONValue], leftDuration: Double, rightDuration: Double) throws {
        guard let state = options["analysisState"]?.stringValue, AudioAnalysisState(rawValue: state) != nil,
              let values = options["correspondences"]?.arrayValue,
              let diagnostics = options["diagnostics"]?.arrayValue, diagnostics.count <= 64 else {
            throw PluginValidationError.invalidField("audio options")
        }
        _ = try decodeCorrespondences(values, leftDuration: leftDuration, rightDuration: rightDuration)
        for value in diagnostics {
            guard let zh = value["zhHans"]?.stringValue, let en = value["en"]?.stringValue,
                  PluginManifest.validText(.init(zhHans: zh, en: en), maximumBytes: 4096) else {
                throw PluginValidationError.invalidField("audio diagnostics")
            }
        }
    }
    public static func validateResult(_ result: PluginComparisonResult, request: PluginComparisonRequest) throws {
        guard let leftInput = request.inputs.first(where: { $0.role == .left }),
              let rightInput = request.inputs.first(where: { $0.role == .right }) else { throw PluginValidationError.invalidField("audio sources") }
        let left = try metadata(leftInput.content), right = try metadata(rightInput.content)
        let parsed = try AudioComparisonResult.parse(result, leftDuration: left.duration, rightDuration: right.duration)
        guard let rawPairs = request.options["correspondences"]?.arrayValue else { throw PluginValidationError.invalidField("audio evidence") }
        let inputPairs = try decodeCorrespondences(rawPairs, leftDuration: left.duration, rightDuration: right.duration)
        let expectedFields = metadataFields.filter { leftInput.content[$0] != rightInput.content[$0] }
        guard let rawDiagnostics = request.options["diagnostics"]?.arrayValue else { throw PluginValidationError.invalidField("audio diagnostics") }
        let requiredDiagnostics = try JSONDecoder().decode([PluginLocalizedText].self, from: JSONEncoder().encode(rawDiagnostics))
        guard parsed.correspondences == inputPairs, parsed.analysisState.rawValue == request.options["analysisState"]?.stringValue,
              parsed.metadataDifferences == expectedFields,
              Array(parsed.diagnostics.prefix(requiredDiagnostics.count)) == requiredDiagnostics else {
            throw PluginValidationError.invalidField("audio result changed source evidence")
        }
    }
    static func decodeCorrespondences(_ raw: [PluginJSONValue], leftDuration: Double, rightDuration: Double) throws -> [AudioCorrespondence] {
        guard raw.count <= maximumCorrespondences else { throw PluginValidationError.sizeLimit }
        let pairs = try JSONDecoder().decode([AudioCorrespondence].self, from: JSONEncoder().encode(raw))
        guard Set(pairs.map(\.id)).count == pairs.count, pairs.allSatisfy({ $0.validated(leftDuration: leftDuration, rightDuration: rightDuration) }) else {
            throw PluginValidationError.invalidField("audio correspondence")
        }
        return pairs
    }
    public static func coveredDuration(_ regions: [AudioRegion]) -> Double {
        guard regions.allSatisfy(\.isValid) else { return 0 }
        let sorted = regions.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return 0 }
        var total = 0.0
        for next in sorted.dropFirst() {
            if next.start <= current.end { current.end = max(current.end, next.end) }
            else { total += current.duration; current = next }
        }
        return total + current.duration
    }
}
