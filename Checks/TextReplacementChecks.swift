import Foundation
import CrossDiffCore

func runTextReplacementChecks() throws {
    let original = "前👩🏽‍💻 Cafe\u{301}\r\nCAFÉ café 🙂🙂\r尾"
    let replaced = try TextReplacement.replacingAll(in: original, query: "café", replacement: "茶🍵", ignoreCase: true)
    precondition(replaced.count == 2)
    precondition(replaced.text.utf16.elementsEqual("前👩🏽‍💻 Cafe\u{301}\r\n茶🍵 茶🍵 🙂🙂\r尾".utf16), "Replacement must retain decomposed Unicode and CRLF/CR source units")
    let emoji = try TextReplacement.replacingAll(in: original, query: "🙂", replacement: "")
    precondition(emoji.count == 2 && emoji.text.utf16.elementsEqual("前👩🏽‍💻 Cafe\u{301}\r\nCAFÉ café \r尾".utf16))
    let multiline = try TextReplacement.replacingAll(in: "a\r\nb\r\na\r\nb", query: "a\r\nb", replacement: "中文\n")
    precondition(multiline.count == 2 && multiline.text.utf16.elementsEqual("中文\n\r\n中文\n".utf16))

    let folded = try TextReplacement.replacingAll(in: "ß SS ﬃ FFI", query: "ss", replacement: "x", ignoreCase: true)
    precondition(folded.count == 2 && folded.text == "x x ﬃ FFI")
    let boundary = try TextReplacement.replacingAll(in: "ß", query: "s", replacement: "x", ignoreCase: true)
    precondition(boundary.count == 0 && boundary.text == "ß")
    let literal = try TextReplacement.replacingAll(in: "a.*a.*", query: ".*", replacement: "$1\\n")
    precondition(literal.count == 2 && literal.text == "a$1\\na$1\\n", "Find and replacement must both be literal, never regex syntax")
    let overlap = try TextReplacement.replacingAll(in: "aaaaa", query: "aa", replacement: "b")
    precondition(overlap.count == 2 && overlap.text == "bba")
    let recursive = try TextReplacement.replacingAll(in: "aaa", query: "a", replacement: "aa")
    precondition(recursive.count == 3 && recursive.text == "aaaaaa", "Replacement only scans the original source once")
    let empty = try TextReplacement.replacingAll(in: original, query: "", replacement: "x")
    precondition(empty.count == 0 && empty.text.utf16.elementsEqual(original.utf16))

    let many = String(repeating: "a ", count: 24_321)
    let full = try TextReplacement.replacingAll(in: many, query: "a", replacement: "b")
    precondition(full.count == 24_321 && full.text == String(repeating: "b ", count: 24_321), "Replace All must not use the 10,000 displayed-match cap")
    var streaming: [NSRange] = []
    try TextSearch.forEachMatch(in: original, query: "café", ignoreCase: true) { streaming.append($0) }
    precondition(streaming == TextSearch.matches(in: original, query: "café", ignoreCase: true))

    var checkpoints = 0
    do {
        _ = try TextReplacement.replacingAll(in: many, query: "a", replacement: "b", cancellationCheck: {
            checkpoints += 1
            if checkpoints == 3 { throw CancellationError() }
        })
        preconditionFailure("A canceled Replace All returned a result")
    } catch is CancellationError {}
    precondition(checkpoints == 3)
    do {
        _ = try TextReplacement.replacingAll(in: "abc", query: "a", replacement: "123456", maximumLength: 5)
        preconditionFailure("Unbounded replacement expansion was accepted")
    } catch TextReplacementError.resultTooLarge {}
    do {
        _ = try TextReplacement.replacingAll(in: "abcdef", query: "a", replacement: "123", maximumLength: 7)
        preconditionFailure("Final unchanged tail exceeded the result limit")
    } catch TextReplacementError.resultTooLarge {}
    let exactLimit = try TextReplacement.replacingAll(in: "abc", query: "a", replacement: "123", maximumLength: 5)
    precondition(exactLimit.text == "123bc")
    print("✓ Replacement: exact Unicode/newline preservation, literal non-overlapping ranges, full counts beyond display cap, case-fold mapping, bounded expansion and cancellation")
}
