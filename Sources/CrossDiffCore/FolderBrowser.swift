import Foundation

public enum FolderBrowserMode: String, CaseIterable, Sendable { case tree, list }
public enum FolderBrowserFilter: String, CaseIterable, Sendable {
    case all, differences, changed, leftOnly, rightOnly, issues, pending
}
public enum FolderBrowserSortKey: String, CaseIterable, Sendable {
    case name, status, leftSize, rightSize, leftModified, rightModified
}

public struct FolderBrowserSort: Equatable, Sendable {
    public var key: FolderBrowserSortKey
    public var ascending: Bool
    public init(key: FolderBrowserSortKey = .name, ascending: Bool = true) {
        self.key = key; self.ascending = ascending
    }
}

/// Counts terminal items, empty directories and a directory's own problem once.
/// Derived "modified" states on ancestor directories never inflate these totals.
public struct FolderBrowserCounts: Equatable, Sendable {
    public let total: Int
    public let same: Int
    public let changed: Int
    public let leftOnly: Int
    public let rightOnly: Int
    public let issues: Int
    public let pending: Int

    public init(total: Int = 0, same: Int = 0, changed: Int = 0, leftOnly: Int = 0,
                rightOnly: Int = 0, issues: Int = 0, pending: Int = 0) {
        self.total = total; self.same = same; self.changed = changed
        self.leftOnly = leftOnly; self.rightOnly = rightOnly
        self.issues = issues; self.pending = pending
    }

    public func count(for filter: FolderBrowserFilter) -> Int {
        switch filter {
        case .all: return total
        case .differences: return total - same
        case .changed: return changed
        case .leftOnly: return leftOnly
        case .rightOnly: return rightOnly
        case .issues: return issues
        case .pending: return pending
        }
    }

    fileprivate func adding(_ other: Self) -> Self {
        Self(total: total + other.total, same: same + other.same, changed: changed + other.changed,
             leftOnly: leftOnly + other.leftOnly, rightOnly: rightOnly + other.rightOnly,
             issues: issues + other.issues, pending: pending + other.pending)
    }

    fileprivate init(status: FolderEntryStatus) {
        self.init(total: 1, same: status == .same ? 1 : 0, changed: status == .changed ? 1 : 0,
                  leftOnly: status == .leftOnly ? 1 : 0, rightOnly: status == .rightOnly ? 1 : 0,
                  issues: status == .unreadable || status == .typeMismatch ? 1 : 0,
                  pending: status == .pending ? 1 : 0)
    }
}

public struct FolderBrowserRow: Identifiable, Sendable {
    public let entry: FolderEntry
    public let depth: Int
    public let hasChildren: Bool
    public let isExpanded: Bool
    public let descendants: FolderBrowserCounts
    public var id: String { entry.path }
}

public struct FolderBrowserProjection: Sendable {
    public let rows: [FolderBrowserRow]
    /// Original entries that directly match the query and filter, excluding context-only ancestors.
    public let matchingEntries: [FolderEntry]
    /// Whole current scope, before filtering/search and independent of expansion state.
    public let counts: FolderBrowserCounts
    public static let empty = Self(rows: [], matchingEntries: [], counts: .init())
}

