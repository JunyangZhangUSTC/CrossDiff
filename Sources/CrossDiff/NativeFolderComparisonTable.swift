import AppKit
import SwiftUI
import CrossDiffCore

/// Both sides share the same native row, selection and clip view. Sorting and
/// expansion operate on the projected pairs in the model, never on individual sides.
@MainActor
struct NativeFolderComparisonTable: NSViewRepresentable {
    let rows: [FolderBrowserRow]
    let mode: FolderBrowserMode
    let sort: FolderBrowserSort
    @Binding var selection: Set<String>
    let showModifiedDates: Bool
    let isDark: Bool
    let allowsExpansion: Bool
    let onToggleFolder: (String) -> Void
    let onOpen: (FolderEntry) -> Void
    let onSort: (FolderBrowserSort) -> Void

    func makeNSView(context: Context) -> FolderComparisonTableContainer { FolderComparisonTableContainer() }
    func updateNSView(_ view: FolderComparisonTableContainer, context: Context) {
        view.onSelection = { selection = $0 }
        view.onToggleFolder = onToggleFolder
        view.onOpen = onOpen
        view.onSort = onSort
        view.update(rows: rows, mode: mode, sort: sort, selection: selection,
                    showModifiedDates: showModifiedDates, isDark: isDark, allowsExpansion: allowsExpansion)
    }
}

