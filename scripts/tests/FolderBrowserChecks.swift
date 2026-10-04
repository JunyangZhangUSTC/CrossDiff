import Foundation
import Darwin

@main enum FolderBrowserChecks {
    static var assertions = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        let success = value()
        if !success { fputs("FAIL: " + message + "\n", stderr) }
        precondition(success, message)
    }

    static func main() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: manager.currentDirectoryPath)
            .appendingPathComponent(".build/folder-browser/fixtures/\(UUID().uuidString)")
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        for side in [left, right] { try manager.createDirectory(at: side, withIntermediateDirectories: true) }
        defer { try? manager.removeItem(at: root) }
        func directory(_ side: URL, _ path: String) throws {
            try manager.createDirectory(at: side.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        func file(_ side: URL, _ path: String, _ size: Int, value: UInt8 = 65, modified: Double = 1_600_000_000) throws {
            let url = side.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: value, count: size).write(to: url)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
        }
        try file(left, "docs/deep/file2.txt", 2)
        try file(right, "docs/deep/file2.txt", 3, modified: 1_600_000_020)
        try file(left, "docs/deep/file10.txt", 10)
        try file(right, "docs/deep/file10.txt", 11, modified: 1_600_000_040)
        try file(left, "docs/same.txt", 5)
        try file(right, "docs/same.txt", 5, modified: 1_600_000_030)
        try file(left, "docs/左侧😀.txt", 4)
        try file(right, "docs/right.txt", 8)
        try file(left, "docs-other/outside.txt", 1)
        try file(left, "zero.bin", 0, modified: 1_600_000_001)
        try file(left, "small.bin", 9, modified: 1_600_000_002)
        try file(left, "large.bin", 2048, modified: 1_600_000_003)
        try file(right, "right.bin", 1)
        try directory(left, "empty")
        try directory(left, "conflict")
        try file(left, "conflict/child.txt", 5)
        try file(right, "conflict", 4)
        for index in 0..<250 { try file(left, "large-one-sided/file\(index).txt", 0) }
        let result = try FolderComparison.scan(left: left, right: right)
        let entries = result.entries

        // Both parents exist, but their only descendant exists on the left. The
        // parent's derived "changed" status is context, not a modified content item.
        let sideOnlySubtree = entries.filter { $0.path == "docs" || $0.path == "docs/左侧😀.txt" }
        for mode in FolderBrowserMode.allCases {
            let modified = try FolderBrowser.project(entries: sideOnlySubtree, mode: mode, filter: .changed)
            expect(modified.counts.changed == 0 && modified.rows.isEmpty && modified.matchingEntries.isEmpty,
                   "A modified count of zero must not leave a derived-only ancestor in the modified filter")
        }

        let collapsed = try FolderBrowser.project(entries: entries)
        expect(!collapsed.rows.contains { $0.id == "large-one-sided/file1.txt" }, "One-sided large directory must initially stay collapsed")
        let large = collapsed.rows.first { $0.id == "large-one-sided" }!
        expect(large.hasChildren && !large.isExpanded && large.depth == 0, "Collapsed directory keeps a disclosure affordance")
        expect(large.descendants.total == 250 && large.descendants.leftOnly == 250, "Directory summary counts contents, not ancestors")
        expect(collapsed.rows.contains { $0.id == "empty" }, "One-sided empty directory must remain visible")
        expect(collapsed.counts.same == 1, "Identical count remains available while identical files are hidden")
        expect(collapsed.counts.issues == 1, "A directory's own type conflict must count once")
        let countable = entries.filter { entry in
            !entry.isDirectory || !entries.contains { $0.path.hasPrefix(entry.path + "/") } || entry.status == .typeMismatch
        }
        expect(collapsed.counts.total == countable.count, "Ancestor changed states must not double-count files")
        expect(collapsed.counts.count(for: .differences) == collapsed.counts.total - 1, "Differences exclude only confirmed identical items")

        let expanded = try FolderBrowser.project(entries: entries, expandedPaths: ["docs", "docs/deep"])
        let expandedIDs = expanded.rows.map(\.id)
        let file2 = expandedIDs.firstIndex(of: "docs/deep/file2.txt")!
        let file10 = expandedIDs.firstIndex(of: "docs/deep/file10.txt")!
        expect(file2 < file10, "Natural sorting must place file2 before file10")
        expect(expanded.rows[file2].depth == 2, "Expanded depth is relative to the visible root")
        expect(!expandedIDs.contains("docs/same.txt"), "Identical file hidden by default")
        expect(expanded.rows.first { $0.id == "docs" }?.isExpanded == true, "Expansion is shared by the paired row")

        let descending = try FolderBrowser.project(entries: entries, filter: .all,
            sort: .init(key: .name, ascending: false), expandedPaths: ["docs", "docs/deep"])
        expect(descending.rows.first?.entry.isDirectory == true, "Descending tree order keeps directories before files")
        let deepIDs = descending.rows.filter { $0.entry.path.hasPrefix("docs/deep/") }.map(\.id)
        expect(deepIDs == ["docs/deep/file10.txt", "docs/deep/file2.txt"], "Only siblings reverse within their parent")

        let scoped = try FolderBrowser.project(entries: entries, filter: .all, scopePath: "docs", expandedPaths: ["docs/deep"])
        expect(scoped.rows.allSatisfy { $0.id.hasPrefix("docs/") }, "Scope boundaries must exclude docs-other")
        expect(!scoped.rows.contains { $0.id == "docs" }, "The current scope directory is not a duplicate row")
        expect(scoped.rows.first { $0.id == "docs/deep" }?.depth == 0, "Scope resets displayed depth")
        expect(scoped.counts.total == 5, "Scope totals cover descendants only")
        expect(scoped.counts.changed == 2 && scoped.counts.leftOnly == 1 && scoped.counts.rightOnly == 1,
               "Scope status counts exclude derived directory states")

        let searched = try FolderBrowser.project(entries: entries, query: "DEEP/FILE2.TXT")
        expect(searched.rows.map(\.id) == ["docs", "docs/deep", "docs/deep/file2.txt"], "Search preserves and expands ancestors")
        expect(searched.matchingEntries.map(\.id) == ["docs/deep/file2.txt"], "Matching entries exclude context-only ancestors")
        expect(searched.rows.filter(\.isExpanded).count == 2, "Search expands only required paths")
        let restored = try FolderBrowser.project(entries: entries, expandedPaths: [])
        expect(restored.rows.map(\.id) == collapsed.rows.map(\.id), "Clearing search restores caller-owned expansion")
        let unicode = try FolderBrowser.project(entries: entries, query: "😀", scopePath: "docs")
        expect(unicode.rows.map(\.id) == ["docs/左侧😀.txt"], "Unicode filename search respects current scope")
        let noMatches = try FolderBrowser.project(entries: entries, query: "no-such-file")
        expect(noMatches.rows.isEmpty && noMatches.counts == collapsed.counts, "No matches leave scope totals intact")

        let onlyRight = try FolderBrowser.project(entries: entries, filter: .rightOnly, expandedPaths: ["docs"])
        expect(onlyRight.rows.contains { $0.id == "docs" && $0.entry.status == .changed }, "Filter retains a mismatched ancestor as context")
        expect(onlyRight.matchingEntries.allSatisfy { $0.status == .rightOnly }, "Direct matches retain exact filter semantics")
        let issues = try FolderBrowser.project(entries: entries, filter: .issues)
        expect(issues.rows.map(\.id) == ["conflict"], "Type mismatches appear under problems")

        let rootFiles = entries.filter { !$0.isDirectory && !$0.path.contains("/") && $0.path != "conflict" }
        for ascending in [true, false] {
            let sizes = try FolderBrowser.project(entries: rootFiles, mode: .list, filter: .all,
                sort: .init(key: .leftSize, ascending: ascending))
            expect(sizes.rows.last?.id == "right.bin", "Missing left size stays last in either direction")
            let known = sizes.rows.compactMap { $0.entry.left?.size }
            expect(known == (ascending ? known.sorted() : known.sorted(by: >)), "Sort raw bytes, not formatted size text")
            expect(known.contains(0), "Zero-byte values are known, not missing")
            let dates = try FolderBrowser.project(entries: rootFiles, mode: .list, filter: .all,
                sort: .init(key: .leftModified, ascending: ascending))
            expect(dates.rows.last?.id == "right.bin", "Missing modification dates stay last")
            let knownDates = dates.rows.compactMap { $0.entry.left?.modifiedDate }
            expect(knownDates == (ascending ? knownDates.sorted() : knownDates.sorted(by: >)), "Modification sorting uses captured dates")
            let rightSamples = entries.filter { $0.path.hasPrefix("docs/") && !$0.isDirectory }
            let rightSizes = try FolderBrowser.project(entries: rightSamples, mode: .list, filter: .all,
                sort: .init(key: .rightSize, ascending: ascending))
            expect(rightSizes.rows.last?.id == "docs/左侧😀.txt", "Missing right-side values also remain last")
            let rightBytes = rightSizes.rows.compactMap { $0.entry.right?.size }
            expect(rightBytes == (ascending ? rightBytes.sorted() : rightBytes.sorted(by: >)), "Right header sorts by right snapshots")
            let rightDates = try FolderBrowser.project(entries: rightSamples, mode: .list, filter: .all,
                sort: .init(key: .rightModified, ascending: ascending))
            expect(rightDates.rows.last?.id == "docs/左侧😀.txt", "Right-side missing modification dates remain last")
            let rightTimes = rightDates.rows.compactMap { $0.entry.right?.modifiedDate }
            expect(rightTimes == (ascending ? rightTimes.sorted() : rightTimes.sorted(by: >)), "Right date sorting is independent of left date values")
        }
        let withDirectory = try FolderBrowser.project(entries: entries.filter { $0.path == "empty" || rootFiles.map(\.id).contains($0.id) },
            mode: .list, filter: .all, sort: .init(key: .leftSize, ascending: true))
        expect(withDirectory.rows.first?.id == "zero.bin", "Flat size sorting is global, not directory-first")
        expect(withDirectory.rows.suffix(2).contains { $0.id == "empty" }, "Directory st_size must never masquerade as file bytes")
        let flat = try FolderBrowser.project(entries: entries, mode: .list, filter: .all, scopePath: "docs")
        expect(flat.rows.allSatisfy { $0.depth == 0 && !$0.hasChildren && !$0.isExpanded }, "Flat rows do not depend on expansion")
        expect(flat.rows.map(\.id) == flat.matchingEntries.map(\.id), "Flat projection preserves paired row identity")

        var pendingEntries = entries
        pendingEntries[pendingEntries.firstIndex { $0.id == "docs/same.txt" }!].status = .pending
        let pending = try FolderBrowser.project(entries: pendingEntries, filter: .pending, expandedPaths: ["docs"])
        expect(pending.rows.map(\.id) == ["docs", "docs/same.txt"], "Pending files remain visible with ancestor context")
        expect(pending.counts.pending == 1 && pending.counts.same == 0, "Pending counts do not claim equality")
        let orphan = entries.filter { $0.id == "docs/deep/file2.txt" }
        let partial = try FolderBrowser.project(entries: orphan, filter: .all)
        expect(partial.rows.first?.depth == 0, "Partial inventories promote missing-ancestor children safely")
        let allExpanded = Set(entries.filter(\.isDirectory).map(\.id))
        for key in FolderBrowserSortKey.allCases {
            for ascending in [true, false] {
                let projection = try FolderBrowser.project(entries: entries, filter: .all,
                    sort: .init(key: key, ascending: ascending), expandedPaths: allExpanded)
                expect(Set(projection.rows.map(\.id)) == Set(entries.map(\.id)), "Sorting cannot drop or duplicate a paired entry")
                for row in projection.rows where row.depth > 0 {
                    let parent = (row.id as NSString).deletingLastPathComponent
                    expect(projection.rows.firstIndex { $0.id == parent }! < projection.rows.firstIndex { $0.id == row.id }!,
                           "Sorting must not detach a child from its parent")
                }
            }
        }

        try directory(left, "unreadable/nested")
        try directory(right, "unreadable/nested")
        try file(left, "unreadable/nested/visible.txt", 7)
        let blocked = right.appendingPathComponent("unreadable")
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        do {
            defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
            let unreadable = try FolderComparison.scan(left: left, right: right)
            let ancestor = unreadable.entries.first { $0.id == "unreadable" }!
            expect(ancestor.status == .unreadable, "Permission fixture must actually be unreadable; do not claim a skipped check passed")
            let child = unreadable.entries.first { $0.id == "unreadable/nested/visible.txt" }!
            expect(child.status == .unreadable && child.right == nil, "Unknown descendant cannot be labeled left-only")
            expect(child.problem != nil, "Unknown descendants retain the failing ancestor's diagnostic")
            expect(ancestor.hasDirectProblem && !child.hasDirectProblem, "Inherited failures are not independent directory errors")
            let unreadableScope = try FolderBrowser.project(entries: unreadable.entries, filter: .issues, scopePath: "unreadable")
            expect(unreadableScope.counts.total == 1 && unreadableScope.counts.issues == 1,
                   "Inherited directory failures must not inflate descendant totals")
            expect(!child.canCopy(toRight: true) && !child.canCopy(toRight: false), "Unknown descendants cannot be copied")
            do {
                _ = try FolderComparison.prepareCopy(unreadable, paths: [child.id], toRight: true)
                expect(false, "Core copy preparation must reject unreadable descendants")
            } catch { expect(true, "Copy rejected before any action is prepared") }
        }

        let canceled = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try FolderBrowser.project(entries: entries)
        }
        canceled.cancel()
        do { _ = try await canceled.value; expect(false, "Canceled projections must not return stale results") }
        catch is CancellationError { expect(true, "Canceled projection rejected") }

        let largeCount = CommandLine.arguments.contains("--large") ? 100_000 : 10_000
        let largeLeft = root.appendingPathComponent("performance-left"), largeRight = root.appendingPathComponent("performance-right")
        for side in [largeLeft, largeRight] { try manager.createDirectory(at: side, withIntermediateDirectories: true) }
        for index in 0..<largeCount { try file(largeLeft, "group-\(index / 100)/item-\(index).txt", 0) }
        let largeResult = try FolderComparison.scan(left: largeLeft, right: largeRight)
        for mode in FolderBrowserMode.allCases {
            let start = ProcessInfo.processInfo.systemUptime
            let projection = try FolderBrowser.project(entries: largeResult.entries, mode: mode)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            expect(projection.counts.total == largeCount && projection.counts.leftOnly == largeCount, "Large directory totals must remain exact")
            expect(mode == .tree ? projection.rows.count == largeCount / 100 : projection.rows.count == largeResult.entries.count,
                   "Large trees remain collapsed while flat mode keeps all matching entries")
            print("Folder browser projection: items=\(largeResult.entries.count) mode=\(mode.rawValue) rows=\(projection.rows.count) seconds=\(String(format: "%.3f", elapsed))")
        }
        print("Folder browser checks passed: \(assertions) assertions")
    }
}
