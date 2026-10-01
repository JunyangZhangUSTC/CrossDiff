import AppKit
import SwiftUI
import CrossDiffCore

@MainActor
extension WorkflowChecks {
    static func checkMenusAndSettings() async throws {
        D.log("Checking native menu shortcuts, replacement, and live language settings")
        AppSettings.shared.language = .simplifiedChinese
        let a = "foo 中文 👩🏽‍💻\r\nfoo e\u{301}\r\n"
        let b = "foo 保留\r\nfoo\r\n"
        let session = try await D.mount(left: a, right: b)
        let left = session.leftEditorState!, right = session.rightEditorState!
        NativeMenuController.shared.install()
        try await activateTestWindow(D.window)
        D.window.makeFirstResponder(left.editor)
        try await D.pause()
        D.log("Installed native menus: \(NSApp.mainMenu?.items.map(\.title) ?? [])")
        D.check(NSApp.mainMenu?.items.map(\.title) == ["CrossDiff", "文件", "编辑", "显示", "比较", "会话", "窗口", "帮助"], "all top-level menu names use Simplified Chinese")
        for (key, mods) in [("z", NSEvent.ModifierFlags.command), ("z", [.command, .shift]), ("f", .command), ("f", [.command, .option]), ("g", .command), ("g", [.command, .shift]), (",", .command)] {
            D.check(menuCommand(key, modifiers: mods) != nil, "native menu exposes \(mods.rawValue)+\(key)")
        }
        for state in [left, right] { state.undoManager.groupsByEvent = false; state.undoManager.removeAllActions() }
        left.undoManager.beginUndoGrouping()
        left.editor.insertText("X", replacementRange: NSRange(location: left.editor.string.utf16.count, length: 0))
        left.editor.breakUndoCoalescing(); left.undoManager.endUndoGrouping()
        try await D.wait("typing before command undo") { !session.calculating }
        try await pressMenu("z")
        try await D.wait("command Z undo") { !session.calculating && session.left.text == a }
        D.check(session.right.text == b, "menu undo targets focused side only")
        try await pressMenu("z", modifiers: [.command, .shift])
        try await D.wait("command shift Z redo") { !session.calculating && session.left.text == a + "X" }
        try await pressMenu("z")
        try await D.wait("reset native edit") { !session.calculating && session.left.text == a }

        try await pressMenu("f")
        try await D.wait("command F opens find") { session.isSearchVisible }
        try await D.wait("command F focuses the native search field") {
            (D.window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        let searchEditor = D.window.firstResponder as! NSTextView
        guard let fieldUndo = searchEditor.undoManager else {
            throw NSError(domain: "CrossDiff.MenuChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Search field has no native undo manager"])
        }
        D.check(fieldUndo !== left.undoManager && fieldUndo !== right.undoManager, "search field owns a separate undo stack")
        let sourceUndoState = [left.undoManager.canUndo, left.undoManager.canRedo, right.undoManager.canUndo, right.undoManager.canRedo]
        let fieldGroupsByEvent = fieldUndo.groupsByEvent
        fieldUndo.groupsByEvent = false
        fieldUndo.beginUndoGrouping()
        searchEditor.insertText("foo", replacementRange: NSRange(location: 0, length: searchEditor.string.utf16.count))
        searchEditor.breakUndoCoalescing(); fieldUndo.endUndoGrouping()
        try await D.wait("search has four matches") { !session.searching && session.searchMatches.count == 4 }
        try await pressMenu("z")
        try await D.wait("command Z undoes the query in the focused search field") { session.searchQuery.isEmpty && !session.searching }
        D.check(session.left.text == a && session.right.text == b && sourceUndoState == [left.undoManager.canUndo, left.undoManager.canRedo, right.undoManager.canUndo, right.undoManager.canRedo],
                "query undo leaves both sources and their undo stacks unchanged")
        try await pressMenu("z", modifiers: [.command, .shift])
        try await D.wait("command shift Z redoes the focused search query") { session.searchQuery == "foo" && !session.searching && session.searchMatches.count == 4 }
        fieldUndo.groupsByEvent = fieldGroupsByEvent
        // The binding can publish before AppKit finishes its field-editor undo
        // cycle. Let the native control and SwiftUI settle before another key.
        try await D.pause()
        try await D.wait("native search field redo has settled") {
            searchEditor.string == "foo" && session.searchQuery == "foo" && !session.searching && session.currentMatch == 0
                && D.window.firstResponder === searchEditor
        }
        try await pressMenu("g")
        D.check(session.currentMatch == 1, "command G advances match")
        try await pressMenu("g", modifiers: [.command, .shift])
        D.check(session.currentMatch == 0, "command shift G returns to previous match")

        session.closeSearch()
        // The closed SwiftUI field must detach before a subsequent body click
        // can establish the comparison editor as the native first responder.
        try await D.pause()
        try await D.wait("closed search field is detached from the window") { searchEditor.window == nil }
        D.window.makeFirstResponder(left.editor)
        try await D.wait("body editor is focused after Find closes") { D.window.firstResponder === left.editor }
        try await pressMenu("g")
        try await D.pause()
        D.check(!session.isSearchVisible && session.currentMatch == 1 && left.editor.selectedRange() == session.currentSearchMatch?.range,
                "command G continues the last query after Find is closed")
        try await pressMenu("g", modifiers: [.command, .shift])
        try await D.pause()
        D.check(!session.isSearchVisible && session.currentMatch == 0 && D.window.firstResponder === left.editor,
                "command shift G continues backwards without reopening Find or stealing focus")
        left.undoManager.beginUndoGrouping()
        left.editor.insertText("!", replacementRange: NSRange(location: left.editor.string.utf16.count, length: 0))
        left.editor.breakUndoCoalescing(); left.undoManager.endUndoGrouping()
        let insertionAfterEdit = left.editor.selectedRange()
        try await D.wait("hidden query refresh after editing") { !session.searching && !session.calculating }
        D.check(session.searchMatches.count == 4 && left.editor.selectedRange() == insertionAfterEdit && D.window.firstResponder === left.editor,
                "hidden search refresh keeps the editing selection and responder unchanged")
        try await pressMenu("g")
        D.check(session.currentMatch == 1, "command G uses refreshed hidden matches")
        try await pressMenu("z")
        try await D.wait("undo hidden-search edit") { !session.searching && !session.calculating && session.left.text == a }

        session.showSearch()
        session.searchQuery = "中文"
        session.closeSearch()
        D.window.makeFirstResponder(left.editor)
        left.editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await D.wait("query started before closing Find completes") { !session.searching && session.searchMatches.count == 1 }
        D.check(left.editor.selectedRange() == NSRange(location: 0, length: 0) && D.window.firstResponder === left.editor,
                "a query finishing after Find closes does not move the insertion point or focus")
        session.searchQuery = "foo"
        try await D.wait("restore last query while Find is hidden") { !session.searching && session.searchMatches.count == 4 }

        D.window.makeFirstResponder(right.editor)
        try await pressMenu("f", modifiers: [.command, .option])
        try await D.wait("command option F opens replace") { session.isReplaceVisible && !session.searching }
        D.check(session.replacementScope == .right, "replace defaults to side focused when invoked")
        session.replacementText = "新🌊"
        session.replaceCurrentMatch()
        try await D.wait("replace current native match") { !session.searching && !session.calculating && session.right.text == "新🌊 保留\r\nfoo\r\n" }
        D.check(session.left.text.utf16.elementsEqual(a.utf16), "current replacement leaves other source unchanged")
        D.window.makeFirstResponder(right.editor)
        try await pressMenu("z")
        try await D.wait("undo replacement") { !session.searching && !session.calculating && session.right.text == b }
        D.check(right.undoManager.canRedo, "replacement supports native redo")
        try await pressMenu("z", modifiers: [.command, .shift])
        try await D.wait("redo replacement") { !session.calculating && session.right.text.hasPrefix("新🌊") }
        try await pressMenu("z")
        try await D.wait("reset replacement") { !session.searching && !session.calculating && session.right.text == b }

        session.replacementScope = .both
        session.replacementText = "bar"
        try await D.wait("both-side replacement matches") { !session.searching && session.searchMatches.count == 4 }
        session.showDeletions = true; try await D.ready(session)
        session.replaceAllMatches()
        try await D.wait("replace all raw sources") { !session.replacing && !session.calculating && !session.searching }
        D.check(session.left.text == a.replacingOccurrences(of: "foo", with: "bar") && session.right.text == b.replacingOccurrences(of: "foo", with: "bar"), "replace all processes both raw sources including preview mode")
        D.check(session.replacementCount == 4, "replace all reports actual total")
        session.showDeletions = false
        try await D.pause()
        D.window.makeFirstResponder(left.editor); try await pressMenu("z")
        try await D.wait("undo all on left") { !session.calculating && session.left.text == a }
        D.check(session.right.text.contains("bar"), "replace-all undo remains independent per side")
        D.window.makeFirstResponder(right.editor); try await pressMenu("z")
        try await D.wait("undo all on right") { !session.searching && !session.calculating && session.right.text == b }

        let originalLeftState = session.leftEditorState, originalRightState = session.rightEditorState
        try await pressMenu(",")
        try await D.wait("settings shortcut opens independent window") {
            NSApp.windows.contains { $0.identifier?.rawValue == "crossdiff-settings" && $0.isVisible }
        }
        let settings = NSApp.windows.first { $0.identifier?.rawValue == "crossdiff-settings" }!
        D.check(settings !== D.window && settings.title == "设置", "settings is a separate localized window")
        settings.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        D.check(menuCommand(",")?.title == "设置/Setting…", "settings menu remains a bilingual discovery entry")
        try await checkSettingsAppearance(settings, language: .simplifiedChinese)
        settings.contentView?.layoutSubtreeIfNeeded()
        if let full = settings.contentView?.superview { _ = try D.capture(full, rect: full.bounds, name: "settings-zh") }
        let find = menuCommand("f")!
        D.check(!NativeMenuController.shared.validateMenuItem(find), "comparison find is disabled while settings is key")
        let undo = menuCommand("z")!
        D.check(!NativeMenuController.shared.validateMenuItem(undo), "settings does not borrow a hidden editor's undo stack")

        AppSettings.shared.language = .english
        try await D.pause()
        D.check(NSApp.mainMenu?.items.map(\.title) == ["CrossDiff", "File", "Edit", "View", "Compare", "Session", "Window", "Help"], "all top-level menu names switch to English immediately")
        D.check(settings.title == "Settings" && menuCommand("f")?.title == "Find…" && menuCommand("g", modifiers: [.command, .shift])?.title == "Find Previous", "settings and find menu items switch together")
        D.check(session.leftEditorState === originalLeftState && session.rightEditorState === originalRightState &&
                session.left.text.utf16.elementsEqual(a.utf16) && session.right.text.utf16.elementsEqual(b.utf16), "live language switch retains source text and native editor identity")
        D.check(left.undoManager.canRedo && right.undoManager.canRedo, "language switching preserves native undo and redo")
        D.check(menuCommand(",")?.title == "设置/Setting…", "English users retain the bilingual settings entry")
        try await checkSettingsAppearance(settings, language: .english)
        settings.contentView?.layoutSubtreeIfNeeded()
        if let full = settings.contentView?.superview { _ = try D.capture(full, rect: full.bounds, name: "settings-en") }
        let data = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]!).appendingPathComponent("preferences.json")
        D.check(try PreferencesFile.load(from: data)?.language == .english, "selected language is saved in isolated local preferences")
        try await pressMenu("w", in: settings)
        try await D.pause()
        D.check(!settings.isVisible && WorkspaceStore.shared.selected?.id == session.id, "command W closes settings without closing current comparison")
        try await activateTestWindow(D.window); D.window.makeFirstResponder(right.editor)
        try await stage("crossdiff-replace-en", session: session, width: 1220, dark: false)
        try await stage("crossdiff-replace-en-narrow", session: session, width: 860, dark: false)
        try await stage("crossdiff-replace-en-dark", session: session, width: 1220, dark: true)
        // Settings deliberately keeps a bilingual discovery label in either locale.
        let menuTitles = flattenMenu(NSApp.mainMenu!).map(\.title).joined(separator: "\n")
        try menuTitles.write(to: D.output.appendingPathComponent("menus-en.txt"), atomically: true, encoding: .utf8)
        let menuDetails = flattenMenu(NSApp.mainMenu!).map { entry in
            "\(entry.title) | action=\(entry.action.map(NSStringFromSelector) ?? "nil") | target=\(entry.target.map { String(describing: type(of: $0)) } ?? "nil")"
        }.joined(separator: "\n")
        try menuDetails.write(to: D.output.appendingPathComponent("menus-en-details.txt"), atomically: true, encoding: .utf8)
        let translatedTitles = flattenMenu(NSApp.mainMenu!).filter { $0.action != #selector(NativeMenuController.showSettings(_:)) }.map(\.title).joined(separator: "\n")
        D.check(!translatedTitles.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) }, "English native menus contain no unintended Chinese app labels")
        checkManagedMenus(language: .english)
        AppSettings.shared.language = .simplifiedChinese
        try await D.pause()
        try flattenMenu(NSApp.mainMenu!).map(\.title).joined(separator: "\n").write(to: D.output.appendingPathComponent("menus-zh.txt"), atomically: true, encoding: .utf8)
        checkManagedMenus(language: .simplifiedChinese)
        session.closeSearch()
        D.log("Native keyboard dispatch, replacement undo, and live bilingual settings passed")
    }

    static func checkSettingsAppearance(_ window: NSWindow, language: AppLanguage) async throws {
        guard let content = window.contentView, let full = content.superview else {
            D.check(false, "settings has native window content"); return
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await activateTestWindow(window)
        try await D.wait("settings native appearance and language controls are mounted") {
            content.layoutSubtreeIfNeeded()
            return descendants(content).contains { $0 is NSSegmentedControl } && descendants(content).contains { $0 is NSPopUpButton }
        }
        for dark in [true, false] {
            try await activateTestWindow(window)
            guard let segmented = descendants(content).compactMap({ $0 as? NSSegmentedControl }).first else {
                D.check(false, "settings appearance uses native segmented buttons"); return
            }
            segmented.selectedSegment = dark ? 1 : 0
            segmented.sendAction(segmented.action, to: segmented.target)
            try await D.wait("settings appearance binding responds to native button") { AppAppearance.shared.isDark == dark }
            try await D.pause()
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            guard let popup = descendants(content).compactMap({ $0 as? NSPopUpButton }).first else {
                D.check(false, "settings language uses a native popup"); return
            }
            let expected: NSAppearance.Name = dark ? .darkAqua : .aqua
            let name = "settings-\(language.rawValue)-\(dark ? "dark" : "light")"
            D.check(popup.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                    "\(name): language popup immediately matches the new background theme")
            D.check(popup.title == language.nativeName && AppSettings.shared.language == language,
                    "\(name): appearance switching retains the selected language")
            _ = try D.capture(full, rect: full.bounds, name: name)
            // Crop the real parent-window composition to the language title,
            // excluding the chevron and most of the bezel from the pixel check.
            let titleRect = popup.bounds.insetBy(dx: 10, dy: 4)
            let textCrop = NSRect(x: titleRect.minX, y: titleRect.minY,
                                  width: max(1, titleRect.width - 28), height: titleRect.height)
            let pixels = try D.capture(full, rect: popup.convert(textCrop, to: full), name: name + "-language")
            D.check(D.countPixels(pixels, background: AppAppearance.shared.colors.canvas).readable >= 18,
                    "\(name): language title stays readable in the actual parent-window bitmap")
        }
    }

    static func flattenMenu(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { entry in [entry] + (entry.submenu.map(flattenMenu) ?? []) }
    }
    static func checkManagedMenus(language: AppLanguage) {
        let chinese = language == .simplifiedChinese
        guard let root = NSApp.mainMenu,
              let edit = root.items.first(where: { $0.title == (chinese ? "编辑" : "Edit") })?.submenu,
              let view = root.items.first(where: { $0.title == (chinese ? "显示" : "View") })?.submenu else {
            D.check(false, "localized Edit and View menus exist"); return
        }
        let editingItems = flattenMenu(edit).filter { !$0.isSeparatorItem }
        let editingTitles = editingItems.map(\.title)
        // Check actual menus after their asynchronous AppKit augmentation, not a
        // freshly built snapshot. Services and dynamic system menus are excluded.
        D.check(editingTitles.count == Set(editingTitles).count, "\(language.rawValue) Edit menu contains no duplicate entries")
        D.check(!editingTitles.contains { $0.contains("Dictation") || $0.contains("听写") || ["AutoFill", "Contact…", "Passwords…", "Credit Card…"].contains($0) },
                "\(language.rawValue) Edit menu has no injected system-language editing groups")
        let emojiItems = editingItems.filter { $0.action == #selector(NSApplication.orderFrontCharacterPalette(_:)) }
        D.check(emojiItems.count == 1 && emojiItems.first?.title == (chinese ? "表情与符号" : "Emoji & Symbols"),
                "\(language.rawValue) Edit menu has exactly one localized native character palette command")
        let find = edit.items.first { $0.title == (chinese ? "查找" : "Find") }?.submenu
        let expectedFind = chinese ? ["查找…", "查找并替换…", "下一个匹配", "上一个匹配", "使用所选内容查找"]
                                   : ["Find…", "Find and Replace…", "Find Next", "Find Previous", "Use Selection for Find"]
        D.check(find?.items.filter { !$0.isSeparatorItem }.map(\.title) == expectedFind, "\(language.rawValue) Find menu uses exact translated commands")
        let expectedView = chinese ? ["显示删除内容", "对齐差异行", "同步滚动", "进入全屏幕"]
                                   : ["Show Deletions", "Align Changed Lines", "Sync Scrolling", "Enter Full Screen"]
        D.check(view.items.filter { !$0.isSeparatorItem }.map(\.title) == expectedView, "\(language.rawValue) View menu has one localized full-screen command")
        if chinese {
            D.check(editingTitles.allSatisfy { $0.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) } },
                    "Chinese Edit menu has no English-only injected entries")
        }
    }
    static func menuCommand(_ key: String, modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem? {
        NSApp.mainMenu.flatMap { flattenMenu($0).first { $0.keyEquivalent.lowercased() == key && $0.keyEquivalentModifierMask == modifiers } }
    }
    /// A physical keystroke can only reach an active app. Directly invoking
    /// NSMenu's synthetic event API skips that OS precondition, so establish it
    /// explicitly even if another app became active during an async test wait.
    static func activateTestWindow(_ window: NSWindow) async throws {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if NSApp.keyWindow !== window { window.makeKeyAndOrderFront(nil) }
        try await D.wait("test app and target window are active") { NSApp.isActive && NSApp.keyWindow === window }
    }

    static func pressMenu(_ key: String, modifiers: NSEvent.ModifierFlags = [.command], in window: NSWindow? = nil) async throws {
        try await activateTestWindow(window ?? D.window)
        let keyCodes: [String: UInt16] = ["z": 6, "f": 3, "g": 5, ",": 43, "w": 13, "e": 14]
        // Synthetic events do not pass through NSApplication's normal menu
        // validation cycle; update enabled states just as opening a menu does.
        if let menu = NSApp.mainMenu {
            for entry in flattenMenu(menu) { entry.submenu?.update() }
            menu.update()
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                                          context: nil, characters: modifiers.contains(.shift) ? key.uppercased() : key,
                                          charactersIgnoringModifiers: modifiers.contains(.shift) ? key.uppercased() : key,
                                          isARepeat: false, keyCode: keyCodes[key] ?? 0) else {
            D.check(false, "create native keyboard event"); return
        }
        D.check(NSApp.mainMenu?.performKeyEquivalent(with: event) == true, "native menu handles \(modifiers.rawValue)+\(key)")
    }
}
