import Foundation
import XCTest
@testable import CrossDiffCore

final class FolderComparisonTests: XCTestCase {
    private func withFolders(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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

}
