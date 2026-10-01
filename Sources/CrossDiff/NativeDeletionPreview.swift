import AppKit
import SwiftUI
import CrossDiffCore

/// A separate, selectable review surface. Its decorated text never enters the
/// editable source, file saving, session persistence, or the source undo stack.
struct NativeDeletionPreview: NSViewRepresentable {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var session: ComparisonSession
    let scrollLink: EditorScrollLink
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.state.editor.delegate = coordinator
        coordinator.state.editor.becameFocused = { [weak session] in session?.focusSide = .right }
        coordinator.state.ruler.selectHunk = { [weak session] index in
            guard let session, !session.calculating else { return }
            session.selectedHunk = index; session.focusSide = .right
        }
        scrollLink.registerPreview(coordinator.state.scroll)
        coordinator.observeScrolling()
        DispatchQueue.main.async { [weak coordinator] in coordinator?.transferFocusIfNeeded() }
        return coordinator.state.scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh(in: scroll, theme: ComparisonTheme(isDark: colorScheme == .dark))
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeDeletionPreview
        let state = DeletionPreviewState()
        private var observer: NSObjectProtocol?
        private var generation = -1
        private var theme: ComparisonTheme?
        private var lastNavigation: UUID
        private var lastCharacterHighlights: Bool?
        private var restoringFocus = true
        private var changingSelection = false
        private var lastSearchNavigation: UUID?
        private var renderedRightRevision = -1
        private var pendingSelection: (source: NSRange, projected: NSRange, text: String, revision: Int)?

        init(_ parent: NativeDeletionPreview) {
            self.parent = parent
            lastNavigation = parent.session.navigationID
        }

