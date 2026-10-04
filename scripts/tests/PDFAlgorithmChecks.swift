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
        var lastAlignment: [String: Any] = [:]
        var lastDiagnostics: [[String: String]] = []
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
            lastAlignment = payload["alignment"] as? [String: Any] ?? [:]
            lastDiagnostics = result["diagnostics"] as? [[String: String]] ?? []
            return pairs
        }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            count += 1
        }
        let unrelated = try compare([page(0, "AAAA", "a")],
                                    [page(0, "BBBB", "b"), page(1, "CCCC", "c"), page(2, "DDDD", "d")])
        check(unrelated[0]["left"] as? Int == 0 && unrelated[0]["right"] as? Int == 0,
              "Unrelated documents never pair left page 1 with right page 3")
        check(lastAlignment["strategy"] as? String == "pageNumber" && lastAlignment["reason"] as? String == "insufficientEvidence",
              "Unsupported alignment explicitly falls back to page numbers")
        check(lastDiagnostics.contains { $0["en"]?.contains("page number") == true }, "Fallback is explained to the user")
        let headings = try compare([page(0, "Introduction", "l0"), page(1, "Conclusion", "l1")],
                                   [page(0, "Contents", "r0"), page(1, "Introduction", "r1"), page(2, "Conclusion", "r2")])
        check(headings[0]["right"] as? Int == 0 && headings[1]["right"] as? Int == 1,
              "Generic short titles do not establish shifted page correspondence")
        check(lastAlignment["strategy"] as? String == "pageNumber", "Short-title matches remain positional")
        let insertion = try compare([page(0, "Introduction", "a"), page(1, "Conclusion", "b")],
                                    [page(0, "Introduction", "a"), page(1, "New results", "c"), page(2, "Conclusion", "b")])
        check(insertion.count == 3, "An inserted page produces one additional aligned row")
        check(insertion[1]["kind"] as? String == "added", "Inserted middle page is an addition")
        check(insertion[2]["left"] as? Int == 1 && insertion[2]["right"] as? Int == 2 && insertion[2]["kind"] as? String == "same", "Later original pages remain aligned")
        check(lastAlignment["strategy"] as? String == "smart" && lastAlignment["reliablePairs"] as? Int == 2,
              "Consistent unique preview anchors identify inserted pages")
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
        let blankShift = try compare([page(0, "", "blank")],
                                     [page(0, "First chapter", "first"), page(1, "Second chapter", "second"), page(2, "", "blank")])
        check(blankShift[0]["left"] as? Int == 0 && blankShift[0]["right"] as? Int == 0 && lastAlignment["reason"] as? String == "insufficientEvidence",
              "A lone blank preview cannot establish a displaced single-page match")
        let briefCoverShift = try compare([page(0, "Introduction", "cover")],
                                          [page(0, "Contents", "contents"), page(1, "Introduction", "cover")])
        check(briefCoverShift[0]["right"] as? Int == 0 && lastAlignment["strategy"] as? String == "pageNumber",
              "A single low-information common cover needs corroboration before shifting")
        let chinese = try compare([page(0, "实验结果：剂量为十毫克。", "c1")], [page(0, "实验结果：剂量为二十毫克。", "c2")])
        check(chinese[0]["kind"] as? String == "changed", "Chinese text changes remain paired")
        let duplicates = try compare([page(0, "Repeated page", "a"), page(1, "Repeated page", "a")],
                                    [page(0, "Repeated page", "a"), page(1, "Repeated page", "a"), page(2, "Repeated page", "a")])
        check(duplicates.filter { $0["kind"] as? String == "added" }.count == 1, "Repeated pages preserve input cardinality")
        check(duplicates[0]["right"] as? Int == 0 && duplicates[1]["right"] as? Int == 1,
              "Duplicate-page ambiguity cannot shift every original page")
        check(lastAlignment["reason"] as? String == "ambiguousEvidence", "Repeated pages report ambiguous evidence")

        let repeatedHeader = String(repeating: "CrossDiff annual publication terms and conditions. ", count: 50)
        let differingBodies = try compare([page(0, repeatedHeader + String(repeating: "aaaa", count: 800), "l-body")],
                                         [page(0, "Contents", "contents"), page(1, repeatedHeader + String(repeating: "zzzz", count: 800), "r-body")])
        check(differingBodies[0]["right"] as? Int == 0, "A shared first 2048 characters cannot conceal unrelated page bodies")
        let common = "This is a shared publication license whose exact wording appears in otherwise unrelated documents."
        let isolated = try compare([page(0, common, "common"), page(1, "apples", "l1"), page(2, "oranges", "l2"), page(3, "pears", "l3")],
                                  [page(0, "cars", "r1"), page(1, common, "common"), page(2, "planes", "r2"), page(3, "boats", "r3")])
        check(isolated[0]["right"] as? Int == 0 && lastAlignment["strategy"] as? String == "pageNumber",
              "One shared page cannot drag unrelated multi-page documents out of position")
        let informative1 = "Results: the instrument measured ten independent samples, with stable confidence and calibrated equipment."
        let informative2 = "Discussion: the observations support reproducible evaluation across different datasets and experimental settings."
        let extractedSinglePage = try compare([page(0, informative1, "extracted")],
                                             [page(0, "Cover", "cover"), page(1, informative1, "extracted")])
        check(extractedSinglePage[1]["left"] as? Int == 0 && extractedSinglePage[1]["right"] as? Int == 1 && lastAlignment["strategy"] as? String == "smart",
              "A single extracted page with informative content can still match its original location")
        let textInsertion = try compare([page(0, informative1, "a-old"), page(1, informative2, "b-old")],
                                        [page(0, informative1.replacingOccurrences(of: "ten", with: "twelve"), "a-new"), page(1, "New figure", "inserted"), page(2, informative2, "b-new")])
        check(textInsertion[1]["kind"] as? String == "added" && textInsertion[2]["left"] as? Int == 1 && textInsertion[2]["right"] as? Int == 2,
              "Informative edited text supports insertion alignment when preview fingerprints changed")
        let chinese1 = "实验方法：研究人员在稳定环境中测量了多组不同样品，并使用经过校准的设备记录每一次测量数据，以确保结果可靠且能够重复。"
        let chinese2 = "结果讨论：各个实验数据集呈现一致趋势，但仍需要结合更多条件开展后续研究，以评估该方法在不同应用场景中的局限性。"
        let chineseInsertion = try compare([page(0, chinese1, "cn1"), page(1, chinese2, "cn2")],
                                           [page(0, chinese1.replacingOccurrences(of: "稳定", with: "低温"), "cn1-new"), page(1, "新增图片", "cn-inserted"), page(2, chinese2, "cn2-new")])
        check(chineseInsertion[1]["kind"] as? String == "added" && chineseInsertion[2]["right"] as? Int == 2,
              "Chinese pages use Unicode content evidence without whitespace tokenization")
        var clipped = page(0, "visible prefix", "same"); clipped["textTruncated"] = true
        let clippedResult = try compare([clipped], [page(0, "visible prefix", "same")], truncated: true)
        check(clippedResult[0]["kind"] as? String == "unknown", "Equal truncated prefixes are not full matches")
        var truncatedText = page(0, informative1, "truncated-old"); truncatedText["textTruncated"] = true
        let clippedAlignment = try compare([truncatedText], [page(0, "Cover", "cover"), page(1, informative1, "truncated-new")])
        check(clippedAlignment[0]["right"] as? Int == 0 && lastAlignment["strategy"] as? String == "pageNumber",
              "Truncated text prefixes cannot establish a confident displaced match")
        let moved = try compare([page(0, "First page", "a"), page(1, "Second page", "b"), page(2, "Third page", "c")],
                               [page(0, "Third page", "c"), page(1, "First page", "a"), page(2, "Second page", "b")])
        check(moved.contains { $0["kind"] as? String == "added" } && moved.contains { $0["kind"] as? String == "removed" },
              "Moved pages remain visible as an insertion and deletion, not silently ignored")
        let crossed = try compare([page(0, "First page", "a"), page(1, "Second page", "b")],
                                  [page(0, "Second page", "b"), page(1, "First page", "a")])
        check(crossed[0]["right"] as? Int == 0 && lastAlignment["reason"] as? String == "ambiguousEvidence",
              "Equally supported conflicting page orders fall back instead of choosing a displaced chain")
        let repeatedText = try compare([page(0, informative1, "repeat-l1"), page(1, informative1, "repeat-l2")],
                                       [page(0, informative1, "repeat-r1"), page(1, informative1, "repeat-r2"), page(2, informative1, "repeat-r3")])
        check(repeatedText[0]["right"] as? Int == 0 && lastAlignment["reason"] as? String == "ambiguousEvidence",
              "Repeated informative text cannot impersonate a unique page anchor")
        let actualResearchFixture = try compare(
            [page(0, "CrossDiff Research\nIntroduction: comparing scientific results.", "intro"), page(1, "Results\nThe measured value is 10. Confidence is high.", "results-old")],
            [page(0, "CrossDiff Research\nIntroduction: comparing scientific results.", "intro"), page(1, "", "scan"), page(2, "Results\nThe measured value is 20. Confidence is high.", "results-new")])
        check(actualResearchFixture[1]["kind"] as? String == "added" && actualResearchFixture[2]["left"] as? Int == 1 && actualResearchFixture[2]["right"] as? Int == 2,
              "Real PDF fixture descriptors retain their changed results page after an inserted scan")
        for leftCount in 1...8 {
            for rightCount in 1...8 {
                let leftPages = (0..<leftCount).map { page($0, "Left \($0)", "l-\($0)") }
                let rightPages = (0..<rightCount).map { page($0, "Right \($0)", "r-\($0)") }
                let pairs = try compare(leftPages, rightPages)
                check(pairs.compactMap { $0["left"] as? Int } == Array(0..<leftCount) && pairs.compactMap { $0["right"] as? Int } == Array(0..<rightCount),
                      "Unrelated documents preserve every original page exactly once in order")
                check(pairs.prefix(min(leftCount, rightCount)).enumerated().allSatisfy { offset, pair in pair["left"] as? Int == offset && pair["right"] as? Int == offset },
                      "Unrelated unequal-length PDFs always begin with stable page-number pairs")
            }
        }
        var seed: UInt64 = 42
        var maximumLeft: [[String: Any]] = [], maximumRight: [[String: Any]] = []
        for index in 0..<200 {
            let bytes: [UInt8] = (0..<1_300).map { _ in
                seed = seed &* 1_664_525 &+ 1_013_904_223
                return UInt8(97 + (seed >> 16) % 26)
            }
            let text = String(decoding: bytes, as: UTF8.self)
            maximumLeft.append(page(index, text, "maximum-old-\(index)"))
            maximumRight.append(page(index, text, "maximum-new-\(index)"))
        }
        let started = ProcessInfo.processInfo.systemUptime
        let maximum = try compare(maximumLeft, maximumRight)
        check(maximum.count == 200 && lastAlignment["reliablePairs"] as? Int == 200,
              "The 200-page and document-text bounds retain every reliable content match")
        print(String(format: "Maximum PDF descriptor comparison: %.3f s", ProcessInfo.processInfo.systemUptime - started))
        let repeatedLongText = maximumLeft[0]["text"] as! String
        let maximumRepeated = try compare((0..<200).map { page($0, repeatedLongText, "repeat-old-\($0)") },
                                          (0..<200).map { page($0, repeatedLongText, "repeat-new-\($0)") })
        check(maximumRepeated.count == 200 && lastAlignment["reason"] as? String == "ambiguousEvidence",
              "Large repeated-page documents stay positional instead of inventing unique text anchors")
        let unsupported: [String: Any] = ["protocolVersion": 1, "runID": "fixture", "mode": "multiSubject", "inputs": []]
        scriptError = nil
        _ = context.objectForKeyedSubscript("compare")?.call(withArguments: [unsupported])
        check(scriptError != nil, "Unsupported multi-subject requests fail instead of dropping inputs")
        print("PDF algorithm checks: \(count) passed")
    }
}
