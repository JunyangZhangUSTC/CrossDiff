import AppKit
import SwiftUI
import CrossDiffCore

@MainActor
final class EditorScrollLink: ObservableObject {
    let alignment = TextAlignmentCoordinator()
    private weak var left: NSScrollView?
    private weak var right: NSScrollView?
    private weak var preview: NSScrollView?
    private var syncing = false
    func register(_ scroll: NSScrollView, side: Side) { if side == .left { left = scroll } else { right = scroll } }
    func registerPreview(_ scroll: NSScrollView) { preview = scroll }
    func unregisterPreview(_ scroll: NSScrollView) {
        // A representable can be replaced before the old instance is dismantled.
        if preview === scroll { preview = nil }
    }

    func synchronize(from side: Side, session: ComparisonSession) {
        guard session.synchronizedScrolling, !session.calculating, !syncing else { return }
        if session.showDeletions {
            // The editable right view stays mounted to preserve its undo stack.
            // Its layout notifications must not move the visible review surface.
            if side == .left { synchronizeProjection(fromPreview: false, session: session) }
            return
        }
        guard
              let source = side == .left ? left : right, let target = side == .left ? right : left,
              let sourceText = source.documentView as? NSTextView, let targetText = target.documentView as? NSTextView,
              sourceText.string.utf16.elementsEqual(session.value(side).text.utf16),
              targetText.string.utf16.elementsEqual(session.value(side == .left ? .right : .left).text.utf16) else { return }
        if session.alignDifferences, alignment.isAligned {
            syncing = true; defer { syncing = false }
            let y = min(max(0, source.contentView.bounds.minY), max(0, targetText.bounds.height - target.contentView.bounds.height))
            target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.minX, y: y))
            target.reflectScrolledClipView(target.contentView)
            return
        }
        let sourceLines = lineOffsets(sourceText.string)
        let targetLines = lineOffsets(targetText.string)
        synchronize(source: source, target: target) { character in
            let sourceLine = max(0, sourceLines.partitionIndex { $0 > character } - 1)
            var targetLine = min(sourceLine, targetLines.count - 1)
            if let rows = session.result?.rows,
               let index = rows.firstIndex(where: { (side == .left ? $0.leftLine : $0.rightLine) == sourceLine }) {
                let after = rows[index...].first { (side == .left ? $0.rightLine : $0.leftLine) != nil }
                let before = rows[..<index].last { (side == .left ? $0.rightLine : $0.leftLine) != nil }
                if let row = after ?? before { targetLine = (side == .left ? row.rightLine : row.leftLine) ?? targetLine }
            }
            targetLine = min(max(0, targetLine), targetLines.count - 1)
            return (sourceLines[sourceLine], targetLines[targetLine])
        }
    }

    func synchronizePreview(session: ComparisonSession) {
        guard session.showDeletions, session.synchronizedScrolling, !session.calculating, !syncing else { return }
        synchronizeProjection(fromPreview: true, session: session)
    }

    private func synchronizeProjection(fromPreview: Bool, session: ComparisonSession) {
        guard let projection = session.deletionPreview, !projection.lines.isEmpty,
              let left, let preview,
              let leftText = left.documentView as? NSTextView,
              let previewText = preview.documentView as? NSTextView,
              leftText.string.utf16.elementsEqual(session.left.text.utf16),
              previewText.string.utf16.elementsEqual(projection.text.utf16) else { return }
        let leftLines = lineOffsets(leftText.string)
        let previewOffsets = projection.lines.map(\.range.location)
        synchronize(source: fromPreview ? preview : left, target: fromPreview ? left : preview) { character in
            if fromPreview {
                let sourceLine = max(0, previewOffsets.partitionIndex { $0 > character } - 1)
                var mappedLine = projection.lines[sourceLine].leftLine
                // Added-only rows have no left counterpart. Use the closest
                // surrounding mapped row, preferring the following row on ties.
                if mappedLine == nil {
                    for distance in 1..<projection.lines.count {
                        let after = sourceLine + distance, before = sourceLine - distance
                        if after < projection.lines.count { mappedLine = projection.lines[after].leftLine }
                        if mappedLine == nil, before >= 0 { mappedLine = projection.lines[before].leftLine }
                        if mappedLine != nil { break }
                    }
                }
                guard let targetLine = mappedLine, leftLines.indices.contains(targetLine) else { return nil }
                return (previewOffsets[sourceLine], leftLines[targetLine])
            }
            let sourceLine = max(0, leftLines.partitionIndex { $0 > character } - 1)
            guard let targetLine = projection.lines.firstIndex(where: { $0.leftLine == sourceLine }) else { return nil }
            return (leftLines[sourceLine], previewOffsets[targetLine])
        }
    }

    /// The mapping supplies logical line starts, keeping the current position
    /// within a wrapped line instead of forcing either side back to its top.
    private func synchronize(source: NSScrollView, target: NSScrollView,
                             mapping: (Int) -> (source: Int, target: Int)?) {
        guard !syncing,
              let sourceText = source.documentView as? NSTextView, let targetText = target.documentView as? NSTextView,
              let sourceLayout = sourceText.layoutManager, let sourceContainer = sourceText.textContainer,
              let targetLayout = targetText.layoutManager, let targetContainer = targetText.textContainer,
              sourceText.string.utf16.count > 0, targetText.string.utf16.count > 0,
              sourceLayout.numberOfGlyphs > 0, targetLayout.numberOfGlyphs > 0 else { return }
        syncing = true; defer { syncing = false }
        let visible = source.contentView.bounds
        let point = NSPoint(x: visible.minX - sourceText.textContainerOrigin.x,
                            y: max(0, visible.minY - sourceText.textContainerOrigin.y))
        let glyph = sourceLayout.glyphIndex(for: point, in: sourceContainer)
        let character = sourceLayout.characterIndexForGlyph(at: min(glyph, sourceLayout.numberOfGlyphs - 1))
        guard let mapped = mapping(character) else { return }
        let targetCharacter = min(max(0, mapped.target), targetText.string.utf16.count - 1)
        let range = targetLayout.glyphRange(forCharacterRange: NSRange(location: targetCharacter, length: 1), actualCharacterRange: nil)
        let targetRect = targetLayout.boundingRect(forGlyphRange: range, in: targetContainer)
        let sourceCharacter = min(max(0, mapped.source), sourceText.string.utf16.count - 1)
        let sourceGlyphRange = sourceLayout.glyphRange(forCharacterRange: NSRange(location: sourceCharacter, length: 1), actualCharacterRange: nil)
        let sourceRect = sourceLayout.boundingRect(forGlyphRange: sourceGlyphRange, in: sourceContainer)
        let relative = visible.minY - sourceRect.minY - sourceText.textContainerOrigin.y
        let y = targetRect.minY + targetText.textContainerOrigin.y + relative
        let maxY = max(0, targetText.bounds.height - target.contentView.bounds.height)
        target.contentView.scroll(to: NSPoint(x: target.contentView.bounds.minX, y: max(0, min(y, maxY))))
        target.reflectScrolledClipView(target.contentView)
    }
}

