import Foundation
import JavaScriptCore
import CrossDiffCore

@main enum APIPluginChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }; count += 1
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { count += 1; return }; throw Failure(description: message)
    }
    static func field(_ key: String, _ type: String = "string", _ value: String, sensitive: Bool = false) -> PluginJSONValue {
        .object(["key": .string(key), "label": .string(key), "type": .string(type), "value": .string(value), "sensitive": .bool(sensitive)])
    }
    static func content(_ sections: [(String, [PluginJSONValue])]) -> PluginJSONValue {
        .object(["sections": .array(sections.map { .object(["id": .string($0.0), "label": .object(["zhHans": .string("测试"), "en": .string("Test")]), "fields": .array($0.1)]) }), "diagnostics": .array([])])
    }
    static func request(_ left: PluginJSONValue, _ right: PluginJSONValue, options: [String:PluginJSONValue] = [:]) -> PluginComparisonRequest {
        .init(runID: "api-check", inputs: [.init(id: "l", role: .left, name: "left", content: left), .init(id: "r", role: .right, name: "right", content: right)], options: options)
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let package = try PluginPackage.load(from: root.appendingPathComponent(".build-api-plugin-checks/API.crossdiffplugin"))
        try check(package.manifest.id == "org.crossdiff.api" && package.manifest.inputKind == .httpExchange, "Dedicated API package and input")
        let context = JSContext()!; var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(package.script!)
        func run(_ req: PluginComparisonRequest) throws -> APIComparisonResult {
            try req.validate(for: package.manifest); exception = nil
            let input = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req))
            guard let object = context.objectForKeyedSubscript("compare")?.call(withArguments: [input])?.toDictionary(), exception == nil else {
                throw Failure(description: exception ?? "No result")
            }
            let result = try JSONDecoder().decode(PluginComparisonResult.self, from: JSONSerialization.data(withJSONObject: object))
            try result.validate(for: req, manifest: package.manifest)
            return try APIComparisonResult.parse(result)
        }
        let left = content([("response.body", [field("$state", "bodyState", "json"), field("", "object", ""), field("/age", "number", "25"), field("/id", "number", "9007199254740992"), field("/null", "null", "null")])])
        let right = content([("response.body", [field("$state", "bodyState", "json"), field("", "object", ""), field("/id", "number", "9007199254740993"), field("/age", "string", "25"), field("/new", "null", "null")])])
        let result = try run(request(left, right))
        try check(result.rows.first { $0.path == "/age" }?.state == .changed, "JSON type change is visible")
        try check(result.rows.first { $0.path == "/id" }?.state == .changed, "Large numeric lexemes retain precision")
        try check(result.rows.first { $0.path == "/null" }?.state == .removed && result.rows.first { $0.path == "/new" }?.state == .added, "Missing remains distinct from null")
        try check(!result.partial, "Small complete result is not partial")
        let processResult = try await PluginRunner.run(package: package, request: request(left, right), helperURL: root.appendingPathComponent(".build-api-plugin-checks/CrossDiffPluginHost"))
        let fromProcess = try APIComparisonResult.parse(processResult)
        try check(fromProcess.rows == result.rows, "Restricted subprocess runs the real API algorithm and preserves typed changes")
        let importedLeft = try APIImporter.parse("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"id\":9007199254740992,\"token\":\"first\",\"array\":[1,2]}").exchanges[0]
        let importedRight = try APIImporter.parse("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n{\"array\":[2,1],\"token\":\"second\",\"id\":9007199254740993}").exchanges[0]
        let imported = try await PluginRunner.run(package: package, request: request(importedLeft.pluginContent, importedRight.pluginContent), helperURL: root.appendingPathComponent(".build-api-plugin-checks/CrossDiffPluginHost"))
        let importedRows = try APIComparisonResult.parse(imported).rows
        try check(importedRows.first { $0.path == "/id" }?.state == .changed && importedRows.first { $0.path == "/array/0" }?.state == .changed, "Real HTTP import reaches helper with exact large numbers and ordered arrays")
        try check(importedRows.first { $0.path == "/token" }?.sensitive == true && importedRows.first { $0.path == "/content-type/0" }?.state == .same, "Imported credentials are marked and header name casing is ignored")
        let flagLeft = try APIImporter.parse("curl 'https://example.test/path?flag&x=1&x=2'").exchanges[0]
        let flagRight = try APIImporter.parse("curl 'https://example.test/path?flag=&x=1&x=3'").exchanges[0]
        let flagRows = try run(request(flagLeft.pluginContent, flagRight.pluginContent)).rows
        try check(flagRows.first { $0.path == "/flag/0" }?.state == .changed && flagRows.first { $0.path == "/x/1" }?.state == .changed, "Query flags and repeated occurrences retain distinctions through cURL import")
        let unicodeA = content([("response.body", [field("/name", "string", "é"), field("/é", "number", "1"), field("/e\u{0301}", "number", "2")])])
        let unicodeB = content([("response.body", [field("/name", "string", "e\u{0301}"), field("/é", "number", "1"), field("/e\u{0301}", "number", "3")])])
        let unicodeProcess = try await PluginRunner.run(package: package, request: request(unicodeA, unicodeB), helperURL: root.appendingPathComponent(".build-api-plugin-checks/CrossDiffPluginHost"))
        let unicodeRows = try APIComparisonResult.parse(unicodeProcess).rows
        try check(unicodeRows.count == 3 && unicodeRows.first { $0.path == "/name" }?.state == .changed, "Canonical-equivalent Unicode values remain a valid exact difference through the helper and validator")
        try check(unicodeRows.filter { $0.state == .changed }.count == 2, "Canonical-equivalent JSON pointer spellings remain distinct keys")
        let headersA = content([("request.headers", [field("/authorization/0", "string", "Bearer secret", sensitive: true), field("/accept/0", "string", "a"), field("/accept/1", "string", "b")])])
        let headersB = content([("request.headers", [field("/accept/0", "string", "a"), field("/accept/1", "string", "c"), field("/authorization/0", "string", "Bearer other", sensitive: true)])])
        let headers = try run(request(headersA, headersB, options: ["ignoreHeaders": .array([.string("AUTHORIZATION")])]))
        try check(headers.rows.first { $0.path == "/authorization/0" }?.state == .ignored, "Header ignore is case insensitive")
        try check(headers.rows.first { $0.path == "/authorization/0" }?.sensitive == true, "Credential markings preserved")
        try check(headers.rows.first { $0.path == "/accept/0" }?.state == .same && headers.rows.first { $0.path == "/accept/1" }?.state == .changed, "Header order independent while repetitions remain ordered")
        let bodyA = content([("request.body", [field("/user", "object", ""), field("/user/token", "string", "a"), field("/user2", "string", "a"), field("/a~1b/0", "number", "1")])])
        let bodyB = content([("request.body", [field("/user", "object", ""), field("/user/token", "string", "b"), field("/user2", "string", "b"), field("/a~1b/0", "number", "2")])])
        let ignored = try run(request(bodyA, bodyB, options: ["ignoreJSONPointers": .array([.string("/user"), .string("/a~1b")])]))
        try check(ignored.rows.first { $0.path == "/user/token" }?.state == .ignored && ignored.rows.first { $0.path == "/user2" }?.state == .changed, "Pointer subtree respects segment boundaries")
        try check(ignored.rows.first { $0.path == "/a~1b/0" }?.state == .ignored, "Escaped pointer matches escaped keys")
        for value in ["missing", "unsupported"] {
            let unknown = content([("response.body", [field("$state", "bodyState", value)])])
            try check(try run(request(unknown, unknown)).rows.first?.state == .unknown, "Unavailable bodies never compare equal")
        }
        let absentBody = content([("response.body", [field("$state", "bodyState", "missing")])])
        let uncertain = try run(request(absentBody, right))
        try check(uncertain.rows.allSatisfy { $0.state == .unknown }, "Missing body makes its entire field comparison unknown rather than claiming additions")
        try rejects("Invalid pointer rule rejected") { _ = try run(request(left, right, options: ["ignoreJSONPointers": .array([.string("/a~2b")])])) }
        try rejects("Invalid header rule rejected") { _ = try run(request(left, right, options: ["ignoreHeaders": .array([.string("Bad Header")])])) }
        let duplicate = content([("request.headers", [field("/a/0", "string", "1"), field("/a/0", "string", "2")])])
        try rejects("Duplicate keys rejected") { _ = try run(request(duplicate, duplicate)) }
        let proto = content([("request.body", [field("/__proto__", "string", "safe"), field("/constructor", "string", "safe")])])
        try check(try run(request(proto, proto)).rows.allSatisfy { $0.state == .same }, "Prototype-like paths remain normal data")
        let manyA = content([("request.body", (0..<4000).map { field("/a\($0)", "string", "a") })])
        let manyB = content([("request.body", (0..<4000).map { field("/b\($0)", "string", "b") })])
        let limited = try run(request(manyA, manyB))
        try check(limited.partial && limited.rows.count <= 5000 && limited.diagnostics.contains { $0.en.contains("limit") }, "Large union explicitly reports partial without false totals")
        try check(APIWorkspaceState(ignoreJSONPointers: ["/é"]) != APIWorkspaceState(ignoreJSONPointers: ["/e\u{0301}"]), "Unicode-distinct pointer rules trigger state changes")
        let state = APIWorkspaceState(leftEntryID: "1", ignoreHeaders: ["Date"], ignoreJSONPointers: ["/timestamp"])
        try check(state.isValid && (try JSONDecoder().decode(APIWorkspaceState.self, from: JSONEncoder().encode(state))) == state, "Selection and explicit rules persist")
        let session = StoredComparison(kind: "plugin", left: .init(text: "local request"), right: .init(text: "local response"), pluginID: package.manifest.id, apiState: state)
        let roundtrip = try JSONDecoder().decode(StoredComparison.self, from: JSONEncoder().encode(session))
        try check(roundtrip.apiState == state, "Workspace session retains selected entries and explicit rules")
        let invalidRow: PluginJSONValue = .object(["id": .string("fake"), "section": .string("response.body"), "path": .string("$state"), "label": .string("body"), "left": .string("missing"), "right": .string("missing"), "leftType": .string("bodyState"), "rightType": .string("bodyState"), "state": .string("same"), "sensitive": .bool(false)])
        let invalidResult = PluginComparisonResult(runID: "api-check", schema: "crossdiff.api-exchange/1", summary: .init(zhHans: "测试", en: "Test"), payload: .object(["rows": .array([invalidRow]), "partial": .bool(false)]))
        try rejects("Result validation rejects a plugin falsely marking unavailable bodies same") { try invalidResult.validate(for: request(left, right), manifest: package.manifest) }
        let partialMismatch = PluginComparisonResult(runID: "api-check", schema: "crossdiff.api-exchange/1", summary: .init(zhHans: "测试", en: "Test"), payload: .object(["rows": .array([]), "partial": .bool(true)]))
        try rejects("Partial status cannot contradict payload") { try partialMismatch.validate(for: request(left, right), manifest: package.manifest) }
        let original = try package.encoded(); var tampered = try JSONSerialization.jsonObject(with: original) as! [String:Any]
        tampered["script"] = "function compare(){return null;}"
        try rejects("Modified plugin digest rejected") { _ = try PluginPackage.decode(data: JSONSerialization.data(withJSONObject: tampered)) }
        let storeURL = root.appendingPathComponent(".build-api-plugin-checks/fixtures/store-\(UUID().uuidString)")
        let store = try PluginStore(root: storeURL)
        _ = try store.install(package)
        try check(store.list().contains { $0.id == package.manifest.id }, "Base can install independent official API package")
        print("API plugin checks: \(count) passed")
    }
}
