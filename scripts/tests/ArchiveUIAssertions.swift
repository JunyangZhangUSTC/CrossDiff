import AppKit
import SwiftUI
import CrossDiffCore

/// Called by the isolated archive workflow harness; does not launch another app.
@MainActor
enum ArchiveUIAssertions {
    typealias D = DeletionPreviewChecks

    static func run(window: NSWindow, model: ArchiveComparisonModel) async throws {
        D.check(model.result != nil && model.error == nil, "archive UI starts with a completed production model")
        let originalContent = window.contentView
        let originalFrame = window.frame
        let originalLanguage = AppSettings.shared.language
        let originalDark = AppAppearance.shared.isDark
        let originalAppearance = window.appearance
        defer {
            window.contentView = originalContent
            window.setFrame(originalFrame, display: true)
            AppSettings.shared.language = originalLanguage
            AppAppearance.shared.isDark = originalDark
            window.appearance = originalAppearance
        }
        try await captureProductionContent(window: window, model: model)
        let state = ArchiveUITestState()
        let fixture = fixtures()
        let host = NSHostingView(rootView: ArchiveUITestShell(state: state, rows: fixture.rows, groups: fixture.groups))
        window.contentView = host
        window.setContentSize(NSSize(width: 1100, height: 620))
        window.makeKeyAndOrderFront(nil)
        AppSettings.shared.language = .simplifiedChinese
        try await D.pause()
        guard let container = descendants(host).compactMap({ $0 as? ArchiveOutlineContainer }).first else {
            throw D.CheckError(description: "Missing native archive outline")
        }
        let outline = container.outline
        checkFirstRow(container, context: "initial path tree")
        D.check(outline.identifier?.rawValue == "archive.outline" && outline.undoManager == nil,
                "native archive outline is identifiable and does not inherit editor undo")
        guard let sources = node("Sources", in: container.roots), let models = node("Sources/Models", in: container.roots),
              let empty = node("Empty", in: container.roots), let changed = node("Sources/Models/Config.swift", in: container.roots) else {
            throw D.CheckError(description: "Missing fixture hierarchy")
        }
        D.check(sources.children.contains { $0 === models } && models.children.contains { $0 === changed },
                "path components form actual parent-child nodes, including implicit parents")
        D.check(empty.children.isEmpty && empty.row?.left?.kind == .directory,
                "explicit empty directory remains a selectable real entry")
        D.check(container.roots.filter { $0.path == "Unicode-é" }.count == 1 &&
                node("Unicode-é", in: container.roots)?.children.first?.path == "Unicode-é/item.txt",
                "canonical Unicode-equivalent prefixes join one real parent while preserving each source spelling")
        outline.expandItem(sources); outline.expandItem(models)
        try await D.pause()
        D.check(container.displayedPaths.contains(changed.path), "expanding native directory reveals nested children")
        outline.collapseItem(models)
        D.check(!container.displayedPaths.contains(changed.path), "collapsing native directory hides nested children")
        outline.expandItem(models)
        let selectedRow = outline.row(forItem: changed)
        outline.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        try await D.pause()
        D.check(state.selection?.path == changed.path && state.selection?.detail == ArchiveComparisonState.changed.title,
                "native selection reports the complete path and comparison status to SwiftUI")

        state.query = "Config.swift"; state.differencesOnly = true
        try await D.pause()
        checkFirstRow(container, context: "path search with ancestor context")
        D.check(container.displayedPaths == ["Sources", "Sources/Models", "Sources/Models/Config.swift"],
                "query and changes filter retain all ancestors and reveal the matching child")
        D.check(container.roots.first?.row?.state == .changed,
                "filtering keeps the validated ancestor status instead of inventing an extra difference")
        state.query = ""
        try await D.pause()
        D.check(node("Empty", in: container.roots) == nil && node("Sources/stable.swift", in: container.roots) == nil,
                "changes-only hides verified same files and empty folders")
        D.check(node("unverified-link", in: container.roots)?.row?.state == .unknown,
                "changes-only keeps unverified content visible")
        D.check(node("type-change", in: container.roots)?.children.first?.path == "type-change/child.txt",
                "file-to-directory type conflict retains the right-side subtree")
        state.differencesOnly = false
        try await D.pause()
        D.check(node("Empty", in: container.roots) != nil, "turning off changes-only restores empty folders")
        if let unknown = node("unverified-link", in: container.roots) {
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: unknown)), byExtendingSelection: false)
            try await D.pause()
            D.check(state.selection?.detail.contains(ArchiveEntryIssue.symbolicLink.localizedDescription) == true,
                    "selected unsupported entry explains why its contents were not verified")
        }

        state.mode = .content
        try await D.pause()
        checkFirstRow(container, context: "switching from paths to content groups")
        D.check(container.roots.count == 1 && container.roots.first?.children.count == 5,
                "one matching-content group has 2 + 3 members without a Cartesian pair list")
        D.check(outline.numberOfRows == 6, "native content mode displays one group and its five source members")
        let members = container.roots.first?.children ?? []
        D.check(members.filter { $0.memberIsLeft == true }.count == 2 && members.filter { $0.memberIsLeft == false }.count == 3,
                "content group retains explicit side provenance for every path")
        state.query = "renamed/final.txt"
        try await D.pause()
        D.check(container.roots.count == 1 && container.roots.first?.children.count == 5,
                "search matching one member retains the entire opposite-side content group")
        state.query = "no-such-entry"
        try await D.pause()
        D.check(outline.numberOfRows == 0, "unmatched group query leaves no misleading placeholder entries")
        state.query = ""; state.mode = .paths
        try await D.pause()
        checkFirstRow(container, context: "returning from empty content search to paths")
        for (name, dark, width, english) in [
            ("archive-outline-light", false, 1100.0, false),
            ("archive-outline-dark", true, 1100.0, false),
            ("archive-outline-english-narrow", false, 860.0, true),
            ("archive-outline-dark-narrow", true, 860.0, false)
        ] {
            AppSettings.shared.language = english ? .english : .simplifiedChinese
            AppAppearance.shared.isDark = dark
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 620))
            try await D.pause()
            outline.deselectAll(nil)
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            checkFirstRow(container, context: name)
            let parent = host.superview ?? host
            _ = try D.capture(parent, rect: parent.bounds, name: name)
            let region = outline.convert(outline.visibleRect, to: parent).intersection(parent.bounds)
            let pixels = try D.capture(parent, rect: region, name: name + "-rows")
            let counts = D.countPixels(pixels, background: AppAppearance.shared.colors.canvas)
            D.check(counts.readable > 150 && counts.red > 2, "actual parent capture contains readable archive rows and removed-item color: \(name)")
            D.check(region.width > 750 && region.height > 350, "native archive table remains usable at \(Int(width)) points")
            D.check(outline.tableColumns.first?.title == (english ? "Name / Relative Path" : "名称／相对路径"),
                    "native archive column titles follow the application language: \(name)")
            D.check(outline.accessibilityLabel() == (english ? "Archive Virtual Directory Comparison" : "压缩包虚拟目录比较"),
                    "native archive accessibility label follows the language: \(name)")
            let fields = descendants(outline).compactMap { $0 as? NSTextField }
            D.check(fields.contains { $0.stringValue == "original.txt" && D.sameColor($0.textColor, AppAppearance.shared.colors.text) },
                    "native path text keeps explicit readable foreground in \(name)")
        }
        state.mode = .content
        try await D.pause()
        checkFirstRow(container, context: "final content group screenshot")
        let parent = host.superview ?? host
        _ = try D.capture(parent, rect: parent.bounds, name: "archive-outline-content-groups")
        D.check(model.result != nil && model.error == nil, "view filtering and native selection never modify the comparison model")
    }

    private static func checkFirstRow(_ container: ArchiveOutlineContainer, context: String) {
        container.layoutSubtreeIfNeeded()
        guard container.outline.numberOfRows > 0, let header = container.outline.headerView else {
            D.check(false, "first row and native header exist: \(context)"); return
        }
        let first = container.outline.convert(container.outline.rect(ofRow: 0), to: container)
        let headerRect = header.convert(header.bounds, to: container)
        let clip = container.contentView.convert(container.contentView.bounds, to: container).intersection(container.bounds)
        let overlap = first.intersection(headerRect)
        D.check(overlap.isNull || overlap.height <= 0.5,
                "first row does not overlap the column header: \(context), row=\(first), header=\(headerRect)")
        D.check(first.intersection(clip).height >= first.height - 0.5,
                "entire first row is visible after native scrolling: \(context)")
    }

    /// Switch the real production Picker through its native target/action, so
    /// these captures include source headers, filters, details and result status.
    private static func captureProductionContent(window: NSWindow, model: ArchiveComparisonModel) async throws {
        func select(_ index: Int) throws {
            guard let content = window.contentView,
                  let picker = descendants(content).compactMap({ $0 as? NSSegmentedControl }).first(where: {
                      $0.segmentCount == 2 && ["按路径", "By Path"].contains($0.label(forSegment: 0) ?? "") &&
                          ["相同内容", "Same Content"].contains($0.label(forSegment: 1) ?? "")
                  }) else { throw D.CheckError(description: "Missing production archive mode Picker") }
            picker.selectedSegment = index
            D.check(picker.sendAction(picker.action, to: picker.target), "production archive mode Picker dispatches its native action")
        }
        try select(1)
        try await D.wait("production content mode") {
            guard let content = window.contentView,
                  let outline = descendants(content).compactMap({ $0 as? ArchiveOutlineContainer }).first else { return false }
            return outline.outline.accessibilityLabel() == L("跨路径相同内容组", "Matching Content Across Paths")
        }
        for (name, dark, width, english) in [
            ("archive-content-light", false, 1220.0, false),
            ("archive-content-dark-narrow", true, 860.0, false),
            ("archive-content-english-narrow", false, 860.0, true)
        ] {
            AppSettings.shared.language = english ? .english : .simplifiedChinese
            AppAppearance.shared.isDark = dark
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 700))
            try await D.pause()
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let content = window.contentView,
                  let container = descendants(content).compactMap({ $0 as? ArchiveOutlineContainer }).first else {
                throw D.CheckError(description: "Missing production content tree")
            }
            D.check(container.roots.count == model.groups.count && container.roots.first?.group != nil,
                    "production content view shows actual validated groups: \(name)")
            D.check(container.outline.tableColumns.first?.title == (english ? "Name / Relative Path" : "名称／相对路径"),
                    "production native column title updates when only the language changes: \(name)")
            D.check(container.outline.accessibilityLabel() == (english ? "Matching Content Across Paths" : "跨路径相同内容组"),
                    "production native accessibility label updates with the language: \(name)")
            let fields = descendants(container.outline).compactMap { $0 as? NSTextField }
            D.check(fields.contains { $0.stringValue.hasPrefix(english ? "Content Group " : "内容组 ") },
                    "production native group cell updates with the language: \(name)")
            checkFirstRow(container, context: name)
            let parent = content.superview ?? content
            _ = try D.capture(parent, rect: parent.bounds, name: name)
        }
        try select(0)
        try await D.pause()
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func node(_ path: String, in roots: [ArchiveOutlineNode]) -> ArchiveOutlineNode? {
        for root in roots {
            if root.path == path { return root }
            if let child = node(path, in: root.children) { return child }
        }
        return nil
    }
    private static func fixtures() -> (rows: [ArchiveComparisonRow], groups: [ArchiveContentGroup]) {
        func file(_ path: String, hash: String = String(repeating: "a", count: 64)) -> ArchiveEntry {
            ArchiveEntry(path: path, kind: .file, size: 17, sha256: hash)
        }
        func directory(_ path: String) -> ArchiveEntry { ArchiveEntry(path: path, kind: .directory, size: nil, sha256: nil) }
        let changed = "Sources/Models/Config.swift"
        let longPath = "Sources/Models/国际化测试_\(String(repeating: "LongName", count: 8))_🌊.swift"
        let l = [file("copies/original.txt"), file("copies/reference.txt")]
        let r = [file("renamed/copy.txt"), file("renamed/final.txt"), file("renamed/reference.txt")]
        var rows: [ArchiveComparisonRow] = [
            .init(path: "Sources", left: directory("Sources"), right: directory("Sources"), state: .changed),
            .init(path: changed, left: file(changed), right: file(changed, hash: String(repeating: "b", count: 64)), state: .changed),
            .init(path: longPath, left: file(longPath), right: file(longPath), state: .same),
            .init(path: "Sources/stable.swift", left: file("Sources/stable.swift"), right: file("Sources/stable.swift"), state: .same),
            .init(path: "Empty", left: directory("Empty"), right: directory("Empty"), state: .same),
            .init(path: "Unicode-e\u{301}", left: directory("Unicode-e\u{301}"), right: directory("Unicode-e\u{301}"), state: .same),
            .init(path: "Unicode-é/item.txt", left: file("Unicode-é/item.txt"), right: file("Unicode-é/item.txt"), state: .same),
            .init(path: "removed.txt", left: file("removed.txt"), right: nil, state: .removed),
            .init(path: "new.txt", left: nil, right: file("new.txt"), state: .added),
            .init(path: "unverified-link", left: ArchiveEntry(path: "unverified-link", kind: .symbolicLink, size: nil, sha256: nil, issue: .symbolicLink), right: nil, state: .unknown),
            .init(path: "type-change", left: file("type-change"), right: directory("type-change"), state: .typeChanged),
            .init(path: "type-change/child.txt", left: nil, right: file("type-change/child.txt"), state: .added)
        ]
        rows += l.map { .init(path: $0.path, left: $0, right: nil, state: .removed) }
        rows += r.map { .init(path: $0.path, left: nil, right: $0, state: .added) }
        return (rows, [.init(id: "fixture-content", sha256: String(repeating: "a", count: 64), size: 17, left: l, right: r)])
    }
}

