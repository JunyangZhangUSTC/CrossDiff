import Foundation
import CrossDiffCore

private final class CapturedUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FolderScanUpdate] = []
    func append(_ update: FolderScanUpdate) { lock.lock(); defer { lock.unlock() }; values.append(update) }
    var all: [FolderScanUpdate] { lock.lock(); defer { lock.unlock() }; return values }
}

/// The scanner remains active until the test explicitly finishes it. Publishing
/// is separate from completion, so assertions never race a fixed replay timer.
private final class ScanGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (FolderScanUpdate) -> Void)?
    private var continuation: CheckedContinuation<FolderComparisonResult, Never>?
    private let result: FolderComparisonResult
    init(result: FolderComparisonResult) { self.result = result }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return callback != nil }
    func run(_ update: @escaping @Sendable (FolderScanUpdate) -> Void) async -> FolderComparisonResult {
        await withCheckedContinuation { continuation in
            lock.lock(); callback = update; self.continuation = continuation; lock.unlock()
        }
    }
    func publish(_ update: FolderScanUpdate) {
        lock.lock(); let callback = callback; lock.unlock()
        callback?(update)
    }
    func finish() {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: result)
    }
}

/// Every nonempty projection gets its own permit. The test can deliver several
/// scan snapshots while an earlier projection is definitely still in flight,
/// then release just that projection and observe what the model publishes.
private final class ProjectionGate: @unchecked Sendable {
    struct Job {
        let id: Int
        let paths: Set<String>
        let query: String
    }
    private let condition = NSCondition()
    private var jobs: [Job] = []
    private var released = Set<Int>()
    private var cancelled = Set<Int>()
    private var allReleased = false
    var started: [Job] { condition.lock(); defer { condition.unlock() }; return jobs }
    func wasCancelled(_ id: Int) -> Bool { condition.lock(); defer { condition.unlock() }; return cancelled.contains(id) }
    func release(_ id: Int) { condition.lock(); released.insert(id); condition.broadcast(); condition.unlock() }
    func releaseAll() { condition.lock(); allReleased = true; condition.broadcast(); condition.unlock() }
    func project(_ input: FolderComparisonModel.ProjectionInput) throws -> FolderBrowserProjection {
        // Changing the initial browser mode may project its empty inventory.
        // It is not part of the scan-publication scenario.
        guard !input.entries.isEmpty else { return try input.project() }
        condition.lock()
        let id = jobs.count
        jobs.append(Job(id: id, paths: Set(input.entries.map(\.path)), query: input.query))
        condition.unlock()
        do {
            while true {
                try Task.checkCancellation()
                condition.lock()
                if allReleased || released.contains(id) { condition.unlock(); break }
                // Only cancellation polling is timed; no assertion depends on
                // a projection completing within this interval.
                _ = condition.wait(until: Date().addingTimeInterval(0.02))
                condition.unlock()
            }
            try Task.checkCancellation()
            return try input.project()
        } catch {
            condition.lock(); cancelled.insert(id); condition.unlock()
            throw error
        }
    }
}

