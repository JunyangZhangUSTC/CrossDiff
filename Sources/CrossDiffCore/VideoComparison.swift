import Foundation

/// A nonnegative rational source time. The wire value is a decimal string, never a JavaScript number.
/// Rendering and conversion to CMTime belong to the native host, not the plugin contract.
public struct VideoTime: Codable, Equatable, Sendable {
    public let value: Int64
    public let timescale: Int32
    public init(value: Int64, timescale: Int32) { self.value = value; self.timescale = timescale }
    public var seconds: Double { Double(value) / Double(timescale) }
    public var isValid: Bool { value >= 0 && timescale > 0 }
    public var pluginContent: PluginJSONValue {
        .object(["value": .string(String(value)), "timescale": .number(Double(timescale))])
    }

    /// Equality of source times without floating-point rounding or overflowing cross multiplication.
    public func isEquivalent(to other: VideoTime) -> Bool {
        guard isValid, other.isValid else { return false }
        func divisor(_ value: Int64, _ scale: Int64) -> Int64 {
            var a = value, b = scale
            while b != 0 { let remainder = a % b; a = b; b = remainder }
            return a
        }
        let a = divisor(value, Int64(timescale)), b = divisor(other.value, Int64(other.timescale))
        return value / a == other.value / b && Int64(timescale) / a == Int64(other.timescale) / b
    }

    private enum CodingKeys: String, CodingKey { case value, timescale }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decode(String.self, forKey: .value)
        guard let value = Int64(text), String(value) == text, value >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Expected a nonnegative canonical Int64 decimal string")
        }
        self.value = value
        timescale = try container.decode(Int32.self, forKey: .timescale)
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .timescale, in: container, debugDescription: "Expected a positive Int32 timescale")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(value), forKey: .value)
        try container.encode(timescale, forKey: .timescale)
    }
}

/// Bounded facts from the selected native video track. No paths, decoded frames or audio enter the plugin.
public struct VideoSourceMetadata: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let duration: VideoTime
    /// Display dimensions after applying the track's preferred transform.
    public let width: Int
    public let height: Int
    /// A reported nominal rate; zero means unavailable and does not imply constant frame rate.
    public let nominalFrameRate: Double
    public let codec: String
    public let hasAudio: Bool
    /// A reported HDR transfer-function flag, not a claim about display calibration or image quality.
    public let isHDR: Bool
    public init(id: String, name: String, duration: VideoTime, width: Int, height: Int,
                nominalFrameRate: Double, codec: String, hasAudio: Bool, isHDR: Bool) {
        self.id = id; self.name = name; self.duration = duration; self.width = width; self.height = height
        self.nominalFrameRate = nominalFrameRate; self.codec = codec; self.hasAudio = hasAudio; self.isHDR = isHDR
    }
    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 128 && name.utf8.count <= 4096
            && VideoContract.validDuration(duration) && (1...32768).contains(width) && (1...32768).contains(height)
            && nominalFrameRate.isFinite && (0...1000).contains(nominalFrameRate)
            && !codec.isEmpty && codec.utf8.count <= 256
    }
    public var pluginContent: PluginJSONValue {
        .object(["id": .string(id), "name": .string(name), "duration": duration.pluginContent,
                 "width": .number(Double(width)), "height": .number(Double(height)),
                 "nominalFrameRate": .number(nominalFrameRate), "codec": .string(codec),
                 "hasAudio": .bool(hasAudio), "isHDR": .bool(isHDR)])
    }
}

public struct VideoComparisonResult: Equatable, Sendable {
    public let metadataDifferences: [String]
    public let summary: PluginLocalizedText
    public let diagnostics: [PluginLocalizedText]
    /// This first contract reports source metadata only; it cannot assert content or temporal correspondence.
    public static func parse(_ result: PluginComparisonResult) throws -> VideoComparisonResult {
        guard result.schema == "crossdiff.video/1", result.status == .completed,
              let payload = result.payload.objectValue,
              Set(payload.keys) == ["metadataDifferences", "contentCompared"],
              payload["contentCompared"]?.boolValue == false,
              let fields = payload["metadataDifferences"]?.arrayValue,
              fields.count <= VideoContract.metadataFields.count,
              fields.allSatisfy({ $0.stringValue.map { VideoContract.metadataFields.contains($0) } == true }),
              Set(fields.compactMap(\.stringValue)).count == fields.count else {
            throw PluginValidationError.invalidField("video result")
        }
        return .init(metadataDifferences: fields.compactMap(\.stringValue), summary: result.summary,
                     diagnostics: result.diagnostics)
    }
}

public enum VideoContract {
    public static let maximumDuration: Double = 24 * 60 * 60
    public static let metadataFields = ["duration", "width", "height", "nominalFrameRate", "codec", "hasAudio", "isHDR"]
    public static func validDuration(_ value: VideoTime) -> Bool {
        value.isValid && value.value > 0 && value.seconds <= maximumDuration
    }
    public static func metadata(_ content: PluginJSONValue) throws -> VideoSourceMetadata {
        guard let object = content.objectValue,
              Set(object.keys) == Set(metadataFields + ["id", "name"]),
              let time = object["duration"]?.objectValue, Set(time.keys) == ["value", "timescale"] else {
            throw PluginValidationError.invalidField("video metadata fields")
        }
        let value = try JSONDecoder().decode(VideoSourceMetadata.self, from: JSONEncoder().encode(content))
        guard value.isValid else { throw PluginValidationError.invalidField("video metadata") }
        return value
    }
    public static func validateInput(_ content: PluginJSONValue) throws { _ = try metadata(content) }
    public static func validateOptions(_ options: [String: PluginJSONValue]) throws {
        guard options.isEmpty else { throw PluginValidationError.invalidField("video options") }
    }
    public static func metadataDifferences(left: VideoSourceMetadata, right: VideoSourceMetadata) -> [String] {
        metadataFields.filter { field in
            field == "duration" ? !left.duration.isEquivalent(to: right.duration)
                : left.pluginContent[field] != right.pluginContent[field]
        }
    }
    public static func validateResult(_ result: PluginComparisonResult, request: PluginComparisonRequest) throws {
        guard request.mode == .pairwise, request.inputs.count == 2,
              let leftInput = request.inputs.first(where: { $0.role == .left }),
              let rightInput = request.inputs.first(where: { $0.role == .right }) else {
            throw PluginValidationError.invalidField("video sources")
        }
        try validateOptions(request.options)
        let left = try metadata(leftInput.content), right = try metadata(rightInput.content)
        let parsed = try VideoComparisonResult.parse(result)
        guard parsed.metadataDifferences == metadataDifferences(left: left, right: right) else {
            throw PluginValidationError.invalidField("video result changed source facts")
        }
    }
}
