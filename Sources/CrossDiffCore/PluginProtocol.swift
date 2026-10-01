import Foundation

/// The experimental wire contract. Bytes, rendering and execution stay outside this module.
public enum PluginProtocol {
    public static let version = 1
}

public indirect enum PluginJSONValue: Codable, Equatable, Sendable {
    case object([String: PluginJSONValue])
    case array([PluginJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([PluginJSONValue].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: PluginJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    /// Accessors return nil for a different JSON type; absent keys and null stay distinct.
    public subscript(key: String) -> PluginJSONValue? { objectValue?[key] }
    public subscript(index: Int) -> PluginJSONValue? {
        guard let values = arrayValue, values.indices.contains(index) else { return nil }
        return values[index]
    }
    public var objectValue: [String: PluginJSONValue]? { if case .object(let value) = self { return value }; return nil }
    public var arrayValue: [PluginJSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var intValue: Int? {
        guard let value = numberValue, value.isFinite, value.rounded(.towardZero) == value else { return nil }
        return Int(exactly: value)
    }
}

public struct PluginLocalizedText: Codable, Equatable, Sendable {
    public let zhHans: String
    public let en: String
    public init(zhHans: String, en: String) { self.zhHans = zhHans; self.en = en }
    public var localized: String { L(zhHans, en) }
}

public enum PluginRuntimeProfile: String, Codable, Sendable { case restrictedJavaScript, trustedExecutable }
public enum PluginInputKind: String, Codable, Sendable { case text, pdf, archiveCatalog }
public enum PluginComparisonMode: String, Codable, Sendable { case pairwise, threeWayMerge, multiSubject }
public enum PluginInputRole: String, Codable, Sendable { case left, right, base, ours, theirs, peer }
public enum PluginResultStatus: String, Codable, Sendable { case completed, partial }

public struct PluginManifest: Codable, Equatable, Sendable {
    public let id: String
    public let version: String
    public let name: PluginLocalizedText
    public let summary: PluginLocalizedText
    public let runtime: PluginRuntimeProfile
    public let inputKind: PluginInputKind
    public let fileExtensions: [String]
    public let resultView: String
    public let supportedModes: [PluginComparisonMode]
    public let minHostProtocol: Int
    public let maxHostProtocol: Int

    public init(id: String, version: String, name: PluginLocalizedText, summary: PluginLocalizedText,
                runtime: PluginRuntimeProfile, inputKind: PluginInputKind, fileExtensions: [String],
                resultView: String, supportedModes: [PluginComparisonMode] = [.pairwise],
                minHostProtocol: Int = 1, maxHostProtocol: Int = 1) {
        self.id = id; self.version = version; self.name = name; self.summary = summary
        self.runtime = runtime; self.inputKind = inputKind; self.fileExtensions = fileExtensions
        self.resultView = resultView; self.supportedModes = supportedModes
        self.minHostProtocol = minHostProtocol; self.maxHostProtocol = maxHostProtocol
    }

    public var resultSchema: String {
        switch resultView {
        case "documentPages": return "crossdiff.document-pages/1"
        case "table": return "crossdiff.table/1"
        case "archiveTree": return "crossdiff.archive-tree/1"
        default: return ""
        }
    }
}

public struct PluginInput: Codable, Equatable, Sendable {
    public let id: String
    public let role: PluginInputRole
    public let name: String
    public let content: PluginJSONValue
    public init(id: String, role: PluginInputRole, name: String, content: PluginJSONValue) {
        self.id = id; self.role = role; self.name = name; self.content = content
    }
}

public struct PluginComparisonRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let runID: String
    public let mode: PluginComparisonMode
    public let inputs: [PluginInput]
    public let options: [String: PluginJSONValue]
    public init(protocolVersion: Int = 1, runID: String, mode: PluginComparisonMode = .pairwise,
                inputs: [PluginInput], options: [String: PluginJSONValue] = [:]) {
        self.protocolVersion = protocolVersion; self.runID = runID; self.mode = mode
        self.inputs = inputs; self.options = options
    }

    public func validate(for manifest: PluginManifest) throws {
        try manifest.validate()
        guard protocolVersion == PluginProtocol.version,
              manifest.minHostProtocol <= protocolVersion, manifest.maxHostProtocol >= protocolVersion else {
            throw PluginValidationError.unsupportedProtocol
        }
        guard !runID.isEmpty, runID.utf8.count <= 128 else { throw PluginValidationError.invalidField("runID") }
        guard manifest.supportedModes.contains(mode) else { throw PluginValidationError.unsupportedMode }
        guard inputs.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && $0.name.utf8.count <= 4096 }),
              Set(inputs.map(\.id)).count == inputs.count else { throw PluginValidationError.invalidField("inputs") }
        guard try JSONEncoder().encode(self).count <= 16 * 1024 * 1024 else { throw PluginValidationError.sizeLimit }
        let roles = inputs.map(\.role)
        switch mode {
        case .pairwise:
            guard inputs.count == 2, Set(roles) == [.left, .right] else { throw PluginValidationError.invalidField("pairwise roles") }
        case .threeWayMerge:
            guard inputs.count == 3, Set(roles) == [.base, .ours, .theirs] else { throw PluginValidationError.invalidField("threeWayMerge roles") }
        case .multiSubject:
            guard (3...32).contains(inputs.count), roles.allSatisfy({ $0 == .peer }) else { throw PluginValidationError.invalidField("multiSubject roles") }
        }
    }
}

public struct PluginComparisonResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let runID: String
    public let schema: String
    public let status: PluginResultStatus
    public let summary: PluginLocalizedText
    public let diagnostics: [PluginLocalizedText]
    public let payload: PluginJSONValue
    public init(protocolVersion: Int = 1, runID: String, schema: String, status: PluginResultStatus = .completed,
                summary: PluginLocalizedText, diagnostics: [PluginLocalizedText] = [], payload: PluginJSONValue) {
        self.protocolVersion = protocolVersion; self.runID = runID; self.schema = schema
        self.status = status; self.summary = summary; self.diagnostics = diagnostics; self.payload = payload
    }

    public func validate(for request: PluginComparisonRequest, manifest: PluginManifest) throws {
        try request.validate(for: manifest)
        guard protocolVersion == request.protocolVersion else { throw PluginValidationError.unsupportedProtocol }
        guard runID == request.runID else { throw PluginValidationError.invalidField("result runID") }
        guard schema == manifest.resultSchema, !schema.isEmpty else { throw PluginValidationError.invalidField("result schema") }
        guard PluginManifest.validText(summary, maximumBytes: 16 * 1024), diagnostics.count <= 128,
              diagnostics.allSatisfy({ PluginManifest.validText($0, maximumBytes: 4096) }) else {
            throw PluginValidationError.invalidField("result summary / diagnostics")
        }
        guard payload.objectValue != nil else { throw PluginValidationError.invalidField("result payload") }
        guard try JSONEncoder().encode(self).count <= 8 * 1024 * 1024 else { throw PluginValidationError.sizeLimit }
    }
}

