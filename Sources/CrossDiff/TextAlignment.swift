import AppKit
import CrossDiffCore

/// The typesetter reserves display space without inserting source characters or
/// changing paragraph attributes. Selection, copy, undo and IME stay native.
@MainActor
final class TextAlignmentLayout: NSObject, @preconcurrency NSLayoutManagerDelegate {
    private var after: [Int: CGFloat] = [:]
    private var leading: CGFloat = 0

    func setPadding(after: [Int: CGFloat], leading: CGFloat, layout: NSLayoutManager) {
        guard self.after != after || self.leading != leading else { return }
        self.after = after; self.leading = leading
        layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: layout.textStorage?.length ?? 0), actualCharacterRange: nil)
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        if glyphRange.location == 0, leading > 0 {
            lineFragmentRect.pointee.origin.y += leading
            lineFragmentUsedRect.pointee.origin.y += leading
        }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        if let padding = after[NSMaxRange(characters)] {
            lineFragmentRect.pointee.size.height += padding
        }
        return true
    }
}

struct EditorHunkBand {
    let index: Int
    let minY: CGFloat
    let height: CGFloat
}

struct EditorDisplayGap {
    let minY: CGFloat
    let height: CGFloat
}

struct AlignedDisplayRow {
    let leftLine: Int?
    let rightLine: Int?
    let minY: CGFloat
    let height: CGFloat
    let hunkIndex: Int?
}

/// Coordinates the two typesetters using their unpadded native measurements. A
/// viewport change can alter either side's wrapping, so both sides update as one.
@MainActor
final class TextAlignmentCoordinator {
    private struct Signature: Equatable {
        let leftRevision: Int
        let rightRevision: Int
        let leftWidth: CGFloat
        let rightWidth: CGFloat
        let wrap: Bool
        let ignoreWhitespace: Bool
        let ignoreCase: Bool
        let leftIdentity: ObjectIdentifier
        let rightIdentity: ObjectIdentifier
    }
    private var signature: Signature?
    private(set) var rows: [AlignedDisplayRow] = []
    private var bands: [EditorHunkBand] = []
    private(set) var isAligned = false
    private var updating = false

    func update(session: ComparisonSession) {
        guard !updating, let left = session.leftEditorState, let right = session.rightEditorState,
              !left.editor.hasMarkedText(), !right.editor.hasMarkedText() else { return }
        updating = true; defer { updating = false }
        guard session.alignDifferences, !session.showDeletions, !session.calculating, let result = session.result,
              left.editor.string.utf16.elementsEqual(session.left.text.utf16),
              right.editor.string.utf16.elementsEqual(session.right.text.utf16) else {
            if isAligned { reset(left); reset(right) }
            signature = nil; rows = []; bands = []; isAligned = false
            return
        }
        let next = Signature(leftRevision: session.leftRevision, rightRevision: session.rightRevision,
                             leftWidth: left.editor.textContainer?.containerSize.width ?? 0,
                             rightWidth: right.editor.textContainer?.containerSize.width ?? 0,
                             wrap: session.wrapLines, ignoreWhitespace: session.ignoreWhitespace,
                             ignoreCase: session.ignoreCase, leftIdentity: ObjectIdentifier(left), rightIdentity: ObjectIdentifier(right))
        guard signature != next else { return }
        signature = next
        align(left: left, right: right, rows: result.rows)
    }

