import Foundation
import CrossDiffCore

private final class TextCheckSuite {
    func testEveryUnicodeAndNewlineFixturePairCanBeMergedBothDirections() {
        let samples = ["", "\n", "\r\n", "a", "a\n", "a\r\n", "a\nb\nc", "a\na\nb\na\n",
                       "b\na\na\nb", "👩🏽‍💻\n中\r\n文", "é", "e\u{301}", "\r\na\r\n\r\n", "a\u{2028}b\u{2029}"]
        for left in samples {
            for right in samples {
                let result = TextDiffEngine.compare(left, right)
                var forward = right, backward = left
                for hunk in result.hunks.reversed() {
                    forward = TextDiffEngine.applying(hunk, fromLeft: true, left: left, right: forward)
                    backward = TextDiffEngine.applying(hunk, fromLeft: false, left: backward, right: right)
                }
                textCheckEqual(Array(forward.utf16), Array(left.utf16))
                textCheckEqual(Array(backward.utf16), Array(right.utf16))
            }
        }
    }

    func testVeryLongSingleLineUsesBoundedGraphemeSafeHighlights() {
        let prefix = String(repeating: "x", count: 110_000)
        let left = prefix + "👨‍👩‍👧‍👦."
        let right = prefix + "👩🏽‍💻."
        let result = TextDiffEngine.compare(left, right)
        textCheckTrue(result.simplified)
        textCheckEqual(result.rows[0].leftHighlights, [NSRange(location: 110_000, length: 11)])
        textCheckEqual(result.rows[0].rightHighlights, [NSRange(location: 110_000, length: 7)])
    }

    func testEmptyTextsAndFinalNewlinesRemainExactThroughMerge() {
        let cases: [(String, String)] = [
            ("", ""), ("", "\n"), ("\r\n", ""), ("a", "a\n"),
            ("a\r\nb\r\n", "a\nb\n"), ("a\r\nb", "a\r\nB\r\n"),
            ("repeat\nrepeat\nx\nrepeat\n", "repeat\nx\nrepeat\nrepeat\n"),
            ("a\nb\nc", "a\ninsert\nb\nc"), ("first", "")
        ]
        for (left, right) in cases {
            let result = TextDiffEngine.compare(left, right)
            var mergedRight = right
            var mergedLeft = left
            for hunk in result.hunks.reversed() {
                mergedRight = TextDiffEngine.applying(hunk, fromLeft: true, left: left, right: mergedRight)
                mergedLeft = TextDiffEngine.applying(hunk, fromLeft: false, left: mergedLeft, right: right)
            }
            textCheckEqual(Array(mergedRight.utf16), Array(left.utf16))
            textCheckEqual(Array(mergedLeft.utf16), Array(right.utf16))
        }
        textCheckTrue(TextDiffEngine.compare("", "").rows.isEmpty)
        textCheckTrue(TextDiffEngine.compare("", "").hunks.isEmpty)
    }

    func testExpensiveComparisonsReportSimplificationAndStillMergeLosslessly() throws {
        let left = "keep\r\n" + String(repeating: "left\r\n", count: 2_200) + "tail\r\n"
        let right = "keep\r\n" + String(repeating: "right\r\n", count: 2_200) + "tail\r\n"
        let result = TextDiffEngine.compare(left, right)
        textCheckTrue(result.simplified)
        textCheckEqual(result.rows.first?.kind, .equal)
        textCheckEqual(result.rows.last?.kind, .equal)
        textCheckEqual(result.hunks.count, 1)
        let hunk = try textCheckUnwrap(result.hunks.first)
        textCheckEqual(TextDiffEngine.applying(hunk, fromLeft: true, left: left, right: right), left)
        textCheckEqual(TextDiffEngine.applying(hunk, fromLeft: false, left: left, right: right), right)

        let longLeft = String(repeating: "a", count: 2_000)
        let longRight = String(repeating: "b", count: 2_000)
        let longResult = TextDiffEngine.compare(longLeft, longRight)
        textCheckTrue(longResult.simplified)
        textCheckEqual(longResult.rows[0].leftHighlights, [NSRange(location: 0, length: 2_000)])
    }

    func testIgnoreRulesHideOnlyRequestedDifferencesAndDoNotRewriteSources() throws {
        let options = TextDiffOptions(ignoreWhitespace: true, ignoreCase: true)
        textCheckTrue(TextDiffEngine.compare("Hello \t WORLD\n", "helloWORLD\n", options: options).hunks.isEmpty)
        let left = "const x = 1;\r\n"
        let right = "CONST x=2;\r\n"
        let result = TextDiffEngine.compare(left, right, options: options)
        textCheckEqual(result.rows[0].leftHighlights, [NSRange(location: 10, length: 1)])
        textCheckEqual(result.rows[0].rightHighlights, [NSRange(location: 8, length: 1)])
        let hunk = try textCheckUnwrap(result.hunks.first)
        textCheckEqual(TextDiffEngine.applying(hunk, fromLeft: true, left: left, right: right), left)
        textCheckFalse(TextDiffEngine.compare("a\n", "a", options: options).hunks.isEmpty)
    }

