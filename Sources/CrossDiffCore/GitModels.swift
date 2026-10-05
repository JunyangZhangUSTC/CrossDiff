import Foundation

public enum GitReferenceKind: String, Sendable { case branch, remoteBranch, tag }
public struct GitReference: Identifiable, Sendable {
    public let fullName: String
    public let name: String
    public let objectID: String
    public let kind: GitReferenceKind
    public var id: String { Data(fullName.utf8).base64EncodedString() }
}
public struct GitCommit: Identifiable, Equatable, Sendable {
    public let objectID: String
    public let subject: String
    public let author: String
    public let date: Date
    public var id: String { objectID }
    public var shortID: String { String(objectID.prefix(8)) }
}
public enum GitObjectKind: String, Sendable { case blob, symbolicLink, submodule }
public struct GitTreeEntry: Identifiable, Equatable, Sendable {
    public let path: String
    public let objectID: String
    public let mode: String
    public let size: Int?
    public let kind: GitObjectKind
    // Git paths use byte identity; Swift String equality normalizes Unicode.
    public var id: String { Data(path.utf8).base64EncodedString() }
}
public enum GitChangeKind: String, CaseIterable, Sendable {
    case unchanged, added, deleted, modified, renamed, typeChanged
    public var title: String {
        switch self {
        case .unchanged: return L("相同", "Unchanged")
        case .added: return L("新增", "Added")
        case .deleted: return L("删除", "Deleted")
        case .modified: return L("修改", "Modified")
        case .renamed: return L("重命名", "Renamed")
        case .typeChanged: return L("类型变化", "Type changed")
        }
    }
}
public struct GitFileChange: Identifiable, Equatable, Sendable {
    public let left: GitTreeEntry?
    public let right: GitTreeEntry?
    public let kind: GitChangeKind
    public let similarity: Int?
    public var path: String { right?.path ?? left?.path ?? "" }
    public var id: String { (left?.id ?? "-") + ":" + (right?.id ?? "-") }
}
public struct GitComparisonOptions: Codable, Equatable, Sendable {
    public var detectRenames: Bool
    public var renameThreshold: Int
    public var useMergeBase: Bool
    public init(detectRenames: Bool = true, renameThreshold: Int = 50, useMergeBase: Bool = false) {
        self.detectRenames = detectRenames
        self.renameThreshold = renameThreshold
        self.useMergeBase = useMergeBase
    }
}
public struct GitComparison: Sendable {
    public let leftCommit: GitCommit
    public let rightCommit: GitCommit
    public let leftTree: [GitTreeEntry]
    public let rightTree: [GitTreeEntry]
    public let files: [GitFileChange]
    public let mergeBaseObjectID: String?
    public var changedFiles: [GitFileChange] { files.filter { $0.kind != .unchanged } }
}
/// Content bytes actually read by a working-tree scan. Reported synchronously on
/// the calling thread; UI consumers must explicitly dispatch to the main actor.
public struct GitScanProgress: Sendable {
    public let bytesRead: UInt64
    public let filesScanned: Int
    public let currentPath: String?
}
public enum GitComparisonSource: Codable, Equatable, Sendable {
    case commit(String), index, workingTree
    public var isCommit: Bool { if case .commit = self { return true }; return false }
}
public struct GitComparisonSnapshot: Sendable {
    public let source: GitComparisonSource
    public let commit: GitCommit?
    public let identity: String
    public let entries: [GitTreeEntry]
    public let isEmptyBaseline: Bool
    public var displayName: String {
        switch source {
        case .commit(let revision): return isEmptyBaseline ? L("HEAD（尚无提交）", "HEAD (no commits yet)") : revision
        case .index: return L("暂存区", "Staging area")
        case .workingTree: return L("工作区", "Working tree")
        }
    }
    public var shortLabel: String { commit?.shortID ?? displayName }
    let repositoryPath: String
    let workingFiles: [Data: GitWorkingFileRecord]
    let rootStamp: GitFileStamp?
    let indexBackedPaths: Set<Data>
}
public struct GitSourceComparison: Sendable {
    public let leftSnapshot: GitComparisonSnapshot
    public let rightSnapshot: GitComparisonSnapshot
    public let files: [GitFileChange]
    public let mergeBaseObjectID: String?
    public var leftTree: [GitTreeEntry] { leftSnapshot.entries }
    public var rightTree: [GitTreeEntry] { rightSnapshot.entries }
    public var changedFiles: [GitFileChange] { files.filter { $0.kind != .unchanged } }
    public var exactRenamesOnly: Bool { !leftSnapshot.source.isCommit || !rightSnapshot.source.isCommit }
}
public enum GitError: LocalizedError {
    case unavailable, notRepository, emptyRepository, invalidRevision, invalidRemote, missingObject
    case invalidOutput, unsupportedPath, tooLarge, cancelled, timeout, readOnlyRepository
    case destinationExists, networkFailed, commandFailed, noMergeBase, ambiguousMergeBase
    case bareLocalSource, unmergedIndex, snapshotChanged, unsafeWorkingPath, unsupportedWorkingFile, localMergeBase
    public var errorDescription: String? {
        switch self {
        case .unavailable: return L("未找到可用的系统 Git。请先安装 Apple Command Line Tools。", "System Git is unavailable. Install Apple Command Line Tools first.")
        case .notRepository: return L("所选目录不是可读取的 Git 仓库。", "The selected folder is not a readable Git repository.")
        case .emptyRepository: return L("这个仓库尚未包含提交。", "This repository does not contain any commits yet.")
        case .invalidRevision: return L("无法找到该提交或分支。请输入有效的分支、标签或提交哈希。", "This revision could not be resolved. Enter a valid branch, tag, or commit hash.")
        case .invalidRemote: return L("请输入仓库的 HTTPS 或 SSH 克隆地址；不要包含密码、令牌、查询参数或网页中的文件路径。", "Enter an HTTPS or SSH repository clone URL, without passwords, tokens, query parameters, or a web file path.")
        case .missingObject: return L("仓库缺少需要的对象。请先在仓库中补全历史，再重新打开。", "Required Git objects are missing. Complete the repository history, then reopen it.")
        case .invalidOutput: return L("无法完整读取 Git 的比较结果。", "Git returned an incomplete or unsupported comparison result.")
        case .unsupportedPath: return L("仓库含有非 UTF-8 文件名，无法无损显示。本次比较未生成不完整结果。", "This repository contains non-UTF-8 filenames that cannot be displayed losslessly. No partial result was produced.")
        case .tooLarge: return L("此文件或比较结果超出预览大小限制，内容未被修改。", "This file or result exceeds the preview size limit. Its contents have not been changed.")
        case .cancelled: return L("Git 操作已取消。", "The Git operation was cancelled.")
        case .timeout: return L("Git 操作超时。请缩小比较范围，或检查网络后重试。", "The Git operation timed out. Try a smaller repository or check your connection.")
        case .readOnlyRepository: return L("本地仓库仅供读取；只能刷新由 CrossDiff 下载的仓库缓存。", "Local repositories are read-only. Only repository caches downloaded by CrossDiff can be refreshed.")
        case .destinationExists: return L("目标缓存目录已存在，请选择新的缓存目录。", "The repository cache destination already exists. Choose a new cache directory.")
        case .networkFailed: return L("无法下载仓库。HTTPS 支持公开仓库；SSH 需要已配置的密钥和受信任的主机。私有 HTTPS 仓库可先自行克隆，再打开本地目录。", "The repository could not be downloaded. HTTPS supports public repositories; SSH requires an existing key and trusted host. For private HTTPS repositories, clone locally first and open that folder.")
        case .noMergeBase: return L("两个版本没有共同祖先，请关闭共同祖先比较。", "These revisions have no common ancestor. Turn off merge-base comparison.")
        case .ambiguousMergeBase: return L("两个版本有多个共同祖先，请选择明确的提交进行比较。", "These revisions have multiple merge bases. Select an explicit commit to compare.")
        case .bareLocalSource: return L("裸仓库没有暂存区或工作区，请选择提交或分支。", "Bare repositories do not have a staging area or working tree. Select commits or branches.")
        case .unmergedIndex: return L("暂存区含有未解决的合并冲突。请先解决冲突，再刷新比较。", "The index contains unresolved merge stages. Resolve those conflicts, then refresh the comparison.")
        case .snapshotChanged: return L("工作区或暂存区在读取期间发生了变化。请刷新比较，避免显示不一致的内容。", "The working tree or index changed while being read. Refresh the comparison to avoid inconsistent contents.")
        case .unsafeWorkingPath: return L("工作区路径经过符号链接或无效目录，未跟随读取。请检查路径后刷新。", "A working-tree path passes through a symlink or invalid directory and was not followed. Check the path, then refresh.")
        case .unsupportedWorkingFile: return L("工作区含有不支持的特殊文件，无法生成完整快照。", "The working tree contains an unsupported special file, so a complete snapshot could not be created.")
        case .localMergeBase: return L("共同祖先比较只适用于两个提交或分支。暂存区和工作区请使用直接比较。", "Merge-base comparison requires two commits or branches. Use direct comparison for the staging area or working tree.")
        case .commandFailed: return L("Git 操作失败；原仓库和工作区未被修改。", "The Git operation failed. The original repository and working tree were not modified.")
        }
    }
}

