import Foundation
import CrossDiffCore

func runLocalizationChecks() throws {
    let originalLanguage = Localization.language
    defer { Localization.language = originalLanguage }
    precondition(AppLanguage.preferred(for: ["zh-Hans-CN", "en-US"]) == .simplifiedChinese)
    precondition(AppLanguage.preferred(for: ["zh-Hant-TW"]) == .simplifiedChinese)
    precondition(AppLanguage.preferred(for: ["en-GB", "zh-Hans"]) == .english)
    precondition(AppLanguage.preferred(for: ["de-DE"]) == .english)
    precondition(AppLanguage.preferred(for: []) == .english)
    Localization.language = .english
    precondition(L("查找并替换", "Find and Replace") == "Find and Replace")
    Localization.language = .simplifiedChinese
    precondition(L("查找并替换", "Find and Replace") == "查找并替换")

    struct ProjectFailure: LocalizedError {
        var errorDescription: String? { L("测试操作无法完成。", "The test operation could not be completed.") }
    }
    let failures: [(Error, String, String)] = [
        (CocoaError(.fileReadNoPermission), "权限", "Permission"),
        (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue), "权限", "Permission"),
        (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue), "权限", "Permission"),
        (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue), "找不到", "could not be found"),
        (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteFileExists.rawValue), "同名", "same name"),
        (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue), "空间不足", "not enough disk space"),
        (NSError(domain: NSPOSIXErrorDomain, code: 13), "权限", "Permission"),
        (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Private payload must not be shown")), "损坏", "damaged"),
        (ProjectFailure(), "测试操作", "test operation")
    ]
    for (failure, chinese, english) in failures {
        Localization.language = .simplifiedChinese
        precondition(localizedErrorDescription(failure).contains(chinese))
        Localization.language = .english
        precondition(localizedErrorDescription(failure).contains(english))
    }
    let unexpected = NSError(domain: "CrossDiff.Test", code: 123, userInfo: [NSLocalizedDescriptionKey: "Private source content"])
    let summary = localizedErrorDescription(unexpected)
    precondition(summary.contains("CrossDiff.Test") && summary.contains("123") && !summary.contains("Private source content"))

    let directory = checkTemporaryDirectory.appendingPathComponent("CrossDiff-preferences-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("preferences.json")
    let missingPreferences = try PreferencesFile.load(from: file)
    precondition(missingPreferences == nil)
    for value in [AppPreferences(language: .english, isDark: false), AppPreferences(language: .simplifiedChinese, isDark: true)] {
        try PreferencesFile.save(value, to: file)
        let restored = try PreferencesFile.load(from: file)
        precondition(restored == value)
    }
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    precondition(permissions?.intValue == 0o600, "Preferences must be private to the current user")
    try Data("{broken-json".utf8).write(to: file)
    do {
        _ = try PreferencesFile.load(from: file)
        preconditionFailure("Malformed preferences must report a decoding error")
    } catch is DecodingError {}
    let blocked = directory.appendingPathComponent("blocked")
    try Data("file blocks directory".utf8).write(to: blocked)
    do {
        try PreferencesFile.save(AppPreferences(language: .english), to: blocked.appendingPathComponent("preferences.json"))
        preconditionFailure("A failed save must be surfaced")
    } catch {}
    print("✓ Localization: language fallback and live lookup, bilingual error details, private language/appearance persistence, malformed settings and save errors")
}
