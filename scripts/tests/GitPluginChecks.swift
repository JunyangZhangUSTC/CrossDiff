import Foundation
import JavaScriptCore
import CrossDiffCore

@main
private enum GitPluginChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var count = 0
    static var script = ""
    static let oidA = String(repeating: "a", count: 40)
    static let oidB = String(repeating: "b", count: 40)
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }; count += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { count += 1; return }; throw Failure(description: message)
    }
    static func entry(_ path: String, _ hash: String = oidA, mode: String = "100644") -> GitPluginEntry {
        GitPluginEntry(path: path, objectID: hash, mode: mode)
    }
    static func request(_ left: [GitPluginEntry], _ right: [GitPluginEntry], hints: [GitPluginRename] = [], commit: String = oidA) -> PluginComparisonRequest {
        PluginComparisonRequest(runID: "git-check", inputs: [
            .init(id: "left", role: .left, name: "main", content: GitPluginContract.content(commit: commit, entries: left)),
            .init(id: "right", role: .right, name: "feature", content: GitPluginContract.content(commit: commit, entries: right))
        ], options: ["renameHints": .array(hints.map(\.value))])
    }
    static func snapshotRequest(_ left: PluginJSONValue, _ right: PluginJSONValue) -> PluginComparisonRequest {
        PluginComparisonRequest(runID: "snapshot-check", inputs: [
            .init(id: "left", role: .left, name: "Source A", content: left),
            .init(id: "right", role: .right, name: "Source B", content: right)
        ])
    }
    static func alteredContent(_ source: PluginJSONValue, _ mutate: (inout [String: PluginJSONValue]) -> Void) -> PluginJSONValue {
        var content = source.objectValue!; mutate(&content); return .object(content)
    }
    static func compare(_ request: PluginComparisonRequest) throws -> PluginComparisonResult {
        guard let context = JSContext() else { throw Failure(description: "Cannot create JavaScriptCore") }
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() ?? "JS exception" }
        context.evaluateScript(script)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let literal = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
        let output = context.evaluateScript("JSON.stringify(compare(JSON.parse(\(literal))))")?.toString()
        if let exception { throw Failure(description: exception) }
        guard let output else { throw Failure(description: "Missing result") }
        return try JSONDecoder().decode(PluginComparisonResult.self, from: Data(output.utf8))
    }
    static func altered(_ result: PluginComparisonResult, _ mutate: (inout [String: PluginJSONValue]) -> Void) -> PluginComparisonResult {
        var payload = result.payload.objectValue!
        mutate(&payload)
        return PluginComparisonResult(runID: result.runID, schema: result.schema, summary: result.summary, payload: .object(payload))
    }
    static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1]), build = URL(fileURLWithPath: CommandLine.arguments[2])
            let package = try PluginPackage.load(from: build.appendingPathComponent("fixtures/Git.crossdiffplugin"))
            let manifest = package.manifest
            script = package.script!
            try expect(manifest.inputKind == .gitRepository && manifest.resultSchema == "crossdiff.git-tree/1", "Git has its own validated protocol")
            let input = request([
                entry("same.txt"), entry("edited.swift"), entry("gone.txt"), entry("mode.sh"),
                entry("kind"), entry("before/name.txt"), entry("link", mode: "120000"), entry("module", mode: "160000")
            ], [
                entry("same.txt"), entry("edited.swift", oidB), entry("new.txt"), entry("mode.sh", mode: "100755"),
                entry("kind", mode: "120000"), entry("after/name.txt", oidB), entry("link", mode: "120000"), entry("module", oidB, mode: "160000")
            ], hints: [.init(left: "before/name.txt", right: "after/name.txt")])
            let result = try compare(input)
            try result.validate(for: input, manifest: manifest)
            let parsed = try GitPluginValidatedResult.parse(result)
            let states = Dictionary(uniqueKeysWithValues: parsed.rows.map { ($0.path, $0.state) })
            try expect(states == ["same.txt": .unchanged, "edited.swift": .modified, "gone.txt": .deleted,
                "new.txt": .added, "mode.sh": .modified, "kind": .typeChanged, "after/name.txt": .renamed,
                "link": .unchanged, "module": .modified], "Real plugin classifies edit, rename, modes, symlinks, submodules and one-sided files")
            try expect(parsed.changedCount == 7 && parsed.counts["unchanged"] == 2, "Counts represent the actual classified files")
            try expect(parsed.rows.count == 9 && parsed.summary.en.contains("7 changes"), "User-facing summary reflects classifications")

            let empty = request([], [])
            let emptyResult = try compare(empty)
            try emptyResult.validate(for: empty, manifest: manifest)
            let emptyParsed = try GitPluginValidatedResult.parse(emptyResult)
            try expect(emptyParsed.changedCount == 0, "Empty trees are valid")

            let unusual = ["é.swift", "e\u{301}.swift", "folder/tab\tline\nfile", "folder/\\backslash", "中文/😀.txt", "-leading-option"]
            let unicode = request(unusual.map { entry($0) }, unusual.map { entry($0) })
            let unicodeResult = try compare(unicode)
            try unicodeResult.validate(for: unicode, manifest: manifest)
            try expect(unicodeResult.payload["rows"]?.arrayValue?.count == unusual.count, "Exact UTF-8 path identities and unusual filenames survive plugin comparison")
            let differentCanonical = request([entry("é")], [entry("e\u{301}")])
            let canonicalResult = try compare(differentCanonical)
            try canonicalResult.validate(for: differentCanonical, manifest: manifest)
            try expect(canonicalResult.payload["rows"]?.arrayValue?.count == 2, "Distinct canonical Git paths are not silently combined")
            let sha256 = String(repeating: "c", count: 64)
            let modern = request([entry("x", sha256)], [entry("x", sha256)], commit: sha256)
            try compare(modern).validate(for: modern, manifest: manifest)
            count += 1

            for path in ["", "/absolute", "..", "a/../b", "a/./b", "a//b", "a/", "a\0b", String(repeating: "界", count: 1366)] {
                let invalid = request([entry(path)], [])
                try rejects("Host accepted invalid path \(path.debugDescription)") { try invalid.validate(for: manifest) }
                try rejects("JS accepted invalid path \(path.debugDescription)") { _ = try compare(invalid) }
            }
            let invalidInputs = [
                request([entry("duplicate"), entry("duplicate")], []),
                request([entry("a"), entry("a/child")], []),
                request([entry("x", "bad")], []),
                request([entry("x", oidA.uppercased())], []),
                request([entry("x", mode: "040000")], []),
                request([entry("x", sha256)], []),
                request([entry("old")], [entry("new")], hints: [.init(left: "missing", right: "new")]),
                request([entry("old")], [entry("new", mode: "160000")], hints: [.init(left: "old", right: "new")]),
                request([entry("old")], [entry("new"), entry("old")], hints: [.init(left: "old", right: "new")]),
                request([entry("old"), entry("other")], [entry("new")], hints: [.init(left: "old", right: "new"), .init(left: "other", right: "new")])
            ]
            for invalid in invalidInputs {
                try rejects("Host accepted invalid tree or rename") { try invalid.validate(for: manifest) }
                try rejects("JS accepted invalid tree or rename") { _ = try compare(invalid) }
            }
            let unsupportedOption = PluginComparisonRequest(runID: "invalid-option", inputs: empty.inputs, options: ["command": .string("status")])
            try rejects("No arbitrary Git commands may cross the plugin contract") { try unsupportedOption.validate(for: manifest) }
            try rejects("Plugin must reject unknown options") { _ = try compare(unsupportedOption) }
            let oversize = request((0...GitPluginContract.maximumBatchEntries).map { entry("f\($0)") }, [])
            try rejects("Host must reject oversized individual batches") { try oversize.validate(for: manifest) }
            try rejects("Plugin must reject oversized individual batches") { _ = try compare(oversize) }

            let rows = result.payload["rows"]!.arrayValue!
            let malicious = [
                altered(result) { $0["rows"] = .array(Array(rows.dropLast())) },
                altered(result) { $0["rows"] = .array(rows + [rows[0]]) },
                altered(result) { value in
                    var changed = rows; var row = changed[0].objectValue!; row["state"] = .string("unchanged"); changed[0] = .object(row); value["rows"] = .array(changed)
                },
                altered(result) { value in
                    var changed = rows; var row = changed[0].objectValue!; row["right"] = .string("forged/path"); changed[0] = .object(row); value["rows"] = .array(changed)
                },
                altered(result) { value in var counts = value["counts"]!.objectValue!; counts["modified"] = .number(0); value["counts"] = .object(counts) },
                altered(result) { value in var counts = value["counts"]!.objectValue!; counts["unexpected"] = .number(1); value["counts"] = .object(counts) }
            ]
            for bad in malicious { try rejects("Forged plugin result must fail closed") { try bad.validate(for: input, manifest: manifest) } }
            let falsePairInput = request([entry("old")], [entry("new")])
            let falsePairResult = try compare(request([entry("old")], [entry("new")], hints: [.init(left: "old", right: "new")]))
            try rejects("Plugin cannot invent a rename without native evidence") { try falsePairResult.validate(for: falsePairInput, manifest: manifest) }
            let partial = PluginComparisonResult(runID: result.runID, schema: result.schema, status: .partial, summary: result.summary, payload: result.payload)
            try rejects("Partial Git results must not be treated as complete") { try partial.validate(for: input, manifest: manifest) }

            // Local state has captured snapshot identities, never fabricated commit hashes.
            let index = GitPluginContract.content(source: .index, snapshot: "index:fixture-v1", commit: nil,
                entries: [entry("tracked.swift"), entry("staged-only.txt")])
            let worktree = GitPluginContract.content(source: .workingTree, snapshot: "working-tree:fixture-v1", commit: nil,
                entries: [entry("tracked.swift", oidB), entry("untracked.txt")])
            let localInput = snapshotRequest(index, worktree)
            let localResult = try compare(localInput)
            try localResult.validate(for: localInput, manifest: manifest)
            let localParsed = try GitPluginValidatedResult.parse(localResult)
            try expect(localParsed.counts["modified"] == 1 && localParsed.counts["deleted"] == 1 && localParsed.counts["added"] == 1,
                "Index/worktree snapshots retain full modified, deleted and untracked coverage")
            try expect(localResult.payload["snapshots"]?["left"]?["source"] == .string("index")
                && localResult.payload["snapshots"]?["right"]?["source"] == .string("workingTree")
                && localResult.payload["snapshots"]?["left"]?["commit"] == .null
                && localResult.payload["snapshots"]?["right"]?["commit"] == .null,
                "Local sources are explicit and never masquerade as commits")
            let firstCommitBaseline = GitPluginContract.content(source: .commit, snapshot: "empty-head", commit: nil,
                emptyBaseline: true, entries: [])
            let firstCommit = snapshotRequest(firstCommitBaseline, index)
            let firstCommitResult = try compare(firstCommit)
            try firstCommitResult.validate(for: firstCommit, manifest: manifest)
            try expect(firstCommitResult.payload["counts"]?["added"] == .number(2)
                && firstCommitResult.payload["snapshots"]?["left"]?["commit"] == .null
                && firstCommitResult.payload["snapshots"]?["left"]?["emptyBaseline"] == .bool(true),
                "Unborn HEAD is an explicit empty baseline, not a synthetic commit")
            let newCommit = GitPluginContract.content(source: .commit, snapshot: "commit:" + oidA, commit: oidA,
                entries: [entry("tracked.swift")])
            let stagedInput = snapshotRequest(newCommit, index)
            let stagedResult = try compare(stagedInput)
            try stagedResult.validate(for: stagedInput, manifest: manifest)
            try expect(stagedResult.payload["counts"]?["unchanged"] == .number(1)
                && stagedResult.payload["counts"]?["added"] == .number(1), "Real commit and staging area share the tree comparison contract")
            let emptyIndex = GitPluginContract.content(source: .index, snapshot: "index:empty", commit: nil, entries: [])
            let emptyWorktree = GitPluginContract.content(source: .workingTree, snapshot: "working-tree:empty", commit: nil, entries: [])
            let emptyLocal = snapshotRequest(emptyIndex, emptyWorktree)
            try compare(emptyLocal).validate(for: emptyLocal, manifest: manifest)
            count += 1
            let legacyMixed = snapshotRequest(GitPluginContract.content(commit: oidA, entries: []), emptyIndex)
            let legacyResult = try compare(legacyMixed)
            try legacyResult.validate(for: legacyMixed, manifest: manifest)
            try expect(legacyResult.payload["snapshots"]?["left"]?["snapshot"] == .string("commit:" + oidA),
                "Legacy commit-only requests normalize to explicit committed snapshots")
            let localSHA256 = snapshotRequest(emptyIndex,
                GitPluginContract.content(source: .workingTree, snapshot: "sha256-local", commit: nil, entries: [entry("x", sha256)]))
            try compare(localSHA256).validate(for: localSHA256, manifest: manifest)
            count += 1

            let malformedSnapshots = [
                alteredContent(index) { $0["source"] = .string("repository") },
                alteredContent(index) { $0.removeValue(forKey: "snapshot") },
                alteredContent(index) { $0["snapshot"] = .string("") },
                alteredContent(index) { $0["snapshot"] = .string(String(repeating: "x", count: 257)) },
                alteredContent(index) { $0["snapshot"] = .string("line\nidentity") },
                alteredContent(index) { $0.removeValue(forKey: "emptyBaseline") },
                alteredContent(index) { $0["emptyBaseline"] = .string("false") },
                alteredContent(index) { $0["commit"] = .string(oidA) },
                alteredContent(worktree) { $0["commit"] = .string(oidA) },
                alteredContent(newCommit) { $0["commit"] = .null },
                alteredContent(newCommit) { $0["commit"] = .string("HEAD") },
                alteredContent(newCommit) { $0["emptyBaseline"] = .bool(true) },
                alteredContent(firstCommitBaseline) { $0["entries"] = .array([entry("fake-baseline").value]) },
                alteredContent(emptyIndex) { $0["emptyBaseline"] = .bool(true) },
                alteredContent(index) { $0["remoteURL"] = .string("https://example.invalid/repo.git") },
                alteredContent(GitPluginContract.content(commit: oidA, entries: [])) { $0["snapshot"] = .string("missing-source") }
            ]
            for content in malformedSnapshots {
                let invalid = snapshotRequest(content, emptyWorktree)
                try rejects("Host accepted malformed snapshot metadata") { try invalid.validate(for: manifest) }
                try rejects("Plugin accepted malformed snapshot metadata") { _ = try compare(invalid) }
            }
            let mixedFormatLocal = snapshotRequest(index,
                GitPluginContract.content(source: .workingTree, snapshot: "mixed", commit: nil, entries: [entry("x", sha256)]))
            try rejects("Local snapshots must use a single Git object format") { try mixedFormatLocal.validate(for: manifest) }
            try rejects("JS must reject mixed object formats for local snapshots") { _ = try compare(mixedFormatLocal) }
            for (field, badValue) in [("source", PluginJSONValue.string("commit")), ("snapshot", .string("index:stale")),
                                      ("commit", .string(oidA)), ("emptyBaseline", .bool(true)), ("extra", .bool(true))] {
                let forged = altered(localResult) { payload in
                    var snapshots = payload["snapshots"]!.objectValue!
                    var left = snapshots["left"]!.objectValue!; left[field] = badValue
                    snapshots["left"] = .object(left); payload["snapshots"] = .object(snapshots)
                }
                try rejects("Result snapshot source/identity must match the originating request") {
                    try forged.validate(for: localInput, manifest: manifest)
                }
            }
            let missingSnapshot = altered(localResult) { $0.removeValue(forKey: "snapshots") }
            try rejects("Every result must bind both snapshot identities") { try missingSnapshot.validate(for: localInput, manifest: manifest) }
            let missingSide = altered(localResult) { payload in
                var snapshots = payload["snapshots"]!.objectValue!; snapshots.removeValue(forKey: "right")
                payload["snapshots"] = .object(snapshots)
            }
            try rejects("Omitted right snapshot identity must fail") { try missingSide.validate(for: localInput, manifest: manifest) }
            let localOmission = altered(localResult) { payload in
                payload["rows"] = .array(Array(payload["rows"]!.arrayValue!.dropFirst()))
            }
            try rejects("Local results require complete source coverage") { try localOmission.validate(for: localInput, manifest: manifest) }
            let exactIdentity = snapshotRequest(alteredContent(emptyIndex) { $0["snapshot"] = .string("é") }, emptyWorktree)
            let exactResult = try compare(exactIdentity)
            let changedCanonicalIdentity = altered(exactResult) { payload in
                var snapshots = payload["snapshots"]!.objectValue!, left = snapshots["left"]!.objectValue!
                left["snapshot"] = .string("e\u{301}"); snapshots["left"] = .object(left); payload["snapshots"] = .object(snapshots)
            }
            try rejects("Snapshot identity binding uses bytes, not Unicode normalization") {
                try changedCanonicalIdentity.validate(for: exactIdentity, manifest: manifest)
            }
            let localHelper = try await PluginRunner.run(package: package, request: localInput,
                helperURL: build.appendingPathComponent("CrossDiffPluginHost"))
            try expect(localHelper.payload == localResult.payload, "Actual restricted helper validates local snapshot comparisons")

            let throughHelper = try await PluginRunner.run(package: package, request: input,
                helperURL: build.appendingPathComponent("CrossDiffPluginHost"))
            try expect(throughHelper.payload == result.payload, "Restricted child runtime produces the same validated result")
            let large = request((0..<GitPluginContract.maximumBatchEntries).map { entry("src/file-\($0).swift") }, (0..<GitPluginContract.maximumBatchEntries).map { entry("src/file-\($0).swift", $0 % 5 == 0 ? oidB : oidA) })
            let largeResult = try await PluginRunner.run(package: package, request: large,
                helperURL: build.appendingPathComponent("CrossDiffPluginHost"))
            let largeParsed = try GitPluginValidatedResult.parse(largeResult)
            try expect(largeParsed.changedCount == 26, "A full batch classifies completely in bounded helper runtime")
            try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Plugins/Official/Git/manifest.json").path), "Fixture package corresponds to project source")
            print("PASS \(count) Git plugin checks")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