    func align(left: TextEditorState, right: TextEditorState, rows diffRows: [DiffRow]) {
        let a = measure(left), b = measure(right)
        var leftPadding: [Int: CGFloat] = [:], rightPadding: [Int: CGFloat] = [:]
        var leftLeading: CGFloat = 0, rightLeading: CGFloat = 0
        var lastLeft: Int?, lastRight: Int?, y: CGFloat = 0, hunkIndex = -1
        var previousWasEqual = true
        rows = []
        for row in diffRows {
            let leftHeight = row.leftLine.flatMap { a.heights.indices.contains($0) ? a.heights[$0] : nil } ?? 0
            let rightHeight = row.rightLine.flatMap { b.heights.indices.contains($0) ? b.heights[$0] : nil } ?? 0
            let height = max(leftHeight, rightHeight, 1)
            if row.kind != .equal, previousWasEqual { hunkIndex += 1 }
            rows.append(AlignedDisplayRow(leftLine: row.leftLine, rightLine: row.rightLine, minY: y, height: height,
                                          hunkIndex: row.kind == .equal ? nil : hunkIndex))
            previousWasEqual = row.kind == .equal
            if let line = row.leftLine, a.ranges.indices.contains(line) {
                let end = NSMaxRange(a.ranges[line]); leftPadding[end, default: 0] += height - leftHeight; lastLeft = end
            } else if let lastLeft { leftPadding[lastLeft, default: 0] += height }
            else { leftLeading += height }
            if let line = row.rightLine, b.ranges.indices.contains(line) {
                let end = NSMaxRange(b.ranges[line]); rightPadding[end, default: 0] += height - rightHeight; lastRight = end
            } else if let lastRight { rightPadding[lastRight, default: 0] += height }
            else { rightLeading += height }
            y += height
        }
        let extra = max(a.extraHeight, b.extraHeight)
        apply(left, after: leftPadding, leading: leftLeading, height: y + extra)
        apply(right, after: rightPadding, leading: rightLeading, height: y + extra)
        bands = []
        for row in rows {
            guard let index = row.hunkIndex else { continue }
            if let previous = bands.last, previous.index == index {
                bands[bands.count - 1] = EditorHunkBand(index: index, minY: previous.minY, height: row.minY + row.height - previous.minY)
            } else { bands.append(EditorHunkBand(index: index, minY: row.minY, height: row.height)) }
        }
        for (state, side) in [(left, Side.left), (right, Side.right)] {
            let gaps = rows.filter { (side == .left ? $0.leftLine : $0.rightLine) == nil }.map {
                EditorDisplayGap(minY: $0.minY + state.editor.textContainerOrigin.y, height: $0.height)
            }
            state.editor.displayGaps = gaps; state.ruler.displayGaps = gaps
            let mappedBands = hunkBands(originY: state.editor.textContainerOrigin.y)
            state.editor.hunkBands = mappedBands; state.ruler.hunkBands = mappedBands
        }
        isAligned = true
    }

    func hunkBands(originY: CGFloat) -> [EditorHunkBand] {
        bands.map { EditorHunkBand(index: $0.index, minY: $0.minY + originY, height: $0.height) }
    }

    private struct Measurement {
        let ranges: [NSRange]
        let heights: [CGFloat]
        let extraHeight: CGFloat
    }

    private func measure(_ state: TextEditorState) -> Measurement {
        let editor = state.editor
        let text = editor.string
        let ranges = sourceLineRanges(text)
        guard let layout = editor.layoutManager, let container = editor.textContainer else {
            return Measurement(ranges: [], heights: [], extraHeight: 0)
        }
        // The view's typesetter has the authoritative fallback-font and screen
        // metrics. Reusing it avoids a one-line discrepancy at narrow Unicode
        // wrap boundaries. Only cached layout is reset; text and attributes stay.
        state.alignmentLayout.setPadding(after: [:], leading: 0, layout: layout)
        layout.ensureLayout(for: container)
        var heights = [CGFloat](repeating: 0, count: ranges.count), current = 0
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, glyphs, _ in
            let character = layout.characterIndexForGlyph(at: glyphs.location)
            while current + 1 < ranges.count && character >= NSMaxRange(ranges[current]) { current += 1 }
            if heights.indices.contains(current) { heights[current] += rect.height }
        }
        return Measurement(ranges: ranges, heights: heights, extraHeight: layout.extraLineFragmentRect.height)
    }

    private func apply(_ state: TextEditorState, after: [Int: CGFloat], leading: CGFloat, height: CGFloat) {
        guard let layout = state.editor.layoutManager, let container = state.editor.textContainer else { return }
        let position = state.scroll.contentView.bounds.origin
        state.alignmentLayout.setPadding(after: after, leading: leading, layout: layout)
        state.editor.alignmentMinimumHeight = height + state.editor.textContainerInset.height * 2
        layout.ensureLayout(for: container); state.editor.sizeToFit()
        state.editor.needsDisplay = true; state.ruler.needsDisplay = true
        // Installing a ruler or reflowing can establish its native horizontal
        // inset after the old origin was captured. A wrapped editor has no
        // horizontal scroll position to retain: restoring an old zero would
        // move the first columns underneath the ruler until another resize.
        let x = container.widthTracksTextView ? -state.scroll.contentView.contentInsets.left : position.x
        state.scroll.contentView.scroll(to: NSPoint(x: x, y: position.y))
        state.scroll.reflectScrolledClipView(state.scroll.contentView)
    }

    private func reset(_ state: TextEditorState) {
        apply(state, after: [:], leading: 0, height: 0)
        state.editor.displayGaps = []; state.ruler.displayGaps = []
        state.editor.hunkBands = []; state.ruler.hunkBands = []
        state.editor.alignmentMinimumHeight = 0
        state.editor.sizeToFit()
    }
}

func sourceLineRanges(_ text: String) -> [NSRange] {
    let string = text as NSString
    var ranges: [NSRange] = [], offset = 0
    while offset < string.length {
        let range = string.lineRange(for: NSRange(location: offset, length: 0))
        guard NSMaxRange(range) > offset else { break }
        ranges.append(range); offset = NSMaxRange(range)
    }
    return ranges
}
