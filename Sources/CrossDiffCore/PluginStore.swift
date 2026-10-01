import Foundation
import Darwin

public struct PluginInstallation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let activeVersion: String
    public let previousVersion: String?
    public let isEnabled: Bool
    /// Approval applies only to this installation's active native payload, never to its publisher name.
    public let approvedNativeDigest: String?
}

/// A local installation registry. Each instance serializes access; external metadata changes require reopening.
/// Version directories are immutable. A failed metadata commit never changes the visible active state.
public final class PluginStore {
    public let root: URL
    private let reservedBundledIDs: Set<String>
    private let lock = NSLock()
    private var state: State
    private var persistedBytes: Data?
    private let fileManager = FileManager.default

    private struct Version: Codable {
        let payloadDigest: String
        let approvedNativeDigest: String?
    }
    private struct Record: Codable {
        var activeVersion: String
        var previousVersion: String?
        var isEnabled: Bool
        var versions: [String: Version]
    }
    private struct State: Codable {
        var formatVersion = 1
        var plugins: [String: Record] = [:]
    }

    public init(root: URL, reservedBundledIDs: Set<String> = []) throws {
        guard root.isFileURL else { throw PluginValidationError.unsafeStore }
        self.root = root.standardizedFileURL
        self.reservedBundledIDs = reservedBundledIDs
        self.state = State()
        try ensureDirectory(self.root, createParents: true)
        try ensureDirectory(versionsURL)
        try ensureDirectory(stagingURL)
        if try exists(metadataURL) {
            let data = try PluginPackage.readRegularFile(from: metadataURL, maximumBytes: 1024 * 1024)
            let loaded: State
            do { loaded = try JSONDecoder().decode(State.self, from: data) }
            catch { throw PluginValidationError.corruptStore }
            guard loaded.formatVersion == 1, loaded.plugins.count <= 256 else { throw PluginValidationError.corruptStore }
            for (id, record) in loaded.plugins {
                // Switching editions may newly bundle an installed identifier.
                // Preserve its local registration; new installs remain rejected.
                guard PluginManifest.validIdentifier(id),
                      record.versions.count <= 64, record.versions[record.activeVersion] != nil,
                      record.previousVersion.map({ record.versions[$0] != nil && $0 != record.activeVersion }) ?? true else {
                    throw PluginValidationError.corruptStore
                }
                for (version, saved) in record.versions {
                    guard PluginManifest.validVersion(version), Self.validDigest(saved.payloadDigest),
                          saved.approvedNativeDigest == nil || saved.approvedNativeDigest == saved.payloadDigest else {
                        throw PluginValidationError.corruptStore
                    }
                }
            }
            state = loaded; persistedBytes = data
        }
    }

    public func list() -> [PluginInstallation] {
        locked { state.plugins.keys.sorted().compactMap { installation(id: $0) } }
    }

    public func package(id: String) throws -> PluginPackage {
        try locked {
            guard let record = state.plugins[id] else { throw PluginValidationError.missingPlugin }
            return try loadPackage(id: id, version: record.activeVersion, record: record)
        }
    }

