import Foundation

public struct TextDiffOptions: Sendable {
    /// Ignore horizontal whitespace; line endings remain significant.
    public var ignoreWhitespace: Bool
    public var ignoreCase: Bool

    public init(ignoreWhitespace: Bool = false, ignoreCase: Bool = false) {
        self.ignoreWhitespace = ignoreWhitespace
        self.ignoreCase = ignoreCase
    }
}

public enum DiffKind: String, Sendable {
    case equal, added, removed, changed
}

public struct DiffSpan: Sendable {
    public let range: NSRange
    public init(range: NSRange) { self.range = range }
}

public struct DiffRow: Sendable, Identifiable {
    public var id: Int
    public var leftLine: Int?
    public var rightLine: Int?
    public var kind: DiffKind
    public var leftHighlights: [NSRange]
    public var rightHighlights: [NSRange]

    public init(id: Int, leftLine: Int?, rightLine: Int?, kind: DiffKind,
                leftHighlights: [NSRange], rightHighlights: [NSRange]) {
        self.id = id
        self.leftLine = leftLine
        self.rightLine = rightLine
        self.kind = kind
        self.leftHighlights = leftHighlights
        self.rightHighlights = rightHighlights
    }
}

public struct DiffHunk: Sendable, Identifiable {
    public var id: Int
    public var leftRange: NSRange
    public var rightRange: NSRange

    public init(id: Int, leftRange: NSRange, rightRange: NSRange) {
        self.id = id
        self.leftRange = leftRange
        self.rightRange = rightRange
    }
}

public struct TextDiffResult: Sendable {
    public var rows: [DiffRow]
    public var hunks: [DiffHunk]
    public var simplified: Bool

    public init(rows: [DiffRow], hunks: [DiffHunk], simplified: Bool) {
        self.rows = rows
        self.hunks = hunks
        self.simplified = simplified
    }
}

public enum TextDiffEngine {
    public static func compare(_ left: String, _ right: String,
                               options: TextDiffOptions = TextDiffOptions()) -> TextDiffResult {
        // Preserve the synchronous API for callers that do not participate in task cancellation.
        try! compareCancellable(left, right, options: options, cancellationCheck: {})
    }