public enum GitBlobText {
    public static func decode(_ data: Data) -> String? {
        // UTF-32 is not a text-preview format; do not mistake its BOM for UTF-16.
        if data.starts(with: [0xFF, 0xFE, 0, 0]) || data.starts(with: [0, 0, 0xFE, 0xFF]) { return nil }
        let payload: Data, encoding: String.Encoding
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { payload = Data(data.dropFirst(3)); encoding = .utf8 }
        else if data.starts(with: [0xFF, 0xFE]) { payload = Data(data.dropFirst(2)); encoding = .utf16LittleEndian }
        else if data.starts(with: [0xFE, 0xFF]) { payload = Data(data.dropFirst(2)); encoding = .utf16BigEndian }
        else { guard !data.contains(0) else { return nil }; payload = data; encoding = .utf8 }
        guard let text = String(data: payload, encoding: encoding) else { return nil }
        guard !text.unicodeScalars.contains(where: { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }) else { return nil }
        return text
    }
}

/// Keep catalog ordering interruptible even after the subprocess has completed.
enum GitCatalogSort {
    static func sorted<C: Collection>(_ values: C, isCancelled: () -> Bool,
                                      by ordered: (C.Element, C.Element) -> Bool) throws -> [C.Element] {
        if isCancelled() { throw GitError.cancelled }
        var comparisons = 0
        let result = try values.sorted { a, b in
            comparisons += 1
            if comparisons & 1023 == 0, isCancelled() { throw GitError.cancelled }
            return ordered(a, b)
        }
        if isCancelled() { throw GitError.cancelled }
        return result
    }
}
