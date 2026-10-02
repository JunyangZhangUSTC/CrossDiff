import Foundation

public enum OfficeDocumentKind: String, Codable, CaseIterable, Sendable {
    case word, spreadsheet, presentation
    public static func from(fileExtension: String) -> Self? {
        switch fileExtension.lowercased() {
        case "docx": return .word
        case "xlsx": return .spreadsheet
        case "pptx": return .presentation
        default: return nil
        }
    }
    public static func fromExtension(_ value: String) -> Self? { from(fileExtension: value) }
    public var title: String {
        switch self { case .word: return "Word"; case .spreadsheet: return "Excel"; case .presentation: return "PowerPoint" }
    }
}

/// Value and formula are source strings; nil and an empty value remain distinct.
public struct OfficeCell: Codable, Equatable, Sendable {
    public let column: Int
    public let type: String
    public let value: String?
    public let formula: String?
    public let format: String?
    public init(column: Int, type: String, value: String? = nil, formula: String? = nil, format: String? = nil) {
        self.column = column; self.type = type; self.value = value; self.formula = formula; self.format = format
    }
    public var display: String { value ?? formula.map { "=" + $0 } ?? "" }
    public var text: String { display }
}

public struct OfficeRow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let position: Int
    public let label: String
    public let cells: [OfficeCell]
    public init(id: String, position: Int, label: String, cells: [OfficeCell]) {
        self.id = id; self.position = position; self.label = label; self.cells = cells
    }
    public var text: String { cells.map(\.display).joined(separator: "\t") }
    public var display: String { text }
    public func cell(column: Int) -> OfficeCell? { cells.first { $0.column == column } }
}

public struct OfficeSection: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let rows: [OfficeRow]
    public init(id: String, name: String, rows: [OfficeRow]) { self.id = id; self.name = name; self.rows = rows }
    public func pluginContent(kind: OfficeDocumentKind) -> PluginJSONValue {
        .object(["kind": .string(kind.rawValue), "sectionID": .string(id), "name": .string(name),
                 "rows": .array(rows.map { row in
                    .object(["id": .string(row.id), "position": .number(Double(row.position)), "label": .string(row.label),
                        "cells": .array(row.cells.map { cell in
                            .object(["column": .number(Double(cell.column)), "type": .string(cell.type),
                                     "value": cell.value.map(PluginJSONValue.string) ?? .null,
                                     "formula": cell.formula.map(PluginJSONValue.string) ?? .null,
                                     "format": cell.format.map(PluginJSONValue.string) ?? .null])
                        })])
                 })])
    }
}

public struct OfficeDocument: Codable, Equatable, Sendable {
    public let kind: OfficeDocumentKind
    public let sections: [OfficeSection]
    public let diagnostics: [PluginLocalizedText]
    public init(kind: OfficeDocumentKind, sections: [OfficeSection], diagnostics: [PluginLocalizedText] = []) {
        self.kind = kind; self.sections = sections; self.diagnostics = diagnostics
    }
    public func pluginContent(sectionID: String? = nil) -> PluginJSONValue? {
        (sections.first { $0.id == sectionID } ?? sections.first)?.pluginContent(kind: kind)
    }
}

public struct OfficeWorkspaceState: Codable, Equatable, Sendable {
    public var leftSectionID: String?
    public var rightSectionID: String?
    public var keyColumns: [Int]
    public var onlyDifferences: Bool
    public init(leftSectionID: String? = nil, rightSectionID: String? = nil,
                keyColumns: [Int] = [], onlyDifferences: Bool = false) {
        self.leftSectionID = leftSectionID; self.rightSectionID = rightSectionID
        self.keyColumns = keyColumns; self.onlyDifferences = onlyDifferences
    }
    public var isValid: Bool {
        [leftSectionID, rightSectionID].compactMap { $0 }.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 } &&
        keyColumns.count <= 16 && Set(keyColumns).count == keyColumns.count && keyColumns.allSatisfy { (1...16384).contains($0) }
    }
    public var pluginOptions: [String: PluginJSONValue] { ["keyColumns": .array(keyColumns.map { .number(Double($0)) })] }
}

