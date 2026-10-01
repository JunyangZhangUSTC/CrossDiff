import Foundation
import CrossDiffCore

private struct DeletionPreviewCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func previewRequire(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw DeletionPreviewCheckFailure(message: message) }
}

private func previewFragments(_ preview: DeletionPreview, _ ranges: [NSRange]) -> [String] {
    ranges.map { (preview.text as NSString).substring(with: $0) }
}

@discardableResult
private func verifyPreview(_ left: String, _ right: String, options: TextDiffOptions = .init(),
                           expected: String? = nil) throws -> DeletionPreview {
    let result = TextDiffEngine.compare(left, right, options: options)
    let preview = DeletionPreview.make(left: left, right: right, result: result, options: options)
    let units = Array(preview.text.utf16)
    if let expected {
        try previewRequire(units == Array(expected.utf16), "Unexpected preview: \(preview.text.debugDescription), expected \(expected.debugDescription)")
    }
    var recovered = units
    var lastEnd = 0
    for range in preview.removedRanges {
        try previewRequire(range.location >= lastEnd && range.length > 0 && NSMaxRange(range) <= units.count,
                           "Removal ranges must be ordered, nonempty and bounded")
        lastEnd = NSMaxRange(range)
    }
    for range in preview.removedRanges.reversed() { recovered.removeSubrange(range.location..<NSMaxRange(range)) }
    try previewRequire(recovered == Array(right.utf16), "Removing deleted fragments must exactly recover right UTF16")
    for range in preview.addedRanges {
        try previewRequire(range.length > 0 && range.location >= 0 && NSMaxRange(range) <= units.count, "Invalid addition range")
        try previewRequire(!preview.removedRanges.contains { NSIntersectionRange($0, range).length > 0 }, "Added/removed ranges overlap")
    }
    try previewRequire(preview.hunkRanges.count == result.hunks.count, "Preview must preserve hunk order/count")
    for range in preview.hunkRanges {
        try previewRequire(range.location >= 0 && range.length > 0 && NSMaxRange(range) <= units.count, "Invalid or empty projected hunk")
    }
    var previewCursor = 0, rightCursor = 0
    for run in preview.runs {
        try previewRequire(run.range.location == previewCursor && run.rightRange.location == rightCursor, "Run mapping must be contiguous")
        try previewRequire(run.rightRange.length == 0 || run.rightRange.length == run.range.length, "Right run UTF16 lengths must match")
        previewCursor = NSMaxRange(run.range)
        rightCursor = NSMaxRange(run.rightRange)
    }
    try previewRequire(previewCursor == units.count && rightCursor == right.utf16.count, "Runs must cover preview and right text")
    for offset in 0...right.utf16.count {
        guard let projected = preview.previewOffset(forRightOffset: offset) else {
            throw DeletionPreviewCheckFailure(message: "Missing right offset \(offset)")
        }
        try previewRequire(preview.rightOffset(forPreviewOffset: projected) == offset, "Source offset round trip failed at \(offset)")
    }
    for offset in 0...units.count {
        guard let source = preview.rightOffset(forPreviewOffset: offset) else {
            throw DeletionPreviewCheckFailure(message: "Missing preview offset \(offset)")
        }
        try previewRequire(source >= 0 && source <= right.utf16.count, "Preview maps outside right source")
    }
    try previewRequire(preview.previewOffset(forRightOffset: -1) == nil && preview.previewOffset(forRightOffset: right.utf16.count + 1) == nil,
                       "Invalid source offsets should return nil")
    try previewRequire(preview.rightOffset(forPreviewOffset: -1) == nil && preview.rightOffset(forPreviewOffset: units.count + 1) == nil,
                       "Invalid preview offsets should return nil")
    var lineCursor = 0
    for line in preview.lines {
        try previewRequire(line.range.location == lineCursor && line.range.length > 0, "Line ranges must cover preview without gaps")
        lineCursor = NSMaxRange(line.range)
    }
    try previewRequire(lineCursor == units.count, "Line ranges must reach preview EOF")
    return preview
}

