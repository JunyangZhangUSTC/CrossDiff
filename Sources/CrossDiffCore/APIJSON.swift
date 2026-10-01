import Foundation

/// A bounded JSON reader which preserves numeric lexemes instead of converting through Double.
/// Used for both HAR envelopes and JSON message bodies. Duplicate keys are rejected.
indirect enum APIJSONNode {
    case object([(String, APIJSONNode)]), array([APIJSONNode]), string(String), number(String), bool(Bool), null
    subscript(_ key: String) -> APIJSONNode? {
        if case .object(let pairs) = self { return pairs.first { $0.0.utf8.elementsEqual(key.utf8) }?.1 }; return nil
    }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var array: [APIJSONNode]? { if case .array(let value) = self { return value }; return nil }
    var number: String? { if case .number(let value) = self { return value }; return nil }
}

struct APIJSONReader {
    private let bytes: [UInt8]
    private var index = 0
    private var nodes = 0
    init(_ text: String) { bytes = Array(text.utf8) }
    mutating func parse() throws -> APIJSONNode {
        let result = try value(depth: 0); whitespace()
        guard index == bytes.count else { throw APIImportError.invalidJSON }
        return result
    }
    private mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace(); guard index < bytes.count && bytes[index] == byte else { return false }
        index += 1; return true
    }
    private mutating func value(depth: Int) throws -> APIJSONNode {
        try Task.checkCancellation()
        nodes += 1
        guard depth <= 64, nodes <= 20_000 else { throw APIImportError.jsonLimit }
        whitespace(); guard index < bytes.count else { throw APIImportError.invalidJSON }
        switch bytes[index] {
        case 123:
            index += 1; var pairs: [(String, APIJSONNode)] = []; var keys = Set<Data>()
            if take(125) { return .object(pairs) }
            repeat {
                whitespace(); let key = try string()
                guard keys.insert(Data(key.utf8)).inserted else { throw APIImportError.duplicateJSONKey }
                guard take(58) else { throw APIImportError.invalidJSON }
                pairs.append((key, try value(depth: depth + 1)))
                if take(125) { return .object(pairs) }
                guard take(44) else { throw APIImportError.invalidJSON }
            } while true
        case 91:
            index += 1; var items: [APIJSONNode] = []
            if take(93) { return .array(items) }
            repeat {
                items.append(try value(depth: depth + 1))
                if take(93) { return .array(items) }
                guard take(44) else { throw APIImportError.invalidJSON }
            } while true
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        case 45, 48...57: return .number(try number())
        default: throw APIImportError.invalidJSON
        }
    }
    private mutating func literal(_ text: String) throws {
        let token = Array(text.utf8)
        guard index + token.count <= bytes.count, Array(bytes[index..<index + token.count]) == token else {
            throw APIImportError.invalidJSON
        }
        index += token.count
    }
    private mutating func string() throws -> String {
        guard index < bytes.count && bytes[index] == 34 else { throw APIImportError.invalidJSON }
        let start = index; index += 1
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 {
                // Foundation validates JSON escapes, UTF-8 and surrogate pairs for this single string.
                guard let value = try? JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: .fragmentsAllowed) as? String else {
                    throw APIImportError.invalidJSON
                }
                return value
            }
            if byte < 32 { throw APIImportError.invalidJSON }
            if byte == 92 { guard index < bytes.count else { throw APIImportError.invalidJSON }; index += 1 }
        }
        throw APIImportError.invalidJSON
    }
    private mutating func number() throws -> String {
        let start = index
        if bytes[index] == 45 { index += 1 }
        guard index < bytes.count else { throw APIImportError.invalidJSON }
        if bytes[index] == 48 { index += 1 }
        else {
            guard (49...57).contains(bytes[index]) else { throw APIImportError.invalidJSON }
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count && bytes[index] == 46 {
            index += 1; let digits = index
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            guard index > digits else { throw APIImportError.invalidJSON }
        }
        if index < bytes.count && [69, 101].contains(bytes[index]) {
            index += 1
            if index < bytes.count && [43, 45].contains(bytes[index]) { index += 1 }
            let digits = index
            while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            guard index > digits else { throw APIImportError.invalidJSON }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}
