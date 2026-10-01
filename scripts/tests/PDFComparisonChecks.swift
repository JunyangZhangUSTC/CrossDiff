import Foundation
import CoreGraphics
import CoreText
import JavaScriptCore
import PDFKit
import CrossDiffCore

private struct FixturePage { let text: String?; let shade: CGFloat }

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

        let execute: @Sendable ([PluginInput]) async throws -> PluginComparisonResult = { inputs in
            try runJavaScript(script, inputs: inputs)
        }
        let model = PDFComparisonModel()
        await model.load(left: leftURL, right: rightURL, execute: execute)
        try check(model.error == nil && model.pairs.count == 3, "Host loads and displays the real plugin's complete correspondence")
        try check(model.pairs[0].kind == .same && model.pairs[1].kind == .added && model.pairs[2].kind == .changed,
                  "Inserted scanned page does not misalign the later changed text page")
        try check(model.pairs[2].left == 1 && model.pairs[2].right == 2, "Page locations refer to the correct original inputs")
        model.selectedIndex = 2
        for _ in 0..<100 where model.textDiff == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(model.textDiff?.hunks.isEmpty == false, "Selected pages provide real text differences")
        try check(model.leftText.contains("10") && model.rightText.contains("20"), "Text review uses original extracted content")
        model.move(by: -1, differencesOnly: true)
        try check(model.selectedIndex == 1, "Difference navigation reaches the inserted page")
        try check(model.leftText.isEmpty && model.rightText.isEmpty, "A scanned inserted page does not fabricate text")
        model.move(by: -1)
        try check(model.selectedIndex == 0, "Page navigation returns to the common page")

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