func runDeletionPreviewChecks() throws {
    let inline = try verifyPreview("aXbYc", "abc", expected: "aXbYc")
    try previewRequire(previewFragments(inline, inline.removedRanges) == ["X", "Y"], "Only inline deleted fragments should be inserted")
    try previewRequire(inline.addedRanges.isEmpty, "Pure inline deletion must not add highlights")
    let replacement = try verifyPreview("aXb", "aYb", expected: "aXYb")
    try previewRequire(previewFragments(replacement, replacement.removedRanges) == ["X"], "Replacement deletion missing")
    try previewRequire(previewFragments(replacement, replacement.addedRanges) == ["Y"], "Replacement addition missing")
    let lines = try verifyPreview("top\nremove\nanchor\ntail\n", "top\nanchor\ninsert\ntail\n",
                                  expected: "top\nremove\nanchor\ninsert\ntail\n")
    try previewRequire(lines.lines.map(\.rightLine) == [0, nil, 1, 2, 3], "Deleted full line should have no right line number")
    try previewRequire(lines.lines.map(\.leftLine) == [0, 1, 2, nil, 3], "Preview left line mapping changed")
    try previewRequire(lines.hunkRanges == [NSRange(location: 4, length: 7), NSRange(location: 18, length: 7)], "Separated hunk navigation ranges incorrect")
    let deleted = try verifyPreview("gone\r\nlast", "", expected: "gone\r\nlast")
    try previewRequire(deleted.lines.allSatisfy { $0.rightLine == nil }, "Pure deletion lines must have no right number")
    let added = try verifyPreview("", "new\nlast", expected: "new\nlast")
    try previewRequire(added.removedRanges.isEmpty && added.lines.allSatisfy { $0.leftLine == nil }, "Pure addition mapping incorrect")
    try verifyPreview("", "", expected: "")
    try verifyPreview("a\n", "a", expected: "a\n")
    try verifyPreview("a", "a\n", expected: "a\n")
    try verifyPreview("a\r\n", "a\n", expected: "a\r\n\n")
    let unicode = try verifyPreview("A👨‍👩‍👧‍👦B e\u{301} C!", "A👩🏽‍💻B é C?",
                                    expected: "A👨‍👩‍👧‍👦👩🏽‍💻B e\u{301}é C!?")
    try previewRequire(previewFragments(unicode, unicode.removedRanges).map { Array($0.utf16) } == ["👨‍👩‍👧‍👦", "e\u{301}", "!"].map { Array($0.utf16) }, "Unicode deletion must preserve complete graphemes")
    let options = TextDiffOptions(ignoreWhitespace: true, ignoreCase: true)
    let ignored = try verifyPreview("Hello \t WORLD\n", "helloWORLD\n", options: options, expected: "helloWORLD\n")
    try previewRequire(ignored.removedRanges.isEmpty && ignored.addedRanges.isEmpty, "Ignored differences should not reappear")
    try verifyPreview("const x = 1;\r\n", "CONST x=2;\r\n", options: options, expected: "CONST x=12;\r\n")
    let fixtures = ["", "a", "\n", "\r\n", "a\n", "a\r\n", "a\nb\nc", "a\na\nb\na\n", "👩🏽‍💻\n中\r\n文", "é", "e\u{301}", "a\u{2028}b\u{2029}"]
    for left in fixtures { for right in fixtures { try verifyPreview(left, right) } }
    let largeLeft = "keep\r\n" + String(repeating: "left\r\n", count: 2_200) + "tail\r\n"
    let largeRight = "keep\r\n" + String(repeating: "right\r\n", count: 2_200) + "tail\r\n"
    try previewRequire(TextDiffEngine.compare(largeLeft, largeRight).simplified, "Large fixture must exercise simplified diff")
    try verifyPreview(largeLeft, largeRight)
    print("✓ Deletion preview: inline edits, lines, Unicode, ignored changes, EOF, offset/line/hunk mappings, exact right recovery and fallback")
}
