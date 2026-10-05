import Foundation

public struct GitRemote: Equatable, Sendable {
    public let url: String
    public let displayName: String

    public static func parse(_ input: String) throws -> GitRemote {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4096,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !value.hasPrefix("-"), !value.contains("\\") else { throw GitError.invalidRemote }
        // SCP syntax has no URL parser: accept only a restricted SSH username/host and path.
        if !value.contains("://"), let colon = value.firstIndex(of: ":") {
            let authority = String(value[..<colon]), path = String(value[value.index(after: colon)...])
            let parts = authority.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count <= 2, let host = parts.last, validHost(String(host)),
                  parts.count == 1 || validUser(String(parts[0])), validPath(path), !path.hasPrefix("/") else { throw GitError.invalidRemote }
            return GitRemote(url: value, displayName: String(host) + "/" + path)
        }
        guard var components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
              ["https", "ssh"].contains(scheme), let host = components.host, validHost(host),
              components.password == nil, components.query == nil, components.fragment == nil,
              scheme != "https" || components.user == nil,
              components.user == nil || validUser(components.user!),
              components.port == nil || (1...65535).contains(components.port!),
              validPath(components.path) else { throw GitError.invalidRemote }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let segments = path.split(separator: "/").map(String.init)
        if ["github.com", "gitee.com"].contains(host.lowercased()) {
            guard segments.count == 2 else { throw GitError.invalidRemote }
            if !path.hasSuffix(".git") { path += ".git" }
        }
        if host.lowercased() == "gitlab.com" {
            guard segments.count >= 2, !segments.contains("-") else { throw GitError.invalidRemote }
            if !path.hasSuffix(".git") { path += ".git" }
        }
        // Self-hosted services may have arbitrary path layouts: preserve the clone URL.
        guard !segments.contains("-"), !segments.contains("blob"), !segments.contains("tree") else { throw GitError.invalidRemote }
        components.scheme = scheme; components.host = host.lowercased(); components.path = path
        guard let normalized = components.string else { throw GitError.invalidRemote }
        return GitRemote(url: normalized, displayName: host + path)
    }

    private static func validUser(_ value: String) -> Bool {
        !value.isEmpty && value.first != "-" && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
    private static func validHost(_ value: String) -> Bool {
        !value.isEmpty && value.first != "-" && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 91, 93].contains($0)
        }
    }
    private static func validPath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("~"), !value.contains("%"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { return false }
        let pieces = value.split(separator: "/", omittingEmptySubsequences: true)
        return !pieces.isEmpty && pieces.allSatisfy { $0 != "." && $0 != ".." && !$0.hasPrefix("-") && !$0.hasPrefix("~") }
    }
}
