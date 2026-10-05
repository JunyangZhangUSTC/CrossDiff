import AppKit
import SwiftUI
import Combine
import CrossDiffCore

/// Keeps the existing SwiftUI cards, with native scrolling independent of macOS's
/// transient overlay-scroller policy. A stable bottom lane never shifts the tabs.
struct SessionTabStrip: NSViewRepresentable {
    @ObservedObject var store: WorkspaceStore
    let theme: ComparisonTheme
    let locale: Locale

    func makeNSView(context: Context) -> SessionTabBarView { SessionTabBarView() }
    func updateNSView(_ view: SessionTabBarView, context: Context) {
        view.update(store: store, theme: theme, locale: locale)
    }
}

@MainActor
final class SessionTabBarView: NSView {
    private let scroll = SessionTabScrollView()
    private let document = FlippedTabDocument()
    private let scroller = SessionTabScroller(frame: NSRect(x: 0, y: 0, width: 400, height: 12))
    private var cards: [UUID: NSHostingView<AnyView>] = [:]
    private var observations: [UUID: AnyCancellable] = [:]
    private var order: [UUID] = []
    private var selectedID: UUID?
    private var revealSelection = true
    private var previousViewportWidth: CGFloat = 0
    private var isLayingOut = false
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var layoutQueued = false
    private var theme = ComparisonTheme.light
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        scroll.documentView = document
        scroll.setAccessibilityIdentifier("session-tabs.scroll")
        addSubview(scroll)
        scroller.scrollerStyle = .overlay
        scroller.controlSize = .mini
        scroller.target = self
        scroller.action = #selector(scrollerChanged(_:))
        scroller.isHidden = true
        scroller.setAccessibilityIdentifier("session-tabs.scroller")
        scroller.trackingChanged = { [weak self] in self?.updateScroller() }
        scroller.onWheel = { [weak self] event in self?.scroll.scrollWheel(with: event) }
        addSubview(scroller)
        scroll.onScroll = { [weak self] in self?.updateScroller() }
        NotificationCenter.default.addObserver(self, selector: #selector(clipMoved), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
    }
    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update(store: WorkspaceStore, theme: ComparisonTheme, locale: Locale) {
        let ids = store.sessions.map(\.id)
        if ids != order || selectedID != store.selectedID { revealSelection = true }
        order = ids; selectedID = store.selectedID
        self.theme = theme
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        scroll.backgroundColor = theme.chrome
        scroller.knobStyle = theme.isDark ? .light : .dark
        scroller.setAccessibilityLabel(L("比较标签滚动条", "Comparison Tabs Scroll Bar"))
        let removed = cards.keys.filter { !ids.contains($0) }
        for id in removed { cards.removeValue(forKey: id)?.removeFromSuperview(); observations.removeValue(forKey: id) }
        for session in store.sessions {
            let content = AnyView(SessionTab(session: session, selected: session.id == selectedID,
                select: { store.selectedID = session.id }, close: { store.close(session) })
                .foregroundStyle(Color(nsColor: theme.text))
                .tint(Color(nsColor: theme.accent))
                .environment(\.locale, locale)
                .preferredColorScheme(theme.isDark ? .dark : .light)
                .fixedSize())
            if let card = cards[session.id] { card.rootView = content }
            else {
                let card = NSHostingView(rootView: content)
                card.sizingOptions = [.intrinsicContentSize]
                cards[session.id] = card; document.addSubview(card)
                observations[session.id] = session.objectWillChange.sink { [weak self] _ in self?.queueLayout() }
            }
        }
        needsLayout = true
        queueLayout()
    }

