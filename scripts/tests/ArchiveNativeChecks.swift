import Foundation
import Darwin
import CrossDiffCore

@main enum ArchiveNativeChecks {
    struct Failure: Error { let message: String }
    struct Digest: Decodable { let size: Int64; let sha256: String }
    static var assertions = 0
    static var stage = "setup"
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(message: message) }; assertions += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { assertions += 1; return }
        throw Failure(message: message)
    }
    static func rejectsLimit(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch ArchiveError.limit { assertions += 1; return }
        throw Failure(message: message)
    }
    static func rejectsAs(_ expected: String, _ body: () throws -> Void) throws {
        do { try body() } catch let error as ArchiveError {
            let category: String
            switch error {
            case .encrypted: category = "encrypted"
            case .multiVolume: category = "multiVolume"
            case .unsupported7z: category = "unsupported7z"
            case .unsupportedRAR: category = "unsupportedRAR"
            case .limit: category = "limit"
            case .damaged: category = "damaged"
            default: category = "unexpected: \(error)"
            }
            try expect(category == expected, "expected \(expected), received \(category)")
            return
        }
        throw Failure(message: "expected \(expected) rejection")
    }
    static func main() async {
        do { try await run(); print("PASS: \(assertions) archive native checks") }
        catch { fputs("FAIL [\(stage)]: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        let helper = URL(fileURLWithPath: CommandLine.arguments[2])
        func snapshot(_ name: String) throws -> ArchiveSnapshot {
            try ArchiveCatalog.snapshot(url: fixtures.appendingPathComponent(name), nativeReaderURL: helper)
        }
        let originals = Set(try FileManager.default.subpathsOfDirectory(atPath: fixtures.path))
        let folder = try snapshot("folder")
        try expect(folder.isComplete && folder.entries.count == 7, "fixture has five files and two explicit directories")
        try expect(folder.entries.first { $0.path == "hello.txt" }?.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", "known SHA-256 vector")
        try expect(folder.entries.first { $0.path == "empty" }?.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty file has the real empty-content digest")
        for name in ["copy.7z", "lzma1.7z", "lzma2.7z", "solid.7z", "header-compressed.7z", "bcj.7z", "delta.7z", "folder.zip", "folder.tar"] {
            stage = name
            let value = try snapshot(name)
            try expect(value.sourceKind == .archive && value.isComplete, "archive is fully content-verified")
            try expect(value.entries == folder.entries, "7z/ZIP/TAR paths, SHA-256 and sizes match the local folder")
            try expect(value.totalExpandedBytes == folder.totalExpandedBytes, "expanded totals match")
            try value.verifyUnchanged()
        }
        for (name, directory) in [("valid.7z", "checksum-single"), ("solid-valid.7z", "checksum-solid"), ("folder-only-valid.7z", "checksum-solid")] {
            stage = name
            let value = try snapshot(name)
            try expect(value.isComplete && value.entries == snapshot(directory).entries,
                       "valid Copy stream and solid-folder CRCs preserve exact file content")
        }
        for (archive, directory) in [("test_read_format_rar5_stored.rar", "rar5-stored"), ("test_read_format_rar5_compressed.rar", "rar5-compressed"), ("test_read_format_rar5_multiple_files_solid.rar", "rar5-solid")] {
            stage = archive
            let value = try snapshot(archive)
            let expected = try snapshot(directory)
            try expect(value.isComplete && value.entries == expected.entries, "RAR5 stored/compressed/solid matches independently regenerated upstream data")
            try expect(value.totalExpandedBytes == expected.totalExpandedBytes, "RAR5 expanded byte count is exact")
            for suffix in [".zip", ".tar"] {
                try expect(snapshot(directory + suffix).entries == value.entries, "RAR/ZIP/TAR cross-format hashes agree")
            }
        }
        stage = "RAR4 symlink"
        let rar4 = try snapshot("test_read_format_rar.rar")
        let rar4Folder = try snapshot("rar4-stored")
        try expect(!rar4.isComplete, "symbolic links prevent a fully verified equality result")
        try expect(rar4.entries.filter { $0.kind != .symbolicLink } == rar4Folder.entries.filter { $0.kind != .symbolicLink }, "RAR4 regular files and directories match expected content")
        try expect(rar4.entries.first { $0.path == "testlink" }.map { $0.kind == .symbolicLink && $0.issue == .symbolicLink && $0.sha256 == nil && !$0.isContentVerified } == true, "RAR4 symbolic link is explicitly unverified and never followed")
        stage = "RAR4 compressed"
        let compressed = try snapshot("test_read_format_rar_compress_normal.rar")
        let manifest = try JSONDecoder().decode([String: Digest].self, from: Data(contentsOf: fixtures.appendingPathComponent("rar4-compressed-expected.json")))
        try expect(compressed.entries.count == 6 && !compressed.isComplete, "RAR4 compressed records include an unverified symlink")
        for (path, digest) in manifest {
            try expect(compressed.entries.first { $0.path == path }.map { $0.sha256 == digest.sha256 && $0.size == digest.size && $0.isContentVerified } == true, "RAR4 compressed bytes match the independent 7-Zip oracle")
        }
        let explicitRejected = ["encrypted-data.7z", "encrypted-header.7z", "split.7z.001", "unsupported-bzip2.7z", "test_read_format_rar4_encrypted.rar", "test_read_format_rar4_encrypted_filenames.rar", "test_read_format_rar5_encrypted_filenames.rar", "test_read_format_rar5_solid_encrypted.rar", "test_read_format_rar5_multiarchive.part01.rar"]
        let bad = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("bad-") }.map(\.lastPathComponent).sorted()
        for name in explicitRejected + bad {
            stage = name
            try rejects("must reject without publishing a partial/false-equal snapshot: " + name) { _ = try snapshot(name) }
        }
        for name in ["bad-data-dictionary.7z", "bad-header-dictionary.7z", "bad-header-expanded-limit.7z", "bad-header-packed-limit.7z"] {
            stage = name + " exact resource limit"
            try rejectsLimit("resource metadata must be rejected specifically by its allocation limit") { _ = try snapshot(name) }
        }
        for (name, category) in [
            ("encrypted-data.7z", "encrypted"), ("encrypted-header.7z", "encrypted"),
            ("test_read_format_rar4_encrypted.rar", "encrypted"), ("test_read_format_rar5_encrypted_filenames.rar", "encrypted"),
            ("split.7z.001", "multiVolume"), ("test_read_format_rar5_multiarchive.part01.rar", "multiVolume"),
            ("unsupported-bzip2.7z", "unsupported7z"), ("bad-payload-crc-copy.7z", "damaged"),
            ("bad-pack-crc.7z", "damaged"), ("bad-folder-crc.7z", "damaged"), ("bad-folder-only-crc.7z", "damaged"),
            ("bad-rar4-solid.rar", "unsupportedRAR"), ("bad-rar5-algorithm.rar", "unsupportedRAR"), ("bad-rar5-dictionary.rar", "limit"),
            ("bad-tail-header-compressed.7z", "damaged"), ("bad-tail-test_read_format_rar5_stored.rar", "damaged")
        ] {
            stage = name + " error classification"
            try rejectsAs(category) { _ = try snapshot(name) }
        }
        stage = "helper failures"
        let source = fixtures.appendingPathComponent("copy.7z")
        try rejects("native format requires its bundled helper") { _ = try ArchiveCatalog.snapshot(url: source) }
        for name in ["missing-helper", "fake-fail", "fake-crash", "fake-invalid", "fake-oversized"] {
            stage = name
            let invalidHelper = helper.deletingLastPathComponent().appendingPathComponent(name)
            try rejects("helper launch/crash/protocol/output-limit failure must never publish equality") {
                _ = try ArchiveCatalog.snapshot(url: source, nativeReaderURL: invalidHelper)
            }
        }
        stage = "unchanged source"
        let mutable = fixtures.appendingPathComponent("mutable.7z")
        let old = try ArchiveCatalog.snapshot(url: mutable, nativeReaderURL: helper)
        let bytes = try Data(contentsOf: mutable)
        try bytes.write(to: mutable, options: .atomic)
        try rejects("native snapshots detect source replacement even with identical data") { try old.verifyUnchanged() }
        stage = "early cancellation"
        let early = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ArchiveCatalog.snapshot(url: source, nativeReaderURL: helper)
        }
        do { _ = try await early.value; throw Failure(message: "cancelled task must not publish a native snapshot") }
        catch is CancellationError { assertions += 1 }
        stage = "late cancellation"
        let late = Task.detached {
            try ArchiveCatalog.snapshot(url: source, nativeReaderURL: helper) { value in
                if value == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await late.value; throw Failure(message: "late cancellation must prevent result publication") }
        catch is CancellationError { assertions += 1 }
        stage = "running helper cancellation"
        let hangingHelper = helper.deletingLastPathComponent().appendingPathComponent("fake-cancel")
        let pidFile = hangingHelper.appendingPathExtension("pid")
        try? FileManager.default.removeItem(at: pidFile)
        let running = Task.detached { try ArchiveCatalog.snapshot(url: source, nativeReaderURL: hangingHelper) }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let pidText = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            running.cancel(); throw Failure(message: "cancellation fixture helper did not start")
        }
        let start = Date()
        running.cancel()
        do { _ = try await running.value; throw Failure(message: "running helper cancellation must not publish") }
        catch is CancellationError { assertions += 1 }
        try expect(Date().timeIntervalSince(start) < 3, "helper cancellation completes promptly")
        try expect(kill(pid, 0) != 0 && errno == ESRCH, "cancelled helper is terminated and reaped")
        try? FileManager.default.removeItem(at: pidFile)
        stage = "no extraction"
        let after = Set(try FileManager.default.subpathsOfDirectory(atPath: fixtures.path))
        try expect(after == originals, "reading archives creates no extracted files")
    }
}
