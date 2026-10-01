import Foundation
import Darwin
import CrossDiffCore

@main enum ArchiveCoreChecks {
    struct Failure: Error { let message: String }
    static var assertions = 0
    static var stage = "folder"
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(message: message) }; assertions += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { assertions += 1; return }; throw Failure(message: message)
    }
    static func main() async {
        do { try await run(); print("PASS: \(assertions) archive core checks") }
        catch { fputs("FAIL [\(stage)]: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = fixtures.appendingPathComponent("folder")
        let snapshot = try ArchiveCatalog.snapshot(url: directory)
        try expect(snapshot.sourceKind == .folder && snapshot.isComplete, "local folder is a fully verified virtual directory")
        try expect(snapshot.entries.first { $0.path == "hello.txt" }?.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", "file content SHA-256 matches the known hello vector")
        try expect(snapshot.entries.first { $0.path == "nested/empty" }?.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty files have a real digest, not an unverified sentinel")
        try snapshot.verifyUnchanged()
        for suffix in ["tar", "tar.gz", "tgz", "tar.bz2", "tbz2", "tar.xz", "txz"] {
            let archive = try ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent("valid." + suffix))
            try expect(archive.sourceKind == .archive && archive.isComplete && archive.entries == snapshot.entries,
                       "TAR/filter contents and implicit directories match the folder snapshot")
        }
        for name in ["stored.zip", "deflated.zip"] {
            stage = name
            let archive = try ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent(name))
            try expect(archive.entries == snapshot.entries && archive.isComplete, "ZIP contents and implicit directories match the folder")
        }
        for name in ["unicode.zip", "unicode.tar"] {
            stage = name
            let value = try ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent(name))
            try expect(value.entries.contains { $0.path == "中文/😀.txt" && $0.isContentVerified }, "UTF-8 paths are preserved")
        }
        for name in ["pax.tar", "gnu.tar", "descriptor.zip", "xz-crc32.tar.xz", "xz-crc64.tar.xz", "xz-sha256.tar.xz", "xz-multiblock.tar.xz", "gzip-members.tar.gz"] {
            stage = name
            let value = try ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent(name))
            try expect(value.entries.filter { $0.kind == .file }.count == 1 && value.isComplete, "bounded PAX/GNU names and ZIP descriptors are supported")
        }
        for name in ["empty.zip", "empty.tar"] {
            stage = name
            let value = try ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent(name))
            try expect(value.entries.isEmpty && value.isComplete, "empty archives are complete directories")
        }
        try expect(ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent("root.tar")).entries == snapshot.entries, "root directory marker is ignored")
        for name in ["links", "links.tar", "links.zip"] {
            stage = name
            let value = try ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent(name))
            try expect(!value.isComplete && value.entries.allSatisfy { !$0.isContentVerified && $0.sha256 == nil }, "links and special entries remain unverified without following targets")
        }
        for url in try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil).filter({ $0.lastPathComponent.hasPrefix("bad-") }) {
            stage = url.lastPathComponent
            try rejects("reject unsafe, corrupt, unsupported or excessive archive: " + url.lastPathComponent) { _ = try ArchiveCatalog.snapshot(url: url) }
        }
        try rejects("folder entry limit rejects the complete scan") { _ = try ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent("many")) }
        try rejects("folder per-file size limit rejects before reading payload") { _ = try ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent("large-folder")) }
        try rejects("a source FIFO is rejected without blocking") { _ = try ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent("links/fifo")) }
        try rejects("a source symbolic link is not followed") { _ = try ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent("links/symbolic")) }
        let rootFixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build-archive-workflow/fixtures")
        for name in ["left.zip", "right.tar.gz"] where FileManager.default.fileExists(atPath: rootFixtures.appendingPathComponent(name).path) {
            stage = "native fixture " + name
            let value = try ArchiveCatalog.snapshot(url: rootFixtures.appendingPathComponent(name))
            try expect(!value.entries.isEmpty, "native integration fixture parses through the real core reader")
        }
        stage = "mutation and cancellation"
        let mutable = fixtures.appendingPathComponent("mutable")
        let old = try ArchiveCatalog.snapshot(url: mutable)
        try Data("after".utf8).write(to: mutable.appendingPathComponent("child/value"))
        try rejects("snapshot detects changed descendant content") { try old.verifyUnchanged() }
        let beforeAdded = try ArchiveCatalog.snapshot(url: mutable)
        try Data().write(to: mutable.appendingPathComponent("new"))
        try rejects("snapshot detects new directory children") { try beforeAdded.verifyUnchanged() }
        let archiveURL = fixtures.appendingPathComponent("descriptor.zip")
        let oldArchive = try ArchiveCatalog.snapshot(url: archiveURL)
        let bytes = try Data(contentsOf: archiveURL); try bytes.write(to: archiveURL, options: .atomic)
        try rejects("snapshot detects source inode replacement even with identical bytes") { try oldArchive.verifyUnchanged() }
        let cancellation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ArchiveCatalog.snapshot(url: directory)
        }
        do { _ = try await cancellation.value; throw Failure(message: "cancellation must stop before publishing") }
        catch is CancellationError { assertions += 1 }
        let lateCancellation = Task {
            try ArchiveCatalog.snapshot(url: directory) { progress in
                if progress == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await lateCancellation.value; throw Failure(message: "late cancellation must prevent publication") }
        catch is CancellationError { assertions += 1 }

    }
}