private func lineOffsets(_ text: String) -> [Int] {
    let string = text as NSString
    var offsets = [0], offset = 0
    while offset < string.length {
        let next = NSMaxRange(string.lineRange(for: NSRange(location: offset, length: 0)))
        guard next > offset else { break }
        if next < string.length { offsets.append(next) }
        offset = next
    }
    return offsets
}

private extension Array where Element == Int {
    func partitionIndex(_ predicate: (Int) -> Bool) -> Int {
        var lower = 0, upper = count
        while lower < upper { let mid = (lower + upper) / 2; if predicate(self[mid]) { upper = mid } else { lower = mid + 1 } }
        return lower
    }
}

final class ComparisonTextView: NSTextView {
    #if CROSSDIFF_UI_CHECKS
    // Isolated native checks drive NSTextInputClient directly and must never
    // attach the user's live input method to their off-screen test windows.
    override var inputContext: NSTextInputContext? { nil }
    #endif
    var alignmentMinimumHeight: CGFloat = 0
    var hunkBands: [EditorHunkBand] = []
    var displayGaps: [EditorDisplayGap] = []
    var selectedHunk = -1
    var comparisonTheme: ComparisonTheme = .light
    lazy var navigationIndicator = TextNavigationIndicator(editor: self)
    var clickedHunk: ((Int) -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        navigationIndicator.draw(in: dirtyRect, theme: comparisonTheme)
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let y = convert(event.locationInWindow, from: nil).y
        if let band = hunkBands.first(where: { y >= $0.minY && y < $0.minY + $0.height }) {
            clickedHunk?(band.index)
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: max(newSize.height, alignmentMinimumHeight)))
    }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        comparisonTheme.separator.withAlphaComponent(0.22).setFill()
        for gap in displayGaps {
            let blank = NSRect(x: 0, y: gap.minY, width: bounds.width, height: gap.height).intersection(rect)
            if !blank.isEmpty { blank.fill() }
        }
        guard let band = hunkBands.first(where: { $0.index == selectedHunk }) else { return }
        let marker = NSRect(x: 3, y: band.minY, width: 3, height: max(3, band.height)).intersection(rect)
        comparisonTheme.accent.setFill(); marker.fill()
    }
    // Build the core editing menu when it is opened so it follows the app's
    // language immediately, without replacing the text view or its undo history.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let groups: [[(String, Selector)]] = [
            [(L("撤销", "Undo"), #selector(undoComparison(_:))),
             (L("重做", "Redo"), #selector(redoComparison(_:)))],
            [(L("剪切", "Cut"), #selector(cut(_:))),
             (L("复制", "Copy"), #selector(copy(_:))),
             (L("粘贴", "Paste"), #selector(paste(_:))),
             (L("删除", "Delete"), #selector(delete(_:)))],
            [(L("全选", "Select All"), #selector(selectAll(_:)))]
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for (title, action) in group {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func undoComparison(_ sender: Any?) { undoManager?.undo() }
    @objc private func redoComparison(_ sender: Any?) { undoManager?.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undoComparison(_:)) { return isEditable && undoManager?.canUndo == true }
        if item.action == #selector(redoComparison(_:)) { return isEditable && undoManager?.canRedo == true }
        return super.validateUserInterfaceItem(item)
    }

    weak var comparisonUndoManager: UndoManager?
    override var undoManager: UndoManager? { comparisonUndoManager }
    var becameFocused: (() -> Void)?
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); if result { becameFocused?() }; return result }
}

final class LineNumberRuler: NSRulerView {
    weak var editor: NSTextView?
    var offsets: [Int] = [0]
    var labels: [String]?
    var theme: ComparisonTheme = .light
    var hunkBands: [EditorHunkBand] = []
    var displayGaps: [EditorDisplayGap] = []
    var selectedHunk = -1
    var selectHunk: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let y = convert(event.locationInWindow, from: nil).y + (scrollView?.contentView.bounds.minY ?? 0)
        if let band = hunkBands.first(where: { y >= $0.minY && y <= $0.minY + max($0.height, 8) }) {
            selectHunk?(band.index)
        } else { super.mouseDown(with: event) }
    }
    init(scrollView: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clipsToBounds = true
        clientView = editor; ruleThickness = 52
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer, let scrollView else { return }
        // SwiftUI hosting can invalidate a dirty rectangle wider than the ruler.
        // Never allow its background or labels to paint over the source editor.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        let dirty = rect.intersection(bounds)
        guard !dirty.isEmpty else { return }
        theme.canvas.setFill(); dirty.fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: theme.secondaryText]
        let visible = scrollView.contentView.bounds
        for gap in displayGaps {
            let y = gap.minY - visible.minY
            if y + gap.height >= 0 && y < visible.height {
                let dash = "—" as NSString
                dash.draw(at: NSPoint(x: ruleThickness - dash.size(withAttributes: attributes).width - 10, y: y + 2), withAttributes: attributes)
            }
        }
        for band in hunkBands where band.index == selectedHunk {
            let marker = NSRect(x: 2, y: band.minY - visible.minY, width: 3, height: max(3, band.height))
            theme.accent.setFill(); marker.intersection(bounds).fill()
        }
        let length = editor.string.utf16.count
        if length == 0 {
            if !displayGaps.isEmpty { return }
            let number = (labels?.first ?? "1") as NSString
            number.draw(at: NSPoint(x: ruleThickness - number.size(withAttributes: attributes).width - 10,
                                    y: editor.textContainerOrigin.y + 2), withAttributes: attributes)
            return
        }
        guard layout.numberOfGlyphs > 0 else { return }
        let startGlyph = layout.glyphIndex(for: NSPoint(x: 0, y: max(0, visible.minY - editor.textContainerOrigin.y)), in: container)
        let character = layout.characterIndexForGlyph(at: min(startGlyph, max(0, layout.numberOfGlyphs - 1)))
        let first = max(0, offsets.partitionIndex { $0 > character } - 1)
        for index in first..<offsets.count {
            let location = offsets[index]
            guard location < length else { continue }
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            let bounds = layout.boundingRect(forGlyphRange: glyph, in: container)
            let y = bounds.minY + editor.textContainerOrigin.y - visible.minY
            if y > visible.height + 25 { break }
            if y < -25 { continue }
            let number = (labels.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? String(index + 1)) as NSString
            number.draw(at: NSPoint(x: ruleThickness - number.size(withAttributes: attributes).width - 10, y: y + 2), withAttributes: attributes)
        }
    }
}

@MainActor
final class TextEditorState {
    let scroll: NSScrollView
    let editor: ComparisonTextView
    let ruler: LineNumberRuler
    let undoManager = UndoManager()
    let alignmentLayout = TextAlignmentLayout()
    var lastNavigation: UUID?
    var lastSearchNavigation: UUID?
    var theme: ComparisonTheme?
    // Retained with the native view so a representable rebind cannot turn an
    // in-flight local edit into an apparent external model replacement.
    var pendingNativeEdit = false
    var applyingModelText = false

    init(text: String, side: Side, wrapLines: Bool) {
        let storage = NSTextStorage()
        let layout = ComparisonTextLayoutManager(); storage.addLayoutManager(layout); layout.delegate = alignmentLayout
        let container = NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)); layout.addTextContainer(container)
        container.lineFragmentPadding = 0
        editor = ComparisonTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), textContainer: container)
        editor.comparisonUndoManager = undoManager
        editor.minSize = NSSize(width: 0, height: 0); editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.isRichText = false; editor.allowsUndo = true
        editor.usesAdaptiveColorMappingForDarkAppearance = false
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        editor.textColor = ComparisonTheme.light.text; editor.backgroundColor = ComparisonTheme.light.canvas
        editor.textContainerInset = NSSize(width: 15, height: 12)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: editor.font!, .foregroundColor: ComparisonTheme.light.text, .paragraphStyle: paragraph]
        editor.string = text
        editor.setAccessibilityLabel(side == .left ? L("左侧文本编辑器", "Left Text Editor") : L("右侧文本编辑器", "Right Text Editor"))
        scroll = ComparisonScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = !wrapLines
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.documentView = editor
        container.widthTracksTextView = true
        ruler = LineNumberRuler(scrollView: scroll, editor: editor)
        ruler.offsets = lineOffsets(text); scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
    }
}