    func testSeparatedUnicodeEditsHighlightWholeGraphemesInOriginalUTF16Coordinates() {
        let left = "标题\r\nA👨‍👩‍👧‍👦B e\u{301} C!"
        let right = "标题\r\nA👩🏽‍💻B é C?"
        let result = TextDiffEngine.compare(left, right)
        let row = result.rows[1]
        textCheckEqual(row.leftHighlights.map { (left as NSString).substring(with: $0) },
                       ["👨‍👩‍👧‍👦", "e\u{301}", "!"])
        textCheckEqual(row.rightHighlights.map { (right as NSString).substring(with: $0) },
                       ["👩🏽‍💻", "é", "?"])
        textCheckEqual(row.leftHighlights.first?.location, 5)
        textCheckEqual(row.leftHighlights.first?.length, 11)
    }

    func testInsertedAndRemovedLinesHaveIndependentMergeBlocks() throws {
        let left = "top\nremove\nanchor\ntail\n"
        let right = "top\nanchor\ninsert\ntail\n"
        let result = TextDiffEngine.compare(left, right)
        textCheckEqual(result.rows.map(\.kind), [.equal, .removed, .equal, .added, .equal])
        textCheckEqual(result.rows.map(\.leftLine), [0, 1, 2, nil, 3])
        textCheckEqual(result.rows.map(\.rightLine), [0, nil, 1, 2, 3])
        textCheckEqual(result.hunks.count, 2)
        let removed = try textCheckUnwrap(result.hunks.first)
        let inserted = try textCheckUnwrap(result.hunks.last)
        textCheckEqual(TextDiffEngine.applying(removed, fromLeft: true, left: left, right: right),
                       "top\nremove\nanchor\ninsert\ntail\n")
        textCheckEqual(TextDiffEngine.applying(inserted, fromLeft: false, left: left, right: right),
                       "top\nremove\nanchor\ninsert\ntail\n")
    }

    func testPastedChineseTextHighlightsTheChangedNumberAndMergesEitherWay() throws {
        let left = "实验准确率为92%，很好。"
        let right = "实验准确率为95%，很好。"
        let result = TextDiffEngine.compare(left, right)

        textCheckEqual(result.rows.count, 1)
        textCheckEqual(result.rows.first?.kind, .changed)
        textCheckEqual(result.rows.first?.leftHighlights, [NSRange(location: 7, length: 1)])
        textCheckEqual(result.rows.first?.rightHighlights, [NSRange(location: 7, length: 1)])
        let hunk = try textCheckUnwrap(result.hunks.first)
        textCheckEqual(TextDiffEngine.applying(hunk, fromLeft: true, left: left, right: right), left)
        textCheckEqual(TextDiffEngine.applying(hunk, fromLeft: false, left: left, right: right), right)
        textCheckFalse(result.simplified)
    }
}

private func textCheckTrue(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(condition(), "Text check expected true", file: file, line: line)
}

private func textCheckFalse(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!condition(), "Text check expected false", file: file, line: line)
}

private func textCheckEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: @autoclosure () -> T,
                                         file: StaticString = #file, line: UInt = #line) {
    let a = actual(), b = expected()
    precondition(a == b, "Text check expected \(b); got \(a)", file: file, line: line)
}

private enum TextCheckError: Error { case missingValue }

private func textCheckUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw TextCheckError.missingValue }
    return value
}

func runTextChecks() throws {
    let suite = TextCheckSuite()
    suite.testEveryUnicodeAndNewlineFixturePairCanBeMergedBothDirections()
    suite.testVeryLongSingleLineUsesBoundedGraphemeSafeHighlights()
    suite.testEmptyTextsAndFinalNewlinesRemainExactThroughMerge()
    try suite.testExpensiveComparisonsReportSimplificationAndStillMergeLosslessly()
    try suite.testIgnoreRulesHideOnlyRequestedDifferencesAndDoNotRewriteSources()
    suite.testSeparatedUnicodeEditsHighlightWholeGraphemesInOriginalUTF16Coordinates()
    try suite.testInsertedAndRemovedLinesHaveIndependentMergeBlocks()
    try suite.testPastedChineseTextHighlightsTheChangedNumberAndMergesEitherWay()
    print("Text checks passed: 8 behaviors, including 196 Unicode/newline fixture pairs.")
}
