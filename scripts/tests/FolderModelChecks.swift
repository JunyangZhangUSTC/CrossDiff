import Foundation
import CrossDiffCore

private final class CapturedUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FolderScanUpdate] = []
    func append(_ update: FolderScanUpdate) { lock.lock(); defer { lock.unlock() }; values.append(update) }
    var all: [FolderScanUpdate] { lock.lock(); defer { lock.unlock() }; return values }
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
    static func slowProjection(_ input: FolderComparisonModel.ProjectionInput) throws -> FolderBrowserProjection {
        // Reproduce a large inventory whose projection takes longer than the
        // engine's 100 ms publication interval, independent of machine speed.
        for _ in 0..<25 {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.01)
        }
        return try input.project()
    }
    @MainActor static func main() async throws {
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
        let partial = beforeUpdates.all.first { $0.result?.isComplete == false }!
        try manager.removeItem(at: left.appendingPathComponent("early-only.txt"))
        try Data("latest".utf8).write(to: left.appendingPathComponent("latest-only.txt"))
        let finalUpdates = CapturedUpdates()
        let final = try await FolderComparison.scanIncrementally(left: left, right: right) { finalUpdates.append($0) }
        let finalUpdate = finalUpdates.all.last!
        let model = FolderComparisonModel(scan: { _, _, _, update in
            for _ in 0..<24 {
                try Task.checkCancellation()
                update(partial)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            update(finalUpdate)
            return final
        }, project: { try slowProjection($0) })
        model.browserMode = .list
        model.scan(left: left, right: right)
        try await Task.sleep(nanoseconds: 700_000_000)
        check(model.scanning, "Fixture is still publishing scan updates when checking progressive rows")
        check(model.browserProjection.rows.contains { $0.id == "early-only.txt" },
              "An in-flight slow projection must publish rows while faster partial updates continue")
        model.selection = ["early-only.txt"]
        check(!model.canCopy(toRight: true), "Partial rows never enable copy")
        model.query = "missing"
        try await wait("new query during continuous snapshots") { model.scanning && model.browserProjection.rows.isEmpty }
        check(model.selection.isEmpty, "A query change cancels old in-flight projections and removes hidden selections")
        model.query = "latest"
        try await wait("scan completion") { !model.scanning }
        check(!model.canCopy(toRight: true), "The final scan cannot authorize an older visible projection")
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
        let replacing = FolderComparisonModel(scan: { a, _, _, update in
            if a == nextLeft { update(replacementUpdate); return replacement }
            for _ in 0..<30 {
                update(partial)
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return final
        }, project: { try slowProjection($0) })
        replacing.browserMode = .list
        replacing.scan(left: left, right: right)
        try await wait("initial replacement-test rows") { replacing.browserProjection.rows.contains { $0.id == "early-only.txt" } }
        replacing.selection = ["early-only.txt"]
        replacing.scan(left: nextLeft, right: nextRight)
        check(replacing.selection.isEmpty && replacing.browserProjection.rows.isEmpty, "Replacing roots clears old selection and rows immediately")
        try await wait("replacement root projection") { !replacing.scanning && !replacing.filtering }
        try await Task.sleep(nanoseconds: 350_000_000)
        check(replacing.result?.leftRoot.path == nextLeft.path && replacing.browserProjection.rows.map(\.id) == ["replacement.txt"],
              "Canceled scan and projection completions cannot overwrite replacement roots")
        replacing.selection = ["replacement.txt"]
        check(replacing.canCopy(toRight: true), "The replacement's complete published projection permits its own copy")
        replacing.cancel()
        if !failures.isEmpty { print("Folder model checks failed: \(failures.count)"); exit(1) }
        print("PASS: folder model progressive projection, latest result, filtering and safe copy")
    }
}