struct NativeTextEditor: NSViewRepresentable {
    let text: String
    let side: Side
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var session: ComparisonSession
    let scrollLink: EditorScrollLink
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let cached = side == .left ? session.leftEditorState : session.rightEditorState
        let state = cached ?? TextEditorState(text: text, side: side, wrapLines: session.wrapLines)
        if side == .left { session.leftEditorState = state } else { session.rightEditorState = state }
        context.coordinator.bind(to: state)
        scrollLink.register(state.scroll, side: side)
        return state.scroll
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.disconnect() }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh(text: text, in: scroll, theme: ComparisonTheme(isDark: colorScheme == .dark))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: NativeTextEditor
        weak var editor: ComparisonTextView?
        weak var ruler: LineNumberRuler?
        weak var state: TextEditorState?
        var observer: NSObjectProtocol?
        var frameObserver: NSObjectProtocol?
        var lastText = ""
        private var needsPresentationNormalization = true
        private var dirtyPresentationRange: NSRange?
        private var normalizingPresentation = false
        var lastNavigation: UUID?
        private var lastSearchNavigation: UUID?
        private var navigating = false
        init(_ parent: NativeTextEditor) { self.parent = parent }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }
        func refresh(text: String, in scroll: NSScrollView, theme: ComparisonTheme = .light) {
            let coordinator = self
            let session = parent.session, side = parent.side
            coordinator.editor?.setAccessibilityLabel(side == .left ? L("左侧文本编辑器", "Left Text Editor") : L("右侧文本编辑器", "Right Text Editor"))
            guard let editor = coordinator.editor,
                  !normalizingPresentation, state?.pendingNativeEdit != true,
                  state?.applyingModelText != true,
                  text.utf16.elementsEqual(session.value(side).text.utf16) else { return }
            if !editor.string.utf16.elementsEqual(text.utf16) && !editor.hasMarkedText() {
                state?.applyingModelText = true
                editor.breakUndoCoalescing()
                editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                editor.breakUndoCoalescing(); editor.undoManager?.setActionName(L("合并差异", "Merge Difference"))
                state?.applyingModelText = false
            }
            editor.isHorizontallyResizable = !session.wrapLines
            editor.autoresizingMask = session.wrapLines ? [.width] : []
            scroll.hasHorizontalScroller = !session.wrapLines
            editor.textContainer?.widthTracksTextView = session.wrapLines
            if session.wrapLines {
                // contentSize includes the area occupied by an overlay ruler.
                // Match ComparisonScrollView's usable viewport, otherwise the
                // next native layout changes wrapping after alignment measured it.
                let insets = scroll.contentView.contentInsets
                let width = max(0, scroll.contentView.bounds.width - insets.left - insets.right)
                editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
                editor.textContainer?.containerSize = NSSize(width: max(0, width - editor.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
            } else { editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude) }
            if !coordinator.lastText.utf16.elementsEqual(text.utf16) {
                coordinator.lastText = text; coordinator.ruler?.offsets = lineOffsets(text); coordinator.ruler?.needsDisplay = true
            }
            guard !editor.hasMarkedText(), let layout = editor.layoutManager else { return }
            if needsPresentationNormalization || state?.theme != theme {
                normalizePresentation(theme: theme, in: scroll)
            }
            parent.scrollLink.alignment.update(session: session)
            updateHunkBands()
            let full = NSRange(location: 0, length: editor.string.utf16.count)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            if !session.calculating, let result = session.result {
                let isRemoval = side == .left
                for (index, hunk) in result.hunks.enumerated() {
                    let range = side == .left ? hunk.leftRange : hunk.rightRange
                    let color = theme.differenceBackground(isRemoval: isRemoval, selected: index == session.selectedHunk)
                    if range.length > 0 && NSMaxRange(range) <= full.length { layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range) }
                }
                if session.characterHighlights {
                    for row in result.rows {
                        for range in (side == .left ? row.leftHighlights : row.rightHighlights) where range.length > 0 && NSMaxRange(range) <= full.length {
                            layout.addTemporaryAttribute(.foregroundColor, value: theme.differenceForeground(isRemoval: isRemoval), forCharacterRange: range)
                        }
                    }
                }
                if coordinator.lastNavigation != session.navigationID, result.hunks.indices.contains(session.selectedHunk) {
                    coordinator.lastNavigation = session.navigationID
                    coordinator.state?.lastNavigation = session.navigationID
                    let hunk = result.hunks[session.selectedHunk], range = side == .left ? hunk.leftRange : hunk.rightRange
                    if NSMaxRange(range) <= full.length {
                        editor.scrollRangeToVisible(range)
                        let band = editor.hunkBands.first { $0.index == session.selectedHunk }
                        let anchor = range.length == 0 ? band.map {
                            NSRect(x: editor.textContainerOrigin.x, y: $0.minY, width: 6, height: max(18, $0.height))
                        } : nil
                        if let anchor { editor.scrollToVisible(anchor) }
                        editor.navigationIndicator.show([range], emptyAnchor: anchor)
                    }
                }
            }
            if session.isSearchVisible {
                for match in session.searchMatches where match.side == side && NSMaxRange(match.range) <= full.length {
                    layout.addTemporaryAttribute(.backgroundColor, value: theme.selectionBackground, forCharacterRange: match.range)
                }
            }
            if lastSearchNavigation != session.searchNavigationID {
                lastSearchNavigation = session.searchNavigationID; state?.lastSearchNavigation = session.searchNavigationID
                if let match = session.currentSearchMatch, match.side == side, NSMaxRange(match.range) <= full.length {
                    navigating = true
                    editor.setSelectedRange(match.range); editor.scrollRangeToVisible(match.range)
                    editor.navigationIndicator.show([match.range])
                    navigating = false
                } else { editor.navigationIndicator.cancel() }
            }
        }
        private func updateHunkBands() {
            let session = parent.session
            guard let editor, let state, let layout = editor.layoutManager, let container = editor.textContainer else { return }
            var bands: [EditorHunkBand] = []
            if !session.calculating, let result = session.result {
                if parent.scrollLink.alignment.isAligned {
                    bands = parent.scrollLink.alignment.hunkBands(originY: editor.textContainerOrigin.y)
                } else {
                    layout.ensureLayout(for: container)
                    let length = editor.string.utf16.count
                    for (index, hunk) in result.hunks.enumerated() {
                        let range = parent.side == .left ? hunk.leftRange : hunk.rightRange
                        guard NSMaxRange(range) <= length else { continue }
                        let rect: NSRect
                        if range.location < length {
                            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: max(1, range.length)), actualCharacterRange: nil)
                            rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                        } else { rect = layout.extraLineFragmentRect }
                        bands.append(EditorHunkBand(index: index, minY: rect.minY + editor.textContainerOrigin.y, height: max(18, rect.height)))
                    }
                }
            }
            state.ruler.hunkBands = bands; state.ruler.selectedHunk = session.selectedHunk; state.ruler.needsDisplay = true
            editor.hunkBands = bands; editor.selectedHunk = session.selectedHunk; editor.needsDisplay = true
        }
        private func normalizePresentation(theme: ComparisonTheme, in scroll: NSScrollView) {
            guard let editor, !editor.hasMarkedText(), !normalizingPresentation else { return }
            normalizingPresentation = true
            defer { normalizingPresentation = false }
            // Plain text input may still arrive as an attributed string from an input client.
            // Normalize only presentation; do not replace characters or register an undo action.
            let font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
            editor.usesAdaptiveColorMappingForDarkAppearance = false
            let normalizeAll = state?.theme != theme || dirtyPresentationRange == nil
            if normalizeAll {
                editor.font = font; editor.defaultParagraphStyle = paragraph; editor.textColor = theme.text
            }
            editor.backgroundColor = theme.canvas
            editor.drawsBackground = true
            editor.insertionPointColor = theme.text
            editor.comparisonTheme = theme
            editor.selectedTextAttributes = [.foregroundColor: theme.selectionText, .backgroundColor: theme.selectionBackground]
            var typing = editor.typingAttributes
            typing[.foregroundColor] = theme.text
            typing[.font] = font; typing[.paragraphStyle] = paragraph
            typing.removeValue(forKey: .backgroundColor)
            editor.typingAttributes = typing
            if let storage = editor.textStorage, storage.length > 0 {
                let full = NSRange(location: 0, length: storage.length)
                let range = normalizeAll ? full : NSIntersectionRange(full, dirtyPresentationRange!)
                storage.beginEditing()
                storage.addAttributes([.foregroundColor: theme.text, .font: font, .paragraphStyle: paragraph], range: range)
                storage.removeAttribute(.backgroundColor, range: range)
                storage.endEditing()
            }
            scroll.drawsBackground = true; scroll.backgroundColor = theme.canvas
            scroll.contentView.drawsBackground = true; scroll.contentView.backgroundColor = theme.canvas
            ruler?.theme = theme; ruler?.needsDisplay = true
            state?.theme = theme
            needsPresentationNormalization = false; dirtyPresentationRange = nil
            editor.needsDisplay = true
        }
        func bind(to state: TextEditorState) {
            if let previous = state.editor.delegate as? Coordinator, previous !== self { previous.disconnect() }
            disconnect()
            self.state = state; editor = state.editor; ruler = state.ruler
            lastText = state.editor.string
            needsPresentationNormalization = true
            let navigation = state.lastNavigation ?? parent.session.navigationID
            lastNavigation = navigation; state.lastNavigation = navigation
            lastSearchNavigation = state.lastSearchNavigation
            state.editor.delegate = self
            state.editor.textStorage?.delegate = self
            let side = parent.side
            state.editor.becameFocused = { [weak session = parent.session] in session?.focusSide = side }
            state.ruler.selectHunk = { [weak session = parent.session] index in
                guard let session, !session.calculating, session.result?.hunks.indices.contains(index) == true else { return }
                session.selectedHunk = index; session.focusSide = side
            }
            state.editor.clickedHunk = state.ruler.selectHunk
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: state.scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.ruler?.needsDisplay = true
                    self.parent.scrollLink.synchronize(from: self.parent.side, session: self.parent.session)
                }
            }
            state.scroll.contentView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: state.scroll.contentView, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let state = self.state else { return }
                    self.refresh(text: self.parent.session.value(self.parent.side).text, in: state.scroll, theme: state.theme ?? .light)
                }
            }
        }
        func disconnect() {
            // An old SwiftUI coordinator may dismantle after the same view has been rebound.
            if editor?.delegate === self {
                editor?.navigationIndicator.cancel()
                editor?.delegate = nil; editor?.becameFocused = nil; editor?.clickedHunk = nil; ruler?.selectHunk = nil
                if editor?.textStorage?.delegate === self { editor?.textStorage?.delegate = nil }
            }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            observer = nil; frameObserver = nil; editor = nil; ruler = nil; state = nil
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor, !editor.hasMarkedText(), !normalizingPresentation, !navigating,
                  state?.pendingNativeEdit != true, state?.applyingModelText != true,
                  editor.string.utf16.elementsEqual(parent.session.value(parent.side).text.utf16) else { return }
            parent.session.selectHunk(atUTF16: editor.selectedRange().location, side: parent.side)
            updateHunkBands()
        }
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard !normalizingPresentation, editedMask.contains(.editedCharacters), editedRange.location != NSNotFound else { return }
            editor?.navigationIndicator.cancel()
            // Input clients may supply styled attributed text. Only the affected
            // range needs normalization; theme changes still repaint everything.
            dirtyPresentationRange = dirtyPresentationRange.map { NSUnionRange($0, editedRange) } ?? editedRange
            needsPresentationNormalization = true
            if state?.applyingModelText != true { state?.pendingNativeEdit = true }
        }
        func textDidChange(_ notification: Notification) {
            guard let editor, !editor.hasMarkedText(), !normalizingPresentation, state?.applyingModelText != true else { return }
            needsPresentationNormalization = true
            ruler?.offsets = lineOffsets(editor.string); ruler?.needsDisplay = true
            // Publishing can synchronously invalidate the SwiftUI hierarchy.
            // Until publication returns, the native edit owns its characters.
            state?.pendingNativeEdit = true
            parent.onChange(editor.string)
            state?.pendingNativeEdit = false
            // Equal strings can still arrive with different presentation attributes.
            // Such edits intentionally do not publish a model change, so repaint here too.
            if let state { refresh(text: editor.string, in: state.scroll, theme: state.theme ?? .light) }
        }
    }
}