        func observeScrolling() {
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: state.scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state.ruler.needsDisplay = true
                    self.parent.scrollLink.synchronizePreview(session: self.parent.session)
                }
            }
        }

        func refresh(in scroll: NSScrollView, theme: ComparisonTheme) {
            let session = parent.session, editor = state.editor
            editor.comparisonTheme = theme
            editor.setAccessibilityLabel(L("右侧含删除内容的只读预览", "Read-only right preview including deletions"))
            let projection = session.deletionPreview
            if projection == nil, let previous = editor.projection {
                let selection = editor.selectedRange()
                if let start = previous.rightOffset(forPreviewOffset: selection.location),
                   let end = previous.rightOffset(forPreviewOffset: NSMaxRange(selection)) {
                    pendingSelection = (NSRange(location: start, length: max(0, end - start)), selection, previous.text, renderedRightRevision)
                }
            }
            editor.projection = projection
            let updated = generation != session.previewGeneration || (projection != nil && !state.hasProjection)
            let colorsChanged = self.theme != theme
            let precisionChanged = lastCharacterHighlights != session.characterHighlights
            if updated { editor.navigationIndicator.cancel() }
            if updated || colorsChanged || precisionChanged {
                var selection = editor.selectedRange()
                if let projection, let pending = pendingSelection {
                    if pending.revision == session.rightRevision {
                        if projection.text.utf16.elementsEqual(pending.text.utf16) { selection = pending.projected }
                        else if let start = projection.previewOffset(forRightOffset: pending.source.location),
                                let end = projection.previewOffset(forRightOffset: NSMaxRange(pending.source)) {
                            selection = NSRange(location: start, length: max(0, end - start))
                        }
                    }
                    pendingSelection = nil
                }
                let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                    .foregroundColor: theme.text, .paragraphStyle: paragraph
                ]
                let text = NSMutableAttributedString(string: projection?.text ?? "", attributes: attributes)
                if let projection {
                    for range in projection.addedRanges {
                        text.addAttribute(.backgroundColor, value: theme.differenceBackground(isRemoval: false), range: range)
                        if session.characterHighlights {
                            text.addAttribute(.foregroundColor, value: theme.differenceForeground(isRemoval: false), range: range)
                        }
                    }
                    for range in projection.removedRanges {
                        text.addAttributes([
                            .foregroundColor: theme.differenceForeground(isRemoval: true),
                            .backgroundColor: theme.differenceBackground(isRemoval: true),
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: theme.differenceForeground(isRemoval: true)
                        ], range: range)
                    }
                    state.ruler.offsets = projection.lines.map(\.range.location)
                    state.ruler.labels = projection.lines.map { $0.rightLine.map { String($0 + 1) } ?? "−" }
                } else {
                    state.ruler.offsets = [0]; state.ruler.labels = [""]
                }
                changingSelection = true
                editor.textStorage?.setAttributedString(text)
                let start = min(selection.location, text.length)
                editor.setSelectedRange(NSRange(location: start, length: min(selection.length, text.length - start)))
                changingSelection = false
                editor.backgroundColor = theme.canvas
                editor.insertionPointColor = theme.text
                editor.selectedTextAttributes = [.foregroundColor: theme.selectionText, .backgroundColor: theme.selectionBackground]
                scroll.backgroundColor = theme.canvas
                scroll.contentView.backgroundColor = theme.canvas
                state.ruler.theme = theme; state.ruler.needsDisplay = true
                state.hasProjection = projection != nil
                if projection != nil { renderedRightRevision = session.rightRevision }
                generation = session.previewGeneration; self.theme = theme
                lastCharacterHighlights = session.characterHighlights
            }
            editor.isHorizontallyResizable = !session.wrapLines
            editor.autoresizingMask = session.wrapLines ? [.width] : []
            scroll.hasHorizontalScroller = !session.wrapLines
            editor.textContainer?.widthTracksTextView = session.wrapLines
            let insets = scroll.contentView.contentInsets
            let viewportWidth = max(0, scroll.contentView.bounds.width - insets.left - insets.right)
            if session.wrapLines { editor.setFrameSize(NSSize(width: viewportWidth, height: editor.frame.height)) }
            editor.textContainer?.containerSize = NSSize(
                width: session.wrapLines ? max(0, viewportWidth - editor.textContainerInset.width * 2) : .greatestFiniteMagnitude,
                height: .greatestFiniteMagnitude)
            scroll.needsLayout = true
            scroll.layoutSubtreeIfNeeded()
            updateHunkBands()

            if let layout = editor.layoutManager, let projection {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: editor.string.utf16.count))
                if session.isSearchVisible {
                    for match in session.searchMatches where match.side == .right {
                        for range in previewRanges(for: match.range, projection: projection) {
                            layout.addTemporaryAttribute(.backgroundColor, value: theme.selectionBackground, forCharacterRange: range)
                        }
                    }
                }
                if lastSearchNavigation != session.searchNavigationID {
                    lastSearchNavigation = session.searchNavigationID
                    if let match = session.currentSearchMatch, match.side == .right,
                       let first = previewRanges(for: match.range, projection: projection).first,
                       let last = previewRanges(for: match.range, projection: projection).last {
                        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
                        changingSelection = true
                        editor.setSelectedRange(range); editor.scrollRangeToVisible(range)
                        editor.navigationIndicator.show(previewRanges(for: match.range, projection: projection))
                        changingSelection = false
                    } else { editor.navigationIndicator.cancel() }
                }
            }

            if let projection, lastNavigation != session.navigationID,
               projection.hunkRanges.indices.contains(session.selectedHunk) {
                lastNavigation = session.navigationID
                editor.scrollRangeToVisible(projection.hunkRanges[session.selectedHunk])
                editor.navigationIndicator.show([projection.hunkRanges[session.selectedHunk]])
            }
            if updated, projection != nil {
                parent.scrollLink.synchronize(from: .left, session: session)
            }
            transferFocusIfNeeded()
        }

        private func previewRanges(for source: NSRange, projection: DeletionPreview) -> [NSRange] {
            projection.runs.compactMap { run in
                guard run.rightRange.length > 0 else { return nil }
                let overlap = NSIntersectionRange(source, run.rightRange)
                guard overlap.length > 0 else { return nil }
                return NSRange(location: run.range.location + overlap.location - run.rightRange.location, length: overlap.length)
            }
        }

        private func updateHunkBands() {
            guard let projection = parent.session.deletionPreview, let layout = state.editor.layoutManager,
                  let container = state.editor.textContainer else { state.ruler.hunkBands = []; return }
            layout.ensureLayout(for: container)
            state.ruler.hunkBands = projection.hunkRanges.enumerated().map { index, range in
                let rect = range.length > 0
                    ? layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                    : layout.extraLineFragmentRect
                return EditorHunkBand(index: index, minY: rect.minY + state.editor.textContainerOrigin.y, height: max(18, rect.height))
            }
            state.ruler.selectedHunk = parent.session.selectedHunk
            state.ruler.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !changingSelection, !parent.session.calculating, let projection = parent.session.deletionPreview else { return }
            let offset = state.editor.selectedRange().location
            if let index = projection.hunkRanges.firstIndex(where: { NSLocationInRange(offset, $0) || ($0.length == 0 && $0.location == offset) }) {
                parent.session.selectedHunk = index
                parent.session.focusSide = .right
                updateHunkBands()
            }
        }

        func transferFocusIfNeeded() {
            if restoringFocus, let window = state.scroll.window {
                restoringFocus = false
                if window.firstResponder === parent.session.rightEditorState?.editor {
                    window.makeFirstResponder(state.editor)
                }
            }
        }

        func disconnect() {
            state.editor.navigationIndicator.cancel()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            state.editor.becameFocused = nil
            state.editor.delegate = nil
            state.ruler.selectHunk = nil
            parent.scrollLink.unregisterPreview(state.scroll)
            if !parent.session.showDeletions {
                parent.scrollLink.synchronize(from: .left, session: parent.session)
            }
            if let window = state.scroll.window, window.firstResponder === state.editor {
                window.makeFirstResponder(parent.session.rightEditorState?.editor)
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

@MainActor
final class DeletionPreviewState {
    let scroll: NSScrollView
    let editor: PreviewTextView
    let ruler: LineNumberRuler
    var hasProjection = false

    init() {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container); container.lineFragmentPadding = 0
        editor = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), textContainer: container)
        editor.isEditable = false; editor.isSelectable = true; editor.allowsUndo = false
        editor.isRichText = true; editor.usesAdaptiveColorMappingForDarkAppearance = false
        editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainerInset = NSSize(width: 15, height: 12)
        editor.drawsBackground = true
        editor.setAccessibilityLabel(L("右侧含删除内容的只读预览", "Read-only right preview including deletions"))
        scroll = ComparisonScrollView()
        scroll.identifier = NSUserInterfaceItemIdentifier("crossdiff-deletion-preview")
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.drawsBackground = true
        scroll.documentView = editor; scroll.contentView.drawsBackground = true
        scroll.contentView.postsBoundsChangedNotifications = true
        ruler = LineNumberRuler(scrollView: scroll, editor: editor)
        ruler.offsets = [0]; ruler.labels = [""]
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
    }
}
