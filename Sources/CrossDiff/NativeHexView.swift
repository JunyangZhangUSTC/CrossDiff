import AppKit
import SwiftUI
import CrossDiffCore

struct BinaryByteSelection: Equatable {
    let side: BinaryDataSide
    let range: Range<Int64>
    let bytes: Data
}

@MainActor
final class BinaryHexSelection: ObservableObject {
    @Published private(set) var value: BinaryByteSelection?
    var selectedHex: String? {
        value.map { $0.bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
    }
    func set(_ value: BinaryByteSelection?) { if self.value != value { self.value = value } }
    func copyHex() {
        guard let text = selectedHex, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
struct NativeHexView: NSViewRepresentable {
    let page: BinaryPage?
    let layout: BinaryRowLayout?
    let selectedSpanIndex: Int?
    let requestedRow: Int64
    let navigationID: UUID
    let theme: ComparisonTheme
    let selection: BinaryHexSelection
    let requestRows: (Int64, Int) -> Void

    func makeNSView(context: Context) -> BinaryHexViewport { BinaryHexViewport() }
    func updateNSView(_ view: BinaryHexViewport, context: Context) {
        view.update(page: page, layout: layout, selectedSpanIndex: selectedSpanIndex,
                    requestedRow: requestedRow, navigationID: navigationID, theme: theme,
                    selection: selection, requestRows: requestRows)
    }
}

/// A fixed-height viewport plus an Int64 row scroller. Even an 8 GiB input
/// never creates an enormous NSView or one view/string per file row.
@MainActor
final class BinaryHexViewport: NSView {
    let canvas = BinaryHexCanvas()
    private let scroll = BinaryHorizontalScrollView()
    private let rowScroller = NSScroller()
    private var rowCount: Int64 = 0
    private var bytesPerRow = 16
    private var lastNavigationID: UUID?
    private var lastRequestedPage: Range<Int64>?
    private var request: ((Int64, Int) -> Void)?
    private var wheelRemainder: CGFloat = 0
    private(set) var firstVisibleRow: Int64 = 0
    var selectedHex: String? { canvas.selection?.selectedHex }
    override var isFlipped: Bool { true }
    var visibleRowCount: Int { max(1, Int((scroll.contentSize.height - BinaryHexCanvas.headerHeight) / BinaryHexCanvas.rowHeight)) }
    private var lastRow: Int64 { max(0, rowCount - Int64(visibleRowCount)) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("binary.hex.viewport")
        canvas.viewport = self; scroll.owner = self
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.documentView = canvas
        rowScroller.scrollerStyle = .legacy
        rowScroller.target = self; rowScroller.action = #selector(scrollerChanged(_:))
        rowScroller.setAccessibilityLabel(L("二进制比较行位置", "Binary Comparison Row Position"))
        addSubview(scroll); addSubview(rowScroller)
    }
    required init?(coder: NSCoder) { nil }

    func update(page: BinaryPage?, layout: BinaryRowLayout?, selectedSpanIndex: Int?, requestedRow: Int64,
                navigationID: UUID, theme: ComparisonTheme, selection: BinaryHexSelection,
                requestRows: @escaping (Int64, Int) -> Void) {
        request = requestRows
        let columnsChanged = bytesPerRow != layout?.bytesPerRow
        rowCount = layout?.totalRows ?? 0; bytesPerRow = layout?.bytesPerRow ?? 16
        canvas.page = page; canvas.bytesPerRow = bytesPerRow; canvas.totalRows = rowCount
        canvas.selectedSpanIndex = selectedSpanIndex; canvas.theme = theme; canvas.selection = selection
        scroll.backgroundColor = theme.canvas
        rowScroller.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        rowScroller.setAccessibilityLabel(L("二进制比较行位置", "Binary Comparison Row Position"))
        canvas.setAccessibilityLabel(L("左右十六进制与 ASCII 字节比较", "Side-by-side Hex and ASCII Byte Comparison"))
        if lastNavigationID != navigationID || columnsChanged {
            lastNavigationID = navigationID
            firstVisibleRow = max(0, min(requestedRow, lastRow))
            lastRequestedPage = nil
            canvas.clearSelection(deferred: true)
        } else {
            firstVisibleRow = min(firstVisibleRow, lastRow)
            canvas.reconcileSelection()
        }
        canvas.firstVisibleRow = firstVisibleRow
        needsLayout = true; canvas.needsDisplay = true
        refreshScroller()
    }

    override func layout() {
        super.layout()
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        scroll.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - scrollerWidth), height: bounds.height)
        rowScroller.frame = NSRect(x: bounds.width - scrollerWidth, y: 0, width: scrollerWidth, height: bounds.height)
        let content = scroll.contentSize
        canvas.frame = NSRect(x: 0, y: 0, width: max(content.width, BinaryHexCanvas.minimumWidth(columns: bytesPerRow)), height: content.height)
        firstVisibleRow = min(firstVisibleRow, lastRow); canvas.firstVisibleRow = firstVisibleRow
        refreshScroller(); requestVisibleRows()
        canvas.needsDisplay = true
    }

    func scroll(toRow row: Int64) {
        let next = min(max(0, row), lastRow)
        guard next != firstVisibleRow else { requestVisibleRows(); return }
        firstVisibleRow = next; canvas.firstVisibleRow = next
        canvas.needsDisplay = true; refreshScroller(); requestVisibleRows()
    }
    func move(rows delta: Int64) { scroll(toRow: firstVisibleRow + delta) }
    func moveToEnd() { scroll(toRow: lastRow) }
    override func scrollWheel(with event: NSEvent) { scrollVertically(event) }
    func scrollVertically(_ event: NSEvent) {
        wheelRemainder += event.hasPreciseScrollingDeltas ? -event.scrollingDeltaY / BinaryHexCanvas.rowHeight : -event.scrollingDeltaY * 3
        let movement = Int64(wheelRemainder.rounded(.towardZero))
        if movement != 0 { wheelRemainder -= CGFloat(movement); move(rows: movement) }
    }
    private func refreshScroller() {
        rowScroller.isEnabled = rowCount > Int64(visibleRowCount)
        rowScroller.knobProportion = rowCount == 0 ? 1 : min(1, CGFloat(visibleRowCount) / CGFloat(rowCount))
        rowScroller.doubleValue = lastRow == 0 ? 0 : Double(firstVisibleRow) / Double(lastRow)
        rowScroller.setAccessibilityValue(L("第 \(firstVisibleRow + 1) 行，共 \(rowCount) 行", "Row \(firstVisibleRow + 1) of \(rowCount)"))
        canvas.setAccessibilityValue(L("第 \(firstVisibleRow + 1) 行，共 \(rowCount) 行；每行 \(bytesPerRow) 字节。方向键滚动，拖动字节选择，Command C 复制十六进制。",
                                      "Row \(firstVisibleRow + 1) of \(rowCount), \(bytesPerRow) bytes per row. Use arrow keys to scroll, drag bytes to select, and Command C to copy hex."))
    }
    private func requestVisibleRows() {
        guard rowCount > 0, bounds.height > 0 else { return }
        let start = firstVisibleRow
        let count = min(BinaryRowLayout.maximumPageRows, visibleRowCount + 96)
        let end = min(rowCount, start + Int64(count))
        let range = start..<end
        guard lastRequestedPage != range else { return }
        lastRequestedPage = range
        // SwiftUI must not receive a synchronous state change during layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastRequestedPage == range else { return }
            self.request?(start, Int(end - start))
        }
    }
    @objc private func scrollerChanged(_ sender: NSScroller) {
        switch sender.hitPart {
        case .decrementLine: move(rows: -1)
        case .incrementLine: move(rows: 1)
        case .decrementPage: move(rows: -Int64(max(1, visibleRowCount - 1)))
        case .incrementPage: move(rows: Int64(max(1, visibleRowCount - 1)))
        default: scroll(toRow: Int64((sender.doubleValue * Double(lastRow)).rounded()))
        }
    }
}