@MainActor
final class FolderComparisonTableContainer: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    let tableView: NSTableView = FolderPairedTableView()
    var onSelection: ((Set<String>) -> Void)?
    var onToggleFolder: ((String) -> Void)?
    var onOpen: ((FolderEntry) -> Void)?
    var onSort: ((FolderBrowserSort) -> Void)?
    private(set) var rows: [FolderBrowserRow] = []
    private var indexByPath: [String: Int] = [:]
    private var mode: FolderBrowserMode = .tree
    private var sort = FolderBrowserSort(key: .name, ascending: true)
    private var theme = ComparisonTheme.light
    private var suppressSelection = false
    private var revision = 0
    private var hasConfigured = false
    private var adjustingColumns = false
    private var showModifiedDates = false
    private var allowsExpansion = true
    private var needsInitialTopPosition = true
    private let dateFormatter = DateFormatter()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("folders.paired-scroll")
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = true
        // Preserve AppKit's vertical header reservation. The table's plain
        // style below removes horizontal decoration without touching it.
        contentView.automaticallyAdjustsContentInsets = true
        tableView.identifier = NSUserInterfaceItemIdentifier("folders.paired-table")
        tableView.setAccessibilityIdentifier("folders.paired-table")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 32
        // The automatic macOS style adds leading/trailing row insets beyond the
        // declared column widths. We own the paired layout and cell padding, so
        // keep native decoration from extending the rightmost column offscreen.
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.focusRingType = .none
        for id in ["leftName", "leftSize", "leftModified", "status", "rightName", "rightSize", "rightModified"] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.minWidth = 0
            column.maxWidth = 20_000
            column.width = id.hasSuffix("Name") ? 300 : 80
            column.resizingMask = []
            tableView.addTableColumn(column)
        }
        documentView = tableView
        tableView.target = self
        tableView.doubleAction = #selector(openClickedRow(_:))
        (tableView as? FolderPairedTableView)?.onNavigationKey = { [weak self] event in
            self?.handleNavigation(event) ?? false
        }
    }
    required init?(coder: NSCoder) { nil }

    func update(rows: [FolderBrowserRow], mode: FolderBrowserMode, sort: FolderBrowserSort,
                selection: Set<String>, showModifiedDates: Bool, isDark: Bool, allowsExpansion: Bool = true) {
        // SwiftUI passes the model's immutable projection array by value. Retaining
        // its storage lets appearance-only refreshes avoid an O(n) equality walk.
        let sameStorage = self.rows.withUnsafeBufferPointer { old in
            rows.withUnsafeBufferPointer { new in old.count == new.count && old.baseAddress == new.baseAddress }
        }
        let dataChanged = !hasConfigured || !sameStorage || self.mode != mode
        let columnsChanged = self.showModifiedDates != showModifiedDates
        if self.rows.isEmpty && !rows.isEmpty { needsInitialTopPosition = true }
        let viewport = (dataChanged || columnsChanged) && !needsInitialTopPosition ? currentViewport() : nil
        self.mode = mode
        self.sort = sort
        self.theme = ComparisonTheme(isDark: isDark)
        self.showModifiedDates = showModifiedDates
        self.allowsExpansion = allowsExpansion
        hasConfigured = true
        revision += 1
        let token = revision
        backgroundColor = theme.canvas
        tableView.backgroundColor = theme.canvas
        (tableView as? FolderPairedTableView)?.theme = theme
        appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        tableView.setAccessibilityLabel(L("左右对齐的文件夹比较", "Aligned Left and Right Folder Comparison"))
        dateFormatter.locale = AppSettings.shared.locale
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .short
        configureHeaders()
        for column in tableView.tableColumns where column.identifier.rawValue.hasSuffix("Modified") {
            column.isHidden = !showModifiedDates
        }
        suppressSelection = true
        if dataChanged {
            self.rows = rows
            indexByPath = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        }
        if dataChanged || columnsChanged {
            // Hidden columns can retain zero-height cells. Reconfigure them
            // after visibility changes while restoring the same paths/viewport.
            tableView.reloadData()
        }
        let indexes = IndexSet(selection.compactMap { indexByPath[$0] })
        if tableView.selectedRowIndexes != indexes { tableView.selectRowIndexes(indexes, byExtendingSelection: false) }
        suppressSelection = false
        resizeColumns()
        restyleAvailableRows()
        tableView.headerView?.needsDisplay = true
        tableView.needsDisplay = true
        let visibleSelection = Set(indexes.map { self.rows[$0].id })
        // Binding writes from updateNSView must wait until SwiftUI's update ends.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == token else { return }
            if let viewport { self.restoreViewport(viewport) }
            else { self.layoutSubtreeIfNeeded(); self.positionAtTopIfNeeded() }
            if visibleSelection != selection { self.onSelection?(visibleSelection) }
        }
    }

    override func layout() {
        super.layout()
        resizeColumns()
        positionAtTopIfNeeded()
    }

    private func resizeColumns() {
        guard !adjustingColumns else { return }
        adjustingColumns = true
        defer { adjustingColumns = false }
        // Use the actual clip view, including any space consumed by a legacy
        // scrollbar. contentSize can still describe the previous tiling pass.
        let width = max(0, floor(contentView.bounds.width))
        guard width > 0 else { return }
        let statusWidth: CGFloat = 48
        let sizeWidth: CGFloat = width < 900 ? 68 : 82
        let dateWidth: CGFloat = showModifiedDates ? (width < 1000 ? 112 : 128) : 0
        let nameWidth = max(0, (width - statusWidth) / 2 - sizeWidth - dateWidth)
        for column in tableView.tableColumns {
            let id = column.identifier.rawValue
            let target = id == "status" ? statusWidth : id.hasSuffix("Name") ? nameWidth : id.hasSuffix("Size") ? sizeWidth : dateWidth
            if abs(column.width - target) > 0.5 { column.width = target }
        }
    }

    private func configureHeaders() {
        for column in tableView.tableColumns {
            let id = column.identifier.rawValue
            switch id {
            case "leftName", "rightName": column.title = mode == .tree ? L("名称", "Name") : L("相对路径", "Relative Path")
            case "leftSize", "rightSize": column.title = L("大小", "Size")
            case "leftModified", "rightModified": column.title = L("修改时间", "Modified")
            default: column.title = L("状态", "Status")
            }
            column.headerCell.font = .systemFont(ofSize: 11, weight: .medium)
            column.headerCell.textColor = theme.secondaryText
            column.headerCell.alignment = id == "status" ? .center : id.hasSuffix("Size") ? .right : .left
            let active = sortKey(for: id) == sort.key
            let indicator = active ? NSImage(named: sort.ascending ? NSImage.touchBarGoUpTemplateName : NSImage.touchBarGoDownTemplateName) : nil
            // Standard table indicators draw inside the header and do not change
            // its title or consume a separate, focusable control.
            tableView.setIndicatorImage(active ? (NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") ?? indicator) : nil, in: column)
            column.headerToolTip = headerTooltip(id)
        }
    }

    private func headerTooltip(_ id: String) -> String {
        let side = id.hasPrefix("left") ? L("左侧", "Left") : L("右侧", "Right")
        let key = sortKey(for: id)
        switch key {
        case .name: return L("按名称自然排序；左右配对项目一起移动。", "Sort names naturally; both sides move together.")
        case .status: return L("按状态排序；左右配对项目一起移动。", "Sort by status; both sides move together.")
        case .leftSize, .rightSize:
            return mode == .tree
                ? L("目录优先，同级文件按\(side)大小排序；缺失大小置后。", "Folders first; sort sibling files by \(side.lowercased()) size, with missing sizes last.")
                : L("按\(side)文件大小排序；目录及缺失大小置后。", "Sort by \(side.lowercased()) file size; folders and missing sizes come last.")
        default: return L("按\(side)修改时间排序；不重新读取文件。", "Sort by \(side.lowercased()) modification time without rereading files.")
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let tableColumn else { return nil }
        let id = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FolderPairedCell) ?? FolderPairedCell()
        cell.identifier = id
        configure(cell, column: id.rawValue, row: rows[row])
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FolderPairedRowView()
        view.theme = theme
        return view
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        revision += 1 // A user's click wins over any queued normalization.
        onSelection?(Set(tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }))
    }
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let key = sortKey(for: tableColumn.identifier.rawValue)
        let descendingInitially = key == .leftSize || key == .rightSize || key == .leftModified || key == .rightModified
        onSort?(FolderBrowserSort(key: key, ascending: key == sort.key ? !sort.ascending : !descendingInitially))
    }
    private func sortKey(for id: String) -> FolderBrowserSortKey {
        switch id {
        case "leftSize": return .leftSize
        case "rightSize": return .rightSize
        case "leftModified": return .leftModified
        case "rightModified": return .rightModified
        case "status": return .status
        default: return .name
        }
    }

    private func configure(_ cell: FolderPairedCell, column: String, row: FolderBrowserRow) {
        let entry = row.entry
        let isLeft = column.hasPrefix("left")
        let snapshot = isLeft ? entry.left : entry.right
        let side = isLeft ? L("左侧", "Left") : L("右侧", "Right")
        let tooltip = entry.path + "\n" + entry.status.title + (entry.problem.map { "\n" + $0 } ?? "") + summaryTooltip(row)
        if column == "status" {
            cell.configure(text: "", symbol: statusSymbol(entry.status), color: statusColor(entry.status), theme: theme,
                           alignment: .center, numeric: false, depth: 0, summary: "", expanded: nil, emphasized: false)
            cell.setAccessibilityLabel(entry.path + ", " + entry.status.title)
        } else if column.hasSuffix("Name") {
            let name = mode == .list ? entry.path : String(entry.path.split(separator: "/").last ?? Substring(entry.path))
            let missing = entry.status == .unreadable ? L("状态未知", "Unknown") : L("此侧不存在", "Not present")
            // When neither side could be inspected, the inventory still knows
            // this path. Keep its name visible instead of showing two Unknowns.
            let bothUnknown = entry.status == .unreadable && entry.left == nil && entry.right == nil
            let text = snapshot == nil && !bothUnknown ? missing : name
            let canExpand = mode == .tree && row.hasChildren
            let summary = snapshot?.kind == .directory ? summaryText(row) : ""
            cell.configure(text: text, symbol: snapshot.map { symbol($0.kind) },
                           color: snapshot == nil ? theme.secondaryText : theme.text,
                           theme: theme, alignment: .left, numeric: false, depth: mode == .tree ? row.depth : 0,
                           summary: summary, expanded: canExpand ? row.isExpanded : nil,
                           emphasized: snapshot?.kind == .directory, allowsExpansion: allowsExpansion)
            cell.onToggle = canExpand && allowsExpansion ? { [weak self] in self?.onToggleFolder?(entry.path) } : nil
            cell.setDisclosureIdentity(entry.path, isLeft: isLeft)
            cell.setAccessibilityLabel(side + ", " + entry.path + ", " + (snapshot == nil ? missing : entry.status.title) + summaryTooltip(row))
        } else {
            let text: String
            if column.hasSuffix("Size") {
                text = snapshot.map { $0.kind == .file ? ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: AppSettings.shared.locale).format($0.size) : "—" } ?? "—"
            } else { text = snapshot.map { dateFormatter.string(from: $0.modifiedDate) } ?? "—" }
            cell.configure(text: text, symbol: nil, color: theme.secondaryText, theme: theme,
                           alignment: column.hasSuffix("Size") ? .right : .left, numeric: true,
                           depth: 0, summary: "", expanded: nil, emphasized: false)
            cell.setAccessibilityLabel(side + ", " + entry.path + ", " + text)
        }
        cell.toolTip = tooltip
    }

    private func summaryText(_ row: FolderBrowserRow) -> String {
        let counts = row.descendants
        let itemCount = "\(counts.total) " + (counts.total == 1 ? "item" : "items")
        if counts.issues > 0 {
            let issueCount = "\(counts.issues) " + (counts.issues == 1 ? "issue" : "issues")
            return L("\(counts.total) 项 · 问题 \(counts.issues)", "\(itemCount) · \(issueCount)")
        }
        if counts.pending > 0 { return L("\(counts.total) 项 · 待校验", "\(itemCount) · pending") }
        let changes = counts.total - counts.same
        if changes > 0 {
            let changeCount = "\(changes) " + (changes == 1 ? "change" : "changes")
            return L("\(changes) 处变化 · \(counts.total) 项", "\(changeCount) · \(counts.total)")
        }
        return L("\(counts.total) 项", itemCount)
    }
    private func summaryTooltip(_ row: FolderBrowserRow) -> String {
        guard row.entry.isDirectory else { return "" }
        let c = row.descendants
        return L("\n目录下配对项目：\(c.total)；相同 \(c.same)，改动 \(c.changed)，仅左 \(c.leftOnly)，仅右 \(c.rightOnly)，问题 \(c.issues)，待校验 \(c.pending)。",
                 "\nCompared descendants: \(c.total); identical \(c.same), modified \(c.changed), left only \(c.leftOnly), right only \(c.rightOnly), issues \(c.issues), pending \(c.pending).")
    }
    private func symbol(_ kind: FolderItemKind) -> String {
        switch kind {
        case .directory: return "folder.fill"
        case .file: return "doc"
        case .symbolicLink: return "link"
        case .other: return "questionmark.square"
        }
    }
    private func statusSymbol(_ status: FolderEntryStatus) -> String {
        switch status {
        case .same: return "equal"
        case .changed: return "plusminus"
        case .leftOnly: return "arrow.left"
        case .rightOnly: return "arrow.right"
        case .pending: return "clock"
        case .typeMismatch, .unreadable: return "exclamationmark.triangle"
        }
    }
    private func statusColor(_ status: FolderEntryStatus) -> NSColor {
        switch status {
        case .leftOnly: return theme.differenceForeground(isRemoval: true)
        case .rightOnly: return theme.differenceForeground(isRemoval: false)
        case .changed, .typeMismatch: return theme.accent
        case .unreadable: return theme.differenceForeground(isRemoval: true)
        default: return theme.secondaryText
        }
    }

    private func restyleAvailableRows() {
        // AppKit retains instantiated rows outside the visible rect. A resize
        // can reveal them without calling viewFor again, so refresh every
        // available view, while never instantiating the entire inventory.
        tableView.enumerateAvailableRowViews { rowView, index in
            guard self.rows.indices.contains(index) else { return }
            if let row = rowView as? FolderPairedRowView {
                row.theme = theme
                row.needsDisplay = true
            }
            for (columnIndex, column) in tableView.tableColumns.enumerated() {
                if let cell = tableView.view(atColumn: columnIndex, row: index, makeIfNecessary: false) as? FolderPairedCell {
                    configure(cell, column: column.identifier.rawValue, row: rows[index])
                }
            }
        }
    }

    private struct Viewport { let path: String; let offset: CGFloat; let origin: CGFloat }
    private func currentViewport() -> Viewport? {
        guard !rows.isEmpty else { return nil }
        // Logical top excludes the floating header. Capturing raw clip bounds
        // loses this reservation when headers are retiled during resizing.
        let top = contentView.bounds.minY + contentView.contentInsets.top
        var visibleRect = tableView.visibleRect
        visibleRect.origin.y = max(0, top)
        visibleRect.size.height = max(0, contentView.bounds.height - contentView.contentInsets.top - contentView.contentInsets.bottom)
        let visible = tableView.rows(in: visibleRect)
        guard visible.location != NSNotFound, rows.indices.contains(visible.location) else { return nil }
        return Viewport(path: rows[visible.location].id,
                        offset: top - tableView.rect(ofRow: visible.location).minY,
                        origin: top)
    }
    private func restoreViewport(_ viewport: Viewport) {
        layoutSubtreeIfNeeded()
        let top = indexByPath[viewport.path].map { tableView.rect(ofRow: $0).minY + viewport.offset } ?? viewport.origin
        let y = top - contentView.contentInsets.top
        let constrained = contentView.constrainBoundsRect(NSRect(x: 0, y: y, width: contentView.bounds.width, height: contentView.bounds.height))
        contentView.scroll(to: constrained.origin)
        reflectScrolledClipView(contentView)
    }
    private func positionAtTopIfNeeded() {
        guard needsInitialTopPosition, !rows.isEmpty, window != nil,
              contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
        needsInitialTopPosition = false
        let insets = contentView.contentInsets
        let proposed = NSRect(x: -insets.left, y: -insets.top,
                              width: contentView.bounds.width, height: contentView.bounds.height)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }
    @objc private func openClickedRow(_ sender: Any?) {
        guard rows.indices.contains(tableView.clickedRow) else { return }
        onOpen?(rows[tableView.clickedRow].entry)
    }
    private func handleNavigation(_ event: NSEvent) -> Bool {
        guard rows.indices.contains(tableView.selectedRow) else { return false }
        let row = rows[tableView.selectedRow]
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 125 && modifiers.contains(.command) { onOpen?(row.entry); return true }
        guard mode == .tree, modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        if event.keyCode == 124 {
            if row.hasChildren && !row.isExpanded && allowsExpansion { onToggleFolder?(row.id) }
            else if row.hasChildren && row.isExpanded, rows.indices.contains(tableView.selectedRow + 1) {
                tableView.selectRowIndexes(IndexSet(integer: tableView.selectedRow + 1), byExtendingSelection: false)
                tableView.scrollRowToVisible(tableView.selectedRow)
            }
            return true
        }
        if event.keyCode == 123 {
            if row.hasChildren && row.isExpanded && allowsExpansion { onToggleFolder?(row.id) }
            else if let slash = row.id.lastIndex(of: "/"), let parent = indexByPath[String(row.id[..<slash])] {
                tableView.selectRowIndexes(IndexSet(integer: parent), byExtendingSelection: false)
                tableView.scrollRowToVisible(parent)
            }
            return true
        }
        return false
    }
}

