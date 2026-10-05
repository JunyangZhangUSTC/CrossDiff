import Foundation
@testable import CrossDiffCore

// Only menu presentation is stubbed. The adapter, PluginExecution, Runner, helper,
// package validation and request/result validation are production implementations.
@MainActor final class NativeMenuController {
    static let shared = NativeMenuController()
    func showPlugins(_ sender: Any?) { }
}

private final class BatchProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []
    func record(_ completed: Int, _ total: Int) { lock.lock(); values.append((completed, total)); lock.unlock() }
    var samples: [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return values }
}

@main private enum GitPluginBatchChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }; checks += 1
    }
    static func entry(_ path: String, hash: String = a) -> GitTreeEntry {
        GitTreeEntry(path: path, objectID: hash, mode: "100644", size: 10, kind: .blob)
    }
    static func snapshot(_ source: GitComparisonSource, _ entries: [GitTreeEntry]) -> GitComparisonSnapshot {
        GitComparisonSnapshot(source: source, commit: nil, identity: source == .index ? "index:batch-check" : "working-tree:batch-check",
            entries: entries, isEmptyBaseline: false, repositoryPath: "unused-fixture-repository", workingFiles: [:],
            rootStamp: nil, indexBackedPaths: [])
    }
    static func sourceComparison(_ files: [GitFileChange], left: [GitTreeEntry]? = nil, right: [GitTreeEntry]? = nil) -> GitSourceComparison {
        GitSourceComparison(leftSnapshot: snapshot(.index, left ?? files.compactMap(\.left)),
            rightSnapshot: snapshot(.workingTree, right ?? files.compactMap(\.right)), files: files, mergeBaseObjectID: nil)
    }
    static func committed(_ files: [GitFileChange]) -> GitComparison {
        GitComparison(leftCommit: GitCommit(objectID: a, subject: "Left", author: "Fixture", date: Date(timeIntervalSince1970: 0)),
            rightCommit: GitCommit(objectID: b, subject: "Right", author: "Fixture", date: Date(timeIntervalSince1970: 0)),
            leftTree: files.compactMap(\.left), rightTree: files.compactMap(\.right), files: files, mergeBaseObjectID: nil)
    }
    static func files(_ total: Int) -> [GitFileChange] {
        (0..<total).map { index in
            // Renames straddle multiple boundaries in independently ordered source trees,
            // yet a complete left/right file pair must always enter a single helper request.
            let renamed = index % 128 == 127
            let changed = !renamed && index % 3 == 0
            let old = entry(renamed ? "old/renamed-\(index).swift" : "Sources/file-\(index).swift")
            let new = entry(renamed ? "new/renamed-\(index).swift" : old.path, hash: changed ? b : a)
            return GitFileChange(left: old, right: new, kind: renamed ? .renamed : changed ? .modified : .unchanged,
                similarity: renamed ? 100 : nil)
        }
    }
    static func execution(_ package: PluginPackage, helper: URL, append script: String = "") -> PluginExecution {
        let script = package.script! + script
        let custom = PluginPackage(manifest: package.manifest, script: script, sha256: PluginPackage.digest(of: Data(script.utf8)))
        return PluginExecution(package: custom, helperURL: helper, executableURL: nil, approvedDigest: nil)
    }
    static func rejects(_ description: String, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { checks += 1; return }
        throw Failure(description: description)
    }
    static func main() async {
        do {
            let build = URL(fileURLWithPath: CommandLine.arguments[1])
            let package = try PluginPackage.load(from: build.appendingPathComponent("fixtures/Git.crossdiffplugin"))
            let helper = build.appendingPathComponent("CrossDiffPluginHost")
            let run = execution(package, helper: helper)
            let many = files(50_513)
            let progress = BatchProgress(), began = Date()
            let comparison = sourceComparison(many, right: many.compactMap(\.right).reversed())
            let result = try await GitPluginComparison.compare(comparison, execution: run, progress: { progress.record($0, $1) })
            try expect(result.rows.count == many.count, "More than 50,000 files finish without a total repository limit")
            let counts = Dictionary(grouping: many, by: { $0.kind.rawValue }).mapValues(\.count)
            try expect(result.counts.allSatisfy { $0.value == counts[$0.key, default: 0] }, "Global counts include every verified batch")
            try expect(zip(result.rows, many).allSatisfy { row, original in
                row.left == original.left?.path && row.right == original.right?.path && row.state.rawValue == original.kind.rawValue
            }, "All source identities and rename pairs survive batching in native tree order")
            try expect(progress.samples.count == (many.count + GitPluginContract.maximumBatchEntries - 1) / GitPluginContract.maximumBatchEntries
                && progress.samples.last?.0 == many.count && progress.samples.allSatisfy { $0.1 == many.count },
                "Progress records complete helper-validated batches only")
            print("PASS: \(many.count) files / \(progress.samples.count) real helper invocations in \(String(format: "%.2f", Date().timeIntervalSince(began)))s")

            let historical = try await GitPluginComparison.compare(committed(Array(many.prefix(400))), execution: run)
            try expect(historical.rows.count == 400 && historical.counts["renamed"] == 3, "Commit-only API uses the same multi-batch pipeline")
            let emptyProgress = BatchProgress()
            let empty = try await GitPluginComparison.compare(sourceComparison([]), execution: run, progress: { emptyProgress.record($0, $1) })
            try expect(empty.rows.isEmpty && emptyProgress.samples.count == 1, "Empty snapshots still execute a validated helper batch")
            let emptyForged = execution(package, helper: helper, append: "\nconst actual = compare; compare = request => { throw new Error('empty still runs'); };\n")
            try await rejects("Empty comparisons cannot bypass plugin execution") {
                _ = try await GitPluginComparison.compare(sourceComparison([]), execution: emptyForged)
            }

            let widest = (0..<GitPluginContract.maximumBatchEntries).map { index -> GitFileChange in
                let prefix = "long-\(index)-", path = prefix + String(repeating: "\u{0001}", count: 4096 - prefix.utf8.count)
                let source = entry(path)
                return GitFileChange(left: source, right: entry(path, hash: b), kind: .modified, similarity: nil)
            }
            let longResult = try await GitPluginComparison.compare(sourceComparison(widest), execution: run)
            try expect(longResult.rows.count == widest.count && longResult.counts["modified"] == widest.count,
                "Worst-case 4096-byte JSON-escaped paths fit existing helper input/output limits")

            let small = Array(many.prefix(300)), l = small.compactMap(\.left), r = small.compactMap(\.right)
            try await rejects("Duplicate source use across batches must fail") {
                _ = try await GitPluginComparison.compare(sourceComparison(small + [small[0]], left: l, right: r), execution: run)
            }
            try await rejects("Global omitted source must fail") {
                _ = try await GitPluginComparison.compare(sourceComparison(Array(small.dropLast()), left: l, right: r), execution: run)
            }
            try await rejects("Duplicate tree metadata cannot disappear across batches") {
                _ = try await GitPluginComparison.compare(sourceComparison(small, left: l + [l[0]], right: r), execution: run)
            }
            var split = Array(small.dropFirst())
            split.insert(GitFileChange(left: small[0].left, right: nil, kind: .deleted, similarity: nil), at: 0)
            split.append(GitFileChange(left: nil, right: small[0].right, kind: .added, similarity: nil))
            let splitComparison = sourceComparison(split, left: l, right: r)
            try await rejects("Same-path pairs cannot be split into false addition/deletion batches") {
                _ = try await GitPluginComparison.compare(splitComparison, execution: run)
            }
            let ancestorEntries = [entry("parent"), entry("parent/child")]
            let ancestorFiles = ancestorEntries.map { GitFileChange(left: $0, right: $0, kind: .unchanged, similarity: nil) }
            try await rejects("Implicit directories cannot collide with files in global source coverage") {
                _ = try await GitPluginComparison.compare(sourceComparison([ancestorFiles[0]] + small + [ancestorFiles[1]]), execution: run)
            }
            let sha256 = entry("later-sha256", hash: String(repeating: "c", count: 64))
            try await rejects("Different object formats cannot hide in separate batches") {
                _ = try await GitPluginComparison.compare(sourceComparison(small + [GitFileChange(left: sha256, right: sha256, kind: .unchanged, similarity: nil)]), execution: run)
            }

            let failureProgress = BatchProgress()
            let forged = execution(package, helper: helper, append: """

            const originalCompare = compare;
            compare = function(request) {
                const result = originalCompare(request);
                if (request.inputs[0].content.entries.some(entry => entry.path === "Sources/file-128.swift")) {
                    result.payload.snapshots.left.snapshot = "stale-snapshot";
                }
                return result;
            };
            """)
            try await rejects("A later-batch identity failure must not return partial success") {
                _ = try await GitPluginComparison.compare(sourceComparison(small), execution: forged, progress: { failureProgress.record($0, $1) })
            }
            try expect(failureProgress.samples.count == 1 && failureProgress.samples.first?.0 == 128,
                "Failed second batch is not reported as verified progress")

            let cancellationProgress = BatchProgress()
            let slow = execution(package, helper: helper, append: """

            const normalCompare = compare;
            compare = function(request) {
                if (request.inputs[0].content.entries.some(entry => entry.path === "Sources/file-128.swift")) { while (true) {} }
                return normalCompare(request);
            };
            """)
            let task = Task {
                try await GitPluginComparison.compare(sourceComparison(small), execution: slow, progress: { cancellationProgress.record($0, $1) })
            }
            let deadline = Date().addingTimeInterval(5)
            while cancellationProgress.samples.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            try expect(cancellationProgress.samples.count == 1, "Cancellation fixture completes the first batch")
            try await Task.sleep(nanoseconds: 100_000_000)
            let cancelledAt = Date()
            task.cancel()
            do { _ = try await task.value; throw Failure(description: "Cancelled batching returned a partial result") }
            catch is CancellationError { checks += 1 }
            try expect(Date().timeIntervalSince(cancelledAt) < 2 && cancellationProgress.samples.count == 1,
                "Cancellation stops the active restricted batch without publishing partial rows")
            print("PASS \(checks) Git plugin batching checks")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
