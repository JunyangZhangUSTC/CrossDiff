import Foundation

/// A presentation of the right source with left-side deletions inserted.
/// Removing the deletion runs always recovers the exact right-side UTF-16 text.
public struct DeletionPreview: Sendable {
    public struct Line: Sendable {
        public let range: NSRange
        public let rightLine: Int?
        public let leftLine: Int?
    }
    public struct Run: Sendable {
        public let range: NSRange
        public let rightRange: NSRange
        fileprivate let leftRange: NSRange?
    }
    public let text: String
    public let removedRanges: [NSRange]
    public let addedRanges: [NSRange]
    public let hunkRanges: [NSRange]
    public let lines: [Line]
    public let runs: [Run]

    public func previewOffset(forRightOffset offset: Int) -> Int? {
        for run in runs where run.rightRange.length > 0 {
            if offset >= run.rightRange.location && offset < NSMaxRange(run.rightRange) {
                return run.range.location + offset - run.rightRange.location
            }
        }
        return offset == (runs.last.map { NSMaxRange($0.rightRange) } ?? 0) ? text.utf16.count : nil
    }

    public func rightOffset(forPreviewOffset offset: Int) -> Int? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        for run in runs where NSLocationInRange(offset, run.range) {
            return run.rightRange.location + (run.rightRange.length == 0 ? 0 : offset - run.range.location)
        }
        return offset == text.utf16.count ? runs.last.map { NSMaxRange($0.rightRange) } ?? 0 : nil
    }

    public static func make(left: String, right: String, result: TextDiffResult,
                            options: TextDiffOptions = .init()) -> DeletionPreview {
        let a = left as NSString, b = right as NSString
        let leftLines = lineRanges(left), rightLines = lineRanges(right)
        struct Insertion {
            let anchor: Int
            let leftRange: NSRange
            let order: Int
        }
        var insertions: [Insertion] = []
        var rightToLeft: [Int: Int] = [:]
        var additions: [NSRange] = []
        var nextRight = b.length
        var rowAnchors = [Int](repeating: b.length, count: result.rows.count)
        for index in result.rows.indices.reversed() {
            if let line = result.rows[index].rightLine, rightLines.indices.contains(line) { nextRight = rightLines[line].location }
            rowAnchors[index] = nextRight
        }
        for (index, row) in result.rows.enumerated() {
            if Task.isCancelled { break }
            if let li = row.leftLine, let ri = row.rightLine { rightToLeft[ri] = li }
            additions.append(contentsOf: row.rightHighlights)
            guard let li = row.leftLine, leftLines.indices.contains(li) else { continue }
            guard let ri = row.rightLine, rightLines.indices.contains(ri) else {
                insertions.append(.init(anchor: rowAnchors[index], leftRange: leftLines[li], order: insertions.count))
                continue
            }
            guard !row.leftHighlights.isEmpty else { continue }
            let commonLeft = unchangedTokens(a.substring(with: leftLines[li]), offset: leftLines[li].location,
                                             changes: row.leftHighlights, options: options)
            let commonRight = unchangedTokens(b.substring(with: rightLines[ri]), offset: rightLines[ri].location,
                                              changes: row.rightHighlights, options: options)
            var commonIndex = 0
            for removal in row.leftHighlights {
                while commonIndex < commonLeft.count && NSMaxRange(commonLeft[commonIndex]) <= removal.location { commonIndex += 1 }
                let anchor = commonIndex > 0 && commonIndex <= commonRight.count
                    ? NSMaxRange(commonRight[commonIndex - 1]) : rightLines[ri].location
                insertions.append(.init(anchor: anchor, leftRange: removal, order: insertions.count))
            }
        }
        insertions.sort { $0.anchor == $1.anchor ? $0.order < $1.order : $0.anchor < $1.anchor }
        additions.sort { $0.location < $1.location }
        var value = "", length = 0, cursor = 0, addedIndex = 0
        var removed: [NSRange] = [], added: [NSRange] = [], runs: [Run] = []
        func appendRight(until end: Int) {
            guard end > cursor else { return }
            let source = NSRange(location: cursor, length: end - cursor)
            value += b.substring(with: source)
            runs.append(.init(range: NSRange(location: length, length: source.length), rightRange: source, leftRange: nil))
            while addedIndex < additions.count && NSMaxRange(additions[addedIndex]) <= cursor { addedIndex += 1 }
            var index = addedIndex
            while index < additions.count && additions[index].location < end {
                let intersection = NSIntersectionRange(source, additions[index])
                if intersection.length > 0 {
                    added.append(NSRange(location: length + intersection.location - cursor, length: intersection.length))
                }
                index += 1
            }
            length += source.length; cursor = end
        }
        for insertion in insertions {
            if Task.isCancelled { break }
            guard insertion.anchor >= cursor, insertion.anchor <= b.length,
                  insertion.leftRange.length > 0, NSMaxRange(insertion.leftRange) <= a.length else { continue }
            appendRight(until: insertion.anchor)
            let range = NSRange(location: length, length: insertion.leftRange.length)
            value += a.substring(with: insertion.leftRange)
            removed.append(range)
            runs.append(.init(range: range, rightRange: NSRange(location: cursor, length: 0), leftRange: insertion.leftRange))
            length += range.length
        }
        appendRight(until: b.length)

        var lines: [Line] = [], runIndex = 0
        for range in lineRanges(value) {
            while runIndex < runs.count && NSMaxRange(runs[runIndex].range) <= range.location { runIndex += 1 }
            var index = runIndex, rightLine: Int?, leftLine: Int?
            while index < runs.count && runs[index].range.location < NSMaxRange(range) {
                let run = runs[index], offset = max(range.location, run.range.location) - run.range.location
                if run.rightRange.length > 0 && rightLine == nil {
                    rightLine = lineIndex(at: run.rightRange.location + offset, in: rightLines)
                }
                if let source = run.leftRange, leftLine == nil {
                    leftLine = lineIndex(at: source.location + offset, in: leftLines)
                }
                index += 1
            }
            if leftLine == nil, let rightLine { leftLine = rightToLeft[rightLine] }
            lines.append(.init(range: range, rightLine: rightLine, leftLine: leftLine))
        }

        var bounds = [NSRange?](repeating: nil, count: result.hunks.count)
        var leftHunk = 0, rightHunk = 0
        func include(_ range: NSRange, at index: Int) {
            bounds[index] = bounds[index].map { NSUnionRange($0, range) } ?? range
        }
        for run in runs {
            if let source = run.leftRange {
                while leftHunk < result.hunks.count && NSMaxRange(result.hunks[leftHunk].leftRange) <= source.location { leftHunk += 1 }
                if leftHunk < result.hunks.count, NSIntersectionRange(source, result.hunks[leftHunk].leftRange).length > 0 {
                    include(run.range, at: leftHunk)
                }
            } else {
                while rightHunk < result.hunks.count && NSMaxRange(result.hunks[rightHunk].rightRange) <= run.rightRange.location { rightHunk += 1 }
                var index = rightHunk
                while index < result.hunks.count && result.hunks[index].rightRange.location < NSMaxRange(run.rightRange) {
                    let intersection = NSIntersectionRange(run.rightRange, result.hunks[index].rightRange)
                    if intersection.length > 0 {
                        include(NSRange(location: run.range.location + intersection.location - run.rightRange.location,
                                        length: intersection.length), at: index)
                    }
                    index += 1
                }
            }
        }
        return DeletionPreview(text: value, removedRanges: removed, addedRanges: added,
                               hunkRanges: bounds.map { $0 ?? NSRange(location: 0, length: 0) }, lines: lines, runs: runs)
    }

    private static func unchangedTokens(_ text: String, offset: Int, changes: [NSRange], options: TextDiffOptions) -> [NSRange] {
        var result: [NSRange] = [], cursor = offset, changeIndex = 0
        for character in text {
            let length = character.utf16.count
            while changeIndex < changes.count && NSMaxRange(changes[changeIndex]) <= cursor { changeIndex += 1 }
            let changed = changeIndex < changes.count && NSLocationInRange(cursor, changes[changeIndex])
            if !changed && !(options.ignoreWhitespace && character.isWhitespace && !character.isNewline) {
                result.append(NSRange(location: cursor, length: length))
            }
            cursor += length
        }
        return result
    }

    private static func lineRanges(_ text: String) -> [NSRange] {
        var result: [NSRange] = [], start = 0, offset = 0
        for character in text {
            offset += character.utf16.count
            if character.isNewline { result.append(NSRange(location: start, length: offset - start)); start = offset }
        }
        if offset > start { result.append(NSRange(location: start, length: offset - start)) }
        return result
    }

    private static func lineIndex(at offset: Int, in lines: [NSRange]) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].location <= offset { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }
}
