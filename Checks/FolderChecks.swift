import Foundation
import CrossDiffCore

func runFolderChecks() throws {
    let manager = FileManager.default
    func folders(_ body: (URL, URL) throws -> Void) throws {
        let base = manager.temporaryDirectory.appendingPathComponent("CrossDiff-folder-" + UUID().uuidString)
        let left = base.appendingPathComponent("left"), right = base.appendingPathComponent("right")
        try manager.createDirectory(at: left, withIntermediateDirectories: true)
        try manager.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        try body(left, right)
    }
    func mustThrow(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected unsafe/stale copy to fail") } catch {}
    }
    try folders { left, right in
        for root in [left, right] { try Data("same".utf8).write(to: root.appendingPathComponent("same.txt")) }
        try Data("old".utf8).write(to: left.appendingPathComponent("changed.txt"))
        try Data("new".utf8).write(to: right.appendingPathComponent("changed.txt"))
        try Data("left".utf8).write(to: left.appendingPathComponent("left.txt"))
        try Data("right".utf8).write(to: right.appendingPathComponent("right.txt"))
        try manager.createDirectory(at: left.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let result = try FolderComparison.scan(left: left, right: right)
        let states = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.path, $0.status) })
        precondition(states["same.txt"] == .same && states["changed.txt"] == .changed)
        precondition(states["left.txt"] == .leftOnly && states["right.txt"] == .rightOnly)
        precondition(states[".git"] == nil && result.ignoredCount == 1)
        let plan = try FolderComparison.prepareCopy(result, paths: ["changed.txt", "left.txt"], toRight: true)
        precondition(plan.actions.count == 2)
        let oldTarget = try String(contentsOf: right.appendingPathComponent("changed.txt"), encoding: .utf8)
        precondition(oldTarget == "new", "Preview must not write")
        let count = try FolderComparison.execute(plan)
        let newTarget = try String(contentsOf: right.appendingPathComponent("changed.txt"), encoding: .utf8)
        precondition(count == 2 && newTarget == "old")
        let rescanned = try FolderComparison.scan(left: left, right: right)
        let reverse = try FolderComparison.prepareCopy(rescanned, paths: ["right.txt"], toRight: false)
        try FolderComparison.execute(reverse)
        precondition(manager.fileExists(atPath: left.appendingPathComponent("right.txt").path))
    }
    for changeSource in [true, false] {
        try folders { left, right in
            let source = left.appendingPathComponent("file.txt"), target = right.appendingPathComponent("file.txt")
            try Data("source".utf8).write(to: source); try Data("target".utf8).write(to: target)
            let result = try FolderComparison.scan(left: left, right: right)
            let plan = try FolderComparison.prepareCopy(result, paths: ["file.txt"], toRight: true)
            try Data("outside edit".utf8).write(to: changeSource ? source : target)
            mustThrow { try FolderComparison.execute(plan) }
            let actual = try String(contentsOf: target, encoding: .utf8)
            precondition(actual == (changeSource ? "target" : "outside edit"))
        }
    }
    try folders { left, right in
        let nested = left.appendingPathComponent("a/b")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0, 1, 2, 255]).write(to: nested.appendingPathComponent("data.bin"))
        let result = try FolderComparison.scan(left: left, right: right)
        let plan = try FolderComparison.prepareCopy(result, paths: ["a/b/data.bin"], toRight: true)
        try FolderComparison.execute(plan)
        let copied = try Data(contentsOf: right.appendingPathComponent("a/b/data.bin"))
        precondition(copied == Data([0, 1, 2, 255]))
    }
    try folders { left, right in
        let outside = left.deletingLastPathComponent().appendingPathComponent("outside")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try manager.createSymbolicLink(at: left.appendingPathComponent("link"), withDestinationURL: outside)
        let result = try FolderComparison.scan(left: left, right: right)
        precondition(result.entries.map(\.path) == ["link"])
        precondition(result.entries.first?.left?.kind == .symbolicLink)
        mustThrow { _ = try FolderComparison.prepareCopy(result, paths: ["link"], toRight: true) }
    }
    try folders { left, right in
        try manager.createDirectory(at: left.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("source".utf8).write(to: left.appendingPathComponent("sub/file.txt"))
        let result = try FolderComparison.scan(left: left, right: right)
        let plan = try FolderComparison.prepareCopy(result, paths: ["sub/file.txt"], toRight: true)
        let outside = left.deletingLastPathComponent().appendingPathComponent("outside")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: right.appendingPathComponent("sub"), withDestinationURL: outside)
        mustThrow { try FolderComparison.execute(plan) }
        precondition(!manager.fileExists(atPath: outside.appendingPathComponent("file.txt").path))
    }
    print("✓ Folder comparisons: content changes, selected copy, preview, both directions, outside edits, nested files, symbolic-link safety")
}