/// Pure, cancellable presentation projection. It owns no selection, expansion or file I/O;
/// callers can calculate it off the main thread and publish only the current generation.
public enum FolderBrowser {
    public static func project(entries: [FolderEntry], mode: FolderBrowserMode = .tree,
                               filter: FolderBrowserFilter = .differences, query: String = "",
                               scopePath: String = "", sort: FolderBrowserSort = .init(),
                               expandedPaths: Set<String> = []) throws -> FolderBrowserProjection {
        try Task.checkCancellation()
        let scope = scopePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let scopePrefix = scope.isEmpty ? "" : scope + "/"
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var indexed: [String: FolderEntry] = [:]
        indexed.reserveCapacity(entries.count)
        for (offset, entry) in entries.enumerated() {
            if offset % 1024 == 0 { try Task.checkCancellation() }
            if scope.isEmpty || entry.path.hasPrefix(scopePrefix) { indexed[entry.path] = entry }
        }
        guard !indexed.isEmpty else { return .empty }

        var children: [String: [String]] = [:], parentByPath: [String: String] = [:]
        var depths: [String: Int] = [:]
        for (offset, path) in indexed.keys.enumerated() {
            if offset % 1024 == 0 { try Task.checkCancellation() }
            var parent = parentPath(path)
            while !parent.isEmpty && parent != scope && indexed[parent] == nil { parent = parentPath(parent) }
            // A partial inventory may omit an ancestor. Promote its children to the
            // closest known parent without manufacturing actionable comparison entries.
            if parent == scope { parent = "" }
            parentByPath[path] = parent
            children[parent, default: []].append(path)
            depths[path] = path.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
        }

        var totals: [String: FolderBrowserCounts] = [:], descendants: [String: FolderBrowserCounts] = [:]
        let bottomUp = indexed.keys.sorted { depths[$0, default: 0] > depths[$1, default: 0] }
        for (offset, path) in bottomUp.enumerated() {
            if offset % 1024 == 0 { try Task.checkCancellation() }
            let childPaths = children[path] ?? []
            var contained = FolderBrowserCounts()
            for child in childPaths { contained = contained.adding(totals[child] ?? .init()) }
            descendants[path] = contained
            let entry = indexed[path]!
            let countSelf = childPaths.isEmpty || !entry.isDirectory || entry.hasDirectProblem
            totals[path] = countSelf ? contained.adding(.init(status: entry.status)) : contained
        }
        let counts = (children[""] ?? []).reduce(FolderBrowserCounts()) { $0.adding(totals[$1] ?? .init()) }

        var matchingPaths = Set<String>()
        for (offset, entry) in indexed.values.enumerated() {
            if offset % 1024 == 0 { try Task.checkCancellation() }
            if accepts(entry.status, filter: filter) && (search.isEmpty || entry.path.localizedCaseInsensitiveContains(search)) {
                matchingPaths.insert(entry.path)
            }
        }
        // Sort a copy of path IDs only. Paired snapshots can never acquire independent
        // ordering, and unknown values are last in either direction.
        func sorted(_ paths: [String], directoriesFirst: Bool) throws -> [String] {
            var comparisons = 0
            let result = try paths.sorted { left, right in
                comparisons += 1
                if comparisons % 2048 == 0 { try Task.checkCancellation() }
                return ordered(indexed[left]!, before: indexed[right]!, sort: sort,
                               fullPath: mode == .list, directoriesFirst: directoriesFirst)
            }
            try Task.checkCancellation()
            return result
        }
        // Hidden descendants need no natural-name sort in the collapsed tree. Preserve
        // inventory order for the compatibility list; only flat mode needs a global sort.
        let matchingEntries = mode == .list
            ? try sorted(Array(matchingPaths), directoriesFirst: false).compactMap { indexed[$0] }
            : entries.filter { matchingPaths.contains($0.path) }
        if mode == .list {
            let rows = matchingEntries.map {
                FolderBrowserRow(entry: $0, depth: 0, hasChildren: false, isExpanded: false,
                                 descendants: descendants[$0.path] ?? .init())
            }
            return FolderBrowserProjection(rows: rows, matchingEntries: matchingEntries, counts: counts)
        }

        var visiblePaths = matchingPaths, searchExpanded = Set<String>()
        for path in matchingPaths {
            var ancestor = parentByPath[path] ?? ""
            while !ancestor.isEmpty {
                let inserted = visiblePaths.insert(ancestor).inserted
                if !search.isEmpty { searchExpanded.insert(ancestor) }
                if !inserted && search.isEmpty { break }
                ancestor = parentByPath[ancestor] ?? ""
            }
        }
        var rows: [FolderBrowserRow] = []
        // Iterative traversal also handles deeply nested inventories without a recursive
        // Swift call stack. Only expanded siblings need to be sorted/materialized.
        var stack = try sorted((children[""] ?? []).filter { visiblePaths.contains($0) }, directoriesFirst: true)
            .reversed().map { (path: $0, depth: 0) }
        while let node = stack.popLast() {
            if rows.count % 1024 == 0 { try Task.checkCancellation() }
            let visibleChildren = (children[node.path] ?? []).filter { visiblePaths.contains($0) }
            let expanded = !visibleChildren.isEmpty && (expandedPaths.contains(node.path) || searchExpanded.contains(node.path))
            rows.append(FolderBrowserRow(entry: indexed[node.path]!, depth: node.depth,
                                         hasChildren: !visibleChildren.isEmpty, isExpanded: expanded,
                                         descendants: descendants[node.path] ?? .init()))
            if expanded {
                let orderedChildren = try sorted(visibleChildren, directoriesFirst: true)
                stack.append(contentsOf: orderedChildren.reversed().map { (path: $0, depth: node.depth + 1) })
            }
        }
        return FolderBrowserProjection(rows: rows, matchingEntries: matchingEntries, counts: counts)
    }

