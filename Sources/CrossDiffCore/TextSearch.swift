import Foundation

/// Literal, non-overlapping matches expressed in the source string's UTF-16 coordinates.
public enum TextSearch {
    public static func matches(in text: String, query: String, ignoreCase: Bool = false, limit: Int = .max) -> [NSRange] {
        try! matches(in: text, query: query, ignoreCase: ignoreCase, limit: limit, cancellationCheck: {})
    }

    public static func matches(in text: String, query: String, ignoreCase: Bool = false, limit: Int = .max,
                               cancellationCheck: () throws -> Void) throws -> [NSRange] {
        var result: [NSRange] = []
        try forEachMatch(in: text, query: query, ignoreCase: ignoreCase, limit: limit,
                         cancellationCheck: cancellationCheck) { result.append($0) }
        return result
    }

    /// Streams source ranges without retaining every match, for operations such as Replace All.
    /// The callback receives the same non-overlapping UTF-16 matches used by search navigation.
    public static func forEachMatch(in text: String, query: String, ignoreCase: Bool = false, limit: Int = .max,
                                    cancellationCheck: () throws -> Void = {},
                                    _ body: (NSRange) throws -> Void) throws {
        try cancellationCheck()
        guard !query.isEmpty, limit > 0 else { return }
        var operations = 0
        func checkpoint() throws {
            operations += 1
            if operations % 2_048 == 0 { try cancellationCheck() }
        }
        // Apply only case folding, without a separate canonical-normalization pass. Cache
        // non-ASCII scalars so Foundation never needs to scan the entire source at once.
        var folds: [UInt32: [UInt16]] = [:]
        func fold(_ scalar: Unicode.Scalar) -> [UInt16] {
            if let cached = folds[scalar.value] { return cached }
            let units = Array(String(scalar).folding(options: [.caseInsensitive], locale: nil).utf16)
            folds[scalar.value] = units
            return units
        }
        var pattern: [UInt16] = []
        if ignoreCase {
            for scalar in query.unicodeScalars {
                try checkpoint()
                if scalar.value < 128 {
                    pattern.append(UInt16((65...90).contains(scalar.value) ? scalar.value + 32 : scalar.value))
                } else {
                    pattern.append(contentsOf: fold(scalar))
                }
            }
        } else {
            for unit in query.utf16 { try checkpoint(); pattern.append(unit) }
        }
        guard !pattern.isEmpty else { return }
        // Prefix lengths keep repeated text and long almost-matching queries linear.
        var prefixes = [Int](repeating: 0, count: pattern.count)
        if pattern.count > 1 {
            for index in 1..<pattern.count {
                try checkpoint()
                var length = prefixes[index - 1]
                while length > 0 && pattern[index] != pattern[length] {
                    try checkpoint()
                    length = prefixes[length - 1]
                }
                if pattern[index] == pattern[length] { length += 1 }
                prefixes[index] = length
            }
        }
        var count = 0
        var matched = 0
        func advance(_ unit: UInt16) throws {
            try checkpoint()
            while matched > 0 && unit != pattern[matched] {
                try checkpoint()
                matched = prefixes[matched - 1]
            }
            if unit == pattern[matched] { matched += 1 }
        }
        if !ignoreCase {
            for (offset, unit) in text.utf16.enumerated() {
                try advance(unit)
                if matched == pattern.count {
                    try body(NSRange(location: offset + 1 - pattern.count, length: pattern.count))
                    count += 1
                    if count >= limit { return }
                    matched = 0
                }
            }
        } else {
            // A folded scalar can expand (ß → ss). Only whole scalar expansions count,
            // and the ring buffer retains their original offsets without copying the source.
            var starts = [Int](repeating: 0, count: pattern.count)
            var processed = 0, sourceOffset = 0
            func consume(_ unit: UInt16, startsScalar: Bool, endsScalar: Bool, sourceEnd: Int) throws {
                starts[processed % pattern.count] = startsScalar ? sourceOffset + 1 : 0
                try advance(unit)
                if matched == pattern.count {
                    let start = starts[(processed + 1 - pattern.count) % pattern.count]
                    if start > 0 && endsScalar {
                        try body(NSRange(location: start - 1, length: sourceEnd - start + 1))
                        count += 1
                        matched = 0
                    } else {
                        matched = prefixes[matched - 1]
                    }
                }
                processed += 1
            }
            for scalar in text.unicodeScalars {
                let sourceEnd = sourceOffset + (scalar.value > 0xFFFF ? 2 : 1)
                if scalar.value < 128 {
                    let unit = UInt16((65...90).contains(scalar.value) ? scalar.value + 32 : scalar.value)
                    try consume(unit, startsScalar: true, endsScalar: true, sourceEnd: sourceEnd)
                } else {
                    let units = fold(scalar)
                    for (index, unit) in units.enumerated() {
                        try consume(unit, startsScalar: index == 0, endsScalar: index == units.count - 1, sourceEnd: sourceEnd)
                    }
                }
                sourceOffset = sourceEnd
                if count >= limit { return }
            }
        }
        try cancellationCheck()
    }
}
