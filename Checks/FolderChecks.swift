import Foundation
import CrossDiffCore
import Darwin

private final class FolderCheckValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func update(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
}

private func waitForFolderCheck<Value>(_ body: @escaping @Sendable () async throws -> Value) throws -> Value {
    let value = FolderCheckValue<Result<Value, Error>?>(nil)
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        do { value.set(.success(try await body())) }
        catch { value.set(.failure(error)) }
        finished.signal()
    }
    guard finished.wait(timeout: .now() + 30) == .success else { preconditionFailure("Folder check timed out") }
    return try value.get()!.get()
}

private func rewriteFolderFilePreservingMtime(_ file: URL, contents: String) throws {
    var original = stat()
    precondition(lstat(file.path, &original) == 0)
    let handle = try FileHandle(forWritingTo: file)
    try handle.write(contentsOf: Data(contents.utf8)); try handle.close()
    var times = [original.st_atimespec, original.st_mtimespec]
    precondition(utimensat(AT_FDCWD, file.path, &times, 0) == 0)
    var updated = stat()
    precondition(lstat(file.path, &updated) == 0 && updated.st_size == original.st_size)
    precondition(updated.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec &&
                 updated.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec)
}

func runFolderChecks() throws {
    let manager = FileManager.default
    func folders(_ body: (URL, URL) throws -> Void) throws {
        let base = checkTemporaryDirectory.appendingPathComponent("CrossDiff-folder-" + UUID().uuidString)
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
        // Reading link targets must write into the byte buffer, never the Array value.
        // Keep the target nonexistent: scanning compares link text without following it.
        let target = String(repeating: "目录/", count: 80) + "文件👩🏽‍💻.txt"
        for root in [left, right] {
            try manager.createSymbolicLink(atPath: root.appendingPathComponent("same-link").path,
                                          withDestinationPath: target)
        }
        try manager.createSymbolicLink(atPath: left.appendingPathComponent("changed-link").path,
                                      withDestinationPath: target + "-old")
        try manager.createSymbolicLink(atPath: right.appendingPathComponent("changed-link").path,
                                      withDestinationPath: target + "-new")
        let result = try FolderComparison.scan(left: left, right: right)
        let states = Dictionary(uniqueKeysWithValues: result.entries.map { ($0.path, $0.status) })
        precondition(states == ["same-link": .same, "changed-link": .changed])
        precondition(result.entries.allSatisfy { $0.left?.kind == .symbolicLink && $0.right?.kind == .symbolicLink })
        mustThrow { _ = try FolderComparison.prepareCopy(result, paths: ["changed-link"], toRight: true) }
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
    try folders { left, right in
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        for (root, text) in [(left, "aaaa"), (right, "bbbb")] {
            let file = root.appendingPathComponent("same-metadata.txt")
            try Data(text.utf8).write(to: file)
            try manager.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        }
        let result = try FolderComparison.scan(left: left, right: right)
        precondition(result.entries.first?.status == .changed, "Equal sizes and timestamps cannot prove equal content")
    }
    for afterPreview in [false, true] {
        for changeSource in [false, true] {
            try folders { left, right in
                let source = left.appendingPathComponent("different-sizes.txt")
                let target = right.appendingPathComponent("different-sizes.txt")
                try Data("source".utf8).write(to: source)
                try Data("dest".utf8).write(to: target)
                let result = try FolderComparison.scan(left: left, right: right)
                let plan = afterPreview ? try FolderComparison.prepareCopy(result, paths: ["different-sizes.txt"], toRight: true) : nil
                try rewriteFolderFilePreservingMtime(changeSource ? source : target, contents: changeSource ? "SOURCE" : "DEST")
                if let plan { mustThrow { try FolderComparison.execute(plan) } }
                else { mustThrow { _ = try FolderComparison.prepareCopy(result, paths: ["different-sizes.txt"], toRight: true) } }
                let targetContents = try String(contentsOf: target, encoding: .utf8)
                precondition(targetContents == (changeSource ? "dest" : "DEST"))
            }
        }
    }
    try folders { left, right in
        let sub = left.appendingPathComponent("sub")
        try manager.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sub.appendingPathComponent("file.txt"))
        let result = try FolderComparison.scan(left: left, right: right)
        let plan = try FolderComparison.prepareCopy(result, paths: ["sub/file.txt"], toRight: true)
        let moved = left.appendingPathComponent("moved")
        try manager.moveItem(at: sub, to: moved)
        try manager.createSymbolicLink(at: sub, withDestinationURL: moved)
        mustThrow { try FolderComparison.execute(plan) }
        precondition(!manager.fileExists(atPath: right.appendingPathComponent("sub/file.txt").path))
    }
    try folders { left, right in
        for (root, size) in [(left, 4096), (right, 2048)] {
            try Data(repeating: 1, count: size).write(to: root.appendingPathComponent("size.bin"))
            try manager.createDirectory(at: root.appendingPathComponent("cache/nested"), withIntermediateDirectories: true)
            try Data([2]).write(to: root.appendingPathComponent("cache/nested/hidden"))
        }
        try Data([1]).write(to: left.appendingPathComponent("left-only"))
        try Data([2]).write(to: right.appendingPathComponent("right-only"))
        let result = try FolderComparison.scan(left: left, right: right, options: FolderScanOptions(ignoredNames: ["cache"]))
        precondition(result.isComplete && result.progress.bytesRead == 0,
                     "One-sided and different-size files need no content reads")
        precondition(result.ignoredCount == 2 && result.entries.map(\.path) == ["left-only", "right-only", "size.bin"])
        let unfiltered = try FolderComparison.scan(left: left, right: right, options: FolderScanOptions(ignoredNames: []))
        precondition(unfiltered.ignoredCount == 0 && unfiltered.entries.contains { $0.path == "cache/nested/hidden" })
        let plan = try FolderComparison.prepareCopy(result, paths: ["size.bin", "left-only"], toRight: true)
        let count = try FolderComparison.execute(plan)
        precondition(count == 2, "Metadata-only findings still support safely revalidated copying")
    }
    try folders { left, right in
        for index in 0..<64 {
            try Data(repeating: UInt8(index), count: 4096).write(to: left.appendingPathComponent("file-\(index).bin"))
            try Data(repeating: UInt8(index % 3 == 0 ? 99 : index), count: 4096).write(to: right.appendingPathComponent("file-\(index).bin"))
        }
        try waitForFolderCheck {
            let updates = FolderCheckValue<[FolderScanUpdate]>([])
            let serial = try await FolderComparison.scanIncrementally(left: left, right: right,
                options: FolderScanOptions(maxConcurrentReads: 1)) { update in updates.update { $0.append(update) } }
            let parallel = try await FolderComparison.scanIncrementally(left: left, right: right,
                options: FolderScanOptions(maxConcurrentReads: 2)) { _ in }
            precondition(serial.entries.map(\.path) == parallel.entries.map(\.path))
            precondition(serial.entries.map(\.status) == parallel.entries.map(\.status))
            precondition(serial.progress.bytesRead == 64 * 4096 * 2 && serial.progress.bytesRead == parallel.progress.bytesRead)
            precondition(serial.isComplete && serial.progress.completedPairs == serial.progress.totalPairs)
            guard let pending = updates.get().compactMap(\.result).first(where: { !$0.isComplete }) else {
                preconditionFailure("Must publish metadata before waiting for file contents")
            }
            precondition(pending.progress.bytesRead == 0 && pending.entries.allSatisfy { $0.status == .pending })
            do {
                _ = try FolderComparison.prepareCopy(pending, paths: ["file-0.bin"], toRight: true)
                preconditionFailure("An incomplete result must not authorize copying")
            } catch {}
            let progress = updates.get().map(\.progress)
            for (previous, next) in zip(progress, progress.dropFirst()) {
                precondition(next.bytesRead >= previous.bytesRead && next.discoveredItems >= previous.discoveredItems,
                             "Progress must never move backward")
            }
        }
        let updates = FolderCheckValue<[FolderScanUpdate]>([])
        do {
            _ = try waitForFolderCheck {
                try await FolderComparison.scanIncrementally(left: left, right: right) { update in
                    updates.update { $0.append(update) }
                    if update.result?.isComplete == false { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            preconditionFailure("Cancellation after metadata must stop the scan")
        } catch is CancellationError {}
        precondition(updates.get().contains { $0.result?.isComplete == false })
        precondition(updates.get().allSatisfy { $0.progress.bytesRead == 0 && $0.result?.isComplete != true })
    }
    try folders { left, right in
        for root in [left, right] {
            try manager.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try Data("same".utf8).write(to: root.appendingPathComponent("sub/file.txt"))
        }
        let mutationError = FolderCheckValue<Error?>(nil)
        let mutated = FolderCheckValue(false)
        do {
            let result = try waitForFolderCheck {
                try await FolderComparison.scanIncrementally(left: left, right: right) { update in
                    guard update.result?.isComplete == false, !mutated.get() else { return }
                    mutated.set(true)
                    do {
                        let sub = left.appendingPathComponent("sub"), moved = left.appendingPathComponent("moved")
                        try FileManager.default.moveItem(at: sub, to: moved)
                        try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: moved)
                    } catch { mutationError.set(error) }
                }
            }
            precondition(result.entries.first { $0.path == "sub/file.txt" }?.status == .unreadable,
                         "A parent replaced by a symlink cannot be accepted as verified content")
            precondition(result.progress.bytesRead == 0, "Do not follow a replaced parent to read file contents")
        } catch FolderComparisonError.stale {} catch FolderComparisonError.unsafe {}
        if let error = mutationError.get() { throw error }
        precondition(mutated.get())
    }
    print("✓ Folder comparisons: content verification, selected copy, preview, both directions, preserved-mtime outside edits, nested files, symbolic-link safety")
    print("✓ Folder scan optimization: zero-read metadata results, configurable subtree exclusions, pending snapshots, serial/parallel equivalence, monotonic progress and cancellation")
}