    private static func parentPath(_ path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "" }
        return String(path[..<separator])
    }

    private static func accepts(_ status: FolderEntryStatus, filter: FolderBrowserFilter) -> Bool {
        switch filter {
        case .all: return true
        case .differences: return status != .same
        case .changed: return status == .changed
        case .leftOnly: return status == .leftOnly
        case .rightOnly: return status == .rightOnly
        case .issues: return status == .unreadable || status == .typeMismatch
        case .pending: return status == .pending
        }
    }

    private static func ordered(_ left: FolderEntry, before right: FolderEntry, sort: FolderBrowserSort,
                                fullPath: Bool, directoriesFirst: Bool) -> Bool {
        if directoriesFirst && left.isDirectory != right.isDirectory { return left.isDirectory }
        let relation: ComparisonResult
        switch sort.key {
        case .name:
            let a = fullPath ? left.path : String(left.path.split(separator: "/").last ?? "")
            let b = fullPath ? right.path : String(right.path.split(separator: "/").last ?? "")
            relation = a.localizedStandardCompare(b)
        case .status:
            relation = compare(statusPriority(left.status), statusPriority(right.status))
        case .leftSize, .rightSize:
            let a = sort.key == .leftSize ? left.left : left.right
            let b = sort.key == .leftSize ? right.left : right.right
            let valueA = a.flatMap { $0.kind == .file ? $0.size : nil }
            let valueB = b.flatMap { $0.kind == .file ? $0.size : nil }
            if (valueA == nil) != (valueB == nil) { return valueA != nil }
            relation = valueA.map { compare($0, valueB!) } ?? .orderedSame
        case .leftModified, .rightModified:
            let a = sort.key == .leftModified ? left.left?.modifiedDate : left.right?.modifiedDate
            let b = sort.key == .leftModified ? right.left?.modifiedDate : right.right?.modifiedDate
            if (a == nil) != (b == nil) { return a != nil }
            relation = a.map { compare($0, b!) } ?? .orderedSame
        }
        if relation != .orderedSame { return relation == (sort.ascending ? .orderedAscending : .orderedDescending) }
        // Equal values have a deterministic, ascending natural-path tie break. A final
        // exact comparison distinguishes names the localized comparator considers equal.
        let natural = left.path.localizedStandardCompare(right.path)
        return natural == .orderedSame ? left.path < right.path : natural == .orderedAscending
    }

    private static func compare<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
        left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
    }

    private static func statusPriority(_ status: FolderEntryStatus) -> Int {
        switch status {
        case .typeMismatch: return 0
        case .unreadable: return 1
        case .changed: return 2
        case .leftOnly: return 3
        case .rightOnly: return 4
        case .pending: return 5
        case .same: return 6
        }
    }
}