@main enum FolderModelChecks {
    @MainActor static var failures: [String] = []
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message); print("FAIL: " + message) }
    }
    @MainActor static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "FolderModelChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out: " + label]) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    @MainActor static func run() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: manager.currentDirectoryPath)
            .appendingPathComponent(".build/folder-model-checks/fixtures/" + UUID().uuidString)
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        for side in [left, right] { try manager.createDirectory(at: side, withIntermediateDirectories: true) }
        defer { try? manager.removeItem(at: root) }
        for side in [left, right] { try Data("identical".utf8).write(to: side.appendingPathComponent("same.txt")) }
        try Data("early".utf8).write(to: left.appendingPathComponent("early-only.txt"))
        let beforeUpdates = CapturedUpdates()
        _ = try await FolderComparison.scanIncrementally(left: left, right: right) { beforeUpdates.append($0) }
        guard let partial = beforeUpdates.all.first(where: {
            $0.result?.isComplete == false && $0.result?.entries.contains { $0.path == "early-only.txt" && $0.status == .leftOnly } == true
        }) else { throw failure("Real metadata snapshot must contain early-only.txt") }
        print("Fixture partial: \(partial.result!.entries.map(\.path).sorted()), stage=\(partial.progress.stage)")
        try manager.removeItem(at: left.appendingPathComponent("early-only.txt"))
        try Data("middle".utf8).write(to: left.appendingPathComponent("middle-only.txt"))
        let middleUpdates = CapturedUpdates()
        _ = try await FolderComparison.scanIncrementally(left: left, right: right) { middleUpdates.append($0) }
        guard let middle = middleUpdates.all.first(where: {
            $0.result?.isComplete == false && $0.result?.entries.contains { $0.path == "middle-only.txt" } == true
        }) else { throw failure("Real metadata snapshot must contain middle-only.txt") }
        try manager.removeItem(at: left.appendingPathComponent("middle-only.txt"))
        try Data("latest".utf8).write(to: left.appendingPathComponent("latest-only.txt"))
        let finalUpdates = CapturedUpdates()
        let final = try await FolderComparison.scanIncrementally(left: left, right: right) { finalUpdates.append($0) }
        guard let latest = finalUpdates.all.first(where: {
            $0.result?.isComplete == false && $0.result?.entries.contains { $0.path == "latest-only.txt" } == true
        }) else { throw failure("Real metadata snapshot must contain latest-only.txt") }
        let scanGate = ScanGate(result: final), projections = ProjectionGate()
        defer { scanGate.finish(); projections.releaseAll() }
        let model = FolderComparisonModel(scan: { _, _, _, update in
            await scanGate.run(update)
        }, project: { try projections.project($0) })
        model.browserMode = .list
        model.scan(left: left, right: right)
        try await wait("scan callback registered") { scanGate.started }
        scanGate.publish(partial)
        try await wait("first projection entered its gate") { projections.started.contains { $0.paths.contains("early-only.txt") } }
        let first = projections.started.first { $0.paths.contains("early-only.txt") }!
        scanGate.publish(middle)
        try await wait("middle snapshot consumed while first projection is blocked") { model.result?.entries.contains { $0.path == "middle-only.txt" } == true }
        scanGate.publish(latest)
        try await wait("latest snapshot consumed while first projection is blocked") { model.result?.entries.contains { $0.path == "latest-only.txt" } == true }
        projections.release(first.id)
        try await wait("first projection publishes or is incorrectly canceled") {
            projections.wasCancelled(first.id) || model.browserProjection.rows.contains { $0.id == "early-only.txt" }
        }
        check(model.scanning, "Fixture is still publishing scan updates when checking progressive rows")
        guard model.browserProjection.rows.contains(where: { $0.id == "early-only.txt" }) else {
            throw failure("An in-flight slow projection must publish rows while faster partial updates continue")
        }
        try await wait("only newest queued snapshot begins projecting") { projections.started.contains { $0.paths.contains("latest-only.txt") && $0.query.isEmpty } }
        let superseded = projections.started.first { $0.paths.contains("latest-only.txt") && $0.query.isEmpty }!
        check(!projections.started.contains { $0.paths.contains("middle-only.txt") }, "Intermediate snapshots coalesce into the latest input")
        model.selection = ["early-only.txt"]
        check(!model.canCopy(toRight: true), "Partial rows never enable copy")
        model.query = "missing"
        try await wait("new query cancels old projection and enters its gate") {
            projections.wasCancelled(superseded.id) && projections.started.contains { $0.query == "missing" }
        }
        let missing = projections.started.first { $0.query == "missing" }!
        projections.release(missing.id)
        try await wait("new query publication, not a preexisting empty table") { model.scanning && !model.filtering }
        check(model.browserProjection.rows.isEmpty, "The published missing query has no matching rows")
        check(model.selection.isEmpty, "A query change cancels old in-flight projections and removes hidden selections")
        model.query = "latest"
        try await wait("latest query entered its gate") { projections.started.contains { $0.query == "latest" } }
        let latestQuery = projections.started.first { $0.query == "latest" }!
        scanGate.finish()
        try await wait("scan completion") { !model.scanning }
        check(!model.canCopy(toRight: true), "The final scan cannot authorize an older visible projection")
        projections.release(latestQuery.id)
        try await wait("final complete result projection entered its gate") { projections.started.contains { $0.id > latestQuery.id && $0.query == "latest" } }
        let complete = projections.started.first { $0.id > latestQuery.id && $0.query == "latest" }!
        model.selection = ["latest-only.txt"]
        check(!model.canCopy(toRight: true), "Even matching partial rows cannot authorize copying before the final projection publishes")
        model.selection = ["early-only.txt"]
        projections.release(complete.id)
        try await wait("latest projection") { !model.filtering }
        check(model.browserProjection.rows.map(\.id) == ["latest-only.txt"], "Final visible rows must reflect the newest snapshot")
        check(model.selection.isEmpty, "The newest projection clears selection of a removed entry")
        model.selection = ["latest-only.txt"]
        check(model.canCopy(toRight: true), "Only a fully published current result enables copy")
        model.prepare(paths: model.selection, toRight: true)
        try await wait("current copy preview") { !model.busy }
        check(model.preview?.actions.map(\.path) == ["latest-only.txt"], "Copy preview uses only the latest visible file")
        model.preview = nil
        model.query = "missing"
        check(!model.canCopy(toRight: true), "Changing a query blocks copy synchronously")
        projections.releaseAll()
        try await wait("query projection") { !model.filtering }
        check(model.browserProjection.rows.isEmpty && model.selection.isEmpty, "New query removes hidden selections")
        model.cancel()

        // Replacing inputs invalidates queued snapshots and projections from the
        // first scan, including completions delivered after cancellation.
        let nextLeft = root.appendingPathComponent("next-left"), nextRight = root.appendingPathComponent("next-right")
        for side in [nextLeft, nextRight] { try manager.createDirectory(at: side, withIntermediateDirectories: true) }
        try Data("replacement".utf8).write(to: nextLeft.appendingPathComponent("replacement.txt"))
        let replacementUpdates = CapturedUpdates()
        let replacement = try await FolderComparison.scanIncrementally(left: nextLeft, right: nextRight) { replacementUpdates.append($0) }
        let replacementUpdate = replacementUpdates.all.last!
        let oldScan = ScanGate(result: final), newScan = ScanGate(result: replacement), replacementProjections = ProjectionGate()
        defer { oldScan.finish(); newScan.finish(); replacementProjections.releaseAll() }
        let replacing = FolderComparisonModel(scan: { a, _, _, update in
            await (a == nextLeft ? newScan : oldScan).run(update)
        }, project: { try replacementProjections.project($0) })
        replacing.browserMode = .list
        replacing.scan(left: left, right: right)
        try await wait("old-root scan callback registered") { oldScan.started }
        oldScan.publish(partial)
        try await wait("old-root projection entered its gate") { replacementProjections.started.contains { $0.paths.contains("early-only.txt") } }
        replacementProjections.release(replacementProjections.started.first { $0.paths.contains("early-only.txt") }!.id)
        try await wait("initial replacement-test rows") { replacing.browserProjection.rows.contains { $0.id == "early-only.txt" } }
        oldScan.publish(middle)
        try await wait("old-root pending projection entered its gate") { replacementProjections.started.contains { $0.paths.contains("middle-only.txt") } }
        let oldProjection = replacementProjections.started.first { $0.paths.contains("middle-only.txt") }!
        replacing.selection = ["early-only.txt"]
        replacing.scan(left: nextLeft, right: nextRight)
        check(replacing.selection.isEmpty && replacing.browserProjection.rows.isEmpty, "Replacing roots clears old selection and rows immediately")
        try await wait("new-root scan callback registered") { newScan.started }
        newScan.publish(replacementUpdate)
        // Intentionally deliver the canceled scanner's callback and completion
        // after replacement, rather than merely hoping a late task overlaps it.
        oldScan.publish(partial); oldScan.finish()
        try await wait("old-root projection observes cancellation") { replacementProjections.wasCancelled(oldProjection.id) }
        newScan.finish(); replacementProjections.releaseAll()
        try await wait("replacement root projection") { !replacing.scanning && !replacing.filtering }
        check(replacing.result?.leftRoot.path == nextLeft.path && replacing.browserProjection.rows.map(\.id) == ["replacement.txt"],
              "Canceled scan and projection completions cannot overwrite replacement roots")
        replacing.selection = ["replacement.txt"]
        check(replacing.canCopy(toRight: true), "The replacement's complete published projection permits its own copy")
        replacing.cancel()
        if !failures.isEmpty { print("Folder model checks failed: \(failures.count)"); exit(1) }
        print("PASS: folder model progressive projection, latest result, filtering and safe copy")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "FolderModelChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
