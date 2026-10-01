import Foundation
import Darwin
import CrossDiffCore

private struct CheckFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(description: message) }
}

@main
private enum BinaryDetectionChecks {
    static func check(_ bytes: Data, binary: Bool, name: String, in root: URL) throws {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        try expect(try BinaryFileDetection.isLikelyBinary(url: url) == binary, "Unexpected classification: " + name)
    }
    static func main() {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try check(Data("中文 e\u{301} 🌿\tfirst\r\nsecond\n".utf8), binary: false, name: "unicode.unknown", in: root)
            print("PASS: plain UTF-8 Unicode remains text with an unknown extension")
            try check(Data([65, 0, 66]), binary: true, name: "nul.unknown", in: root)
            try check(Data([65, 1, 66]), binary: true, name: "control.txt", in: root)
            try check(Data([65, 0x7f, 66]), binary: true, name: "delete-control.dat", in: root)
            try check(Data([0xfe, 0x42, 0x80]), binary: true, name: "invalid-utf8", in: root)
            try check(Data((0...255).map(UInt8.init)), binary: true, name: "arbitrary.data", in: root)
            print("PASS: NUL, non-text controls and invalid UTF-8 identify binary content")
            let unicode = "中文 🌿 e\u{301}\r\n"
            try check(Data([0xef, 0xbb, 0xbf]) + Data(unicode.utf8), binary: false, name: "utf8-bom.bin", in: root)
            try check(Data([0xff, 0xfe]) + unicode.data(using: .utf16LittleEndian)!, binary: false, name: "utf16le.txt", in: root)
            try check(Data([0xfe, 0xff]) + unicode.data(using: .utf16BigEndian)!, binary: false, name: "utf16be.txt", in: root)
            try check(Data([0xff, 0xfe, 65, 0, 0, 0]), binary: true, name: "utf16-nul.bin", in: root)
            try check(Data([0xff, 0xfe, 65]), binary: true, name: "utf16-odd.bin", in: root)
            try check(Data([0xfe, 0xff, 0xd8, 0x00]), binary: true, name: "utf16-unpaired.bin", in: root)
            try check(Data([65, 0, 66, 0]), binary: true, name: "utf16-without-bom.bin", in: root)
            print("PASS: UTF-8/UTF-16 BOM text is recognized; malformed and unsupported UTF-16 stays binary")
            for (character, length) in [("é", 2), ("中", 3), ("🌿", 4)] {
                for split in 1..<length {
                    try check(Data(repeating: 65, count: 8192 - split) + Data((character + "tail").utf8),
                              binary: false, name: "utf8-boundary-\(length)-\(split)", in: root)
                }
            }
            try check(Data(repeating: 65, count: 8191) + Data([0xc3]), binary: true, name: "utf8-incomplete-at-eof", in: root)
            try check(Data(repeating: 65, count: 8190) + Data([0xe0, 0x80, 0x80]), binary: true, name: "utf8-overlong-boundary", in: root)
            try check(Data(repeating: 65, count: 8190) + Data([0xed, 0xa0, 0x80]), binary: true, name: "utf8-surrogate-boundary", in: root)
            try check(Data(repeating: 65, count: 8190) + Data([0xf4, 0x90, 0x80, 0x80]), binary: true, name: "utf8-out-of-range-boundary", in: root)
            print("PASS: incomplete UTF-8 at the sample boundary stays text; invalid sequences and incomplete EOF stay binary")
            let boundaryText = String(repeating: "A", count: 4094) + "🌿"
            try check(Data([0xff, 0xfe]) + boundaryText.data(using: .utf16LittleEndian)!, binary: false, name: "utf16le-boundary", in: root)
            try check(Data([0xfe, 0xff]) + boundaryText.data(using: .utf16BigEndian)!, binary: false, name: "utf16be-boundary", in: root)
            try check(Data([0xfe, 0xff]) + String(repeating: "A", count: 4094).data(using: .utf16BigEndian)! + Data([0xd8, 0x3c]), binary: true, name: "utf16-boundary-eof", in: root)
            print("PASS: a UTF-16 surrogate pair may cross the sampling boundary but not the file end")
            try check(Data(), binary: false, name: "empty.bin", in: root)
            try check(Data([0xef, 0xbb, 0xbf]), binary: false, name: "utf8-bom-only", in: root)
            try check(Data([0xff, 0xfe]), binary: false, name: "utf16-bom-only", in: root)
            try check(Data("ordinary printable text".utf8), binary: false, name: "printable.bin", in: root)
            print("PASS: empty files, BOM-only text and printable .bin files remain text")
            let large = root.appendingPathComponent("large-sparse.unknown")
            try Data(repeating: 65, count: 8192).write(to: large)
            let descriptor = open(large.path, O_WRONLY | O_CLOEXEC)
            try expect(descriptor >= 0, "Could not open sparse fixture")
            let truncated = ftruncate(descriptor, off_t(5 * 1024 * 1024 * 1024))
            close(descriptor)
            try expect(truncated == 0, "Could not create sparse fixture")
            // NUL bytes immediately after the known 8 KiB prefix prove this is a
            // bounded hint, not complete-file validation or the 20 MiB text reader.
            try expect(try !BinaryFileDetection.isLikelyBinary(url: large), "Large files should inspect only the bounded prefix")
            print("PASS: a 5 GiB sparse file is inspected only through its text prefix without a text size limit")
            let fifo = root.appendingPathComponent("input.fifo")
            try expect(mkfifo(fifo.path, 0o600) == 0, "Could not create FIFO fixture")
            let started = ProcessInfo.processInfo.systemUptime
            for url in [root, fifo] {
                do {
                    _ = try BinaryFileDetection.isLikelyBinary(url: url)
                    throw CheckFailure(description: "Directory or FIFO was accepted: " + url.lastPathComponent)
                } catch BinaryFileDetectionError.notRegularFile { }
            }
            try expect(ProcessInfo.processInfo.systemUptime - started < 1, "Special-file rejection should not block")
            do {
                _ = try BinaryFileDetection.isLikelyBinary(url: URL(string: "https://fixture.invalid/data")!)
                throw CheckFailure(description: "Non-file URL was accepted")
            } catch BinaryFileDetectionError.notLocalFile { }
            let link = root.appendingPathComponent("linked-input")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: large)
            do {
                _ = try BinaryFileDetection.isLikelyBinary(url: link)
                throw CheckFailure(description: "Symbolic link was followed")
            } catch let failure as CheckFailure { throw failure }
            catch { }
            print("PASS: directories, FIFO, non-file URLs and symlinks are rejected without blocking")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