private final class BinaryHorizontalScrollView: NSScrollView {
    weak var owner: BinaryHexViewport?
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), !event.modifierFlags.contains(.shift) {
            owner?.scrollVertically(event)
        } else { super.scrollWheel(with: event) }
    }
}

@MainActor
final class BinaryHexCanvas: NSView, NSUserInterfaceValidations {
    static let rowHeight: CGFloat = 25
    static let headerHeight: CGFloat = 31
    private static let offsetWidth: CGFloat = 88
    private static let byteWidth: CGFloat = 21.5
    private static let characterWidth: CGFloat = 7.2
    private static let groupGap: CGFloat = 10
    weak var viewport: BinaryHexViewport?
    var page: BinaryPage?
    var bytesPerRow = 16
    var totalRows: Int64 = 0
    var firstVisibleRow: Int64 = 0
    var selectedSpanIndex: Int?
    var theme = ComparisonTheme.light
    var selection: BinaryHexSelection?
    private var anchor: (side: BinaryDataSide, offset: Int64)?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { nil }
    var selectedHex: String? { selection?.selectedHex }
    static func minimumWidth(columns: Int) -> CGFloat {
        2 * (offsetWidth + CGFloat(columns) * byteWidth + (columns == 16 ? groupGap : 0) + 20 + CGFloat(columns) * characterWidth + 16)
    }
    private var paneWidth: CGFloat { bounds.width / 2 }
    private var hexWidth: CGFloat { CGFloat(bytesPerRow) * Self.byteWidth + (bytesPerRow == 16 ? Self.groupGap : 0) }
    private var asciiStart: CGFloat { Self.offsetWidth + hexWidth + 20 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("binary.hex.canvas")
        setAccessibilityRole(.table)
        setAccessibilityLabel(L("左右十六进制与 ASCII 字节比较", "Side-by-side Hex and ASCII Byte Comparison"))
    }
    required init?(coder: NSCoder) { nil }

