import Foundation

public enum APIComparisonRowState: String, Codable, Sendable, CaseIterable {
    case same, changed, added, removed, ignored, unknown
}

public struct APIComparisonRow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let section: String
    public let path: String
    public let label: String
    public let left: String?
    public let right: String?
    public let leftType: String?
    public let rightType: String?
    public let state: APIComparisonRowState
    public let sensitive: Bool
}

public struct APIComparisonResult: Equatable, Sendable {
    public let rows: [APIComparisonRow]
    public let diagnostics: [PluginLocalizedText]
    public let summary: PluginLocalizedText
    public let partial: Bool

    public static func parse(_ result: PluginComparisonResult) throws -> APIComparisonResult {
        guard result.schema == "crossdiff.api-exchange/1",
              let rawRows = result.payload["rows"]?.arrayValue, rawRows.count <= 5000,
              let partial = result.payload["partial"]?.boolValue,
              partial == (result.status == .partial) else {
            throw PluginValidationError.invalidField("API result")
        }
        let rows = try JSONDecoder().decode([APIComparisonRow].self, from: JSONEncoder().encode(rawRows))
        guard Set(rows.map { Data($0.id.utf8) }).count == rows.count else { throw PluginValidationError.invalidField("API row identity") }
        for row in rows {
            guard !row.id.isEmpty, row.id.utf8.count <= 32,
                  APIContract.sections.contains(row.section), row.path.utf8.count <= 16 * 1024,
                  row.label.utf8.count <= 16 * 1024,
                  [row.left, row.right].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 1024 * 1024 }),
                  [row.leftType, row.rightType].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
                  (row.left == nil) == (row.leftType == nil), (row.right == nil) == (row.rightType == nil),
                  row.left != nil || row.right != nil else {
                throw PluginValidationError.invalidField("API row")
            }
            switch row.state {
            case .same:
                guard row.left != nil, APIContract.equalText(row.left, row.right), APIContract.equalText(row.leftType, row.rightType),
                      !APIContract.isUnknown(row.leftType, row.left) else { throw PluginValidationError.invalidField("API same row") }
            case .added: guard row.left == nil, row.right != nil else { throw PluginValidationError.invalidField("API added row") }
            case .removed: guard row.left != nil, row.right == nil else { throw PluginValidationError.invalidField("API removed row") }
            case .changed:
                guard row.left != nil, row.right != nil, !APIContract.equalText(row.left, row.right) || !APIContract.equalText(row.leftType, row.rightType) else {
                    throw PluginValidationError.invalidField("API changed row")
                }
            case .ignored, .unknown: break
            }
        }
        return .init(rows: rows, diagnostics: result.diagnostics, summary: result.summary, partial: partial)
    }
}

/// Only entry choices and explicit comparison rules are persisted; no credentials are added here.
public struct APIWorkspaceState: Codable, Equatable, Sendable {
    public var leftEntryID: String?
    public var rightEntryID: String?
    public var ignoreHeaders: [String]
    /// RFC 6901 JSON pointers, matching the selected node and its descendants in both bodies.
    public var ignoreJSONPointers: [String]
    public init(leftEntryID: String? = nil, rightEntryID: String? = nil,
                ignoreHeaders: [String] = [], ignoreJSONPointers: [String] = []) {
        self.leftEntryID = leftEntryID; self.rightEntryID = rightEntryID
        self.ignoreHeaders = ignoreHeaders; self.ignoreJSONPointers = ignoreJSONPointers
    }
    public static func == (lhs: APIWorkspaceState, rhs: APIWorkspaceState) -> Bool {
        lhs.leftEntryID == rhs.leftEntryID && lhs.rightEntryID == rhs.rightEntryID &&
        lhs.ignoreHeaders == rhs.ignoreHeaders &&
        lhs.ignoreJSONPointers.map { Data($0.utf8) } == rhs.ignoreJSONPointers.map { Data($0.utf8) }
    }
    public var isValid: Bool {
        [leftEntryID, rightEntryID].compactMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) &&
        ignoreHeaders.count <= 128 && ignoreHeaders.allSatisfy(APIContract.validHeaderName) &&
        ignoreJSONPointers.count <= 128 && ignoreJSONPointers.allSatisfy(APIContract.validPointer)
    }
    public var pluginOptions: [String: PluginJSONValue] {
        ["ignoreHeaders": .array(ignoreHeaders.map(PluginJSONValue.string)),
         "ignoreJSONPointers": .array(ignoreJSONPointers.map(PluginJSONValue.string))]
    }
}

