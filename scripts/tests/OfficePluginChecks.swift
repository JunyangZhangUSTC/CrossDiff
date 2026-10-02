import Foundation
import JavaScriptCore
import CrossDiffCore

@main enum OfficePluginChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(description: message) }; count += 1; print("PASS: " + message)
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { count += 1; return }; throw Failure(description: message)
    }
    static func row(_ id: String, _ position: Int, _ values: [String]) -> OfficeRow {
        .init(id: id, position: position, label: "Row \(position)", cells: values.enumerated().map { .init(column: $0.offset + 1, type: "text", value: $0.element) })
    }
    static func request(_ left: [OfficeRow], _ right: [OfficeRow], keys: [Int] = [], kind: OfficeDocumentKind = .spreadsheet) -> PluginComparisonRequest {
        .init(runID: "office-check", inputs: [
            .init(id: "left", role: .left, name: "left", content: OfficeSection(id: "sheet1", name: "Before", rows: left).pluginContent(kind: kind)),
            .init(id: "right", role: .right, name: "right", content: OfficeSection(id: "sheet1", name: "After", rows: right).pluginContent(kind: kind))
        ], options: OfficeWorkspaceState(keyColumns: keys).pluginOptions)
    }
    static func main() async {
        do { try await runChecks() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func runChecks() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let script = try String(contentsOf: root.appendingPathComponent("Plugins/Official/Office/compare.js"), encoding: .utf8)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: root.appendingPathComponent("Plugins/Official/Office/manifest.json")))
        let context = JSContext()!; var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(script)
        func raw(_ request: PluginComparisonRequest) throws -> PluginComparisonResult {
            exception = nil
            let input = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
            let literal = String(data: try JSONSerialization.data(withJSONObject: [input]), encoding: .utf8)!
            guard let result = context.evaluateScript("JSON.stringify(compare(JSON.parse(\(literal)[0])))")?.toString()?.data(using: .utf8), exception == nil else {
                throw Failure(description: exception ?? "No Office result")
            }
            return try JSONDecoder().decode(PluginComparisonResult.self, from: result)
        }
        func run(_ request: PluginComparisonRequest) throws -> OfficeComparisonResult {
            try request.validate(for: manifest)
            let result = try raw(request)
            try result.validate(for: request, manifest: manifest)
            return try OfficeComparisonResult.parse(result)
        }
        let reorderedRequest = request([row("l1", 1, ["Alpha"]), row("l2", 2, ["Beta"]), row("l3", 3, ["Gamma"])],
                                       [row("r1", 1, ["Gamma"]), row("r2", 2, ["Alpha"]), row("r3", 3, ["Beta"])])
        let reordered = try run(reorderedRequest)
        try check(reordered.rows.count == 3 && reordered.rows.allSatisfy { $0.status == .equal && $0.basis == .exact }, "Reordered equal rows match globally instead of appearing added and removed")
        try check(reordered.rows.first { $0.leftID == "l3" }?.rightID == "r1", "A matched row retains its two distinct source IDs")
        try check(reordered.rows.filter(\.moved).count == 1 && reordered.rows.first { $0.leftID == "l3" }?.moved == true, "A rotation marks only the relocated passage rather than every shifted row")
        let inserted = try run(request([row("l1", 1, ["A"]), row("l2", 2, ["B"])], [row("r1", 1, ["new"]), row("r2", 2, ["A"]), row("r3", 3, ["B"])]))
        try check(inserted.rows.filter { $0.status == .added }.count == 1 && inserted.rows.allSatisfy { !$0.moved }, "An inserted row does not make all subsequent rows look moved")
        let keyed = try run(request([row("l1", 1, ["A", "10"]), row("l2", 2, ["B", "20"])],
                                    [row("r1", 1, ["B", "25"]), row("r2", 2, ["A", "10"])], keys: [1]))
        try check(keyed.rows.first { $0.leftID == "l2" }?.rightID == "r1" && keyed.rows.first { $0.leftID == "l2" }?.status == .modified && keyed.rows.first { $0.leftID == "l2" }?.basis == .key, "Unique business keys pair modified rows after a reorder")
        let duplicateKey = try run(request([row("l1", 1, ["A", "10"]), row("l2", 2, ["A", "20"])],
                                            [row("r1", 1, ["A", "10"]), row("r2", 2, ["A", "30"])], keys: [1]))
        try check(duplicateKey.rows.contains { $0.leftID == "l2" && $0.rightID == nil && $0.ambiguous } && duplicateKey.rows.contains { $0.rightID == "r2" && $0.leftID == nil && $0.ambiguous }, "Duplicate business keys do not force a speculative pairing even after one exact match")
        let editedParagraph = try run(request([row("l1", 1, ["Heading"]), row("l2", 2, ["Old paragraph"])],
                                              [row("r1", 1, ["Heading"]), row("r2", 2, ["New paragraph"])], kind: .word))
        try check(editedParagraph.rows.first { $0.leftID == "l2" }?.status == .modified && editedParagraph.rows.first { $0.leftID == "l2" }?.basis == .position, "A changed Word paragraph remains a visible positional comparison")
        let uncertainPosition = try run(request([row("l1", 1, ["A"]), row("l2", 2, ["B"]), row("l3", 3, ["C"])],
                                                [row("r1", 1, ["A"]), row("r2", 2, ["D"]), row("r3", 3, ["B"])], kind: .word))
        try check(uncertainPosition.rows.first { $0.leftID == "l3" }?.basis == .position && uncertainPosition.rows.allSatisfy { !$0.moved }, "Positional comparison does not invent a moved identity or disrupt the exact-match backbone")
        func single(_ id: String, _ cell: OfficeCell) -> OfficeRow { .init(id: id, position: 1, label: id, cells: [cell]) }
        let precision = try run(request([single("left", .init(column: 1, type: "number", value: "9007199254740992"))], [single("right", .init(column: 1, type: "number", value: "9007199254740993"))]))
        try check(precision.rows.first?.status == .modified, "Large numeric lexemes do not round through JavaScript numbers")
        let empty = try run(request([single("left", .init(column: 1, type: "text", value: nil))], [single("right", .init(column: 1, type: "text", value: ""))]))
        try check(empty.rows.first?.status == .modified, "Missing and explicitly empty values stay distinct")
        let formula = try run(request([single("left", .init(column: 1, type: "number", value: "2", formula: "1+1"))], [single("right", .init(column: 1, type: "number", value: "2", formula: "4/2"))]))
        try check(formula.rows.first?.status == .modified, "Different formulas with an equal cached value remain different")
        let cache = try run(request([single("left", .init(column: 1, type: "number", value: "2", formula: "A1+1"))], [single("right", .init(column: 1, type: "number", value: "3", formula: "A1+1"))]))
        try check(cache.rows.first?.status == .modified, "Changed cached values remain visible without recalculation")
        let format = try run(request([single("left", .init(column: 1, type: "text", value: "same", format: "first"))], [single("right", .init(column: 1, type: "text", value: "same", format: "second"))]))
        try check(format.rows.first?.status == .equal, "The documented content comparison does not treat style IDs as content")
        let unicode = try run(request([row("é", 1, ["é"]), row("e\u{0301}", 2, ["stable"])], [row("r1", 1, ["e\u{0301}"]), row("r2", 2, ["stable"])]))
        try check(unicode.rows.count == 2 && unicode.rows.filter { $0.status == .modified }.count == 1, "Unicode code-unit distinctions survive the plugin and host contract")
        let duplicates = try run(request([row("l1", 1, ["same"]), row("l2", 2, ["same"])], [row("r1", 1, ["same"])]))
        try check(duplicates.rows.first { $0.status == .equal }?.ambiguous == true && duplicates.rows.filter { $0.status == .removed }.count == 1, "Repeated equal rows retain multiplicity and disclose nonunique occurrence pairing")
        let missingKey = try run(request([row("l1", 1, ["", "old"])], [row("r1", 1, ["", "new"])], keys: [1]))
        try check(missingKey.rows.count == 2 && missingKey.rows.allSatisfy(\.ambiguous), "Blank business keys remain unpaired with explicit ambiguity")
        let spaceRequest = request([row("l1", 1, ["\u{FEFF}", "old"])], [row("r1", 1, ["\u{FEFF}", "new"])], keys: [1])
        let spaceKey = try run(spaceRequest)
        try check(spaceKey.rows.count == 1 && spaceKey.rows.first?.basis == .key, "Key spelling is exact and never implicitly trimmed by different Unicode libraries")
        let typedKey = try run(request([single("l", .init(column: 1, type: "number", value: "001"))], [single("r", .init(column: 1, type: "text", value: "001"))], keys: [1]))
        try check(typedKey.rows.count == 2, "A numeric key and text key are distinct identities")
        let composite = try run(request([row("l1", 1, ["A", "1", "old"]), row("l2", 2, ["A", "2", "keep"])], [row("r1", 1, ["A", "2", "keep"]), row("r2", 2, ["A", "1", "new"])], keys: [1, 2]))
        try check(composite.rows.first { $0.leftID == "l1" }?.rightID == "r2" && composite.rows.first { $0.leftID == "l1" }?.basis == .key, "Composite business keys disambiguate rows sharing their first column")
        try check(try run(request([], [])).rows.isEmpty, "Two empty sections yield a complete empty comparison")
        try rejects("Duplicate source IDs are rejected") { _ = try run(request([row("duplicate", 1, ["one"]), row("duplicate", 2, ["two"])], [])) }
        try rejects("Duplicate key columns are rejected") { _ = try run(request([], [], keys: [1, 1])) }
        try rejects("The standalone algorithm rejects duplicate source identities") { _ = try raw(request([row("duplicate", 1, ["one"]), row("duplicate", 2, ["two"])], [])) }
        try rejects("Keys cannot silently apply to Word paragraphs") { _ = try run(request([], [], keys: [1], kind: .word)) }
        let original = try raw(reorderedRequest)
        func forged(_ rows: [PluginJSONValue], extra: Bool = false) -> PluginComparisonResult {
            var payload: [String: PluginJSONValue] = ["rows": .array(rows)]
            if extra { payload["renderHTML"] = .string("<script>arbitrary</script>") }
            return .init(runID: original.runID, schema: original.schema, summary: original.summary, payload: .object(payload))
        }
        try rejects("Omitted source rows cannot appear complete") { try forged([]).validate(for: reorderedRequest, manifest: manifest) }
        var wrongID = original.payload["rows"]!.arrayValue!
        var altered = wrongID[0].objectValue!; altered["leftID"] = .string("not-in-source"); wrongID[0] = .object(altered)
        try rejects("Result IDs must refer to source rows") { try forged(wrongID).validate(for: reorderedRequest, manifest: manifest) }
        var wrongStatus = original.payload["rows"]!.arrayValue!
        altered = wrongStatus[0].objectValue!; altered["status"] = .string("modified"); wrongStatus[0] = .object(altered)
        try rejects("A plugin cannot mislabel equal content as modified") { try forged(wrongStatus).validate(for: reorderedRequest, manifest: manifest) }
        try rejects("Output cannot inject its own rendering content") { try forged(original.payload["rows"]!.arrayValue!, extra: true).validate(for: reorderedRequest, manifest: manifest) }
        var wrongMove = original.payload["rows"]!.arrayValue!
        altered = wrongMove[0].objectValue!; altered["moved"] = .bool(!(altered["moved"]!.boolValue!)); wrongMove[0] = .object(altered)
        try rejects("Reorder flags cannot contradict the source-order backbone") { try forged(wrongMove).validate(for: reorderedRequest, manifest: manifest) }
        let state = OfficeWorkspaceState(leftSectionID: "sheet1", rightSectionID: "sheet2", keyColumns: [1, 3], onlyDifferences: true)
        try check(state.isValid && (try JSONDecoder().decode(OfficeWorkspaceState.self, from: JSONEncoder().encode(state))) == state, "Workspace selection and composite-key settings round-trip")
        let manyLeft = (1...4000).map { row("l\($0)", $0, ["Item \($0)"]) }
        let manyRight = (1...4000).map { row("r\($0)", $0, ["Item \(4001 - $0)"]) }
        let many = try run(request(manyLeft, manyRight))
        try check(many.rows.count == 4000 && many.rows.allSatisfy { $0.status == .equal }, "Thousands of reordered rows match without a quadratic similarity matrix")
        let package = try PluginPackage.load(from: root.appendingPathComponent(".build-office-plugin-checks/Office.crossdiffplugin"))
        let process = try await PluginRunner.run(package: package, request: reorderedRequest, helperURL: root.appendingPathComponent(".build-office-plugin-checks/CrossDiffPluginHost"))
        try check(try OfficeComparisonResult.parse(process).rows == reordered.rows, "The real restricted helper preserves row alignment and original identities")
        let partial = PluginComparisonResult(runID: process.runID, schema: process.schema, status: .partial, summary: process.summary,
                                              diagnostics: process.diagnostics, payload: process.payload)
        try partial.validate(for: reorderedRequest, manifest: manifest)
        try check(try OfficeComparisonResult.parse(partial).partial, "A complete row snapshot can retain a partial document coverage declaration")
        let store = try PluginStore(root: root.appendingPathComponent(".build-office-plugin-checks/fixtures/store-\(UUID().uuidString)"))
        _ = try store.install(package)
        try check(store.list().contains { $0.id == "org.crossdiff.office" }, "Base can install the independent restricted Office package")
        print("Office plugin checks: \(count) passed")
    }
}
