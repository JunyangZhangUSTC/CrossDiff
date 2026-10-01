import Foundation
import CrossDiffCore

func runSearchPersistenceChecks() throws {
    let text = "前👩🏽‍💻 Cafe\u{301}\r\nCAFÉ café 🙂🙂"
    let source = text as NSString
    let emoji = TextSearch.matches(in: text, query: "👩🏽‍💻")
    precondition(emoji == [NSRange(location: 1, length: "👩🏽‍💻".utf16.count)])
    let decomposed = TextSearch.matches(in: text, query: "Cafe\u{301}")
    precondition(decomposed.count == 1 && source.substring(with: decomposed[0]) == "Cafe\u{301}")
    let exact = TextSearch.matches(in: text, query: "café")
    precondition(exact.count == 1 && source.substring(with: exact[0]) == "café")
    let folded = TextSearch.matches(in: text, query: "café", ignoreCase: true)
    precondition(folded.count == 2 && folded.allSatisfy { source.substring(with: $0).utf16.count == 4 })
    precondition(TextSearch.matches(in: "aaaa", query: "aa") == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    precondition(TextSearch.matches(in: text, query: "").isEmpty)
    precondition(TextSearch.matches(in: "aaaaaa", query: "a", limit: 2) == [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)])
    precondition(TextSearch.matches(in: "ß SS SS", query: "ss", ignoreCase: true, limit: 1) == [NSRange(location: 0, length: 1)])
    precondition(TextSearch.matches(in: "aaaa", query: "a", limit: 0).isEmpty)
    precondition(TextSearch.matches(in: text, query: "不存在").isEmpty)
    let newline = TextSearch.matches(in: text, query: "\r\n")
    precondition(newline.count == 1 && source.substring(with: newline[0]) == "\r\n")
    precondition(TextSearch.matches(in: "🙂🙂", query: "🙂") == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    precondition(TextSearch.matches(in: "é e\u{301}", query: "É", ignoreCase: true) == [NSRange(location: 0, length: 1)])
    precondition(TextSearch.matches(in: "é e\u{301}", query: "E\u{301}", ignoreCase: true) == [NSRange(location: 2, length: 2)])
    precondition(TextSearch.matches(in: "ß SS ﬃ FFI", query: "ss", ignoreCase: true) == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 2)])
    precondition(TextSearch.matches(in: "ß", query: "s", ignoreCase: true).isEmpty)
    precondition(TextSearch.matches(in: "ﬃ FFI", query: "ﬃ", ignoreCase: true) == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 3)])
    precondition(TextSearch.matches(in: "𐐀𐐨", query: "𐐨", ignoreCase: true) == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    do {
        _ = try TextSearch.matches(in: text, query: "café", cancellationCheck: { throw CancellationError() })
        preconditionFailure("Canceled search returned matches")
    } catch is CancellationError {}
    var searchCheckpoints = 0
    do {
        _ = try TextSearch.matches(in: String(repeating: "a", count: 1_000_000), query: "z", cancellationCheck: {
            searchCheckpoints += 1
            if searchCheckpoints == 3 { throw CancellationError() }
        })
        preconditionFailure("A no-match search did not respond to cancellation during scanning")
    } catch is CancellationError {}
    precondition(searchCheckpoints == 3)

    let before = (0..<4_000).map { "行 \($0) 👩🏽‍💻\r\n" }.joined()
    let after = before + "末行\r\n"
    var checkpoints = 0
    do {
        _ = try TextDiffEngine.compareCancellable(before, after) {
            checkpoints += 1
            if checkpoints == 100 { throw CancellationError() }
        }
        preconditionFailure("Canceled comparison returned a publishable result")
    } catch is CancellationError {}
    precondition(checkpoints == 100)
    let expected = TextDiffEngine.compare(before, after)
    let actual = try TextDiffEngine.compareCancellable(before, after)
    precondition(expected.hunks.map(\.leftRange) == actual.hunks.map(\.leftRange))
    precondition(expected.hunks.map(\.rightRange) == actual.hunks.map(\.rightRange))
    precondition(expected.rows.count == actual.rows.count && expected.simplified == actual.simplified)

    let directory = checkTemporaryDirectory.appendingPathComponent("CrossDiff-ordered-session-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("sessions.json")
    let writer = SessionPersistence(url: file)
    for index in 0..<25 {
        let snapshot = StoredComparison(kind: "text", left: .init(text: "编辑 \(index)"), right: .init())
        writer.save([snapshot]) { result in
            precondition(!Thread.isMainThread, "Session encoding/write must leave the main thread")
            if case .failure(let error) = result { preconditionFailure(error.localizedDescription) }
        }
    }
    let latest = StoredComparison(kind: "text", left: .init(text: "退出前最后编辑 👩🏽‍💻\r\n", savedText: "原文"), right: .init())
    try writer.saveAndWait([latest])
    let restored = try SessionFile.load(from: file)
    precondition(restored.count == 1 && restored[0].id == latest.id)
    precondition(restored[0].left.text.utf16.elementsEqual(latest.left.text.utf16))
    writer.save([latest]) { result in
        if case .failure(let error) = result { preconditionFailure(error.localizedDescription) }
    }
    try writer.clearAndWait()
    precondition(!FileManager.default.fileExists(atPath: file.path), "Older save resurrected cleared history")
    let fresh = StoredComparison(kind: "text", left: .init(text: "清除后的新会话"), right: .init())
    try writer.saveAndWait([fresh])
    let afterClear = try SessionFile.load(from: file)
    precondition(afterClear.count == 1 && afterClear[0].id == fresh.id)
    print("✓ Search and persistence: literal UTF-16 matches, case folding, cooperative cancellation, ordered background saves, exit flush and clear ordering")
}
