import Foundation
import CrossDiffCore

// CI captures stdout through a pipe. Keep completed checks visible if a later one crashes.
setbuf(stdout, nil)

func runStorageChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CrossDiff-storage-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = "中文 👩🏽‍💻\r\n第二行\r\n"
    for encoding in [TextFileEncoding.utf8, .utf8BOM, .utf16LE, .utf16BE] {
        let file = directory.appendingPathComponent(encoding.rawValue + ".txt")
        try TextFileIO.encoded(original, encoding: encoding).write(to: file)
        let loaded = try TextFileIO.read(file)
        precondition(loaded.text == original && loaded.encoding == encoding)
        try TextFileIO.write(original + "追加", to: file, encoding: encoding, expectedSignature: loaded.signature)
        let saved = try TextFileIO.read(file)
        precondition(saved.text == original + "追加")
        try Data("external changes".utf8).write(to: file)
        do {
            try TextFileIO.write("my changes", to: file, encoding: encoding, expectedSignature: saved.signature)
            preconditionFailure("External changes must not be overwritten")
        } catch TextFileError.changedOnDisk {}
        let external = try String(contentsOf: file, encoding: .utf8)
        precondition(external == "external changes")
    }
    let binary = directory.appendingPathComponent("binary.bin")
    try Data([0, 1, 2, 3]).write(to: binary)
    do { _ = try TextFileIO.read(binary); preconditionFailure("Binary file accepted as text") } catch TextFileError.unsupportedEncoding {}
    let file = directory.appendingPathComponent("sessions.json")
    let session = StoredComparison(kind: "text", left: .init(text: "未保存", savedText: "原文"), right: .init(text: "second"))
    try SessionFile.save([session], to: file)
    let restored = try SessionFile.load(from: file)
    precondition(restored.first?.left.text == "未保存" && restored.first?.left.savedText == "原文")
    try SessionFile.clear(at: file)
    let empty = try SessionFile.load(from: file)
    precondition(empty.isEmpty)
    print("✓ Storage: UTF-8/UTF-16 and newlines, external-edit protection, binary rejection, unsaved-session recovery and clearing")
}

do {
    try runLocalizationChecks()
    try runTextChecks()
    try runLinePairingChecks()
    try runDeletionPreviewChecks()
    try runPreviewCopyChecks()
    try runSearchPersistenceChecks()
    try runTextReplacementChecks()
    try runFolderChecks()
    try runStorageChecks()
    print("All CrossDiff core checks passed.")
} catch {
    fputs("CrossDiff check failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
