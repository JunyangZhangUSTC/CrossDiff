import AppKit
import SwiftUI
import CrossDiffCore

enum ArchiveDisplayMode: String, CaseIterable, Identifiable {
    case paths, content
    var id: String { rawValue }
    var title: String { self == .paths ? L("按路径", "By Path") : L("相同内容", "Same Content") }
}

/// Metadata-only nodes. Synthetic parents preserve hierarchy without inventing catalog entries.
@MainActor
final class ArchiveOutlineNode: NSObject {
    let id: String
    let path: String
    let basename: String
    var row: ArchiveComparisonRow?
    var group: ArchiveContentGroup?
    var groupNumber: Int?
    var member: ArchiveEntry?
    var memberIsLeft: Bool?
    var children: [ArchiveOutlineNode] = []

    init(id: String, path: String) {
        self.id = id; self.path = path
        basename = path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
    }
    var isDirectory: Bool { row?.left?.kind == .directory || row?.right?.kind == .directory || (row == nil && group == nil && member == nil) }
    var title: String {
        if let group, let number = groupNumber {
            let size = ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: AppSettings.shared.locale).format(group.size)
            return L("内容组 \(number) · \(group.left.count + group.right.count) 个文件 · \(size)", "Content Group \(number) · \(group.left.count + group.right.count) Files · \(size)")
        }
        return member == nil ? basename : path
    }
    var symbol: String {
        if group != nil { return "square.stack.3d.up" }
        if isDirectory { return "folder" }
        let kind = member?.kind ?? row?.left?.kind ?? row?.right?.kind
        if kind == .symbolicLink || kind == .hardLink { return "link" }
        return kind == .other ? "questionmark.square" : "doc"
    }
    var statusTitle: String {
        if group != nil { return L("内容相同", "Same Content") }
        if let isLeft = memberIsLeft { return isLeft ? L("左侧", "Left") : L("右侧", "Right") }
        return row?.state.title ?? L("目录", "Folder")
    }
    var statusSymbol: String {
        if group != nil { return "checkmark.circle" }
        if let isLeft = memberIsLeft { return isLeft ? "arrow.left" : "arrow.right" }
        return row?.state.symbol ?? "folder"
    }
    var detail: String {
        if let group {
            return L("相同 SHA-256 与大小 · \(group.left.count) 个左侧文件，\(group.right.count) 个右侧文件。重复内容不代表一对一移动。",
                     "Matching SHA-256 and size · \(group.left.count) left \(group.left.count == 1 ? "file" : "files"), \(group.right.count) right \(group.right.count == 1 ? "file" : "files"). Duplicate content does not imply a one-to-one move.")
        }
        if member != nil { return L("已完整读取并计算内容摘要；仅比较文件内容。", "Full content was read and hashed; this compares file contents only.") }
        var messages: [String] = []
        if let issue = row?.left?.issue { messages.append(L("左侧：", "Left: ") + issue.localizedDescription) }
        if let issue = row?.right?.issue { messages.append(L("右侧：", "Right: ") + issue.localizedDescription) }
        if !messages.isEmpty { return messages.joined(separator: " · ") }
        if isDirectory { return L("目录状态包含子项结果；展开查看文件与空目录。", "Folder status includes its descendants; expand to inspect files and empty folders.") }
        if row?.state == .unknown { return L("内容尚未验证，不能判定相同。", "Contents are unverified and cannot be declared identical.") }
        if row?.state == .typeChanged { return L("两侧路径相同，但条目类型不同。", "The path is the same, but the item types differ.") }
        return statusTitle
    }
    var tooltip: String {
        if let group { return detail + "\nSHA-256: " + group.sha256 }
        return path + "\n" + detail
    }
    func color(theme: ComparisonTheme) -> NSColor {
        switch row?.state {
        case .removed: return theme.differenceForeground(isRemoval: true)
        case .added: return theme.differenceForeground(isRemoval: false)
        case .changed, .typeChanged: return theme.accent
        default: return theme.secondaryText
        }
    }
    func sizeText(isLeft: Bool) -> String {
        if let group {
            let count = isLeft ? group.left.count : group.right.count
            return L("\(count) 个文件", "\(count) \(count == 1 ? "file" : "files")")
        }
        let entry = member != nil ? (memberIsLeft == isLeft ? member : nil) : (isLeft ? row?.left : row?.right)
        guard let entry else { return "—" }
        switch entry.kind {
        case .directory: return L("文件夹", "Folder")
        case .symbolicLink: return L("符号链接", "Symlink")
        case .hardLink: return L("硬链接", "Hard Link")
        case .other: return L("特殊条目", "Special Item")
        case .file:
            return entry.size.map { ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: AppSettings.shared.locale).format($0) } ?? L("未知", "Unknown")
        }
    }
}

