import Foundation
import JavaScriptCore

@main
struct PDFAlgorithmChecks {
    static func main() throws {
        let path = CommandLine.arguments[1]
        let script = try String(contentsOfFile: path, encoding: .utf8)
        let context = JSContext()!
        var scriptError: String?
        context.exceptionHandler = { _, exception in scriptError = exception?.toString() }
        context.evaluateScript(script)
        func page(_ index: Int, _ text: String, _ fingerprint: String) -> [String: Any] {
            ["index": index, "text": text, "width": 612, "height": 792, "fingerprint": fingerprint]
        }
        func compare(_ left: [[String: Any]], _ right: [[String: Any]], truncated: Bool = false) throws -> [[String: Any]] {
            let request: [String: Any] = ["protocolVersion": 1, "runID": "fixture", "mode": "pairwise", "options": [:],
                "inputs": [["id": "left", "role": "left", "name": "Left.pdf", "content": ["pages": left, "truncated": truncated]],
                           ["id": "right", "role": "right", "name": "Right.pdf", "content": ["pages": right, "truncated": false]]]]
            scriptError = nil
            guard let result = context.objectForKeyedSubscript("compare")?.call(withArguments: [request])?.toDictionary() as? [String: Any],
                  scriptError == nil,
                  result["runID"] as? String == "fixture",
                  result["schema"] as? String == "crossdiff.document-pages/1",
                  let payload = result["payload"] as? [String: Any], let pairs = payload["pairs"] as? [[String: Any]] else {
                throw NSError(domain: "PDFChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: scriptError ?? "Invalid result"])
            }
            return pairs
        }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            count += 1
        }
        let insertion = try compare([page(0, "Introduction", "a"), page(1, "Conclusion", "b")],
                                    [page(0, "Introduction", "a"), page(1, "New results", "c"), page(2, "Conclusion", "b")])
        check(insertion.count == 3, "An inserted page produces one additional aligned row")
        check(insertion[1]["kind"] as? String == "added", "Inserted middle page is an addition")
        check(insertion[2]["left"] as? Int == 1 && insertion[2]["right"] as? Int == 2 && insertion[2]["kind"] as? String == "same", "Later original pages remain aligned")
        let deletion = try compare([page(0, "Introduction", "a"), page(1, "Removed appendix", "c"), page(2, "Conclusion", "b")],
                                   [page(0, "Introduction", "a"), page(1, "Conclusion", "b")])
        check(deletion.count == 3 && deletion[1]["kind"] as? String == "removed", "Deleted middle page stays visible")
        check(deletion[2]["left"] as? Int == 2 && deletion[2]["right"] as? Int == 1, "Deletion does not shift later matches")
        let textChange = try compare([page(0, "The value is 10.", "old")], [page(0, "The value is 20.", "new")])
        check(textChange[0]["kind"] as? String == "changed", "Changed text is reported")
        let imageChange = try compare([page(0, "Figure caption", "red")], [page(0, "Figure caption", "blue")])
        check(imageChange[0]["kind"] as? String == "changed", "Identical extracted text cannot hide a visual change")
        let scan = try compare([page(0, "", "scan")], [page(0, "", "scan")])
        check(scan[0]["kind"] as? String == "unknown", "No-text pages are never declared fully identical")
        let scanChange = try compare([page(0, "", "scan1")], [page(0, "", "scan2")])
        check(scanChange[0]["kind"] as? String == "changed", "A changed scanned page remains visible without OCR")
        let scanInsertion = try compare([page(0, "", "scan1"), page(1, "", "scan2")],
                                       [page(0, "", "scan1"), page(1, "", "new"), page(2, "", "scan2")])
        check(scanInsertion[1]["kind"] as? String == "added" && scanInsertion[2]["left"] as? Int == 1,
              "Preview anchors align inserted scanned pages")
        let chinese = try compare([page(0, "实验结果：剂量为十毫克。", "c1")], [page(0, "实验结果：剂量为二十毫克。", "c2")])
        check(chinese[0]["kind"] as? String == "changed", "Chinese text changes remain paired")
        let duplicates = try compare([page(0, "Repeated page", "a"), page(1, "Repeated page", "a")],
                                    [page(0, "Repeated page", "a"), page(1, "Repeated page", "a"), page(2, "Repeated page", "a")])
        check(duplicates.filter { $0["kind"] as? String == "added" }.count == 1, "Repeated pages preserve input cardinality")
        var clipped = page(0, "visible prefix", "same"); clipped["textTruncated"] = true
        let clippedResult = try compare([clipped], [page(0, "visible prefix", "same")], truncated: true)
        check(clippedResult[0]["kind"] as? String == "unknown", "Equal truncated prefixes are not full matches")
        let moved = try compare([page(0, "First page", "a"), page(1, "Second page", "b"), page(2, "Third page", "c")],
                               [page(0, "Third page", "c"), page(1, "First page", "a"), page(2, "Second page", "b")])
        check(moved.contains { $0["kind"] as? String == "added" } && moved.contains { $0["kind"] as? String == "removed" },
              "Moved pages remain visible as an insertion and deletion, not silently ignored")
        let unsupported: [String: Any] = ["protocolVersion": 1, "runID": "fixture", "mode": "multiSubject", "inputs": []]
        scriptError = nil
        _ = context.objectForKeyedSubscript("compare")?.call(withArguments: [unsupported])
        check(scriptError != nil, "Unsupported multi-subject requests fail instead of dropping inputs")
        print("PDF algorithm checks: \(count) passed")
    }
}
