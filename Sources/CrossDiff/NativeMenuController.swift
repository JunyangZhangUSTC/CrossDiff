import AppKit
import SwiftUI
import CrossDiffCore

/// One native menu owns both the visible commands and their keyboard equivalents.
/// Validation follows the key window/responder, so Settings and search fields get
/// their own undo and clipboard actions instead of editing a hidden comparison.
@MainActor
final class NativeMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    static let shared = NativeMenuController()
    private var mainMenu: NSMenu?
    private var languageObserver: NSObjectProtocol?
    private var menuItemObserver: NSObjectProtocol?
    private var settingsController: NSWindowController?
    private(set) weak var comparisonWindow: NSWindow?
    private struct ManagedMenu {
        let menu: NSMenu
        let items: Set<ObjectIdentifier>
    }
    private var managedMenus: [ObjectIdentifier: ManagedMenu] = [:]
    private var menuCleanupScheduled = false
    private var cleaningMenus = false

    private override init() {
        super.init()
        languageObserver = NotificationCenter.default.addObserver(forName: .crossDiffLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        menuItemObserver = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let menu = notification.object as? NSMenu,
                      self.managedMenus[ObjectIdentifier(menu)] != nil else { return }
                self.scheduleMenuCleanup()
            }
        }
    }

    func registerComparisonWindow(_ window: NSWindow) { comparisonWindow = window }

    func install() {
        _ = AppSettings.shared
        if comparisonWindow == nil {
            comparisonWindow = NSApp.windows.first { $0.title == "CrossDiff" && !($0 is NSPanel) }
        }
        if let mainMenu, NSApp.mainMenu === mainMenu { return }
        rebuild()
    }

    private var session: ComparisonSession? { WorkspaceStore.shared.selected }
    private var comparisonActive: Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        return window === comparisonWindow && window.attachedSheet == nil
    }
    private var canEditComparison: Bool { comparisonActive && session?.kind == .text }
    private var activeUndoManager: UndoManager? { NSApp.keyWindow?.firstResponder?.undoManager }

    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], native: Bool = false) -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action,
                                keyEquivalent: modifiers.contains(.shift) ? key.uppercased() : key)
        result.keyEquivalentModifierMask = modifiers
        result.target = native ? nil : self
        return result
    }
    private func addMenu(_ title: String, to root: NSMenu) -> NSMenu {
        let submenu = NSMenu(title: title)
        submenu.delegate = self
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = submenu; root.addItem(entry)
        return submenu
    }

    private func rebuild() {
        managedMenus.removeAll()
        let root = NSMenu(title: "CrossDiff")
        let app = addMenu("CrossDiff", to: root)
        app.addItem(item(L("关于 CrossDiff", "About CrossDiff"), #selector(about(_:))))
        app.addItem(.separator())
        app.addItem(item(L("设置/Setting…", "设置/Setting…"), #selector(showSettings(_:)), key: ","))
        app.addItem(.separator())
        let services = addMenu(L("服务", "Services"), to: app)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(item(L("隐藏 CrossDiff", "Hide CrossDiff"), #selector(NSApplication.hide(_:)), key: "h", native: true))
        app.addItem(item(L("隐藏其他", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], native: true))
        app.addItem(item(L("显示全部", "Show All"), #selector(NSApplication.unhideAllApplications(_:)), native: true))
        app.addItem(.separator())
        app.addItem(item(L("退出 CrossDiff", "Quit CrossDiff"), #selector(NSApplication.terminate(_:)), key: "q", native: true))

        let file = addMenu(L("文件", "File"), to: root)
        file.addItem(item(L("新建文本比较", "New Text Comparison"), #selector(newComparison(_:)), key: "n"))
        file.addItem(item(L("打开…", "Open…"), #selector(open(_:)), key: "o"))
        file.addItem(.separator())
        file.addItem(item(L("关闭", "Close"), #selector(close(_:)), key: "w"))
        file.addItem(item(L("保存当前侧", "Save Current Side"), #selector(save(_:)), key: "s"))
        file.addItem(item(L("当前侧另存为…", "Save Current Side As…"), #selector(saveAs(_:)), key: "s", modifiers: [.command, .shift]))

        let edit = addMenu(L("编辑", "Edit"), to: root)
        edit.addItem(item(L("撤销", "Undo"), #selector(undo(_:)), key: "z"))
        edit.addItem(item(L("重做", "Redo"), #selector(redo(_:)), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(L("剪切", "Cut"), #selector(NSText.cut(_:)), key: "x", native: true))
        edit.addItem(item(L("复制", "Copy"), #selector(NSText.copy(_:)), key: "c", native: true))
        edit.addItem(item(L("粘贴", "Paste"), #selector(NSText.paste(_:)), key: "v", native: true))
        edit.addItem(item(L("删除", "Delete"), #selector(NSText.delete(_:)), native: true))
        edit.addItem(item(L("全选", "Select All"), #selector(NSText.selectAll(_:)), key: "a", native: true))
        edit.addItem(.separator())
        let findMenu = addMenu(L("查找", "Find"), to: edit)
        findMenu.addItem(item(L("查找…", "Find…"), #selector(find(_:)), key: "f"))
        findMenu.addItem(item(L("查找并替换…", "Find and Replace…"), #selector(findAndReplace(_:)), key: "f", modifiers: [.command, .option]))
        findMenu.addItem(item(L("下一个匹配", "Find Next"), #selector(findNext(_:)), key: "g"))
        findMenu.addItem(item(L("上一个匹配", "Find Previous"), #selector(findPrevious(_:)), key: "g", modifiers: [.command, .shift]))
        findMenu.addItem(.separator())
        findMenu.addItem(item(L("使用所选内容查找", "Use Selection for Find"), #selector(findSelection(_:)), key: "e"))
        edit.addItem(.separator())
        edit.addItem(item(L("表情与符号", "Emoji & Symbols"), #selector(NSApplication.orderFrontCharacterPalette(_:)), key: " ", modifiers: [.command, .control], native: true))

        let view = addMenu(L("显示", "View"), to: root)
        view.addItem(item(L("显示删除内容", "Show Deletions"), #selector(toggleDeletions(_:))))
        view.addItem(item(L("对齐差异行", "Align Changed Lines"), #selector(toggleAlignment(_:))))
        view.addItem(item(L("同步滚动", "Sync Scrolling"), #selector(toggleScrolling(_:))))
        view.addItem(.separator())
        view.addItem(item(L("进入全屏幕", "Enter Full Screen"), #selector(toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]))

        let compare = addMenu(L("比较", "Compare"), to: root)
        compare.addItem(item(L("文本比较", "Text Comparison"), #selector(newComparison(_:))))
        compare.addItem(item(L("文件夹比较…", "Folder Comparison…"), #selector(openFolders(_:))))
        compare.addItem(item(L("图片比较…", "Image Comparison…"), #selector(openImages(_:))))
        compare.addItem(.separator())
        compare.addItem(item(L("下一处差异", "Next Difference"), #selector(nextDifference(_:)), key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.command, .option]))
        compare.addItem(item(L("上一处差异", "Previous Difference"), #selector(previousDifference(_:)), key: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command, .option]))
        compare.addItem(.separator())
        compare.addItem(item(L("清空两侧", "Clear Both"), #selector(clearBoth(_:))))
        let sessions = addMenu(L("会话", "Session"), to: root)
        sessions.addItem(item(L("清除本机会话记录…", "Clear Local Session History…"), #selector(clearHistory(_:))))

        let windows = addMenu(L("窗口", "Window"), to: root)
        windows.addItem(item(L("最小化", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m", native: true))
        windows.addItem(item(L("缩放", "Zoom"), #selector(NSWindow.performZoom(_:)), native: true))
        windows.addItem(.separator())
        windows.addItem(item(L("全部置于顶层", "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)), native: true))
        NSApp.windowsMenu = windows
        let help = addMenu(L("帮助", "Help"), to: root)
        help.addItem(item(L("CrossDiff 帮助", "CrossDiff Help"), #selector(showHelp(_:))))
        NSApp.helpMenu = help
        for menu in [edit, findMenu, view] {
            managedMenus[ObjectIdentifier(menu)] = ManagedMenu(menu: menu, items: Set(menu.items.map(ObjectIdentifier.init)))
        }
        mainMenu = root; NSApp.mainMenu = root
        scheduleMenuCleanup()
        settingsController?.window?.title = L("设置", "Settings")
    }

    // AppKit can append default editing/full-screen items again when the main
    // menu is replaced for a language change. Keep our explicitly defined items
    // (including native responder actions), using only public NSMenu APIs.
    // Services, the Window list, and Help search remain entirely system-managed.
    private func scheduleMenuCleanup() {
        guard !menuCleanupScheduled, !cleaningMenus else { return }
        menuCleanupScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuCleanupScheduled = false
            for managed in self.managedMenus.values { self.removeInjectedItems(from: managed.menu) }
        }
    }

    private func removeInjectedItems(from menu: NSMenu) {
        guard !cleaningMenus, let managed = managedMenus[ObjectIdentifier(menu)] else { return }
        cleaningMenus = true
        defer { cleaningMenus = false }
        for entry in menu.items where !managed.items.contains(ObjectIdentifier(entry)) {
            menu.removeItem(entry)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeInjectedItems(from: menu)
        for entry in menu.items where entry.target === self { entry.isEnabled = validateMenuItem(entry) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)), #selector(redo(_:)):
            let isUndo = menuItem.action == #selector(undo(_:))
            let manager = activeUndoManager
            let name = localizedActionName(isUndo ? manager?.undoActionName ?? "" : manager?.redoActionName ?? "")
            let verb = isUndo ? L("撤销", "Undo") : L("重做", "Redo")
            menuItem.title = name.isEmpty ? verb : verb + " " + name
            return isUndo ? manager?.canUndo == true : manager?.canRedo == true
        case #selector(save(_:)), #selector(saveAs(_:)), #selector(find(_:)), #selector(findAndReplace(_:)):
            return canEditComparison
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return canEditComparison && session?.searching == false && session?.searchMatches.isEmpty == false
        case #selector(findSelection(_:)):
            return canEditComparison && selectedSourceText()?.isEmpty == false
        case #selector(nextDifference(_:)), #selector(previousDifference(_:)):
            return canEditComparison && session?.calculating == false && session?.result?.hunks.isEmpty == false
        case #selector(toggleDeletions(_:)):
            menuItem.state = session?.showDeletions == true ? .on : .off; return canEditComparison
        case #selector(toggleAlignment(_:)):
            menuItem.state = session?.alignDifferences == true ? .on : .off; return canEditComparison
        case #selector(toggleScrolling(_:)):
            menuItem.state = session?.synchronizedScrolling == true ? .on : .off; return canEditComparison
        case #selector(clearBoth(_:)): return canEditComparison && session?.canClearText == true
        case #selector(toggleFullScreen(_:)):
            let full = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true
            menuItem.title = full ? L("退出全屏幕", "Exit Full Screen") : L("进入全屏幕", "Enter Full Screen")
            return comparisonActive
        case #selector(newComparison(_:)), #selector(open(_:)), #selector(openFolders(_:)), #selector(openImages(_:)):
            return comparisonWindow?.attachedSheet == nil && NSApp.modalWindow == nil
        case #selector(close(_:)): return NSApp.keyWindow != nil
        case #selector(clearHistory(_:)): return comparisonActive
        default: return true
        }
    }

    private func localizedActionName(_ name: String) -> String {
        let names = [("合并差异", "Merge Difference"), ("清空文本", "Clear Text"), ("恢复清空", "Restore Cleared Text"),
                     ("替换", "Replace"), ("全部替换", "Replace All"), ("输入", "Typing"), ("粘贴", "Paste"), ("剪切", "Cut"), ("删除", "Delete")]
        for (zh, en) in names where name == zh || name == en { return L(zh, en) }
        return name
    }
    private func selectedSourceText() -> String? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        if let preview = editor as? PreviewTextView, let projection = preview.projection {
            return PreviewCopy.sourceText(from: projection, selection: editor.selectedRange())
        }
        guard editor is ComparisonTextView, editor.selectedRange().length > 0 else { return nil }
        return (editor.string as NSString).substring(with: editor.selectedRange())
    }
    private func focusComparison() { comparisonWindow?.makeKeyAndOrderFront(nil) }
    @objc func newComparison(_ sender: Any?) { focusComparison(); WorkspaceStore.shared.newText() }
    @objc func open(_ sender: Any?) { focusComparison(); WorkspaceStore.shared.openPanel() }
    @objc func openFolders(_ sender: Any?) { focusComparison(); WorkspaceStore.shared.openPanel(kind: .folder) }
    @objc func openImages(_ sender: Any?) { focusComparison(); WorkspaceStore.shared.openPanel(kind: .image) }
    @objc func close(_ sender: Any?) {
        if comparisonActive, let session { WorkspaceStore.shared.close(session) }
        else { NSApp.keyWindow?.performClose(sender) }
    }
    @objc func save(_ sender: Any?) { if canEditComparison, let session { WorkspaceStore.shared.save(session, side: session.focusSide) } }
    @objc func saveAs(_ sender: Any?) { if canEditComparison, let session { WorkspaceStore.shared.save(session, side: session.focusSide, saveAs: true) } }
    @objc func undo(_ sender: Any?) { if activeUndoManager?.canUndo == true { activeUndoManager?.undo() } }
    @objc func redo(_ sender: Any?) { if activeUndoManager?.canRedo == true { activeUndoManager?.redo() } }
    @objc func find(_ sender: Any?) { beginFind(replacing: false) }
    @objc func findAndReplace(_ sender: Any?) { beginFind(replacing: true) }
    private func beginFind(replacing: Bool) {
        guard canEditComparison, let session else { return }
        session.showSearch(replacing: replacing)
        NotificationCenter.default.post(name: .crossDiffFocusSearch, object: session.id)
    }
    @objc func findNext(_ sender: Any?) { if canEditComparison { session?.navigateSearch(1) } }
    @objc func findPrevious(_ sender: Any?) { if canEditComparison { session?.navigateSearch(-1) } }
    @objc func findSelection(_ sender: Any?) {
        guard canEditComparison, let text = selectedSourceText(), !text.isEmpty else { return }
        session?.searchQuery = text; beginFind(replacing: false)
    }
    @objc func nextDifference(_ sender: Any?) { if canEditComparison { session?.navigate(1) } }
    @objc func previousDifference(_ sender: Any?) { if canEditComparison { session?.navigate(-1) } }
    @objc func toggleDeletions(_ sender: Any?) { if canEditComparison { session?.showDeletions.toggle() } }
    @objc func toggleAlignment(_ sender: Any?) { if canEditComparison { session?.alignDifferences.toggle() } }
    @objc func toggleScrolling(_ sender: Any?) { if canEditComparison { session?.synchronizedScrolling.toggle() } }
    @objc func clearBoth(_ sender: Any?) { if canEditComparison { session?.clearText() } }
    @objc func clearHistory(_ sender: Any?) { if comparisonActive { WorkspaceStore.shared.clearHistory() } }
    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil {
            let host = NSHostingView(rootView: SettingsView())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("crossdiff-settings")
            window.title = L("设置", "Settings"); window.isReleasedWhenClosed = false
            window.contentView = host
            #if CROSSDIFF_UI_CHECKS
            window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            #else
            window.center()
            #endif
            settingsController = NSWindowController(window: window)
        }
        settingsController?.showWindow(sender)
        settingsController?.window?.makeKeyAndOrderFront(sender)
    }
    @objc func toggleFullScreen(_ sender: Any?) { if comparisonActive { comparisonWindow?.toggleFullScreen(sender) } }
    @objc func about(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "CrossDiff"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("开发版", "Development")
        alert.informativeText = L("版本 \(version)\n本地文本、文件夹和图片比较。\n\n免费开源 · GNU AGPL v3\n© 2026 Junyang Zhang", "Version \(version)\nLocal text, folder, and image comparison.\n\nFree & open source · GNU AGPL v3\n© 2026 Junyang Zhang")
        alert.addButton(withTitle: L("好", "OK")); alert.runModal()
    }
    @objc func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = L("CrossDiff 帮助", "CrossDiff Help")
        alert.informativeText = L("粘贴两段文本或打开两个文件开始比较。\n\n⌘Z 撤销 · ⇧⌘Z 重做\n⌘F 查找 · ⌥⌘F 查找并替换\n⌘G 下一个匹配 · ⇧⌘G 上一个匹配\n⌘S 保存当前侧 · ⌘, 设置\n\n比较与替换不会自动修改原文件，保存时才会写入。", "Paste two texts or open two files to compare.\n\n⌘Z Undo · ⇧⌘Z Redo\n⌘F Find · ⌥⌘F Find and Replace\n⌘G Find Next · ⇧⌘G Find Previous\n⌘S Save Current Side · ⌘, Settings\n\nComparing and replacing do not write to files until you save.")
        alert.addButton(withTitle: L("好", "OK")); alert.runModal()
    }
}
