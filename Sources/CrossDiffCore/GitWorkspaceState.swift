import Foundation

public enum GitRevisionSourceKind: String, Codable, CaseIterable, Sendable {
    case commit, index, workingTree
    public var title: String {
        switch self {
        case .commit: return L("提交 / 分支", "Commit / Branch")
        case .index: return L("暂存区", "Staging Area")
        case .workingTree: return L("工作区", "Working Tree")
        }
    }
}

/// Only repository identity and viewing preferences are persisted, never blob contents or credentials.
public struct GitWorkspaceState: Codable, Equatable, Sendable {
    public var source: String
    public var isRemote: Bool
    public var cacheID: String
    public var leftRevision: String = ""
    public var rightRevision: String = ""
    public var leftKind: GitRevisionSourceKind = .commit
    public var rightKind: GitRevisionSourceKind = .commit
    public var includeUntracked = true
    public var differencesOnly = true
    public var detectRenames = true
    public var useMergeBase = false
    public var selectedPath: String?
    public init(source: String, isRemote: Bool, cacheID: String = UUID().uuidString) {
        self.source = source; self.isRemote = isRemote; self.cacheID = cacheID
    }
    private enum CodingKeys: String, CodingKey {
        case source, isRemote, cacheID, leftRevision, rightRevision, leftKind, rightKind
        case includeUntracked, differencesOnly, detectRenames, useMergeBase, selectedPath
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(String.self, forKey: .source)
        isRemote = try values.decode(Bool.self, forKey: .isRemote)
        cacheID = try values.decode(String.self, forKey: .cacheID)
        leftRevision = try values.decodeIfPresent(String.self, forKey: .leftRevision) ?? ""
        rightRevision = try values.decodeIfPresent(String.self, forKey: .rightRevision) ?? ""
        // Earlier Git sessions always compared two committed revisions.
        leftKind = try values.decodeIfPresent(GitRevisionSourceKind.self, forKey: .leftKind) ?? .commit
        rightKind = try values.decodeIfPresent(GitRevisionSourceKind.self, forKey: .rightKind) ?? .commit
        includeUntracked = try values.decodeIfPresent(Bool.self, forKey: .includeUntracked) ?? true
        differencesOnly = try values.decodeIfPresent(Bool.self, forKey: .differencesOnly) ?? true
        detectRenames = try values.decodeIfPresent(Bool.self, forKey: .detectRenames) ?? true
        useMergeBase = try values.decodeIfPresent(Bool.self, forKey: .useMergeBase) ?? false
        selectedPath = try values.decodeIfPresent(String.self, forKey: .selectedPath)
    }
    public var isValid: Bool {
        !source.isEmpty && source.utf8.count <= 4096 && !source.contains("\0") && UUID(uuidString: cacheID) != nil &&
        leftRevision.utf8.count <= 1024 && rightRevision.utf8.count <= 1024 &&
        (selectedPath?.utf8.count ?? 0) <= 16384
    }
}