public enum OfficeRowStatus: String, Codable, CaseIterable, Sendable { case equal, modified, added, removed }
public enum OfficeMatchBasis: String, Codable, Sendable { case exact, key, position, unmatched }
public struct OfficeComparisonRow: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let leftID: String?
    public let rightID: String?
    public let status: OfficeRowStatus
    public let moved: Bool
    public let ambiguous: Bool
    public let basis: OfficeMatchBasis
    public var isDifference: Bool { status != .equal || moved || ambiguous }
}

public struct OfficeComparisonResult: Equatable, Sendable {
    public let rows: [OfficeComparisonRow]
    public let summary: PluginLocalizedText
    public let diagnostics: [PluginLocalizedText]
    public let partial: Bool
    public var changedCount: Int { rows.filter(\.isDifference).count }
    public static func parse(_ result: PluginComparisonResult) throws -> Self {
        guard result.schema == "crossdiff.office/1",
              let values = result.payload["rows"]?.arrayValue, values.count <= 20000 else {
            throw PluginValidationError.invalidField("Office result")
        }
        let rows = try JSONDecoder().decode([OfficeComparisonRow].self, from: JSONEncoder().encode(values))
        guard Set(rows.map { Data($0.id.utf8) }).count == rows.count,
              rows.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 }) else {
            throw PluginValidationError.invalidField("Office result identity")
        }
        return .init(rows: rows, summary: result.summary, diagnostics: result.diagnostics, partial: result.status == .partial)
    }
}

public enum OfficeContract {
    public static let maximumRows = 10000
    public static let maximumCells = 100000
    public static let maximumCellBytes = 131072

    public static func validateInput(_ content: PluginJSONValue) throws {
        guard let object = content.objectValue, Set(object.keys) == ["kind", "sectionID", "name", "rows"],
              let rawKind = content["kind"]?.stringValue, OfficeDocumentKind(rawValue: rawKind) != nil,
              let id = content["sectionID"]?.stringValue, validID(id),
              let name = content["name"]?.stringValue, name.utf8.count <= 4096,
              let rows = content["rows"]?.arrayValue, rows.count <= maximumRows else {
            throw PluginValidationError.invalidField("Office section")
        }
        var ids = Set<Data>(), previousPosition = 0, count = 0
        for row in rows {
            try Task.checkCancellation()
            guard let object = row.objectValue, Set(object.keys) == ["id", "position", "label", "cells"],
                  let id = row["id"]?.stringValue, validID(id), ids.insert(Data(id.utf8)).inserted,
                  let position = row["position"]?.intValue, position > previousPosition, position <= 1048576,
                  let label = row["label"]?.stringValue, label.utf8.count <= 4096,
                  let cells = row["cells"]?.arrayValue else { throw PluginValidationError.invalidField("Office row") }
            previousPosition = position; count += cells.count
            guard count <= maximumCells else { throw PluginValidationError.sizeLimit }
            var previousColumn = 0
            for cell in cells {
                guard let object = cell.objectValue, Set(object.keys) == ["column", "type", "value", "formula", "format"],
                      let column = cell["column"]?.intValue, column > previousColumn, column <= 16384,
                      let type = cell["type"]?.stringValue, !type.isEmpty, type.utf8.count <= 64,
                      validOptional(cell["value"], maximum: maximumCellBytes),
                      validOptional(cell["formula"], maximum: maximumCellBytes),
                      validOptional(cell["format"], maximum: 4096) else { throw PluginValidationError.invalidField("Office cell") }
                previousColumn = column
            }
        }
    }

    public static func validateOptions(_ options: [String: PluginJSONValue]) throws {
        guard Set(options.keys).isSubset(of: ["keyColumns"]) else { throw PluginValidationError.invalidField("Office options") }
        guard let value = options["keyColumns"] else { return }
        guard let entries = value.arrayValue, entries.count <= 16,
              entries.allSatisfy({ $0.intValue.map { (1...16384).contains($0) } == true }),
              Set(entries.compactMap(\.intValue)).count == entries.count else {
            throw PluginValidationError.invalidField("Office key columns")
        }
    }