@MainActor
private final class FolderPairedTableView: NSTableView {
    var onNavigationKey: ((NSEvent) -> Bool)?
    var theme = ComparisonTheme.light
    override var undoManager: UndoManager? { nil }
    override func keyDown(with event: NSEvent) {
        if onNavigationKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let index = tableColumns.firstIndex(where: { $0.identifier.rawValue == "status" }) else { return }
        let center = rect(ofColumn: index)
        theme.separator.withAlphaComponent(0.65).setFill()
        for x in [center.minX, center.maxX] {
            NSRect(x: x, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
    }
}

@MainActor
private final class FolderPairedRowView: NSTableRowView {
    var theme = ComparisonTheme.light
    override func drawSelection(in dirtyRect: NSRect) {
        theme.selectionBackground.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}

@MainActor
private final class FolderPairedCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let disclosure = NSButton()
    private var contentColor = NSColor.labelColor
    private var secondaryColor = NSColor.secondaryLabelColor
    private var selectedColor = NSColor.selectedControlTextColor
    private var depth = 0
    private var centered = false
    private var showsIcon = false
    private var showsDisclosure = false
    var onToggle: (() -> Void)?
    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for field in [label, summaryLabel] {
            field.isEditable = false
            field.isSelectable = false
            field.drawsBackground = false
            field.maximumNumberOfLines = 1
            field.lineBreakMode = .byTruncatingMiddle
            addSubview(field)
        }
        summaryLabel.font = .systemFont(ofSize: 10)
        disclosure.isBordered = false
        disclosure.bezelStyle = .inline
        disclosure.imagePosition = .imageOnly
        disclosure.target = self
        disclosure.action = #selector(toggle(_:))
        disclosure.setButtonType(.momentaryChange)
        addSubview(disclosure)
        addSubview(icon)
        icon.imageScaling = .scaleProportionallyDown
        textField = label
        imageView = icon
    }
    required init?(coder: NSCoder) { nil }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        // Native table reuse may allocate the final cell frame after configure
        // has already laid out a hidden column at zero height.
        if changed { needsLayout = true }
    }
    func setDisclosureIdentity(_ path: String, isLeft: Bool) {
        disclosure.setAccessibilityIdentifier("folders.disclosure." + (isLeft ? "left." : "right.") + path)
    }
    func configure(text: String, symbol: String?, color: NSColor, theme: ComparisonTheme,
                   alignment: NSTextAlignment, numeric: Bool, depth: Int, summary: String,
                   expanded: Bool?, emphasized: Bool, allowsExpansion: Bool = true) {
        label.stringValue = text
        label.font = numeric ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12, weight: emphasized ? .medium : .regular)
        label.alignment = alignment
        label.lineBreakMode = numeric ? .byTruncatingTail : .byTruncatingMiddle
        summaryLabel.stringValue = summary
        contentColor = color
        selectedColor = theme.selectionText
        secondaryColor = theme.secondaryText
        self.depth = depth
        centered = alignment == .center
        showsIcon = symbol != nil
        icon.isHidden = !showsIcon
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        showsDisclosure = expanded != nil
        disclosure.isHidden = !showsDisclosure
        disclosure.isEnabled = showsDisclosure && allowsExpansion
        disclosure.image = NSImage(systemSymbolName: expanded == true ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        disclosure.setAccessibilityLabel(expanded == true ? L("折叠文件夹", "Collapse Folder") : L("展开文件夹", "Expand Folder"))
        disclosure.toolTip = allowsExpansion ? nil : L("搜索期间自动展开匹配路径", "Matching paths expand automatically during search")
        disclosure.setAccessibilityHelp(disclosure.toolTip)
        onToggle = nil
        applyColors()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        if centered {
            icon.frame = NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
            label.frame = .zero
            summaryLabel.isHidden = true
            return
        }
        let indentation = min(CGFloat(depth) * 16, max(0, bounds.width - 130))
        let start: CGFloat = 8 + indentation
        disclosure.frame = NSRect(x: start, y: (bounds.height - 20) / 2, width: 16, height: 20)
        // Every name cell keeps the same disclosure slot, including leaf rows.
        let nameCell = identifier?.rawValue.hasSuffix("Name") == true
        let iconX = start + (nameCell ? 18 : 0)
        icon.frame = NSRect(x: iconX, y: (bounds.height - 15) / 2, width: 15, height: 15)
        let textX = iconX + (showsIcon ? 22 : 0)
        let available = max(0, bounds.width - textX - 8)
        // Reused text fields can report an intrinsic size constrained by their
        // previous cell frame. Measure this string independently and include the
        // text-field drawing inset so short summaries never gain an ellipsis.
        let measuredSummary = ceil((summaryLabel.stringValue as NSString).size(withAttributes: [
            .font: summaryLabel.font ?? NSFont.systemFont(ofSize: 10)
        ]).width) + 8
        let summaryWidth = summaryLabel.stringValue.isEmpty ? 0 : min(measuredSummary, max(0, available - 100))
        summaryLabel.isHidden = summaryWidth < 24
        let gap: CGFloat = summaryLabel.isHidden ? 0 : 9
        let taken = summaryLabel.isHidden ? 0 : summaryWidth
        label.frame = NSRect(x: textX, y: (bounds.height - 16) / 2, width: max(0, available - taken - gap), height: 16)
        summaryLabel.frame = NSRect(x: bounds.width - 8 - taken, y: (bounds.height - 15) / 2, width: taken, height: 15)
    }
    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        label.textColor = selected ? selectedColor : contentColor
        icon.contentTintColor = selected ? selectedColor : contentColor
        summaryLabel.textColor = selected ? selectedColor : secondaryColor
        disclosure.contentTintColor = selected ? selectedColor : secondaryColor
    }
    @objc private func toggle(_ sender: Any?) { onToggle?() }
}
