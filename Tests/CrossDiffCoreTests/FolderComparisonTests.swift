import Foundation
import XCTest
import Darwin
@testable import CrossDiffCore

private final class FolderUpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FolderScanUpdate] = []
    func append(_ update: FolderScanUpdate) { lock.lock(); defer { lock.unlock() }; values.append(update) }
    var updates: [FolderScanUpdate] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class FolderMutationState: @unchecked Sendable {
    private let lock = NSLock()
    private var didMutate = false
    private var storedError: Error?
    func mutateOnce(_ body: () throws -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !didMutate else { return }
        didMutate = true
        do { try body() } catch { storedError = error }
    }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
}

final class FolderComparisonTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/folder-tests")
            .appendingPathComponent(UUID().uuidString)
    }
    private func withFoldersAsync(_ body: (URL, URL) async throws -> Void) async throws {
        let root = fixtureRoot
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(left, right)
    }
    private func withFolders(_ body: (URL, URL) throws -> Void) throws {
        let root = fixtureRoot
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(left, right)
    }

    func testFolderComparisonFindsContentChangesAndIgnoredEntries() throws {
        try withFolders { left, right in
            for root in [left, right] { try Data("same".utf8).write(to: root.appendingPathComponent("same.txt")) }
            try Data("old".utf8).write(to: left.appendingPathComponent("changed.txt"))
            try Data("new".utf8).write(to: right.appendingPathComponent("changed.txt"))
            try Data("left".utf8).write(to: left.appendingPathComponent("left.txt"))
            try Data("right".utf8).write(to: right.appendingPathComponent("right.txt"))
            try FileManager.default.createDirectory(at: left.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let result = try FolderComparison.scan(left: left, right: right)
            let states = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.path, $0.status) })
            XCTAssertEqual(states["same.txt"], .same)
            XCTAssertEqual(states["changed.txt"], .changed)
            XCTAssertEqual(states["left.txt"], .leftOnly)
            XCTAssertEqual(states["right.txt"], .rightOnly)
            XCTAssertNil(states[".git"])
            XCTAssertEqual(result.ignoredCount, 1)
        }
    }
    func testFolderComparisonCopiesOnlySelectedFilesAfterPreview() throws {
        try withFolders { left, right in
            try Data("new".utf8).write(to: left.appendingPathComponent("selected.txt"))
            try Data("skip".utf8).write(to: left.appendingPathComponent("unselected.txt"))
            let result = try FolderComparison.scan(left: left, right: right)
            let plan = try FolderComparison.prepareCopy(result, paths: ["selected.txt"], toRight: true)
            XCTAssertEqual(plan.actions.map(\.path), ["selected.txt"])
            XCTAssertEqual(plan.actions.first?.operation, .add)
            XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("selected.txt").path))
            XCTAssertEqual(try FolderComparison.execute(plan), 1)
            XCTAssertEqual(try String(contentsOf: right.appendingPathComponent("selected.txt"), encoding: .utf8), "new")
            XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("unselected.txt").path))
        }
    }

    func testFolderComparisonStopsCopyWhenSourceOrTargetChanges() throws {
        for changeSource in [true, false] {
            try withFolders { left, right in
                let source = left.appendingPathComponent("file.txt"), target = right.appendingPathComponent("file.txt")
                try Data("source".utf8).write(to: source)
                try Data("target".utf8).write(to: target)
                let result = try FolderComparison.scan(left: left, right: right)
                let plan = try FolderComparison.prepareCopy(result, paths: ["file.txt"], toRight: true)
                try Data("outside edit".utf8).write(to: changeSource ? source : target)
                XCTAssertThrowsError(try FolderComparison.execute(plan))
                XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), changeSource ? "target" : "outside edit")
            }
        }
    }

    func testFolderComparisonDoesNotTraverseOrCopySymbolicLinks() throws {
        try withFolders { left, right in
            let outside = left.deletingLastPathComponent().appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("private".utf8).write(to: outside.appendingPathComponent("private.txt"))
            try FileManager.default.createSymbolicLink(at: left.appendingPathComponent("linked"), withDestinationURL: outside)
            let result = try FolderComparison.scan(left: left, right: right)
            XCTAssertEqual(result.entries.map(\.path), ["linked"])
            XCTAssertEqual(result.entries.first?.left?.kind, .symbolicLink)
            XCTAssertThrowsError(try FolderComparison.prepareCopy(result, paths: ["linked"], toRight: true))
        }
    }

    func testFolderComparisonRejectsDestinationParentReplacedBySymbolicLink() throws {
        try withFolders { left, right in
            let sourceFolder = left.appendingPathComponent("sub"), targetFolder = right.appendingPathComponent("sub")
            try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
            try Data("source".utf8).write(to: sourceFolder.appendingPathComponent("file.txt"))
            let result = try FolderComparison.scan(left: left, right: right)
            let plan = try FolderComparison.prepareCopy(result, paths: ["sub/file.txt"], toRight: true)
            let outside = left.deletingLastPathComponent().appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: targetFolder, withDestinationURL: outside)
            XCTAssertThrowsError(try FolderComparison.execute(plan))
            XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("file.txt").path))
        }
    }

    func testFolderComparisonCreatesMissingParentsAndCopiesOnlyTheSelectedDescendant() throws {
        try withFolders { left, right in
            let sub = left.appendingPathComponent("a/b")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data([0, 1, 2, 255]).write(to: sub.appendingPathComponent("data.bin"))
            let result = try FolderComparison.scan(left: left, right: right)
            let plan = try FolderComparison.prepareCopy(result, paths: ["a/b/data.bin"], toRight: true)
            XCTAssertEqual(try FolderComparison.execute(plan), 1)
            XCTAssertEqual(try Data(contentsOf: right.appendingPathComponent("a/b/data.bin")), Data([0, 1, 2, 255]))
        }
    }

    func testSameSizeAndModificationTimeStillRequireContentVerification() throws {
        try withFolders { left, right in
            let stamp = Date(timeIntervalSince1970: 1_700_000_000)
            for (root, text) in [(left, "aaaa"), (right, "bbbb")] {
                let file = root.appendingPathComponent("file.txt")
                try Data(text.utf8).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
            }
            let result = try FolderComparison.scan(left: left, right: right)
            XCTAssertEqual(result.entries.first?.status, .changed)
            XCTAssertEqual(result.progress.bytesRead, 8)
        }
    }

    func testMetadataDifferencesAvoidContentReadsAndIgnoreNamesPruneSubtrees() throws {
        try withFolders { left, right in
            for (root, size) in [(left, 4096), (right, 2048)] {
                try Data(repeating: 1, count: size).write(to: root.appendingPathComponent("size.bin"))
                try FileManager.default.createDirectory(at: root.appendingPathComponent("cache/nested"), withIntermediateDirectories: true)
                try Data([2]).write(to: root.appendingPathComponent("cache/nested/hidden"))
            }
            try Data([1]).write(to: left.appendingPathComponent("left-only"))
            try Data([2]).write(to: right.appendingPathComponent("right-only"))
            let result = try FolderComparison.scan(left: left, right: right,
                options: FolderScanOptions(ignoredNames: ["cache"]))
            XCTAssertEqual(result.progress.bytesRead, 0)
            XCTAssertEqual(result.ignoredCount, 2)
            XCTAssertEqual(result.entries.map(\.path), ["left-only", "right-only", "size.bin"])
            XCTAssertTrue(result.isComplete)
            XCTAssertEqual(try FolderComparison.scan(left: left, right: right,
                options: FolderScanOptions(ignoredNames: [])).ignoredCount, 0)
        }
    }

    func testIncrementalSnapshotsNeverTreatUnverifiedContentAsIdentical() async throws {
        try await withFoldersAsync { left, right in
            for (root, text) in [(left, "same"), (right, "diff")] {
                try Data(text.utf8).write(to: root.appendingPathComponent("file.txt"))
            }
            let log = FolderUpdateLog()
            let result = try await FolderComparison.scanIncrementally(left: left, right: right) { log.append($0) }
            let pending = try XCTUnwrap(log.updates.compactMap(\.result).first { !$0.isComplete })
            XCTAssertEqual(pending.entries.first?.status, .pending)
            XCTAssertEqual(pending.progress.bytesRead, 0)
            XCTAssertThrowsError(try FolderComparison.prepareCopy(pending, paths: ["file.txt"], toRight: true))
            XCTAssertEqual(result.entries.first?.status, .changed)
            XCTAssertTrue(result.isComplete)
            XCTAssertEqual(result.progress.completedPairs, result.progress.totalPairs)
        }
    }

    func testIncrementalCancellationAfterEnumerationStopsBeforeContentReads() async throws {
        try await withFoldersAsync { left, right in
            for root in [left, right] { try Data(repeating: 1, count: 512 * 1024).write(to: root.appendingPathComponent("file.bin")) }
            let log = FolderUpdateLog()
            let task = Task.detached {
                try await FolderComparison.scanIncrementally(left: left, right: right) { update in
                    log.append(update)
                    if update.result?.isComplete == false {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
            do { _ = try await task.value; XCTFail("Cancellation must stop the scan") }
            catch is CancellationError {}
            XCTAssertTrue(log.updates.contains { $0.result?.isComplete == false })
            XCTAssertFalse(log.updates.contains { $0.result?.isComplete == true })
            XCTAssertTrue(log.updates.allSatisfy { $0.progress.bytesRead == 0 })
        }
    }

    func testBoundedParallelAndSerialScansReturnTheSameContentResults() async throws {
        try await withFoldersAsync { left, right in
            for index in 0..<64 {
                try Data(repeating: UInt8(index), count: 4096).write(to: left.appendingPathComponent("file-\(index).bin"))
                try Data(repeating: UInt8(index % 3 == 0 ? 99 : index), count: 4096).write(to: right.appendingPathComponent("file-\(index).bin"))
            }
            let serial = try await FolderComparison.scanIncrementally(left: left, right: right,
                options: FolderScanOptions(maxConcurrentReads: 1)) { _ in }
            let parallel = try await FolderComparison.scanIncrementally(left: left, right: right,
                options: FolderScanOptions(maxConcurrentReads: 2)) { _ in }
            XCTAssertEqual(serial.entries.map(\.path), parallel.entries.map(\.path))
            XCTAssertEqual(serial.entries.map(\.status), parallel.entries.map(\.status))
            XCTAssertEqual(serial.progress.bytesRead, 64 * 4096 * 2)
            XCTAssertEqual(serial.progress.bytesRead, parallel.progress.bytesRead)
        }
    }

    func testIncrementalComparisonDoesNotFollowParentsReplacedAfterEnumeration() async throws {
        try await withFoldersAsync { left, right in
            let manager = FileManager.default
            for root in [left, right] {
                try manager.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
                try Data("same".utf8).write(to: root.appendingPathComponent("sub/file.txt"))
            }
            let mutation = FolderMutationState()
            do {
                let result = try await FolderComparison.scanIncrementally(left: left, right: right) { update in
                    if update.result?.isComplete == false {
                        mutation.mutateOnce {
                            let sub = left.appendingPathComponent("sub"), moved = left.appendingPathComponent("moved")
                            try FileManager.default.moveItem(at: sub, to: moved)
                            try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: moved)
                        }
                    }
                }
                XCTAssertEqual(result.entries.first { $0.path == "sub/file.txt" }?.status, .unreadable)
                XCTAssertEqual(result.progress.bytesRead, 0)
            } catch FolderComparisonError.stale {} catch FolderComparisonError.unsafe {}
            if let error = mutation.error { throw error }
        }
    }

    func testMetadataOnlySnapshotRejectsEditsWithOriginalSizeAndMtime() throws {
        for afterPreview in [false, true] {
            for changeSource in [false, true] {
                try withFolders { left, right in
                    let source = left.appendingPathComponent("file.txt"), target = right.appendingPathComponent("file.txt")
                    try Data("source".utf8).write(to: source); try Data("dest".utf8).write(to: target)
                    let result = try FolderComparison.scan(left: left, right: right)
                    XCTAssertEqual(result.progress.bytesRead, 0)
                    let plan = afterPreview ? try FolderComparison.prepareCopy(result, paths: ["file.txt"], toRight: true) : nil
                    let changed = changeSource ? source : target
                    var original = stat()
                    XCTAssertEqual(lstat(changed.path, &original), 0)
                    let handle = try FileHandle(forWritingTo: changed)
                    try handle.write(contentsOf: Data((changeSource ? "SOURCE" : "DEST").utf8)); try handle.close()
                    var times = [original.st_atimespec, original.st_mtimespec]
                    XCTAssertEqual(utimensat(AT_FDCWD, changed.path, &times, 0), 0)
                    if let plan { XCTAssertThrowsError(try FolderComparison.execute(plan)) }
                    else { XCTAssertThrowsError(try FolderComparison.prepareCopy(result, paths: ["file.txt"], toRight: true)) }
                    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), changeSource ? "dest" : "DEST")
                }
            }
        }
    }

}
