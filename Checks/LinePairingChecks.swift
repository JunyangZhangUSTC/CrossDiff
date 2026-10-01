import Foundation
import CrossDiffCore

func runLinePairingChecks() throws {
    let left = "header\nvar legacyMode = true\nvar fontSize = 14\nfooter\n"
    let right = "header\nvar fontSize = 15\nfooter\n"
    let result = TextDiffEngine.compare(left, right)
    precondition(result.rows.map(\.kind) == [.equal, .removed, .changed, .equal])
    precondition(result.rows.map(\.leftLine) == [0, 1, 2, 3])
    precondition(result.rows.map(\.rightLine) == [0, nil, 1, 2])
    precondition(result.rows[2].leftHighlights.map { (left as NSString).substring(with: $0) } == ["4"])
    precondition(result.rows[2].rightHighlights.map { (right as NSString).substring(with: $0) } == ["5"])
    precondition(result.hunks.count == 1)
    precondition(TextDiffEngine.applying(result.hunks[0], fromLeft: true, left: left, right: right) == left)
    precondition(TextDiffEngine.applying(result.hunks[0], fromLeft: false, left: left, right: right) == right)
    let reverse = TextDiffEngine.compare(right, left)
    precondition(reverse.rows.map(\.kind) == [.equal, .added, .changed, .equal])
    precondition(reverse.rows.map(\.leftLine) == [0, nil, 1, 2])
    precondition(reverse.rows.map(\.rightLine) == [0, 1, 2, 3])
    let preview = DeletionPreview.make(left: left, right: right, result: result)
    precondition(preview.text == "header\nvar legacyMode = true\nvar fontSize = 145\nfooter\n")
    precondition(preview.lines.map(\.rightLine) == [0, nil, 1, 2])

    let shiftedLeft = "removeLegacyFlag(true)\nfontSize = 14\nrowHeight = 20\n"
    let shiftedRight = "fontSize = 15\nrowHeight = 21\naddNewRenderer(false)\n"
    let shifted = TextDiffEngine.compare(shiftedLeft, shiftedRight)
    precondition(shifted.rows.map(\.kind) == [.removed, .changed, .changed, .added])
    precondition(shifted.rows.map(\.leftLine) == [0, 1, 2, nil])
    precondition(shifted.rows.map(\.rightLine) == [nil, 0, 1, 2])
    precondition(TextDiffEngine.compare("a\n", "z\n").rows.map(\.kind) == [.changed])

    let unicodeLeft = "弃用 👨‍👩‍👧‍👦 e\u{301}\r\n字号 👩🏽‍💻 = 14\r\n"
    let unicodeRight = "字号 👩🏽‍💻 = 15\r\n"
    let unicode = TextDiffEngine.compare(unicodeLeft, unicodeRight)
    precondition(unicode.rows.map(\.kind) == [.removed, .changed])
    precondition(unicode.rows[1].leftHighlights.map { (unicodeLeft as NSString).substring(with: $0) } == ["4"])
    let unicodePreview = DeletionPreview.make(left: unicodeLeft, right: unicodeRight, result: unicode)
    let recovered = NSMutableString(string: unicodePreview.text)
    for range in unicodePreview.removedRanges.reversed() { recovered.deleteCharacters(in: range) }
    precondition((recovered as String).utf16.elementsEqual(unicodeRight.utf16))
    precondition(TextDiffEngine.applying(unicode.hunks[0], fromLeft: true, left: unicodeLeft, right: unicodeRight).utf16.elementsEqual(unicodeLeft.utf16))
    let ignored = TextDiffEngine.compare("legacy = true\nFONT SIZE = 14\n", "fontSize=15\n",
                                         options: .init(ignoreWhitespace: true, ignoreCase: true))
    precondition(ignored.rows.map(\.kind) == [.removed, .changed])

    let largeLeft = (0..<300).map { "old \($0)\n" }.joined()
    let largeRight = (0..<300).map { "new \($0)\n" }.joined()
    let bounded = TextDiffEngine.compare(largeLeft, largeRight)
    precondition(bounded.simplified)
    precondition(bounded.rows.count == 300)
    precondition(TextDiffEngine.applying(bounded.hunks[0], fromLeft: true, left: largeLeft, right: largeRight) == largeLeft)
    precondition(TextDiffEngine.applying(bounded.hunks[0], fromLeft: false, left: largeLeft, right: largeRight) == largeRight)
    print("✓ Line pairing: deleted/inserted neighbors, ordered related replacements, precise inline marks, Unicode preview recovery and bounded fallback")
}