    public static func compareCancellable(_ left: String, _ right: String,
                                          options: TextDiffOptions = TextDiffOptions(),
                                          cancellationCheck: () throws -> Void = { try Task.checkCancellation() }) throws -> TextDiffResult {
        try cancellationCheck()
        let a = try lines(in: left, options: options, cancellationCheck: cancellationCheck)
        let b = try lines(in: right, options: options, cancellationCheck: cancellationCheck)
        // Intern line keys once so the alignment search does not repeatedly compare long lines.
        var interned: [[UInt16]: Int] = [:]
        func lineIDs(_ lines: [Line]) throws -> [Int] {
            try lines.enumerated().map { index, line in
                if index % 256 == 0 { try cancellationCheck() }
                if let id = interned[line.key] { return id }
                let id = interned.count
                interned[line.key] = id
                return id
            }
        }
        let leftIDs = try lineIDs(a), rightIDs = try lineIDs(b)
        // Bound the unmatched region rather than rejecting large mostly-identical files.
        var lineBudget = 2_000_000
        let changes = try changedOffsets(leftIDs, rightIDs, budget: &lineBudget, maxElements: 10_000,
                                         cancellationCheck: cancellationCheck)
        let removed = changes.removed, inserted = changes.inserted
        var simplified = changes.simplified
        var inlineBudget = 1_000_000
        var pairingBudget = 32_768
        var rows: [DiffRow] = [], hunks: [DiffHunk] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if rows.count % 256 == 0 { try cancellationCheck() }
            if i < a.count, j < b.count, !removed.contains(i), !inserted.contains(j) {
                rows.append(DiffRow(id: rows.count, leftLine: i, rightLine: j, kind: .equal,
                                    leftHighlights: [], rightHighlights: []))
                i += 1
                j += 1
                continue
            }
            let startI = i, startJ = j
            while i < a.count, removed.contains(i) {
                if i % 256 == 0 { try cancellationCheck() }
                i += 1
            }
            while j < b.count, inserted.contains(j) {
                if j % 256 == 0 { try cancellationCheck() }
                j += 1
            }
            let leftStart = startI < a.count ? a[startI].range.location : left.utf16.count
            let rightStart = startJ < b.count ? b[startJ].range.location : right.utf16.count
            let leftEnd = i < a.count ? a[i].range.location : left.utf16.count
            let rightEnd = j < b.count ? b[j].range.location : right.utf16.count
            hunks.append(DiffHunk(id: hunks.count,
                                 leftRange: NSRange(location: leftStart, length: leftEnd - leftStart),
                                 rightRange: NSRange(location: rightStart, length: rightEnd - rightStart)))
            let pairing = try pairedLines(a, b, leftRange: startI..<i, rightRange: startJ..<j,
                                          budget: &pairingBudget, cancellationCheck: cancellationCheck)
            simplified = simplified || pairing.simplified
            for index in 0..<(pairing.rows?.count ?? max(i - startI, j - startJ)) {
                if index % 256 == 0 { try cancellationCheck() }
                let li: Int?, ri: Int?
                if let pairs = pairing.rows {
                    (li, ri) = pairs[index]
                } else {
                    li = startI + index < i ? startI + index : nil
                    ri = startJ + index < j ? startJ + index : nil
                }
                let kind: DiffKind = li == nil ? .added : (ri == nil ? .removed : .changed)
                var leftHighlights: [NSRange] = [], rightHighlights: [NSRange] = []
                if let li, let ri {
                    let highlights = try changedRanges(a[li].text, b[ri].text, options: options, budget: &inlineBudget,
                                                       cancellationCheck: cancellationCheck)
                    simplified = simplified || highlights.2
                    leftHighlights = highlights.0.map {
                        NSRange(location: a[li].range.location + $0.location, length: $0.length)
                    }
                    rightHighlights = highlights.1.map {
                        NSRange(location: b[ri].range.location + $0.location, length: $0.length)
                    }
                } else if let li { leftHighlights = [a[li].range] }
                else if let ri { rightHighlights = [b[ri].range] }
                rows.append(DiffRow(id: rows.count, leftLine: li, rightLine: ri, kind: kind,
                                    leftHighlights: leftHighlights, rightHighlights: rightHighlights))
            }
        }
        try cancellationCheck()
        return TextDiffResult(rows: rows, hunks: hunks, simplified: simplified)
    }

    private struct Line {
        let text: String
        let range: NSRange
        let key: [UInt16]
    }

    /// Pair nearby edited lines by content while keeping both source orders. The hunk's
    /// exact ranges still drive merging; these choices affect only rows and inline marks.
    private static func pairedLines(_ left: [Line], _ right: [Line],
                                    leftRange: Range<Int>, rightRange: Range<Int>, budget: inout Int,
                                    cancellationCheck: () throws -> Void) throws
        -> (rows: [(Int?, Int?)]?, simplified: Bool) {
        let n = leftRange.count, m = rightRange.count
        // A lone replacement remains a replacement, even when it has no shared characters.
        guard n > 0, m > 0, n != 1 || m != 1 else { return (nil, false) }
        guard n <= 256, m <= 256, n <= budget / m else { return (nil, true) }
        budget -= n * m
        try cancellationCheck()

        func signature(_ key: [UInt16]) -> [UInt32] {
            // Fixed-size prefix/suffix samples keep long or minified lines bounded. Skip
            // common layout whitespace so indentation/newlines cannot dominate the score.
            let sample = key.count <= 192 ? key : Array(key.prefix(96)) + Array(key.suffix(96))
            let units = sample.filter { $0 != 9 && $0 != 10 && $0 != 13 && $0 != 32 }
            guard let first = units.first else { return [] }
            if units.count == 1 { return [UInt32(first) << 16] }
            return zip(units, units.dropFirst()).map { UInt32($0) << 16 | UInt32($1) }.sorted()
        }
        let a = leftRange.map { signature(left[$0].key) }
        let b = rightRange.map { signature(right[$0].key) }
        func replacementCost(_ a: [UInt32], _ b: [UInt32]) -> Int {
            if a.isEmpty && b.isEmpty { return 0 }
            var i = 0, j = 0, shared = 0
            while i < a.count && j < b.count {
                if a[i] == b[j] { shared += 1; i += 1; j += 1 }
                else if a[i] < b[j] { i += 1 }
                else { j += 1 }
            }
            return 1_000 - 2_000 * shared / max(1, a.count + b.count)
        }
        let width = m + 1, gapCost = 400
        var scores = [Int](repeating: 0, count: (n + 1) * width)
        // 0 = replacement, 1 = removal, 2 = addition. Prefer replacement on ties.
        var directions = [UInt8](repeating: 0, count: scores.count)
        for i in 1...n { scores[i * width] = i * gapCost; directions[i * width] = 1 }
        for j in 1...m { scores[j] = j * gapCost; directions[j] = 2 }
        for i in 1...n {
            try cancellationCheck()
            for j in 1...m {
                let cell = i * width + j
                var cost = scores[(i - 1) * width + j - 1] + replacementCost(a[i - 1], b[j - 1])
                var direction: UInt8 = 0
                let removal = scores[(i - 1) * width + j] + gapCost
                let addition = scores[i * width + j - 1] + gapCost
                if removal < cost { cost = removal; direction = 1 }
                if addition < cost || (addition == cost && direction == 1) { cost = addition; direction = 2 }
                scores[cell] = cost
                directions[cell] = direction
            }
        }
        var rows: [(Int?, Int?)] = [], i = n, j = m
        while i > 0 || j > 0 {
            switch directions[i * width + j] {
            case 1:
                i -= 1; rows.append((leftRange.lowerBound + i, nil))
            case 2:
                j -= 1; rows.append((nil, rightRange.lowerBound + j))
            default:
                i -= 1; j -= 1
                rows.append((leftRange.lowerBound + i, rightRange.lowerBound + j))
            }
        }
        return (Array(rows.reversed()), false)
    }

    private static func lines(in text: String, options: TextDiffOptions,
                              cancellationCheck: () throws -> Void) throws -> [Line] {
        var result: [Line] = []
        var start = text.startIndex, offset = 0, length = 0
        for (iteration, index) in text.indices.enumerated() {
            if iteration % 256 == 0 { try cancellationCheck() }
            let character = text[index]
            length += character.utf16.count
            if character.isNewline {
                let end = text.index(after: index)
                let value = String(text[start..<end])
                result.append(Line(text: value, range: NSRange(location: offset, length: length),
                                   key: try normalizedKey(value, options: options, cancellationCheck: cancellationCheck)))
                start = end
                offset += length
                length = 0
            }
        }
        if start < text.endIndex {
            let value = String(text[start...])
            result.append(Line(text: value, range: NSRange(location: offset, length: length),
                               key: try normalizedKey(value, options: options, cancellationCheck: cancellationCheck)))
        }
        return result
    }

    /// The hunk must come from a comparison of these exact source strings.
    public static func applying(_ hunk: DiffHunk, fromLeft: Bool,
                                left: String, right: String) -> String {
        let source = fromLeft ? left : right
        let target = fromLeft ? right : left
        let sourceRange = fromLeft ? hunk.leftRange : hunk.rightRange
        let targetRange = fromLeft ? hunk.rightRange : hunk.leftRange
        guard let sourceIndices = Range(sourceRange, in: source),
              let targetIndices = Range(targetRange, in: target) else { return target }
        var result = target
        result.replaceSubrange(targetIndices, with: source[sourceIndices])
        return result
    }

    private struct Token {
        let key: [UInt16]
        let range: NSRange
    }

    private static func normalizedKey(_ text: String, options: TextDiffOptions,
                                      cancellationCheck: () throws -> Void) throws -> [UInt16] {
        try cancellationCheck()
        var value = text
        if options.ignoreWhitespace {
            var filtered = String()
            filtered.reserveCapacity(text.utf8.count)
            for (index, character) in text.enumerated() {
                if index % 256 == 0 { try cancellationCheck() }
                if !character.isWhitespace || character.isNewline { filtered.append(character) }
            }
            value = filtered
        }
        if options.ignoreCase { value = value.lowercased() }
        try cancellationCheck()
        return Array(value.utf16)
    }

    private static func tokens(in text: String, options: TextDiffOptions,
                               cancellationCheck: () throws -> Void) throws -> [Token] {
        var result: [Token] = [], offset = 0
        for (index, character) in text.enumerated() {
            if index % 256 == 0 { try cancellationCheck() }
            let length = character.utf16.count
            if !(options.ignoreWhitespace && character.isWhitespace && !character.isNewline) {
                let value = options.ignoreCase ? String(character).lowercased() : String(character)
                result.append(Token(key: Array(value.utf16), range: NSRange(location: offset, length: length)))
            }
            offset += length
        }
        return result
    }

    private static func changedRanges(_ left: String, _ right: String,
                                      options: TextDiffOptions, budget: inout Int,
                                      cancellationCheck: () throws -> Void) throws -> ([NSRange], [NSRange], Bool) {
        try cancellationCheck()
        // Avoid materializing hundreds of thousands of grapheme tokens for minified files.
        if left.utf16.count > 100_000 || right.utf16.count > 100_000 {
            return try coarseRanges(left, right, options: options, cancellationCheck: cancellationCheck)
        }
        let a = try tokens(in: left, options: options, cancellationCheck: cancellationCheck)
        let b = try tokens(in: right, options: options, cancellationCheck: cancellationCheck)
        var sliceBudget = min(budget, 250_000)
        let allowance = sliceBudget
        let changes = try changedOffsets(a.map(\.key), b.map(\.key), budget: &sliceBudget, maxElements: 10_000,
                                         cancellationCheck: cancellationCheck)
        budget -= allowance - sliceBudget
        func ranges(_ tokens: [Token], _ selected: Set<Int>) -> [NSRange] {
            var result: [NSRange] = []
            for (index, token) in tokens.enumerated() where selected.contains(index) {
                if let previous = result.last, NSMaxRange(previous) == token.range.location {
                    result[result.count - 1].length += token.range.length
                } else { result.append(token.range) }
            }
            return result
        }
        return (ranges(a, changes.removed), ranges(b, changes.inserted), changes.simplified)
    }

    private static func coarseRanges(_ left: String, _ right: String,
                                     options: TextDiffOptions,
                                     cancellationCheck: () throws -> Void) throws -> ([NSRange], [NSRange], Bool) {
        var leftStart = left.startIndex, rightStart = right.startIndex
        var leftEnd = left.endIndex, rightEnd = right.endIndex
        func same(_ a: Character, _ b: Character) throws -> Bool {
            try normalizedKey(String(a), options: options, cancellationCheck: cancellationCheck)
                == normalizedKey(String(b), options: options, cancellationCheck: cancellationCheck)
        }
        while leftStart < leftEnd, rightStart < rightEnd, try same(left[leftStart], right[rightStart]) {
            left.formIndex(after: &leftStart)
            right.formIndex(after: &rightStart)
        }
        while leftStart < leftEnd, rightStart < rightEnd {
            let a = left.index(before: leftEnd), b = right.index(before: rightEnd)
            guard try same(left[a], right[b]) else { break }
            leftEnd = a
            rightEnd = b
        }
        let a = NSRange(leftStart..<leftEnd, in: left), b = NSRange(rightStart..<rightEnd, in: right)
        return (a.length == 0 ? [] : [a], b.length == 0 ? [] : [b], true)
    }

    /// Swift's sequence diff is bounded by both element count and worst-case search area.
    /// The fallback marks the unmatched middle as one change while retaining exact ranges.
    private static func changedOffsets<Key: Equatable>(_ left: [Key], _ right: [Key],
                                       budget: inout Int, maxElements: Int,
                                       cancellationCheck: () throws -> Void)
        throws -> (removed: Set<Int>, inserted: Set<Int>, simplified: Bool) {
        try cancellationCheck()
        var prefix = 0
        while prefix < min(left.count, right.count), left[prefix] == right[prefix] {
            if prefix % 256 == 0 { try cancellationCheck() }
            prefix += 1
        }
        var suffix = 0
        while suffix < min(left.count, right.count) - prefix,
              left[left.count - suffix - 1] == right[right.count - suffix - 1] {
            if suffix % 256 == 0 { try cancellationCheck() }
            suffix += 1
        }
        let leftEnd = left.count - suffix, rightEnd = right.count - suffix
        let n = leftEnd - prefix, m = rightEnd - prefix
        func offsets(in range: Range<Int>) throws -> Set<Int> {
            var result = Set<Int>()
            for offset in range {
                if offset % 256 == 0 { try cancellationCheck() }
                result.insert(offset)
            }
            return result
        }
        if n == 0 || m == 0 {
            return try (offsets(in: prefix..<leftEnd), offsets(in: prefix..<rightEnd), false)
        }
        if n > maxElements || m > maxElements || n > budget / m {
            return try (offsets(in: prefix..<leftEnd), offsets(in: prefix..<rightEnd), true)
        }
        budget -= n * m
        // The standard-library search is bounded above; check immediately on both sides of it.
        try cancellationCheck()
        let changes = right[prefix..<rightEnd].difference(from: left[prefix..<leftEnd])
        try cancellationCheck()
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removed.insert(prefix + offset)
            case .insert(let offset, _, _): inserted.insert(prefix + offset)
            }
        }
        return (removed, inserted, false)
    }

}
