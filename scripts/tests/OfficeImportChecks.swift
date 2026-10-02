import Foundation
import CrossDiffCore

@main enum OfficeImportChecks {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw NSError(domain: "OfficeImportChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let before = try Data(contentsOf: root.appendingPathComponent("word.docx"))
            let word = try OfficeImporter.load(root.appendingPathComponent("word.docx"))
            try check(word.sections[0].rows[0].cells[0].value == "中文👩🏽‍💻\tA\nB", "Word Unicode, tabs and breaks retain their text")
            try check(word.sections[0].rows[1].cells.map(\.value) == ["Cell one", "二"], "Word table cells preserve block order")
            try check(word.sections[0].rows[2].cells[0].value == "kept", "Word current text excludes deleted revisions")
            try check(!word.diagnostics.isEmpty, "Word states its content comparison scope")
            let after = try Data(contentsOf: root.appendingPathComponent("word.docx"))
            try check(after == before, "Import leaves the source unchanged")
            let sheet = try OfficeImporter.load(root.appendingPathComponent("sheet.xlsx"))
            try check(sheet.sections.map(\.name) == ["Later", "First"], "Workbook relationship order is retained")
            let row = sheet.sections[0].rows[0]
            try check(row.position == 2 && row.cells.map(\.column) == [1, 4, 6, 7, 8, 9], "Sparse worksheet source coordinates are preserved")
            try check(row.cells[0].value == "Studio One" && row.cells[1].value == "中文", "Shared and inline rich strings exclude phonetic guides")
            try check(row.cells[2].formula == "SUM(B2:C2)" && row.cells[2].value == "10", "Formulas and cached results remain separate")
            try check(sheet.sections[0].rows[1].cells[0].formula?.contains("shared") == true, "Shared formula followers retain formula identity")
            try check(sheet.sections[0].rows[1].cells[1].formula == "NA()" && sheet.sections[0].rows[1].cells[1].value == nil, "Missing formula cache is not a blank value")
            try check(row.cells[4].type == "boolean" && row.cells[4].value == "false", "Boolean false remains typed")
            try check(row.cells[5].format != nil && sheet.diagnostics.contains { $0.en.contains("1904") }, "Date format and 1904 epoch are explicit")
            let slides = try OfficeImporter.load(root.appendingPathComponent("slides.pptx"))
            try check(slides.sections.count == 2 && slides.sections[0].rows[0].cells[0].value == "Results\n第二行", "Presentation follows slide relationships, not ZIP filename order")
            try check(slides.sections[0].rows[1].cells.map(\.value) == ["Quarter", "42"], "Slide table cells retain their structure")
            try check(slides.sections[0].rows.last?.cells[0].value == "Speaker note", "Speaker notes are included with their slide")
            try check(!slides.diagnostics.isEmpty, "Presentation states that visual layout is outside content comparison")
            for name in ["doctype-utf8.docx", "doctype-utf16.docx", "doctype-utf32.docx", "deep.docx", "broken-rel.docx", "encoded-rel.docx", "missing-rel.xlsx", "namespace-spoof.xlsx", "duplicate-row.xlsx", "duplicate-cell.xlsx", "missing-formula-master.xlsx", "invalid-shared-string.xlsx", "wrong-coordinate.xlsx", "wrong-type.docx", "oversized-xml.docx", "truncated-xml.docx", "unsafe-zip.docx", "oversized.docx", "legacy.doc", "crc.docx", "duplicate-zip.docx", "link.docx"] {
                var rejected = false
                do { _ = try OfficeImporter.load(root.appendingPathComponent(name)) } catch { rejected = true }
                try check(rejected, "Reject unsafe or ambiguous input: " + name)
            }
            let empty = try OfficeImporter.load(root.appendingPathComponent("empty.xlsx"))
            try check(empty.sections.isEmpty, "An empty workbook is reported as empty, not corrupt")
            let external = try OfficeImporter.load(root.appendingPathComponent("external-link.docx"))
            try check(external.sections[0].rows.count == 3 && external.diagnostics.contains { $0.en.contains("never fetched") }, "External links are ignored and explicitly reported")
            let utf16 = try OfficeImporter.load(root.appendingPathComponent("utf16.docx"))
            try check(utf16.sections[0].rows[0].cells[0].value == "中文👩🏽‍💻\tA\nB", "Valid UTF-16 XML preserves Unicode text")
            let strict = try OfficeImporter.load(root.appendingPathComponent("strict.docx"))
            try check(strict.sections[0].rows[0].cells[0].value == "中文👩🏽‍💻\tA\nB", "Strict OOXML namespaces retain their supported text content")
            let revisionCell = try OfficeImporter.load(root.appendingPathComponent("revision-cell.docx"))
            try check(revisionCell.sections[0].rows[0].cells[0].value == "kept cell paragraph", "Deleted table paragraphs do not re-enter current visible text")
            let emptyCache = try OfficeImporter.load(root.appendingPathComponent("empty-formula-cache.xlsx"))
            try check(emptyCache.sections[0].rows[1].cells[1].value == nil, "An empty numeric formula cache means unavailable, not an empty-string result")
            let outOfOrder = try OfficeImporter.load(root.appendingPathComponent("out-of-order.xlsx"))
            try check(outOfOrder.sections[0].rows.map(\.position) == [3, 8] && outOfOrder.sections[0].rows[1].cells.map(\.column) == [1, 4], "Sparse input is presented in actual coordinate order")
            for name in ["limit-rows.docx", "limit-cell.docx", "zero-coordinate.xlsx", "limit-column.xlsx", "limit-expanded.docx"] {
                var rejected = false
                do { _ = try OfficeImporter.load(root.appendingPathComponent(name)) } catch { rejected = true }
                try check(rejected, "Reject resource or coordinate limit: " + name)
            }
            let annotations = try OfficeImporter.load(root.appendingPathComponent("word-annotations.docx"))
            try check(annotations.sections.count == 3 && annotations.sections[1].rows[0].cells[0].value == "Project header", "Word header text is read from its relationship")
            try check(annotations.sections[2].rows.count == 1 && annotations.sections[2].rows[0].cells[0].value == "A research note", "Footnote separator metadata is not compared as note prose")
            let cancelledTask = Task.detached { () throws -> OfficeDocument in
                while !Task.isCancelled { await Task.yield() }
                return try OfficeImporter.load(root.appendingPathComponent("word.docx"))
            }
            cancelledTask.cancel()
            var cancelled = false
            do { _ = try await cancelledTask.value } catch is CancellationError { cancelled = true }
            try check(cancelled, "Cancelled import publishes no document")
            for name in ["duplicate-body.docx", "duplicate-sheet-data.xlsx"] {
                var rejected = false
                do { _ = try OfficeImporter.load(root.appendingPathComponent(name)) } catch { rejected = true }
                try check(rejected, "Duplicate document containers cannot hide content: " + name)
            }
            let wordMCE = try OfficeImporter.load(root.appendingPathComponent("word-mce.docx"))
            try check(wordMCE.sections[0].rows[0].cells[0].value == "Before Fallback once", "Word compatibility fallback contributes text once without Choice duplication")
            try check(wordMCE.diagnostics.contains { $0.en.contains("fallback") }, "Compatibility fallback is explicitly reported")
            let slidesMCE = try OfficeImporter.load(root.appendingPathComponent("slides-mce.pptx"))
            try check(slidesMCE.sections[0].rows.map { $0.cells[0].value } == ["Fallback once", "Speaker note"], "Slide compatibility fallback contributes one shape, with notes retained")
            for name in ["word-mce-no-fallback.docx", "slides-mce-no-fallback.pptx"] {
                var rejected = false
                do { _ = try OfficeImporter.load(root.appendingPathComponent(name)) } catch { rejected = true }
                try check(rejected, "Compatibility content without a supported fallback must fail explicitly: " + name)
            }
            print("Office import checks passed: \(checks)")
        } catch { print("Office import check failed after \(checks): \(error)"); exit(1) }
    }
}
