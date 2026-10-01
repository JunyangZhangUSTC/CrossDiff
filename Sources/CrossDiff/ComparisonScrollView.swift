import AppKit

/// The editor is already laid out below the toolbar. Disable inferred title-bar
/// insets while keeping the native clip view's horizontal ruler reservation.
@MainActor
final class ComparisonScrollView: NSScrollView {
    private var stabilizingGeometry = false
    private var lastViewportSize = NSSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureInsets()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInsets()
    }

    private func configureInsets() {
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        // Keep the clip view's native ruler inset: on current macOS the ruler
        // overlays the clip frame and is reserved by a negative horizontal
        // bounds origin. Disabling this would cover the first text columns.
        contentView.automaticallyAdjustsContentInsets = true
    }

    override func tile() {
        guard !stabilizingGeometry else { super.tile(); return }
        stabilizingGeometry = true
        let position = contentView.bounds.origin
        super.tile()
        stabilizeTextGeometry(preserving: position)
        stabilizingGeometry = false
    }

    override func layout() {
        guard !stabilizingGeometry else { super.layout(); return }
        stabilizingGeometry = true
        let position = contentView.bounds.origin
        super.layout()
        stabilizeTextGeometry(preserving: position)
        stabilizingGeometry = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    private func stabilizeTextGeometry(preserving position: NSPoint) {
        guard let editor = documentView as? NSTextView else { return }
        let insets = contentView.contentInsets
        let viewport = NSSize(width: contentView.bounds.width - insets.left - insets.right,
                              height: contentView.bounds.height - insets.top - insets.bottom)
        guard viewport.width > 0, viewport.height > 0 else { return }

        // A zero minimum allows NSTextView's initial 400-point frame to be
        // shifted above the viewport during ruler installation and resizing.
        let minimum = NSSize(width: viewport.width, height: viewport.height)
        if editor.minSize != minimum { editor.minSize = minimum }
        let wrapped = editor.textContainer?.widthTracksTextView == true
        if wrapped, abs(editor.frame.width - viewport.width) > 0.5 {
            editor.setFrameSize(NSSize(width: viewport.width, height: editor.frame.height))
        }
        if viewport != lastViewportSize {
            lastViewportSize = viewport
            editor.sizeToFit()
        }
        let size = NSSize(width: wrapped ? viewport.width : max(viewport.width, editor.frame.width),
                          height: max(viewport.height, editor.frame.height))
        if editor.frame.size != size { editor.setFrameSize(size) }
        if editor.frame.origin != .zero { editor.setFrameOrigin(.zero) }

        // Keep the user's existing scroll position. Only clamp when the new
        // viewport/document dimensions make that position impossible.
        let origin = NSPoint(x: min(max(-insets.left, position.x), max(-insets.left, size.width - viewport.width - insets.left)),
                             y: min(max(-insets.top, position.y), max(-insets.top, size.height - viewport.height - insets.top)))
        if contentView.bounds.origin != origin {
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        }
    }
}
