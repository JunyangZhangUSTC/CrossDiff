import Foundation
import CoreGraphics
import CoreText
import JavaScriptCore
import PDFKit
import CrossDiffCore

private struct FixturePage { let text: String?; let shade: CGFloat }
private actor ExecutionCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@main
struct PDFComparisonChecks {
    @MainActor
    static func main() async {
        do { try await run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor
    static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixtures = root.appendingPathComponent(".build-pdf-checks/fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let script = try String(contentsOf: root.appendingPathComponent("Plugins/PDF/compare.js"), encoding: .utf8)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw NSError(domain: "PDFChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let packaged = try PluginPackage.load(from: root.appendingPathComponent(".build-pdf-checks/PDF.crossdiffplugin"))
        try check(packaged.manifest.id == "org.crossdiff.pdf" && packaged.script == script,
                  "Reproducible standalone package contains the actual validated PDF algorithm")
        let leftURL = fixtures.appendingPathComponent("left.pdf"), rightURL = fixtures.appendingPathComponent("right.pdf")
        let intro = FixturePage(text: "CrossDiff Research\nIntroduction: comparing scientific results.", shade: 0.2)
        let results = FixturePage(text: "Results\nThe measured value is 10. Confidence is high.", shade: 0.4)
        let changed = FixturePage(text: "Results\nThe measured value is 20. Confidence is high.", shade: 0.7)
        let scan = FixturePage(text: nil, shade: 0.55)
        try makePDF([intro, results]).write(to: leftURL)
        try makePDF([intro, scan, changed]).write(to: rightURL)
        let originalLeft = try Data(contentsOf: leftURL), originalRight = try Data(contentsOf: rightURL)
        let documents = try await Task.detached {
            (try PDFComparisonDecoder.load(leftURL), try PDFComparisonDecoder.load(rightURL))
        }.value
        try check(documents.0.pages.count == 2 && documents.1.pages.count == 3, "All fixture pages are read")
        try check(documents.0.pages[0].text.contains("CrossDiff Research"), "PDFKit extracts the original text")
        try check(documents.0.pages[0].fingerprint == documents.1.pages[0].fingerprint, "Identical pages have matching rendered fingerprints")
        try check(documents.0.pages[1].fingerprint != documents.1.pages[2].fingerprint, "A visible page change changes its fingerprint")
        try check(documents.1.pages[1].text.isEmpty, "Synthetic scan remains no-text, not fabricated OCR")
        try check(documents.0.data == originalLeft && documents.1.data == originalRight, "Snapshots retain the exact source bytes")

        let calls = ExecutionCounter()
        let execute: @Sendable ([PluginInput]) async throws -> PluginComparisonResult = { inputs in
            await calls.increment()
            return try runJavaScript(script, inputs: inputs)
        }
        let model = PDFComparisonModel()
        await model.load(left: leftURL, right: rightURL, execute: execute)
        try check(model.error == nil && model.pairs.count == 3, "Host loads all pages from the real plugin")
        try check(model.alignmentMode == .pageNumber && !model.isSmartFallback, "Default comparison uses stable page numbers")
        try check(model.pairs[0].left == 0 && model.pairs[0].right == 0 && model.pairs[1].left == 1 && model.pairs[1].right == 1,
                  "Default pages remain 1-to-1 and 2-to-2 even when the second PDF has an insertion")
        try check(model.pairs[2].left == nil && model.pairs[2].right == 2, "Extra pages remain on their actual source side")
        try check(!model.presentationTitle(for: model.pairs[2]).contains("Added") && !model.presentationTitle(for: model.pairs[2]).contains("新增"),
                  "Page-number alignment does not claim that unrelated extra pages were added")
        let positional = model.presentation(for: model.pairs[2])
        try check(positional == .onlyRight && positional.symbol == "doc" && positional.emptyPageSymbol == "doc" && positional.tone == .neutral,
                  "Page-number extra pages use a neutral page symbol and color, not an insertion badge")
        let beforeModes = await calls.count
        model.selectAlignmentMode(.smart)
        try check(model.pairs[0].kind == .same && model.pairs[1].kind == .added && model.pairs[2].kind == .changed,
                  "Inserted scanned page does not misalign the later changed text page")
        try check(model.pairs[2].left == 1 && model.pairs[2].right == 2, "Page locations refer to the correct original inputs")
        try check(!model.isSmartFallback, "Well-supported insertion remains smart-aligned")
        let inserted = model.presentation(for: model.pairs[1])
        try check(inserted == .comparison(.added) && inserted.symbol == "plus" && inserted.emptyPageSymbol == "plus.rectangle.on.rectangle" && inserted.tone == .added,
                  "Reliable smart insertion retains its added-page symbol and color")
        model.selectedIndex = 2
        for _ in 0..<100 where model.textDiff == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(model.textDiff?.hunks.isEmpty == false, "Selected pages provide real text differences")
        try check(model.leftText.contains("10") && model.rightText.contains("20"), "Text review uses original extracted content")
        model.move(by: -1, differencesOnly: true)
        try check(model.selectedIndex == 1, "Difference navigation reaches the inserted page")
        try check(model.leftText.isEmpty && model.rightText.isEmpty, "A scanned inserted page does not fabricate text")
        model.move(by: -1)
        try check(model.selectedIndex == 0, "Page navigation returns to the common page")

        model.selectAlignmentMode(.manual)
        model.selectManualPage(1, isLeft: true)
        model.selectManualPage(2, isLeft: false)
        try check(model.selectedPair?.left == 1 && model.selectedPair?.right == 2, "Manual selection preserves independent source page indices")
        try check(model.leftText.contains("10") && model.rightText.contains("20"), "Manual comparison reviews the selected original pages")
        for _ in 0..<100 where model.textDiff == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(model.textDiff?.hunks.isEmpty == false, "Manual selection refreshes character differences")
        model.selectManualPage(0, isLeft: false)
        try check(model.selectedPair?.left == 1 && model.selectedPair?.right == 0, "Changing the right page never moves the left page")
        model.selectAlignmentMode(.pageNumber)
        model.selectAlignmentMode(.manual)
        try check(model.manualLeftPage == 1 && model.manualRightPage == 0, "Manual source selections survive switching alignment modes")
        for invalidNumber in [Int.min, Int.max, 0, -1, 99] {
            model.selectManualPageNumber(invalidNumber, isLeft: true)
            model.selectManualPageNumber(invalidNumber, isLeft: false)
        }
        try check(model.manualLeftPage == 1 && model.manualRightPage == 0, "Invalid or overflowing human page numbers never change the selected source or trap")
        model.selectManualPageNumber(2, isLeft: true)
        model.selectManualPageNumber(3, isLeft: false)
        try check(model.manualLeftPage == 1 && model.manualRightPage == 2, "Valid human page numbers convert to their exact zero-based source locations")
        model.selectManualPageNumber(1, isLeft: false)
        await model.load(left: leftURL, right: rightURL, execute: execute)
        try check(model.alignmentMode == .manual && model.selectedPair?.left == 1 && model.selectedPair?.right == 0,
                  "Re-entering a loaded view preserves its alignment mode and manual pages")
        let afterModes = await calls.count
        try check(afterModes == beforeModes, "Changing page modes and remounting a loaded view do not re-read or re-run the plugin")

        let reversed = PDFComparisonModel()
        await reversed.load(left: rightURL, right: leftURL, execute: execute)
        try check(reversed.error == nil && reversed.pairs.count == 3, "Swapped inputs remain a complete page-number comparison")
        let leftOnly = reversed.presentation(for: reversed.pairs[2])
        try check(leftOnly == .onlyLeft && leftOnly.symbol == "doc" && leftOnly.emptyPageSymbol == "doc" && leftOnly.tone == .neutral,
                  "Swapping inputs keeps a positional left-only page neutral rather than calling it deleted")
        reversed.selectAlignmentMode(.smart)
        try check(!reversed.isSmartFallback && reversed.pairs[1].left == 1 && reversed.pairs[1].right == nil,
                  "Swapped smart insertion preserves the actual removed-page source")
        let removed = reversed.presentation(for: reversed.pairs[1])
        try check(removed == .comparison(.removed) && removed.symbol == "minus" && removed.emptyPageSymbol == "minus.rectangle" && removed.tone == .removed,
                  "Reliable smart removal retains its removed-page symbol and color")

        let unrelatedLeft = fixtures.appendingPathComponent("unrelated-left.pdf")
        let unrelatedRight = fixtures.appendingPathComponent("unrelated-right.pdf")
        try makePDF([FixturePage(text: "AAAA", shade: 0.1)]).write(to: unrelatedLeft)
        try makePDF([FixturePage(text: "BBBB", shade: 0.3), FixturePage(text: "CCCC", shade: 0.6),
                     FixturePage(text: "DDDD", shade: 0.8)]).write(to: unrelatedRight)
        let unrelated = PDFComparisonModel()
        await unrelated.load(left: unrelatedLeft, right: unrelatedRight, execute: execute)
        try check(unrelated.selectedPair?.left == 0 && unrelated.selectedPair?.right == 0,
                  "Reported regression: unrelated left page 1 opens beside right page 1, never page 3")
        unrelated.selectAlignmentMode(.smart)
        try check(unrelated.isSmartFallback && !unrelated.alignmentNotice.isEmpty, "Unrelated documents explain their safe page-number fallback")
        try check(unrelated.pairs.count == 3 && unrelated.pairs[0].left == 0 && unrelated.pairs[0].right == 0,
                  "Insufficient smart evidence cannot push page 1 to the end of a longer document")
        unrelated.selectedIndex = 2
        try check(unrelated.selectedPair?.left == nil && unrelated.selectedPair?.right == 2 && unrelated.rightText.contains("DDDD"),
                  "Fallback navigation retains original page numbers and no fabricated left page")
        try check(!unrelated.presentationTitle(for: unrelated.pairs[2]).contains("Added") && !unrelated.presentationTitle(for: unrelated.pairs[2]).contains("新增"),
                  "Smart fallback also uses neutral single-sided page labels")
        let fallback = unrelated.presentation(for: unrelated.pairs[2])
        try check(fallback == .onlyRight && fallback.symbol == "doc" && fallback.emptyPageSymbol == "doc" && fallback.tone == .neutral,
                  "Smart fallback uses the same neutral symbol and color as page-number comparison")
        await unrelated.load(left: unrelatedRight, right: unrelatedLeft, execute: execute)
        try check(unrelated.error == nil && unrelated.isSmartFallback && unrelated.pairs.count == 3,
                  "Swapped unrelated documents still fall back without losing source pages")
        let reversedFallback = unrelated.presentation(for: unrelated.pairs[2])
        try check(reversedFallback == .onlyLeft && reversedFallback.symbol == "doc" && reversedFallback.emptyPageSymbol == "doc" && reversedFallback.tone == .neutral,
                  "Smart fallback never changes a left-only page into a red deletion badge")

        for unsupportedEvidence in [false, true] {
            let contradictory: @Sendable ([PluginInput]) async throws -> PluginComparisonResult = { inputs in
                let valid = try await execute(inputs)
                var payload = valid.payload.objectValue!
                var alignment: [String: PluginJSONValue] = ["strategy": .string("smart"), "reliablePairs": .number(2)]
                if unsupportedEvidence {
                    // Counts fit both documents but exceed all actual two-sided
                    // correspondences, so a plugin must not authorize smart mode.
                    payload["pairs"] = .array([
                        .object(["left": .number(0), "right": .null, "kind": .string("removed")]),
                        .object(["left": .number(1), "right": .null, "kind": .string("removed")]),
                        .object(["left": .null, "right": .number(0), "kind": .string("added")]),
                        .object(["left": .null, "right": .number(1), "kind": .string("added")]),
                        .object(["left": .null, "right": .number(2), "kind": .string("added")])])
                } else {
                    alignment["reason"] = .string("ambiguousEvidence")
                }
                payload["alignment"] = .object(alignment)
                return PluginComparisonResult(runID: valid.runID, schema: valid.schema, summary: valid.summary, payload: .object(payload))
            }
            let inconsistent = PDFComparisonModel()
            await inconsistent.load(left: leftURL, right: rightURL, execute: contradictory)
            inconsistent.selectAlignmentMode(.smart)
            try check(inconsistent.error == nil && inconsistent.isSmartFallback && inconsistent.pairs.count == 3,
                      unsupportedEvidence ? "Claimed reliability cannot exceed actual two-sided pairs" : "Ambiguous evidence cannot be declared reliable by a contradictory plugin strategy")
        }

        let scannedURL = fixtures.appendingPathComponent("scan.pdf")
        try makePDF([scan]).write(to: scannedURL)
        let scannedModel = PDFComparisonModel()
        await scannedModel.load(left: scannedURL, right: scannedURL, execute: execute)
        try check(scannedModel.pairs.first?.kind == .unknown, "Matching scanned previews remain explicitly unverified")
        try check(scannedModel.result?.diagnostics.contains(where: { $0.en.contains("OCR") }) == true, "No-text limitations reach the user")

        let coloredURL = fixtures.appendingPathComponent("visual-change.pdf")
        try makePDF([FixturePage(text: intro.text, shade: 0.9)]).write(to: coloredURL)
        let visualModel = PDFComparisonModel()
        await visualModel.load(left: coloredURL, right: leftURL, execute: execute)
        try check(visualModel.pairs[0].kind == .changed, "Identical text does not hide changed vector artwork")

        let corruptURL = fixtures.appendingPathComponent("corrupt.pdf")
        try Data("Not a PDF document".utf8).write(to: corruptURL)
        do { _ = try PDFComparisonDecoder.load(corruptURL); try check(false, "Corrupt PDFs must be rejected") }
        catch is PDFComparisonFailure { checks += 1 }
        let lockedURL = fixtures.appendingPathComponent("locked.pdf")
        try makePDF([intro], password: "example-test-password").write(to: lockedURL)
        do { _ = try PDFComparisonDecoder.load(lockedURL); try check(false, "Locked PDFs must be rejected") }
        catch PDFComparisonFailure.locked { checks += 1 }
        let longURL = fixtures.appendingPathComponent("page-limit.pdf")
        try makePDF(Array(repeating: FixturePage(text: nil, shade: 0.5), count: 201)).write(to: longURL)
        let limited = try await Task.detached { try PDFComparisonDecoder.load(longURL) }.value
        try check(limited.pages.count == 200 && limited.totalPageCount == 201 && limited.truncated, "Page limits are explicit partial coverage")
        let limitedResult = try runJavaScript(script, inputs: [
            PluginInput(id: "left", role: .left, name: "Pages.pdf", content: limited.pluginContent),
            PluginInput(id: "right", role: .right, name: "Pages.pdf", content: limited.pluginContent)])
        try check(limitedResult.status == .partial, "Partial extraction is never published as full coverage")
        try check(limitedResult.diagnostics.contains { $0.en.contains("limit") }, "Partial coverage has a readable diagnostic")

        let cancelledModel = PDFComparisonModel()
        let pending = Task { await cancelledModel.load(left: leftURL, right: rightURL, execute: { inputs in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await execute(inputs)
        }) }
        try await Task.sleep(nanoseconds: 30_000_000)
        cancelledModel.cancel()
        await pending.value
        try check(cancelledModel.result == nil && !cancelledModel.isLoading, "Canceling a run prevents publication and clears loading")
        await cancelledModel.load(left: leftURL, right: rightURL, execute: execute)
        try check(cancelledModel.result != nil, "A canceled comparison can be restarted")

        let invalid: @Sendable ([PluginInput]) async throws -> PluginComparisonResult = { inputs in
            let valid = try await execute(inputs)
            return PluginComparisonResult(runID: valid.runID, schema: valid.schema, summary: valid.summary,
                                          payload: .object(["pairs": .array([])]))
        }
        await model.load(left: leftURL, right: rightURL, execute: invalid, executionID: "updated-plugin")
        try check(model.error != nil && model.result == nil, "Changing plugin identity invalidates cached results; dropped pages are rejected")
        await model.load(left: leftURL, right: rightURL, execute: execute, executionID: "restored-plugin")
        try check(model.result != nil, "Recovery after a bad plugin result preserves usable sources")
        let finalLeft = try Data(contentsOf: leftURL), finalRight = try Data(contentsOf: rightURL)
        try check(finalLeft == originalLeft && finalRight == originalRight,
                  "Comparing, navigation, cancellation and errors never rewrite source PDFs")
        print("PDF comparison checks: \(checks) passed")
    }

    static func runJavaScript(_ script: String, inputs: [PluginInput]) throws -> PluginComparisonResult {
        let request = PluginComparisonRequest(runID: UUID().uuidString, inputs: inputs)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        guard let context = JSContext() else { throw PDFComparisonFailure.invalidResult }
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(script)
        guard let result = context.evaluateScript("JSON.stringify(compare(\(json)))")?.toString(), exception == nil else {
            throw NSError(domain: "PDFChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: exception ?? "Invalid JavaScript result"])
        }
        return try JSONDecoder().decode(PluginComparisonResult.self, from: Data(result.utf8))
    }

    private static func makePDF(_ pages: [FixturePage], password: String? = nil) -> Data {
        let bytes = NSMutableData()
        let consumer = CGDataConsumer(data: bytes)!
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        var metadata: [CFString: Any] = [kCGPDFContextTitle: "Synthetic CrossDiff PDF Fixture"]
        if let password { metadata[kCGPDFContextUserPassword] = password; metadata[kCGPDFContextOwnerPassword] = password }
        let context = CGContext(consumer: consumer, mediaBox: &bounds, metadata as CFDictionary)!
        for page in pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
            context.setFillColor(CGColor(red: page.shade, green: 0.35, blue: 1 - page.shade, alpha: 1))
            context.fill(CGRect(x: 40, y: 410, width: 240, height: 110))
            if let text = page.text {
                let font = CTFontCreateWithName("Helvetica" as CFString, 17, nil)
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)]
                    context.textPosition = CGPoint(x: 40, y: 735 - index * 30)
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        return bytes as Data
    }
}
