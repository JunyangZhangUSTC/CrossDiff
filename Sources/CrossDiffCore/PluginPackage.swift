import Foundation
import CryptoKit
import Darwin

/// A bounded UTF-8 JSON package. The digest covers the payload bytes, not publisher identity.
public struct PluginPackage: Codable, Equatable, Sendable {
    public static let maximumPackageBytes = 16 * 1024 * 1024
    public static let maximumScriptBytes = 2 * 1024 * 1024
    public static let maximumExecutableBytes = 8 * 1024 * 1024

    public let formatVersion: Int
    public let manifest: PluginManifest
    public let script: String?
    public let executable: Data?
    public let sha256: String

    public init(formatVersion: Int = 1, manifest: PluginManifest, script: String? = nil,
                executable: Data? = nil, sha256: String) {
        self.formatVersion = formatVersion; self.manifest = manifest
        self.script = script; self.executable = executable; self.sha256 = sha256
    }

    /// Call validate before using a payload. Invalid mixed/empty packages are never executable.
    public var payloadData: Data { script.map { Data($0.utf8) } ?? executable ?? Data() }
    public var payloadSHA256: String { Self.digest(of: payloadData) }
    public static func digest(of data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public func validate(hostProtocol: Int = PluginProtocol.version) throws {
        guard formatVersion == 1 else { throw PluginValidationError.unsupportedProtocol }
        try manifest.validate(hostProtocol: hostProtocol)
        switch manifest.runtime {
        case .restrictedJavaScript:
            guard let script, !script.isEmpty, executable == nil else { throw PluginValidationError.invalidPayload }
            guard script.utf8.count <= Self.maximumScriptBytes else { throw PluginValidationError.sizeLimit }
        case .trustedExecutable:
            guard let executable, !executable.isEmpty, script == nil else { throw PluginValidationError.invalidPayload }
            guard executable.count <= Self.maximumExecutableBytes else { throw PluginValidationError.sizeLimit }
        }
        guard sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              sha256 == payloadSHA256 else { throw PluginValidationError.digestMismatch }
    }

    public static func decode(data: Data) throws -> PluginPackage {
        guard data.count <= maximumPackageBytes else { throw PluginValidationError.sizeLimit }
        guard String(data: data, encoding: .utf8) != nil else { throw PluginValidationError.invalidField("UTF-8 package") }
        let package = try JSONDecoder().decode(PluginPackage.self, from: data)
        try package.validate()
        return package
    }

    /// Opens only a regular file and refuses a final symbolic link, without mapping the input.
    public static func load(from url: URL) throws -> PluginPackage {
        try decode(data: readRegularFile(from: url, maximumBytes: maximumPackageBytes))
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumPackageBytes else { throw PluginValidationError.sizeLimit }
        return data
    }

    static func readRegularFile(from url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL else { throw PluginValidationError.unsafeStore }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw posixError() }
        guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw PluginValidationError.unsafeStore }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw PluginValidationError.sizeLimit }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { break }
            guard count <= maximumBytes - result.count else { throw PluginValidationError.sizeLimit }
            result.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw posixError() }
        guard before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw PluginValidationError.digestMismatch }
        return result
    }

    static func posixError() -> Error { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

extension PluginManifest {
    public func validate(hostProtocol: Int = PluginProtocol.version) throws {
        guard Self.validIdentifier(id) else { throw PluginValidationError.invalidField("id") }
        guard Self.validVersion(version) else { throw PluginValidationError.invalidField("version") }
        guard Self.validText(name, maximumBytes: 512), Self.validText(summary, maximumBytes: 4096) else {
            throw PluginValidationError.invalidField("name / summary")
        }
        guard (1...32).contains(fileExtensions.count), Set(fileExtensions).count == fileExtensions.count,
              fileExtensions.allSatisfy({ $0.utf8.count <= 16 && $0.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil }) else {
            throw PluginValidationError.invalidField("fileExtensions")
        }
        guard (resultView == "table" && (inputKind == .text || inputKind == .pdf))
                || (resultView == "documentPages" && inputKind == .pdf)
                || (resultView == "archiveTree" && inputKind == .archiveCatalog)
                || (resultView == "photography" && inputKind == .photoAnalysis)
                || (resultView == "apiExchange" && inputKind == .httpExchange)
                || (resultView == "audioTimeline" && inputKind == .audioAnalysis)
                || (resultView == "officeDocuments" && inputKind == .officeDocument)
                || (resultView == "videoTimeline" && inputKind == .videoAnalysis) else {
            throw PluginValidationError.invalidField("resultView")
        }
        guard !supportedModes.isEmpty, Set(supportedModes).count == supportedModes.count else {
            throw PluginValidationError.invalidField("supportedModes")
        }
        guard (inputKind != .archiveCatalog && inputKind != .photoAnalysis && inputKind != .httpExchange && inputKind != .audioAnalysis && inputKind != .officeDocument && inputKind != .videoAnalysis) || supportedModes == [.pairwise] else {
            throw PluginValidationError.unsupportedMode
        }
        guard minHostProtocol >= 1, maxHostProtocol >= minHostProtocol,
              hostProtocol >= minHostProtocol, hostProtocol <= maxHostProtocol else {
            throw PluginValidationError.unsupportedProtocol
        }
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.range(of: #"^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$"#, options: .regularExpression) != nil
    }
    static func validVersion(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#, options: .regularExpression) != nil
    }
    static func validText(_ value: PluginLocalizedText, maximumBytes: Int) -> Bool {
        !value.zhHans.isEmpty && !value.en.isEmpty && value.zhHans.utf8.count <= maximumBytes && value.en.utf8.count <= maximumBytes
    }
}
