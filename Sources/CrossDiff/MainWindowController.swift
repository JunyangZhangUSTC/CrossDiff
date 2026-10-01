import AppKit
import SwiftUI
import Combine
import CrossDiffCore

/// AppKit owns windows and menus; the comparison content remains SwiftUI.
/// This keeps native responder routing stable when Settings becomes the key window.
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private static let newID = NSToolbarItem.Identifier("crossdiff.new")
    private static let appearanceID = NSToolbarItem.Identifier("crossdiff.appearance")
    private static let activityID = NSToolbarItem.Identifier("crossdiff.activity")
    private static let undoID = NSToolbarItem.Identifier("crossdiff.undo")
    private static let redoID = NSToolbarItem.Identifier("crossdiff.redo")
    private var languageObserver: NSObjectProtocol?
    private var appearanceObservation: AnyCancellable?
    private var activityObservation: AnyCancellable?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 746),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CrossDiff"
        window.identifier = NSUserInterfaceItemIdentifier("crossdiff-main")
        window.minSize = NSSize(width: 860, height: 580)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WorkspaceView(store: WorkspaceStore.shared))
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "crossdiff.main-toolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar; window.toolbarStyle = .unifiedCompact
        #if CROSSDIFF_UI_CHECKS
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        #else
        window.center()
        #endif
        languageObserver = NotificationCenter.default.addObserver(forName: .crossDiffLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshToolbar() }
        }
        appearanceObservation = AppAppearance.shared.$isDark.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshToolbar() }
        }
        activityObservation = WorkspaceStore.shared.$opening.sink { [weak self] opening in
            guard let indicator = self?.window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.activityID })?.view as? NSProgressIndicator else { return }
            indicator.isHidden = !opening
            if opening { indicator.startAnimation(nil) } else { indicator.stopAnimation(nil) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.newID, Self.activityID, .flexibleSpace, Self.undoID, Self.redoID, .space, Self.appearanceID]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = ValidatedToolbarItem(itemIdentifier: identifier)
        item.isNavigational = identifier == Self.newID
        if identifier == Self.activityID {
            let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
            progress.style = .spinning; progress.controlSize = .small
            progress.isIndeterminate = true; progress.isHidden = true; item.view = progress
        } else {
            let action: Selector
            switch identifier {
            case Self.newID: action = #selector(NativeMenuController.newComparison(_:))
            case Self.undoID: action = #selector(NativeMenuController.undo(_:))
            case Self.redoID: action = #selector(NativeMenuController.redo(_:))
            default: action = #selector(toggleAppearance(_:))
            }
            let button = ChromeToolbarButton(title: "", target: identifier == Self.appearanceID ? self : NativeMenuController.shared, action: action)
            button.outlined = identifier == Self.newID
            button.bezelStyle = .texturedRounded; button.isBordered = false
            // A toolbar click must act on the current editor or search field,
            // rather than move first responder to the button itself.
            button.refusesFirstResponder = true
            // Center the icon and title together so the extra width becomes
            // balanced outer padding instead of a gap after a leading icon.
            button.imagePosition = identifier == Self.newID ? .imageLeading : .imageOnly
            button.imageHugsTitle = identifier == Self.newID
            item.view = button
            if identifier != Self.appearanceID {
                let command = NSMenuItem(title: "", action: action, keyEquivalent: "")
                item.validation = { NativeMenuController.shared.validateMenuItem(command) }
            }
            configure(item)
        }
        if #available(macOS 26.0, *) { item.isBordered = false }
        return item
    }
    private func configure(_ item: NSToolbarItem) {
        guard let button = item.view as? ChromeToolbarButton else { return }
        let opening = item.itemIdentifier == Self.newID
        let dark = AppAppearance.shared.isDark
        let label: String, symbol: String, help: String
        switch item.itemIdentifier {
        case Self.newID:
            label = L("新建…", "New…"); symbol = "plus"
            help = L("新建比较（⌘N）", "New comparison (⌘N)")
        case Self.undoID:
            label = L("撤销", "Undo"); symbol = "arrow.uturn.backward"
            help = L("撤销（⌘Z）", "Undo (⌘Z)")
        case Self.redoID:
            label = L("重做", "Redo"); symbol = "arrow.uturn.forward"
            help = L("重做（⇧⌘Z）", "Redo (⇧⌘Z)")
        default:
            label = dark ? L("切换到浅色外观", "Switch to Light Appearance") : L("切换到深色外观", "Switch to Dark Appearance")
            symbol = dark ? "sun.max" : "moon"; help = label
        }
        button.title = opening ? label : ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = help
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(item.itemIdentifier.rawValue)
        button.theme = AppAppearance.shared.colors
        button.contentTintColor = button.theme.text
        button.invalidateIntrinsicContentSize()
        button.setFrameSize(button.intrinsicContentSize)
        item.label = label; item.paletteLabel = label; item.toolTip = button.toolTip
        item.validate()
    }
    private func refreshToolbar() { window?.toolbar?.items.forEach(configure) }
    @objc private func toggleAppearance(_ sender: Any?) { AppAppearance.shared.isDark.toggle() }
}

/// Custom-view toolbar items require explicit validation; AppKit invokes this
/// during its normal event cycle, including focus and undo-stack changes.
@MainActor
private final class ValidatedToolbarItem: NSToolbarItem {
    var validation: (() -> Bool)?
    override func validate() {
        isEnabled = validation?() ?? true
        (view as? NSControl)?.isEnabled = isEnabled
    }
}

@MainActor
final class ChromeToolbarButton: NSButton {
    var outlined = false
    var theme: ComparisonTheme = .light { didSet { needsDisplay = true } }
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        let content = super.intrinsicContentSize
        return NSSize(width: title.isEmpty ? 30 : content.width + 18, height: max(28, content.height))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if outlined || hovered || isHighlighted {
            let opacity: CGFloat = isHighlighted ? 0.14 : (hovered ? 0.08 : 0.035)
            theme.text.withAlphaComponent(opacity).setFill(); path.fill()
        }
        if outlined {
            theme.separator.setStroke(); path.lineWidth = 0.75; path.stroke()
        }
        super.draw(dirtyRect)
    }
}
