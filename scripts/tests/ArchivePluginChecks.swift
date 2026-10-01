import Foundation
import JavaScriptCore
import CrossDiffCore

@main
private enum ArchivePluginChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static var script = ""
    static let hashA = String(repeating: "a", count: 64)
    static let hashB = String(repeating: "b", count: 64)
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }; count += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { count += 1; return }; throw Failure(description: message)
    }
    static func manifest(input: String = "archiveCatalog", view: String = "archiveTree", modes: [String] = ["pairwise"]) throws -> PluginManifest {
        let value: [String: Any] = ["id": "org.example.archive", "version": "0.1.0", "name": ["zhHans": "归档", "en": "Archive"],
            "summary": ["zhHans": "比较归档", "en": "Compare archives"], "runtime": "restrictedJavaScript", "inputKind": input,
            "fileExtensions": ["zip", "tar"], "resultView": view, "supportedModes": modes, "minHostProtocol": 1, "maxHostProtocol": 1]
        return try JSONDecoder().decode(PluginManifest.self, from: JSONSerialization.data(withJSONObject: value))
    }
    static func entry(_ path: String, kind: String = "file", hash: String? = hashA, size: Any = 3, verified: Bool = true) -> [String: Any] {
        ["id": path, "path": path, "kind": kind, "size": size, "sha256": hash.map { $0 as Any } ?? NSNull(), "contentState": verified ? "verified" : "unverified"]
    }
    static func request(_ left: [[String: Any]], _ right: [[String: Any]], complete: Bool = true) -> [String: Any] {
        ["protocolVersion": 1, "runID": "archive-check", "mode": "pairwise", "options": [:], "inputs": [
            ["id": "l", "name": "left.zip", "role": "left", "content": ["listingComplete": complete, "entries": left]],
            ["id": "r", "name": "right.tar", "role": "right", "content": ["listingComplete": true, "entries": right]]]]
    }
    static func directory(_ path: String) -> [String: Any] { entry(path, kind: "directory", hash: nil, size: 0) }
    static func compare(_ request: [String: Any]) throws -> PluginComparisonResult {
        guard let context = JSContext() else { throw Failure(description: "Cannot create JavaScriptCore") }
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() ?? "JS exception" }
        context.evaluateScript(script)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), as: UTF8.self)
        let literal = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        let output = context.evaluateScript("JSON.stringify(compare(JSON.parse(\(literal))))")?.toString()
        if let exception { throw Failure(description: exception) }
        guard let output else { throw Failure(description: "No JS result") }
        return try JSONDecoder().decode(PluginComparisonResult.self, from: Data(output.utf8))
    }
    static func states(_ result: PluginComparisonResult) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (result.payload["pairs"]?.arrayValue ?? []).map { pair in
            (pair["left"]?.stringValue ?? pair["right"]?.stringValue ?? "missing", pair["state"]?.stringValue ?? "missing")
        })
    }
    static func main() async {
        do {
            let archive = try manifest()
            try archive.validate()
            try expect(archive.resultSchema == "crossdiff.archive-tree/1", "Archive manifest must resolve its specific result schema")
            try rejects("Text must not declare the archive tree renderer") { try manifest(input: "text").validate() }
            try rejects("Archive input must not fall through to the text table reader") { try manifest(view: "table").validate() }
            try rejects("Archive input must reject unsupported three-way mode") { try manifest(modes: ["pairwise", "threeWayMerge"]).validate() }
            try manifest(input: "pdf", view: "documentPages").validate()
            try manifest(input: "text", view: "table").validate()
            script = try String(contentsOfFile: CommandLine.arguments[1] + "/Plugins/Official/Archive/compare.js", encoding: .utf8)
            let result = try compare(request([entry("same"), entry("edit"), entry("gone"), entry("type")],
                [entry("same"), entry("edit", hash: hashB), entry("new"), entry("type", kind: "directory", hash: nil, size: 0)]))
            try expect(states(result) == ["same": "same", "edit": "changed", "gone": "removed", "new": "added", "type": "typeChanged"], "Path classification must use content hashes and kinds")
            try expect(result.runID == "archive-check" && result.status == .completed, "Result identity and completed status")
            let grouped = try compare(request([entry("old"), entry("copy"), entry("onlySame", hash: hashB)], [entry("new"), entry("onlySame", hash: hashB)]))
            try expect(grouped.payload["sameContentGroups"] == .array([.object(["left": .array([.string("copy"), .string("old")]), "right": .array([.string("new")])])]), "Groups must contain complete same-content cohorts and exclude same-path-only pairs")
            let treeLeft = [directory("root"), directory("root/sub"), entry("root/sub/file"), directory("empty"), entry("unknown", hash: nil, size: NSNull(), verified: false)]
            let treeRight = [directory("root"), directory("root/sub"), entry("root/sub/file", hash: hashB), directory("empty"), directory("unknown")]
            let tree = try compare(request(treeLeft, treeRight))
            try expect(states(tree)["root"] == "changed" && states(tree)["root/sub"] == "changed" && states(tree)["empty"] == "same", "Changed descendants propagate to all parent directories")
            try expect(states(tree)["unknown"] == "unknown" && tree.status == .partial, "Unverified content has priority over kind changes")
            let unknownChild = try compare(request([directory("d"), directory("d/n"), entry("d/n/link", kind: "symbolicLink", hash: nil, size: NSNull(), verified: false)], [directory("d"), directory("d/n")]))
            try expect(states(unknownChild).values.allSatisfy { $0 == "unknown" }, "One-sided unverified link propagates unknown to all matching parents")
            let equivalent = try compare(request([entry("e\u{301}")], [entry("é")]))
            try expect(equivalent.payload["pairs"]?.arrayValue?.count == 1 && states(equivalent).values.first == "same", "Canonical-equivalent Unicode paths match without changing source IDs")
            let incomplete = try compare(request([], [entry("maybe")], complete: false))
            try expect(states(incomplete)["maybe"] == "unknown" && incomplete.status == .partial, "Incomplete listing cannot prove a one-sided addition")
            for path in ["", "/absolute", "../outside", "a/../b", "a/./b", "a//b", "a/", "C:drive", "a\\b", "a\0b", String(repeating: "界", count: 1366)] {
                try rejects("Invalid normalized path accepted: \(path.debugDescription)") { _ = try compare(request([entry(path)], [])) }
            }
            try rejects("Canonical duplicate IDs must not disappear in a dictionary") { _ = try compare(request([entry("é"), entry("e\u{301}")], [])) }
            try rejects("Missing ancestor directory must not create an incomplete tree") { _ = try compare(request([entry("missing/file")], [])) }
            try rejects("File cannot be an ancestor") { _ = try compare(request([entry("a"), entry("a/file")], [])) }
            for (field, badValue) in [("id", "different" as Any), ("kind", "unsupported"), ("contentState", "maybe"), ("size", -1), ("size", 1.5), ("size", 9007199254740992.0), ("size", NSNull()), ("sha256", "bad"), ("sha256", hashA.uppercased()), ("sha256", NSNull())] {
                var invalid = entry("file"); invalid[field] = badValue
                try rejects("Invalid entry field accepted: \(field)=\(badValue)") { _ = try compare(request([invalid], [])) }
            }
            try rejects("Links cannot claim verified content") { _ = try compare(request([entry("link", kind: "hardLink")], [])) }
            try rejects("Directories cannot carry a file digest") { _ = try compare(request([entry("dir", kind: "directory", size: 0)], [])) }
            try rejects("Entry count over budget must fail") { _ = try compare(request((0...10000).map { entry("file\($0)") }, [])) }
            var badMode = request([], []); badMode["mode"] = "multiSubject"
            try rejects("Unsupported modes must not compare only the first pair") { _ = try compare(badMode) }
            var badProtocol = request([], []); badProtocol["protocolVersion"] = 2
            try rejects("Protocol mismatch must fail") { _ = try compare(badProtocol) }
            var badRoles = request([], []); var roleInputs = badRoles["inputs"] as! [[String: Any]]; roleInputs[1]["role"] = "left"; badRoles["inputs"] = roleInputs
            try rejects("Duplicate roles must fail") { _ = try compare(badRoles) }
            let shuffled = try compare(request(Array(treeLeft.reversed()), Array(treeRight.reversed())))
            try expect(shuffled == tree, "Output is independent of input enumeration order")
            var reversedRoles = request(treeLeft, treeRight); reversedRoles["inputs"] = Array((reversedRoles["inputs"] as! [[String: Any]]).reversed())
            let reversedResult = try compare(reversedRoles)
            try expect(reversedResult == tree, "Input roles, not array positions, define left and right")
            let differentSize = try compare(request([entry("file", size: 1)], [entry("file", size: 2)]))
            try expect(states(differentSize)["file"] == "changed" && differentSize.payload["sameContentGroups"]?.arrayValue?.isEmpty == true, "Size is part of content identity even when digests match")
            let emptyHash = PluginPackage.digest(of: Data())
            let emptyFiles = try compare(request([entry("empty-left", hash: emptyHash, size: 0)], [entry("empty-right", hash: emptyHash, size: 0)]))
            try expect(emptyFiles.payload["sameContentGroups"]?.arrayValue?.count == 1, "Empty files also form content groups")
            for kind in ["symbolicLink", "hardLink", "other"] {
                let unsupported = try compare(request([entry("entry", kind: kind, hash: nil, size: NSNull(), verified: false)], []))
                try expect(states(unsupported)["entry"] == "unknown" && unsupported.status == .partial && unsupported.payload["sameContentGroups"]?.arrayValue?.isEmpty == true, "Non-regular entries never claim equality or verified removal")
            }
            let packageURL = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("fixtures/Archive.crossdiffplugin")
            let package = try PluginPackage.load(from: packageURL)
            try expect(package.script == script && package.manifest.id == "org.crossdiff.archive", "Packaged algorithm and official identity match source")
            let wire = try JSONDecoder().decode(PluginComparisonRequest.self, from: JSONSerialization.data(withJSONObject: request(treeLeft, treeRight)))
            let runtime = try await PluginRunner.run(package: package, request: wire, helperURL: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("CrossDiffPluginHost"))
            try expect(runtime == tree, "Real child runner produces the same verified protocol result")
            let many = (0..<10000).map { entry(String(format: "file%05d", $0)) }
            let manyRequest = try JSONDecoder().decode(PluginComparisonRequest.self, from: JSONSerialization.data(withJSONObject: request(many, many)))
            let started = Date()
            let manyResult = try await PluginRunner.run(package: package, request: manyRequest, helperURL: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("CrossDiffPluginHost"))
            let cohorts = manyResult.payload["sameContentGroups"]?.arrayValue ?? []
            try expect(manyResult.payload["pairs"]?.arrayValue?.count == 10000 && cohorts.count == 1
                && cohorts[0]["left"]?.arrayValue?.count == 10000 && cohorts[0]["right"]?.arrayValue?.count == 10000,
                "Maximum-size duplicate cohorts have linear references, not Cartesian pairs")
            print(String(format: "10,000 entries per side via child runner: %.3fs", Date().timeIntervalSince(started)))
            print("PASS: \(count) archive plugin checks")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