public enum PluginValidationError: Error, LocalizedError, Sendable {
    case invalidField(String)
    case unsupportedProtocol
    case unsupportedMode
    case invalidPayload
    case digestMismatch
    case sizeLimit
    case nativeTrustRequired
    case reservedIdentifier
    case immutableVersionConflict
    case missingPlugin
    case missingPreviousVersion
    case unsafeStore
    case corruptStore

    public var errorDescription: String? {
        switch self {
        case .invalidField(let field): return L("插件字段无效：\(field)", "Invalid plugin field: \(field)")
        case .unsupportedProtocol: return L("插件协议版本与此宿主不兼容。", "The plugin protocol version is incompatible with this host.")
        case .unsupportedMode: return L("此插件不支持所选比较方式。", "This plugin does not support the selected comparison mode.")
        case .invalidPayload: return L("插件必须包含且仅包含与运行模式对应的程序。", "The plugin must contain exactly one payload matching its runtime profile.")
        case .digestMismatch: return L("插件内容校验失败。", "Plugin payload verification failed.")
        case .sizeLimit: return L("插件数据超出允许的大小。", "Plugin data exceeds the allowed size.")
        case .nativeTrustRequired: return L("原生插件需要明确批准对此内容的完全信任。", "The native plugin requires explicit full-trust approval for this payload.")
        case .reservedIdentifier: return L("此插件标识由内置插件保留。", "This plugin identifier is reserved for a bundled plugin.")
        case .immutableVersionConflict: return L("此版本已存在且内容不同，请使用新的版本号。", "This version already exists with different contents. Use a new version number.")
        case .missingPlugin: return L("找不到已安装的插件。", "The installed plugin could not be found.")
        case .missingPreviousVersion: return L("此插件没有可回退的版本。", "This plugin has no version to roll back to.")
        case .unsafeStore: return L("插件存储路径不安全，操作已停止。", "The plugin storage path is unsafe. The operation was stopped.")
        case .corruptStore: return L("插件记录损坏，已保留现有文件。", "Plugin records are damaged. Existing files have been preserved.")
        }
    }
}