    func cellRect(side: BinaryDataSide, row: Int64, column: Int, ascii: Bool = false) -> NSRect? {
        guard row >= firstVisibleRow, row < firstVisibleRow + Int64(viewport?.visibleRowCount ?? 1),
              column >= 0, column < bytesPerRow else { return nil }
        let base = side == .left ? CGFloat(0) : paneWidth
        let x = ascii ? base + asciiStart + CGFloat(column) * Self.characterWidth :
            base + Self.offsetWidth + CGFloat(column) * Self.byteWidth + (column >= 8 ? Self.groupGap : 0)
        return NSRect(x: x, y: Self.headerHeight + CGFloat(row - firstVisibleRow) * Self.rowHeight + 2,
                      width: ascii ? Self.characterWidth : Self.byteWidth - 2, height: Self.rowHeight - 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.canvas.setFill(); dirtyRect.fill()
        theme.chrome.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight).fill()
        drawHeaders()
        theme.separator.setFill()
        NSRect(x: paneWidth, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: Self.headerHeight - 1, width: bounds.width, height: 1).fill()
        if totalRows == 0 {
            drawText(L("两份文件均为空", "Both Files Are Empty"), at: NSPoint(x: 24, y: 60), font: .systemFont(ofSize: 13), color: theme.secondaryText)
            return
        }
        let first = max(0, Int((dirtyRect.minY - Self.headerHeight) / Self.rowHeight))
        let last = min(viewport?.visibleRowCount ?? 1, Int(ceil((dirtyRect.maxY - Self.headerHeight) / Self.rowHeight)))
        guard first < last else { return }
        for localRow in first..<last {
            let index = firstVisibleRow + Int64(localRow)
            guard index < totalRows else { break }
            let y = Self.headerHeight + CGFloat(localRow) * Self.rowHeight
            if index % 2 == 1 { theme.chrome.withAlphaComponent(0.35).setFill(); NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight).fill() }
            guard let row = page?.row(at: index) else {
                drawText(L("读取中…", "Loading…"), at: NSPoint(x: 16, y: y + 5), font: .systemFont(ofSize: 11), color: theme.secondaryText)
                continue
            }
            for side in [BinaryDataSide.left, .right] { draw(row: row, side: side, y: y) }
        }
    }
    private func drawHeaders() {
        for side in [BinaryDataSide.left, .right] {
            let base = side == .left ? CGFloat(0) : paneWidth
            drawText(L("偏移", "OFFSET"), at: NSPoint(x: base + 14, y: 10), font: .monospacedSystemFont(ofSize: 10, weight: .medium), color: theme.secondaryText)
            for column in 0..<bytesPerRow {
                let x = base + Self.offsetWidth + CGFloat(column) * Self.byteWidth + (column >= 8 ? Self.groupGap : 0)
                drawText(String(format: "%02X", column), at: NSPoint(x: x + 2, y: 10), font: .monospacedSystemFont(ofSize: 10, weight: .regular), color: theme.secondaryText)
            }
            drawText("ASCII", at: NSPoint(x: base + asciiStart, y: 10), font: .monospacedSystemFont(ofSize: 10, weight: .medium), color: theme.secondaryText)
        }
    }
    private func draw(row: BinaryLayoutRow, side: BinaryDataSide, y: CGFloat) {
        let base = side == .left ? CGFloat(0) : paneWidth
        let firstOffset = row.cells.compactMap { $0.offset(on: side) }.first
        drawText(firstOffset.map { String(format: "%09llX", $0) } ?? "—————————", at: NSPoint(x: base + 14, y: y + 5),
                 font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: theme.secondaryText)
        for (column, cell) in row.cells.enumerated() {
            guard let hexRect = cellRect(side: side, row: row.index, column: column),
                  let asciiRect = cellRect(side: side, row: row.index, column: column, ascii: true) else { continue }
            guard let offset = cell.offset(on: side) else {
                drawText("—", at: NSPoint(x: hexRect.minX + 4, y: y + 5), font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: theme.secondaryText.withAlphaComponent(0.55))
                continue
            }
            guard let byte = page?.byte(at: offset, side: side) else { continue }
            let selected = selection?.value.map { $0.side == side && $0.range.contains(offset) } ?? false
            let marked = cell.kind == .changed || cell.kind == (side == .left ? .removed : .added)
            var color = theme.text
            if selected || marked {
                let background = selected ? theme.selectionBackground : theme.differenceBackground(isRemoval: side == .left, selected: cell.spanIndex == selectedSpanIndex)
                background.setFill()
                NSBezierPath(roundedRect: hexRect, xRadius: 3, yRadius: 3).fill()
                asciiRect.fill()
                color = selected ? theme.selectionText : theme.differenceForeground(isRemoval: side == .left)
            }
            if cell.spanIndex == selectedSpanIndex && marked {
                theme.navigationOutline.withAlphaComponent(0.7).setFill()
                NSRect(x: hexRect.minX + 2, y: hexRect.maxY - 1, width: hexRect.width - 4, height: 1).fill()
            }
            drawText(String(format: "%02X", byte), at: NSPoint(x: hexRect.minX + 2, y: y + 5),
                     font: .monospacedSystemFont(ofSize: 11.5, weight: marked ? .medium : .regular), color: color)
            let character = byte >= 0x20 && byte <= 0x7e ? String(UnicodeScalar(byte)) : "."
            drawText(character, at: NSPoint(x: asciiRect.minX, y: y + 5), font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                     color: marked || selected || byte >= 0x20 && byte <= 0x7e ? color : theme.secondaryText)
        }
    }
    private func drawText(_ value: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (value as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let hit = hitByte(convert(event.locationInWindow, from: nil)) else { clearSelection(); return }
        anchor = hit
        select(side: hit.side, from: hit.offset, to: hit.offset)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor, let hit = hitByte(convert(event.locationInWindow, from: nil)), anchor.side == hit.side else { return }
        select(side: anchor.side, from: anchor.offset, to: hit.offset)
    }
    override func mouseUp(with event: NSEvent) { anchor = nil }
    private func hitByte(_ point: NSPoint) -> (side: BinaryDataSide, offset: Int64)? {
        guard point.y >= Self.headerHeight else { return nil }
        let side: BinaryDataSide = point.x < paneWidth ? .left : .right
        let x = point.x - (side == .left ? 0 : paneWidth)
        let rowIndex = firstVisibleRow + Int64((point.y - Self.headerHeight) / Self.rowHeight)
        guard let row = page?.row(at: rowIndex) else { return nil }
        let column: Int
        if x >= asciiStart, x < asciiStart + CGFloat(bytesPerRow) * Self.characterWidth {
            column = Int((x - asciiStart) / Self.characterWidth)
        } else if x >= Self.offsetWidth, x < Self.offsetWidth + hexWidth {
            var local = x - Self.offsetWidth
            if bytesPerRow == 16, local >= 8 * Self.byteWidth {
                guard local >= 8 * Self.byteWidth + Self.groupGap else { return nil }
                local -= Self.groupGap
            }
            column = Int(local / Self.byteWidth)
        } else { return nil }
        guard row.cells.indices.contains(column), let offset = row.cells[column].offset(on: side) else { return nil }
        return (side, offset)
    }
    private func select(side: BinaryDataSide, from start: Int64, to end: Int64) {
        let range = min(start, end)..<(max(start, end) + 1)
        guard let bytes = page?.bytes(in: range, side: side) else { return }
        selection?.set(BinaryByteSelection(side: side, range: range, bytes: bytes))
        needsDisplay = true
    }
    func clearSelection(deferred: Bool = false) {
        anchor = nil
        if deferred {
            let previous = selection?.value
            DispatchQueue.main.async { [weak selection] in
                if selection?.value == previous { selection?.set(nil) }
            }
        } else { selection?.set(nil) }
        needsDisplay = true
    }
    func reconcileSelection() {
        guard let value = selection?.value else { return }
        guard let bytes = page?.bytes(in: value.range, side: value.side), bytes == value.bytes else { clearSelection(deferred: true); return }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if let hit = hitByte(convert(event.locationInWindow, from: nil)),
           selection?.value.map({ $0.side == hit.side && $0.range.contains(hit.offset) }) != true {
            select(side: hit.side, from: hit.offset, to: hit.offset)
        }
        let menu = NSMenu()
        let item = NSMenuItem(title: L("复制十六进制", "Copy Hexadecimal"), action: #selector(copy(_:)), keyEquivalent: "")
        item.target = self; menu.addItem(item)
        return menu
    }
    @objc func copy(_ sender: Any?) { selection?.copyHex() }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        item.action == #selector(copy(_:)) && selection?.value != nil
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: viewport?.move(rows: -1)
        case 125: viewport?.move(rows: 1)
        case 116: viewport?.move(rows: -Int64(max(1, (viewport?.visibleRowCount ?? 1) - 1)))
        case 121: viewport?.move(rows: Int64(max(1, (viewport?.visibleRowCount ?? 1) - 1)))
        case 115: viewport?.scroll(toRow: 0)
        case 119: viewport?.moveToEnd()
        case 53: clearSelection()
        default: super.keyDown(with: event)
        }
    }
}