enum APIContract {
    /// JSON strings and pointers retain their code units; Swift String equality
    /// would silently consider canonically equivalent spellings identical.
    static func equalText(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) {
        case (.none, .none): return true
        case (.some(let left), .some(let right)): return left.utf16.elementsEqual(right.utf16)
        default: return false
        }
    }
    static let sections: Set<String> = ["request.summary", "request.query", "request.headers", "request.body",
                                        "response.summary", "response.headers", "response.body"]
    static func validHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.range(of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#, options: .regularExpression) != nil
    }
    static func validPointer(_ value: String) -> Bool {
        value.utf8.count <= 16 * 1024 && (value.isEmpty || value.hasPrefix("/")) &&
        value.range(of: #"~(?![01])"#, options: .regularExpression) == nil
    }
    static func isUnknown(_ type: String?, _ value: String?) -> Bool {
        type == "bodyState" && (value == "missing" || value == "unsupported")
    }
    static func validateInput(_ content: PluginJSONValue) throws {
        guard let sections = content["sections"]?.arrayValue, !sections.isEmpty, sections.count <= 7,
              Set(sections.compactMap { $0["id"]?.stringValue }).count == sections.count,
              let diagnostics = content["diagnostics"]?.arrayValue, diagnostics.count <= 128 else {
            throw PluginValidationError.invalidField("HTTP exchange")
        }
        for item in diagnostics {
            guard let zh = item["zhHans"]?.stringValue, let en = item["en"]?.stringValue,
                  PluginManifest.validText(.init(zhHans: zh, en: en), maximumBytes: 4096) else {
                throw PluginValidationError.invalidField("HTTP diagnostics")
            }
        }
        var total = 0
        for section in sections {
            guard let id = section["id"]?.stringValue, Self.sections.contains(id),
                  let fields = section["fields"]?.arrayValue,
                  let zh = section["label"]?["zhHans"]?.stringValue, let en = section["label"]?["en"]?.stringValue,
                  PluginManifest.validText(.init(zhHans: zh, en: en), maximumBytes: 512),
                  Set(fields.compactMap { $0["key"]?.stringValue.map { Data($0.utf8) } }).count == fields.count else {
                throw PluginValidationError.invalidField("HTTP section")
            }
            total += fields.count
            guard total <= 5000 else { throw PluginValidationError.sizeLimit }
            for field in fields {
                guard let key = field["key"]?.stringValue, key.utf8.count <= 16 * 1024,
                      let label = field["label"]?.stringValue, label.utf8.count <= 16 * 1024,
                      let type = field["type"]?.stringValue, !type.isEmpty, type.utf8.count <= 64,
                      let value = field["value"]?.stringValue, value.utf8.count <= 1024 * 1024,
                      field["sensitive"]?.boolValue != nil else { throw PluginValidationError.invalidField("HTTP field") }
            }
        }
    }
    static func validateOptions(_ options: [String: PluginJSONValue]) throws {
        for (key, valid) in [("ignoreHeaders", validHeaderName), ("ignoreJSONPointers", validPointer)] {
            guard let value = options[key] else { continue }
            guard let entries = value.arrayValue, entries.count <= 128,
                  entries.allSatisfy({ $0.stringValue.map(valid) == true }) else {
                throw PluginValidationError.invalidField("API ignore rules")
            }
        }
    }
}