    /// The renderer always obtains content from its retained source snapshot, never
    /// from arbitrary strings supplied by a comparison plugin.
    public static func validateResult(_ result: PluginComparisonResult, request: PluginComparisonRequest) throws {
        guard let leftInput = request.inputs.first(where: { $0.role == .left }),
              let rightInput = request.inputs.first(where: { $0.role == .right }),
              leftInput.content["kind"] == rightInput.content["kind"] else {
            throw PluginValidationError.invalidField("Office document families")
        }
        try validateInput(leftInput.content); try validateInput(rightInput.content); try validateOptions(request.options)
        let keys = request.options["keyColumns"]?.arrayValue?.compactMap(\.intValue) ?? []
        guard keys.isEmpty || leftInput.content["kind"]?.stringValue == "spreadsheet" else {
            throw PluginValidationError.invalidField("Office key columns require a spreadsheet")
        }
        let comparison = try OfficeComparisonResult.parse(result)
        let left = try sourceRows(leftInput.content), right = try sourceRows(rightInput.content)
        let leftByID = Dictionary(uniqueKeysWithValues: left.map { (Data($0.id.utf8), $0) })
        let rightByID = Dictionary(uniqueKeysWithValues: right.map { (Data($0.id.utf8), $0) })
        let leftKeyCounts = try keyCounts(left, columns: keys), rightKeyCounts = try keyCounts(right, columns: keys)
        let leftExactCounts = try exactCounts(left), rightExactCounts = try exactCounts(right)
        var seenLeft = Set<Data>(), seenRight = Set<Data>()
        guard Set(result.payload.objectValue?.keys.map { $0 } ?? []) == ["rows"] else {
            throw PluginValidationError.invalidField("Office result fields")
        }
        for (index, row) in comparison.rows.enumerated() {
            try Task.checkCancellation()
            let raw = result.payload["rows"]![index]!
            guard Set(raw.objectValue?.keys.map { $0 } ?? []) == ["id", "leftID", "rightID", "status", "moved", "ambiguous", "basis"] else {
                throw PluginValidationError.invalidField("Office result row fields")
            }
            let l = row.leftID.flatMap { leftByID[Data($0.utf8)] }, r = row.rightID.flatMap { rightByID[Data($0.utf8)] }
            if let id = row.leftID { guard l != nil, seenLeft.insert(Data(id.utf8)).inserted else { throw PluginValidationError.invalidField("Office left coverage") } }
            if let id = row.rightID { guard r != nil, seenRight.insert(Data(id.utf8)).inserted else { throw PluginValidationError.invalidField("Office right coverage") } }
            switch (l, r) {
            case (.some(let a), .some(let b)):
                let same = try canonical(a) == canonical(b)
                guard row.status == (same ? .equal : .modified), row.basis != .unmatched else {
                    throw PluginValidationError.invalidField("Office result content status")
                }
                switch row.basis {
                case .exact:
                    let fingerprint = try canonical(a)
                    let ambiguous = leftExactCounts[fingerprint, default: 0] > 1 || rightExactCounts[fingerprint, default: 0] > 1
                    guard same, row.ambiguous == ambiguous else { throw PluginValidationError.invalidField("Office exact match") }
                case .key:
                    guard !keys.isEmpty, let ka = try key(a, columns: keys), let kb = try key(b, columns: keys),
                          ka == kb, leftKeyCounts[ka] == 1, rightKeyCounts[kb] == 1, !row.ambiguous else {
                        throw PluginValidationError.invalidField("Office key match")
                    }
                case .position: guard keys.isEmpty, !same, !row.ambiguous, !row.moved else { throw PluginValidationError.invalidField("Office positional match") }
                case .unmatched: throw PluginValidationError.invalidField("Office match basis")
                }
            case (.some(let source), .none):
                guard row.status == .removed, row.basis == .unmatched, !row.moved else { throw PluginValidationError.invalidField("Office removed row") }
                try validateAmbiguity(row, source: source, columns: keys, leftCounts: leftKeyCounts, rightCounts: rightKeyCounts)
            case (.none, .some(let source)):
                guard row.status == .added, row.basis == .unmatched, !row.moved else { throw PluginValidationError.invalidField("Office added row") }
                try validateAmbiguity(row, source: source, columns: keys, leftCounts: leftKeyCounts, rightCounts: rightKeyCounts)
            case (.none, .none): throw PluginValidationError.invalidField("Office empty result row")
            }
        }
        guard seenLeft.count == left.count, seenRight.count == right.count else {
            throw PluginValidationError.invalidField("Office result source coverage")
        }
        try validateMoves(comparison.rows, left: leftByID, right: rightByID)
    }