@MainActor
private final class ArchiveUITestState: ObservableObject {
    @Published var mode = ArchiveDisplayMode.paths
    @Published var query = ""
    @Published var differencesOnly = false
    @Published var selection: ArchiveOutlineNode?
}

@MainActor
private struct ArchiveUITestShell: View {
    @ObservedObject var state: ArchiveUITestState
    let rows: [ArchiveComparisonRow]
    let groups: [ArchiveContentGroup]
    @ObservedObject private var appearance = AppAppearance.shared
    @ObservedObject private var settings = AppSettings.shared
    var body: some View {
        VStack(spacing: 0) {
            Text(L("归档目录原生视图验收", "Native Archive Outline Verification"))
                .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .foregroundStyle(Color(nsColor: appearance.colors.text)).background(Color(nsColor: appearance.colors.chrome))
            Divider()
            NativeArchiveOutlineView(rows: rows, groups: groups, dataID: "ui-fixture", mode: state.mode,
                query: state.query, differencesOnly: state.differencesOnly, theme: appearance.colors,
                language: settings.language, selection: $state.selection)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(state.selection?.path ?? L("选择项目", "Select an Item"))
                Text(state.selection?.detail ?? L("只读原生目录树", "Read-only Native Outline"))
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .foregroundStyle(Color(nsColor: appearance.colors.text)).background(Color(nsColor: appearance.colors.chrome))
        }.environment(\.locale, settings.locale)
    }
}