@MainActor
struct NativeArchiveOutlineView: NSViewRepresentable {
    let rows: [ArchiveComparisonRow]
    let groups: [ArchiveContentGroup]
    let dataID: String
    let mode: ArchiveDisplayMode
    let query: String
    let differencesOnly: Bool
    let theme: ComparisonTheme
    // Keep language in the bridge value so a language-only change refreshes
    // cached native headers and cells without rebuilding the directory tree.
    let language: AppLanguage
    @Binding var selection: ArchiveOutlineNode?

    func makeNSView(context: Context) -> ArchiveOutlineContainer { ArchiveOutlineContainer() }
    func updateNSView(_ view: ArchiveOutlineContainer, context: Context) {
        view.onSelection = { selection = $0 }
        view.update(rows: rows, groups: groups, dataID: dataID, mode: mode, query: query,
                    differencesOnly: differencesOnly, theme: theme)
    }
}

@MainActor
final class ArchiveOutlineContainer: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = ArchiveReadOnlyOutlineView()
    var onSelection: ((ArchiveOutlineNode?) -> Void)?
    private(set) var roots: [ArchiveOutlineNode] = []
    private var allRoots: [ArchiveOutlineNode] = []
    private var dataID = ""
    private var mode: ArchiveDisplayMode = .paths
    private var query = ""
    private var differencesOnly = false
    private var hasConfigured = false
    private var expandedIDs: [ArchiveDisplayMode: Set<String>] = [:]
    private var suppressSelection = false
    private var theme = ComparisonTheme.light
    private var revision = UUID()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("archive.outline.scroll")
        hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true; borderType = .noBorder
        drawsBackground = true
        outline.identifier = NSUserInterfaceItemIdentifier("archive.outline")
        outline.dataSource = self; outline.delegate = self
        outline.rowHeight = 30; outline.intercellSpacing = NSSize(width: 12, height: 0)
        outline.indentationPerLevel = 16; outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.selectionHighlightStyle = .regular
        outline.allowsMultipleSelection = false; outline.allowsEmptySelection = true
        outline.focusRingType = .none
        outline.usesAlternatingRowBackgroundColors = false
        for (id, width, minimum) in [("path", CGFloat(430), CGFloat(240)), ("status", 145, 125), ("left", 104, 90), ("right", 104, 90)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width; column.minWidth = minimum
            column.resizingMask = id == "path" ? .autoresizingMask : .userResizingMask
            outline.addTableColumn(column)
            if id == "path" { outline.outlineTableColumn = column }
        }
        documentView = outline
        outline.target = self; outline.doubleAction = #selector(doubleClick(_:))
    }
    required init?(coder: NSCoder) { nil }

    func update(rows: [ArchiveComparisonRow], groups: [ArchiveContentGroup], dataID: String,
                mode: ArchiveDisplayMode, query: String, differencesOnly: Bool, theme: ComparisonTheme) {
        self.theme = theme
        backgroundColor = theme.canvas; outline.backgroundColor = theme.canvas
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        outline.setAccessibilityLabel(mode == .paths ? L("压缩包虚拟目录比较", "Archive Virtual Directory Comparison") : L("跨路径相同内容组", "Matching Content Across Paths"))
        let titles = [L("名称／相对路径", "Name / Relative Path"), L("状态", "Status"), L("左侧", "Left"), L("右侧", "Right")]
        for (column, title) in zip(outline.tableColumns, titles) {
            column.title = title
            column.headerCell.textColor = theme.secondaryText
            column.headerCell.font = .systemFont(ofSize: 11, weight: .medium)
        }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let datasetChanged = !hasConfigured || self.dataID != dataID
        let modeChanged = self.mode != mode
        let filterChanged = self.query != normalizedQuery || self.differencesOnly != differencesOnly
        guard datasetChanged || modeChanged || filterChanged else {
            restyleVisibleCells()
            outline.headerView?.needsDisplay = true
            return
        }
        let selectedID = (outline.item(atRow: outline.selectedRow) as? ArchiveOutlineNode)?.id
        if datasetChanged { expandedIDs = [:] }
        if datasetChanged || modeChanged {
            allRoots = mode == .paths ? Self.pathTree(rows) : Self.contentTree(groups)
            if expandedIDs[mode] == nil { expandedIDs[mode] = Set(allRoots.filter { !$0.children.isEmpty }.map(\.id)) }
        }
        self.dataID = dataID; self.mode = mode; self.query = normalizedQuery; self.differencesOnly = differencesOnly
        hasConfigured = true
        roots = mode == .paths ? Self.filterTree(allRoots, query: normalizedQuery, differencesOnly: differencesOnly) :
            allRoots.filter { normalizedQuery.isEmpty || $0.children.contains { $0.path.localizedCaseInsensitiveContains(normalizedQuery) } }
        let token = UUID(); revision = token
        suppressSelection = true
        outline.reloadData()
        restoreExpansion(roots, searching: !normalizedQuery.isEmpty)
        if let selectedID, let selected = findNode(id: selectedID, in: roots) {
            let row = outline.row(forItem: selected)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            else { outline.deselectAll(nil) }
        } else { outline.deselectAll(nil) }
        suppressSelection = false
        let selected = outline.item(atRow: outline.selectedRow) as? ArchiveOutlineNode
        // SwiftUI bindings cannot be changed synchronously inside updateNSView.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == token else { return }
            self.layoutSubtreeIfNeeded()
            if self.outline.numberOfRows > 0 {
                // NSTableView accounts for its floating column header and native
                // content insets. A clip-view origin of zero can hide row zero.
                self.outline.scrollRowToVisible(0)
                self.outline.scrollColumnToVisible(0)
            }
            self.reflectScrolledClipView(self.contentView)
            self.onSelection?(selected)
        }
    }

    func path(atRow row: Int) -> String? { (outline.item(atRow: row) as? ArchiveOutlineNode)?.path }
    var displayedPaths: [String] { (0..<outline.numberOfRows).compactMap(path(atRow:)) }

    private func restyleVisibleCells() {
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<NSMaxRange(visible) {
            guard let node = outline.item(atRow: row) as? ArchiveOutlineNode else { continue }
            for column in outline.tableColumns.indices {
                if let cell = outline.view(atColumn: column, row: row, makeIfNecessary: false) as? ArchiveOutlineCell {
                    configure(cell, node: node, column: outline.tableColumns[column].identifier.rawValue)
                }
            }
            if let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? ArchiveOutlineRowView {
                rowView.theme = theme; rowView.needsDisplay = true
            }
        }
    }
    private func restoreExpansion(_ nodes: [ArchiveOutlineNode], searching: Bool) {
        for node in nodes where !node.children.isEmpty {
            if searching || expandedIDs[mode]?.contains(node.id) == true {
                outline.expandItem(node); restoreExpansion(node.children, searching: searching)
            }
        }
    }
    private func findNode(id: String, in nodes: [ArchiveOutlineNode]) -> ArchiveOutlineNode? {
        for node in nodes {
            if node.id == id { return node }
            if let found = findNode(id: id, in: node.children) { return found }
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ArchiveOutlineNode)?.children.count ?? roots.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ArchiveOutlineNode)?.children[index] ?? roots[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ArchiveOutlineNode)?.children.isEmpty == false
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ArchiveOutlineNode, let column = tableColumn else { return nil }
        let id = NSUserInterfaceItemIdentifier("archive.cell." + column.identifier.rawValue)
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? ArchiveOutlineCell ?? ArchiveOutlineCell()
        cell.identifier = id; configure(cell, node: node, column: column.identifier.rawValue)
        return cell
    }
    private func configure(_ cell: ArchiveOutlineCell, node: ArchiveOutlineNode, column: String) {
        let primary = column == "path"
        let status = column == "status"
        let title = primary ? node.title : status ? node.statusTitle : node.sizeText(isLeft: column == "left")
        let symbol = primary ? node.symbol : status ? node.statusSymbol : nil
        let color = primary ? theme.text : status ? node.color(theme: theme) : theme.secondaryText
        cell.configure(text: title, symbol: symbol, color: color, theme: theme,
                       emphasized: primary && (node.isDirectory || node.group != nil), numeric: !primary && !status)
        cell.toolTip = node.tooltip
        cell.setAccessibilityLabel(title)
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let view = ArchiveOutlineRowView(); view.theme = theme; return view
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        onSelection?(outline.item(atRow: outline.selectedRow) as? ArchiveOutlineNode)
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !suppressSelection, query.isEmpty, let node = notification.userInfo?["NSObject"] as? ArchiveOutlineNode else { return }
        expandedIDs[mode, default: []].insert(node.id)
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !suppressSelection, query.isEmpty, let node = notification.userInfo?["NSObject"] as? ArchiveOutlineNode else { return }
        expandedIDs[mode, default: []].remove(node.id)
    }
    @objc private func doubleClick(_ sender: Any?) {
        guard let node = outline.item(atRow: outline.clickedRow) as? ArchiveOutlineNode, !node.children.isEmpty else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    static func pathTree(_ rows: [ArchiveComparisonRow]) -> [ArchiveOutlineNode] {
        var nodes: [String: ArchiveOutlineNode] = [:]
        var roots: [ArchiveOutlineNode] = []
        // Catalogs already contain their ancestors. Index real entries first so
        // deeply nested siblings do not repeatedly rebuild every path prefix.
        for row in rows {
            let node = nodes[row.path] ?? ArchiveOutlineNode(id: "path:" + row.path, path: row.path)
            node.row = row; nodes[row.path] = node
        }
        func parentNode(_ path: String) -> ArchiveOutlineNode {
            if let existing = nodes[path] { return existing }
            let node = ArchiveOutlineNode(id: "path:" + path, path: path)
            nodes[path] = node
            if let slash = path.lastIndex(of: "/") {
                parentNode(String(path[..<slash])).children.append(node)
            } else { roots.append(node) }
            return node
        }
        // Snapshot the real nodes: parentNode may append synthetic ancestors.
        for node in Array(nodes.values) {
            if let slash = node.path.lastIndex(of: "/") {
                parentNode(String(node.path[..<slash])).children.append(node)
            } else {
                roots.append(node)
            }
        }
        func sorted(_ items: [ArchiveOutlineNode]) -> [ArchiveOutlineNode] {
            for node in items { node.children = sorted(node.children) }
            return items.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.basename.localizedStandardCompare($1.basename) == .orderedAscending
            }
        }
        return sorted(roots)
    }
    static func contentTree(_ groups: [ArchiveContentGroup]) -> [ArchiveOutlineNode] {
        groups.enumerated().map { index, group in
            let root = ArchiveOutlineNode(id: "group:" + group.id, path: "")
            root.group = group; root.groupNumber = index + 1
            for (isLeft, members) in [(true, group.left), (false, group.right)] {
                for entry in members.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                    let child = ArchiveOutlineNode(id: root.id + (isLeft ? ":left:" : ":right:") + entry.path, path: entry.path)
                    child.member = entry; child.memberIsLeft = isLeft; root.children.append(child)
                }
            }
            return root
        }
    }
    static func filterTree(_ roots: [ArchiveOutlineNode], query: String, differencesOnly: Bool) -> [ArchiveOutlineNode] {
        roots.compactMap { node in
            let children = filterTree(node.children, query: query, differencesOnly: differencesOnly)
            let matches = node.row != nil && (!differencesOnly || node.row?.state != .same) &&
                (query.isEmpty || node.path.localizedCaseInsensitiveContains(query))
            guard matches || !children.isEmpty else { return nil }
            let copy = ArchiveOutlineNode(id: node.id, path: node.path)
            copy.row = node.row; copy.children = children
            return copy
        }
    }
}