    public static func cellsEqual(_ left: OfficeCell?, _ right: OfficeCell?) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        return left.column == right.column && equalText(left.type, right.type) && equalText(left.value, right.value) && equalText(left.formula, right.formula)
    }
    private static func validID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 128 }
    private static func validOptional(_ value: PluginJSONValue?, maximum: Int) -> Bool {
        value == .null || value?.stringValue.map { $0.utf8.count <= maximum } == true
    }
    private static func equalText(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) { case (.none, .none): return true; case (.some(let a), .some(let b)): return a.utf16.elementsEqual(b.utf16); default: return false }
    }
    private static func sourceRows(_ content: PluginJSONValue) throws -> [OfficeRow] {
        try JSONDecoder().decode([OfficeRow].self, from: JSONEncoder().encode(content["rows"]!))
    }
    private static func cellValue(_ cell: OfficeCell) -> PluginJSONValue {
        .array([.number(Double(cell.column)), .string(cell.type), cell.value.map(PluginJSONValue.string) ?? .null, cell.formula.map(PluginJSONValue.string) ?? .null])
    }
    private static func canonical(_ row: OfficeRow) throws -> Data { try JSONEncoder().encode(row.cells.map(cellValue)) }
    private static func key(_ row: OfficeRow, columns: [Int]) throws -> Data? {
        guard !columns.isEmpty else { return nil }
        var cells: [PluginJSONValue] = []
        for column in columns {
            guard let cell = row.cell(column: column), let value = cell.value, !value.isEmpty else { return nil }
            cells.append(cellValue(cell))
        }
        return try JSONEncoder().encode(cells)
    }
    private static func keyCounts(_ rows: [OfficeRow], columns: [Int]) throws -> [Data: Int] {
        var counts: [Data: Int] = [:]
        for row in rows { try Task.checkCancellation(); if let key = try key(row, columns: columns) { counts[key, default: 0] += 1 } }
        return counts
    }
    private static func exactCounts(_ rows: [OfficeRow]) throws -> [Data: Int] {
        var counts: [Data: Int] = [:]
        for row in rows { try Task.checkCancellation(); counts[try canonical(row), default: 0] += 1 }
        return counts
    }
    private static func validateAmbiguity(_ row: OfficeComparisonRow, source: OfficeRow, columns: [Int],
                                          leftCounts: [Data: Int], rightCounts: [Data: Int]) throws {
        let key = try key(source, columns: columns)
        let ambiguous = !columns.isEmpty && (key == nil || leftCounts[key!, default: 0] > 1 || rightCounts[key!, default: 0] > 1)
        guard row.ambiguous == ambiguous else { throw PluginValidationError.invalidField("Office ambiguous key") }
    }
    private static func validateMoves(_ rows: [OfficeComparisonRow], left: [Data: OfficeRow], right: [Data: OfficeRow]) throws {
        let pairs = rows.filter { $0.leftID != nil && $0.rightID != nil && ($0.basis == .exact || $0.basis == .key) }.sorted {
            left[Data($0.leftID!.utf8)]!.position < left[Data($1.leftID!.utf8)]!.position
        }
        var tails: [Int] = [], tailIndices: [Int] = [], previous: [Int] = []
        for (index, row) in pairs.enumerated() {
            try Task.checkCancellation()
            let position = right[Data(row.rightID!.utf8)]!.position
            var lower = 0, upper = tails.count
            while lower < upper { let middle = (lower + upper) / 2; if tails[middle] < position { lower = middle + 1 } else { upper = middle } }
            previous.append(lower == 0 ? -1 : tailIndices[lower - 1])
            if lower == tails.count { tails.append(position); tailIndices.append(index) }
            else { tails[lower] = position; tailIndices[lower] = index }
        }
        var retained = Set<Int>(), current = tailIndices.last ?? -1
        while current >= 0 { retained.insert(current); current = previous[current] }
        for (index, row) in pairs.enumerated() {
            guard row.moved == !retained.contains(index) else { throw PluginValidationError.invalidField("Office source order") }
        }
    }
}
