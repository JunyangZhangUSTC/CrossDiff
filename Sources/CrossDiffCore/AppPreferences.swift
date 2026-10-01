import Foundation

public struct AppPreferences: Codable, Equatable, Sendable {
    public var language: AppLanguage
    public var isDark: Bool

    public init(language: AppLanguage, isDark: Bool = false) {
        self.language = language
        self.isDark = isDark
    }
}

public enum PreferencesFile {
    /// A missing file is a first launch. Malformed or inaccessible preferences are reported.
    public static func load(from url: URL) throws -> AppPreferences? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               failure.code == CocoaError.fileReadNoSuchFile.rawValue || failure.code == CocoaError.fileNoSuchFile.rawValue { return nil }
            throw error
        }
        return try JSONDecoder().decode(AppPreferences.self, from: data)
    }

    public static func save(_ preferences: AppPreferences, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