    @discardableResult
    public func install(_ package: PluginPackage, approvedNativeDigest: String? = nil,
                        sourceQuarantine: Data? = nil) throws -> PluginInstallation {
        try locked {
            try package.validate()
            let id = package.manifest.id, version = package.manifest.version
            guard !reservedBundledIDs.contains(id) else { throw PluginValidationError.reservedIdentifier }
            guard state.plugins[id] != nil || state.plugins.count < 256 else { throw PluginValidationError.sizeLimit }
            let approved: String?
            if package.manifest.runtime == .trustedExecutable {
                guard approvedNativeDigest == package.sha256 else { throw PluginValidationError.nativeTrustRequired }
                approved = approvedNativeDigest
            } else { approved = nil }
            guard sourceQuarantine == nil || sourceQuarantine!.count <= 4096 else { throw PluginValidationError.sizeLimit }
            try validateRoot()
            try checkMetadataUnchanged()
            let parent = versionsURL.appendingPathComponent(id, isDirectory: true)
            try ensureDirectory(parent)
            let destination = parent.appendingPathComponent(version, isDirectory: true)
            let alreadyExists = try exists(destination)
            if alreadyExists {
                try ensureDirectory(destination)
                let saved = try PluginPackage.load(from: destination.appendingPathComponent("package.crossdiffplugin"))
                guard saved == package else { throw PluginValidationError.immutableVersionConflict }
                try validateNativeExecutable(package: package, directory: destination)
                if let record = state.plugins[id], record.activeVersion == version {
                    _ = try loadPackage(id: id, version: version, record: record)
                    return installation(id: id)!
                }
            } else {
                let stage = stagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try ensureDirectory(stage)
                defer { try? fileManager.removeItem(at: stage) }
                let dataURL = stage.appendingPathComponent("package.crossdiffplugin")
                try package.encoded().write(to: dataURL, options: .withoutOverwriting)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dataURL.path)
                if let executable = package.executable {
                    let executableURL = stage.appendingPathComponent("plugin-executable")
                    try executable.write(to: executableURL, options: .withoutOverwriting)
                    if let sourceQuarantine {
                        let result = sourceQuarantine.withUnsafeBytes { bytes in
                            setxattr(executableURL.path, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
                        }
                        guard result == 0 else { throw PluginPackage.posixError() }
                    }
                    try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: executableURL.path)
                }
                try fileManager.moveItem(at: stage, to: destination)
            }
            var next = state
            var record = next.plugins[id] ?? Record(activeVersion: version, previousVersion: nil, isEnabled: true, versions: [:])
            guard record.versions[version] != nil || record.versions.count < 64 else {
                if !alreadyExists { try? fileManager.removeItem(at: destination) }
                throw PluginValidationError.sizeLimit
            }
            if record.activeVersion != version { record.previousVersion = record.activeVersion }
            record.activeVersion = version
            record.isEnabled = true
            record.versions[version] = Version(payloadDigest: package.sha256, approvedNativeDigest: approved)
            next.plugins[id] = record
            do { try persist(next) }
            catch {
                if !alreadyExists { try? fileManager.removeItem(at: destination) }
                throw error
            }
            return installation(id: id)!
        }
    }

    public func setEnabled(_ enabled: Bool, for id: String) throws {
        try locked {
            guard var record = state.plugins[id] else { throw PluginValidationError.missingPlugin }
            if enabled { _ = try loadPackage(id: id, version: record.activeVersion, record: record) }
            var next = state
            record.isEnabled = enabled
            next.plugins[id] = record
            try persist(next)
        }
    }

    @discardableResult
    public func rollback(id: String) throws -> PluginInstallation {
        try locked {
            guard var record = state.plugins[id] else { throw PluginValidationError.missingPlugin }
            guard let previous = record.previousVersion else { throw PluginValidationError.missingPreviousVersion }
            _ = try loadPackage(id: id, version: previous, record: record)
            let active = record.activeVersion
            record.activeVersion = previous
            record.previousVersion = active
            var next = state
            next.plugins[id] = record
            try persist(next)
            return installation(id: id)!
        }
    }

    /// Removes the registration atomically. False means an inactive on-disk package could not be cleaned up.
    /// Cleanup failure never restores a trusted/active registration for an uninstalled plugin.
    @discardableResult
    public func uninstall(id: String) throws -> Bool {
        try locked {
            guard state.plugins[id] != nil else { throw PluginValidationError.missingPlugin }
            var next = state
            next.plugins.removeValue(forKey: id)
            try persist(next)
            let directory = versionsURL.appendingPathComponent(id, isDirectory: true)
            do {
                if try exists(directory) {
                    try requireDirectory(directory)
                    try fileManager.removeItem(at: directory)
                }
                return true
            } catch { return false }
        }
    }

    /// Returns only digest-verified native code. The caller must still validate its signature before launching.
    public func executableURL(id: String) throws -> URL? {
        try locked {
            guard let record = state.plugins[id] else { throw PluginValidationError.missingPlugin }
            let package = try loadPackage(id: id, version: record.activeVersion, record: record)
            guard package.manifest.runtime == .trustedExecutable else { return nil }
            let url = versionsURL.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(record.activeVersion, isDirectory: true).appendingPathComponent("plugin-executable")
            return url
        }
    }

    private var metadataURL: URL { root.appendingPathComponent("state.json") }
    private var versionsURL: URL { root.appendingPathComponent("versions", isDirectory: true) }
    private var stagingURL: URL { root.appendingPathComponent("staging", isDirectory: true) }

    private func installation(id: String) -> PluginInstallation? {
        guard let record = state.plugins[id] else { return nil }
        return PluginInstallation(id: id, activeVersion: record.activeVersion, previousVersion: record.previousVersion,
                                  isEnabled: record.isEnabled, approvedNativeDigest: record.versions[record.activeVersion]?.approvedNativeDigest)
    }

    private func loadPackage(id: String, version: String, record: Record) throws -> PluginPackage {
        try validateRoot()
        guard PluginManifest.validIdentifier(id), PluginManifest.validVersion(version), let saved = record.versions[version] else {
            throw PluginValidationError.corruptStore
        }
        let parent = versionsURL.appendingPathComponent(id, isDirectory: true)
        try requireDirectory(parent)
        let directory = parent.appendingPathComponent(version, isDirectory: true)
        try requireDirectory(directory)
        let package = try PluginPackage.load(from: directory.appendingPathComponent("package.crossdiffplugin"))
        guard package.manifest.id == id, package.manifest.version == version,
              package.sha256 == saved.payloadDigest else { throw PluginValidationError.digestMismatch }
        if package.manifest.runtime == .trustedExecutable, saved.approvedNativeDigest != package.sha256 {
            throw PluginValidationError.nativeTrustRequired
        }
        try validateNativeExecutable(package: package, directory: directory)
        return package
    }

    private func validateNativeExecutable(package: PluginPackage, directory: URL) throws {
        guard package.manifest.runtime == .trustedExecutable else { return }
        let url = directory.appendingPathComponent("plugin-executable")
        let bytes = try PluginPackage.readRegularFile(from: url, maximumBytes: PluginPackage.maximumExecutableBytes)
        guard PluginPackage.digest(of: bytes) == package.sha256 else { throw PluginValidationError.digestMismatch }
        guard fileManager.isExecutableFile(atPath: url.path) else { throw PluginValidationError.unsafeStore }
    }

    private func persist(_ next: State) throws {
        try validateRoot()
        try checkMetadataUnchanged()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 1024 * 1024 else { throw PluginValidationError.sizeLimit }
        // Foundation stages a sibling and renames it; in-memory state advances only on success.
        try data.write(to: metadataURL, options: .atomic)
        state = next
        persistedBytes = data
    }

    private func checkMetadataUnchanged() throws {
        let current = try exists(metadataURL)
            ? PluginPackage.readRegularFile(from: metadataURL, maximumBytes: 1024 * 1024) : nil
        guard current == persistedBytes else { throw PluginValidationError.corruptStore }
    }

    private func validateRoot() throws {
        try requireDirectory(root)
        try requireDirectory(versionsURL)
        try requireDirectory(stagingURL)
    }
    private func ensureDirectory(_ url: URL, createParents: Bool = false) throws {
        if try !exists(url) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: createParents,
                                            attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(url)
    }
    private func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw PluginPackage.posixError() }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw PluginValidationError.unsafeStore }
    }
    private func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw PluginPackage.posixError()
    }
    private static func validDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