    /// Session notifications precede property changes. Wait for SwiftUI's updated
    /// title/dirty marker before measuring; unrelated editor updates keep the offset.
    private func queueLayout() {
        guard !layoutQueued else { return }
        layoutQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutQueued = false; self.needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        guard !isLayingOut, bounds.width > 0, bounds.height > 0 else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        if scroll.frame != bounds { scroll.frame = bounds }
        scroll.layoutSubtreeIfNeeded()
        let viewport = scroll.contentView.bounds.width
        guard viewport > 0 else { return }
        if abs(viewport - previousViewportWidth) > 0.5 { revealSelection = true; previousViewportWidth = viewport }
        let selectedWasVisible = selectedID.flatMap { cards[$0] }.map {
            scroll.contentView.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.frame)
        } ?? false
        var x: CGFloat = 12
        var changedGeometry = false
        for id in order {
            guard let card = cards[id] else { continue }
            let fitting = card.fittingSize
            let frame = NSRect(x: x, y: 7, width: min(320, max(60, ceil(fitting.width))), height: 29)
            if card.frame != frame { changedGeometry = true; card.frame = frame }
            x = frame.maxX + 4
        }
        let size = NSSize(width: max(viewport, x + 8), height: bounds.height)
        if document.frame.size != size { document.setFrameSize(size) }
        scroller.frame = NSRect(x: 12, y: bounds.height - 12, width: max(0, bounds.width - 24), height: 12)
        // Keep a visible active card visible during reflow, but do not undo a
        // deliberate scroll away from it merely because its dirty dot changed.
        if revealSelection || (changedGeometry && selectedWasVisible) { showSelectedIfNeeded() }
        else { scroll.move(to: scroll.contentView.bounds.minX) }
        revealSelection = false
        updateScroller()
    }

    private func showSelectedIfNeeded() {
        guard let selectedID, let card = cards[selectedID] else { return }
        let visible = scroll.contentView.bounds
        var x = visible.minX
        if card.frame.minX < visible.minX + 8 { x = card.frame.minX - 8 }
        else if card.frame.maxX > visible.maxX - 8 { x = card.frame.maxX + 8 - visible.width }
        scroll.move(to: x)
    }

    @objc private func clipMoved() { updateScroller() }
    private func updateScroller() {
        let width = scroll.contentView.bounds.width, total = document.bounds.width
        let overflow = total > width + 0.5 && width > 0
        scroller.knobProportion = total > 0 ? min(1, width / total) : 1
        scroller.doubleValue = overflow ? Double(scroll.contentView.bounds.minX / (total - width)) : 0
        scroller.isEnabled = overflow
        scroller.isHidden = !overflow || (!hovering && !scroller.isTracking)
    }
    @objc private func scrollerChanged(_ sender: NSScroller) {
        let visible = scroll.contentView.bounds
        let maximum = max(0, document.bounds.width - visible.width)
        switch sender.hitPart {
        case .decrementLine: scroll.move(to: visible.minX - 40)
        case .incrementLine: scroll.move(to: visible.minX + 40)
        case .decrementPage: scroll.move(to: visible.minX - visible.width * 0.85)
        case .incrementPage: scroll.move(to: visible.minX + visible.width * 0.85)
        default: scroll.move(to: CGFloat(sender.doubleValue) * maximum)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func scrollWheel(with event: NSEvent) { scroll.scrollWheel(with: event) }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateScroller() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateScroller() }
}

@MainActor
private final class FlippedTabDocument: NSView { override var isFlipped: Bool { true } }

@MainActor
final class SessionTabScrollView: NSScrollView {
    var onScroll: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder; drawsBackground = true
        hasHorizontalScroller = false; hasVerticalScroller = false
        automaticallyAdjustsContentInsets = false; contentInsets = .init()
        contentView.automaticallyAdjustsContentInsets = false
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
    }
    required init?(coder: NSCoder) { nil }
    func move(to x: CGFloat) {
        let maximum = max(0, (documentView?.bounds.width ?? 0) - contentView.bounds.width)
        let origin = NSPoint(x: min(maximum, max(0, x)), y: 0)
        if contentView.bounds.origin != origin {
            contentView.scroll(to: origin); reflectScrolledClipView(contentView)
        }
        onScroll?()
    }
    override func scrollWheel(with event: NSEvent) {
        // Horizontal trackpad motion and an ordinary mouse wheel both browse tabs.
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        move(to: contentView.bounds.minX - delta * (event.hasPreciseScrollingDeltas ? 1 : 20))
    }
}

@MainActor
final class SessionTabScroller: NSScroller {
    private(set) var isTracking = false
    var trackingChanged: (() -> Void)?
    var onWheel: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) { onWheel?(event) }
    override func mouseDown(with event: NSEvent) {
        isTracking = true; trackingChanged?()
        super.mouseDown(with: event)
        isTracking = false; trackingChanged?()
    }
}
