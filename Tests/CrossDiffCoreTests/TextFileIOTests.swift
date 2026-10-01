import XCTest
@testable import CrossDiffCore

final class TextFileIOTests: XCTestCase {
    func testUTF16AndNewlinesSurviveSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("paper.txt")
        let original = "中文 👩🏽‍💻\r\n第二行\r\n"
        try TextFileIO.encoded(original, encoding: .utf16LE).write(to: file)
        let loaded = try TextFileIO.read(file)
        XCTAssertEqual(loaded.text, original)
        XCTAssertEqual(loaded.encoding, .utf16LE)
        try TextFileIO.write(original + "追加", to: file, encoding: loaded.encoding, expectedSignature: loaded.signature)
        XCTAssertEqual(try TextFileIO.read(file).text, original + "追加")
    }
    func testExternalEditIsNeverOverwrittenBySave() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("original".utf8).write(to: file)
        let loaded = try TextFileIO.read(file)
        try Data("external changes".utf8).write(to: file)
        XCTAssertThrowsError(try TextFileIO.write("my changes", to: file, encoding: .utf8, expectedSignature: loaded.signature))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external changes")
    }
    func testSessionsRestoreUnsavedTextAndCanBeCleared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sessions.json")
        let record = StoredComparison(kind: "text", left: .init(text: "未保存", savedText: "原文"), right: .init(text: "another"))
        try SessionFile.save([record], to: file)
        let restored = try SessionFile.load(from: file)
        XCTAssertEqual(restored.first?.left.text, "未保存")
        XCTAssertEqual(restored.first?.left.savedText, "原文")
        try SessionFile.clear(at: file)
        XCTAssertTrue(try SessionFile.load(from: file).isEmpty)
    }
}