@MainActor
final class ArchiveReadOnlyOutlineView: NSOutlineView {
    override var undoManager: UndoManager? { nil }
}

private final class ArchiveOutlineRowView: NSTableRowView {
    var theme = ComparisonTheme.light
    override func drawSelection(in dirtyRect: NSRect) {
        theme.selectionBackground.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
    }
}

private final class ArchiveOutlineCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var contentColor = NSColor.labelColor
    private var selectedColor = NSColor.selectedControlTextColor
    private var showsIcon = true
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.isEditable = false; label.isSelectable = false; label.drawsBackground = false
        label.lineBreakMode = .byTruncatingMiddle; label.maximumNumberOfLines = 1
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon); addSubview(label)
        textField = label; imageView = icon
    }
    required init?(coder: NSCoder) { nil }
    func configure(text: String, symbol: String?, color: NSColor, theme: ComparisonTheme, emphasized: Bool, numeric: Bool) {
        label.stringValue = text
        label.font = numeric ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12, weight: emphasized ? .medium : .regular)
        label.alignment = numeric ? .right : .left
        label.lineBreakMode = numeric ? .byTruncatingTail : .byTruncatingMiddle
        contentColor = color; selectedColor = theme.selectionText
        showsIcon = symbol != nil; icon.isHidden = !showsIcon
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        applyColors(); needsLayout = true
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 1, y: (bounds.height - 15) / 2, width: 15, height: 15)
        let x: CGFloat = showsIcon ? 23 : 1
        let height = min(bounds.height, label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - 2), height: height)
    }
    private func applyColors() {
        let color = backgroundStyle == .emphasized ? selectedColor : contentColor
        label.textColor = color; icon.contentTintColor = color
    }
}
