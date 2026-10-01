import AppKit

/// A presentation-only locator in document coordinates. It follows native text
/// layout and scrolling without changing text attributes, selection, or focus.
@MainActor
final class TextNavigationIndicator {
    private weak var editor: NSTextView?
    private var timer: Timer?
    private var startedAt: TimeInterval = 0
    private var reduceMotion = false
    private var emptyAnchor: NSRect?
    private(set) var activeRanges: [NSRange] = []
    private(set) var opacity: CGFloat = 0

    init(editor: NSTextView) { self.editor = editor }
    deinit { timer?.invalidate() }

    func show(_ ranges: [NSRange], emptyAnchor: NSRect? = nil) {
        cancel()
        guard let editor else { return }
        let length = editor.string.utf16.count
        activeRanges = ranges.filter { $0.location != NSNotFound && $0.location <= length && $0.length <= length - $0.location }
        guard !activeRanges.isEmpty else { return }
        self.emptyAnchor = emptyAnchor
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        startedAt = ProcessInfo.processInfo.systemUptime
        opacity = 1
        editor.needsDisplay = true
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        activeRanges = []; emptyAnchor = nil; opacity = 0
        editor?.needsDisplay = true
    }

    private func advance() {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        if elapsed >= 1.05 { cancel(); return }
        // Reduce Motion uses a stationary locator with no opacity animation.
        opacity = reduceMotion ? 1 : CGFloat(min(1, (1.05 - elapsed) / 0.4))
        editor?.needsDisplay = true
    }

    /// These are the same document rectangles drawn on screen, also allowing
    /// native checks to verify wrapped, projected, and empty-range navigation.
    var visibleRects: [NSRect] {
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer,
              !activeRanges.isEmpty else { return [] }
        layout.ensureLayout(for: container)
        let origin = editor.textContainerOrigin
        let visible = editor.visibleRect
        let length = editor.string.utf16.count
        var rectangles: [NSRect] = []
        for range in activeRanges where range.location <= length && range.length <= length - range.location {
            if range.length == 0 {
                let rect: NSRect
                if let emptyAnchor { rect = emptyAnchor }
                else if range.location < length {
                    let glyph = layout.glyphIndexForCharacter(at: range.location)
                    let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let position = layout.location(forGlyphAt: glyph)
                    rect = NSRect(x: origin.x + fragment.minX + position.x, y: origin.y + fragment.minY,
                                  width: 6, height: max(18, fragment.height))
                } else if layout.extraLineFragmentTextContainer === container {
                    let fragment = layout.extraLineFragmentRect
                    rect = NSRect(x: origin.x + fragment.minX, y: origin.y + fragment.minY, width: 6, height: max(18, fragment.height))
                } else if layout.numberOfGlyphs > 0 {
                    let glyph = layout.numberOfGlyphs - 1
                    let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                    rect = NSRect(x: origin.x + used.maxX, y: origin.y + fragment.minY, width: 6, height: max(18, fragment.height))
                } else { rect = NSRect(x: origin.x, y: origin.y, width: 6, height: 20) }
                if rect.intersects(visible) { rectangles.append(rect) }
                continue
            }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let visibleGlyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
            let drawnGlyphs = NSIntersectionRange(glyphs, visibleGlyphs)
            guard drawnGlyphs.length > 0 else { continue }
            layout.enumerateEnclosingRects(forGlyphRange: drawnGlyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                var documentRect = rect.offsetBy(dx: origin.x, dy: origin.y)
                documentRect.size.width = max(6, documentRect.width)
                documentRect = documentRect.insetBy(dx: -2.5, dy: -1)
                if documentRect.intersects(visible) { rectangles.append(documentRect) }
            }
        }
        return rectangles
    }

    func draw(in dirtyRect: NSRect, theme: ComparisonTheme) {
        guard opacity > 0, let editor else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: dirtyRect.intersection(editor.visibleRect)).addClip()
        for rect in visibleRects where rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            theme.navigationFill.withAlphaComponent(0.045 * opacity).setFill()
            path.fill()
            theme.navigationOutline.withAlphaComponent(0.85 * opacity).setStroke()
            path.lineWidth = 1.25
            path.stroke()
        }
    }
}
