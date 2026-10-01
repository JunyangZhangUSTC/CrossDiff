import AppKit
import CrossDiffCore

@MainActor
extension WorkflowChecks {
    static func checkToolbarActions() async throws {
        D.log("Checking toolbar undo/redo against actual focused source and search field")
        let session = try await D.mount(left: "left base", right: "right base")
        try await activateTestWindow(D.window)
        let left = session.leftEditorState!, right = session.rightEditorState!
        guard let toolbar = D.window.toolbar,
              let undoButton = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "crossdiff.undo" })?.view as? NSButton,
              let redoButton = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "crossdiff.redo" })?.view as? NSButton else {
            throw D.CheckError(description: "Missing toolbar undo/redo buttons")
        }
        D.check(undoButton.title.isEmpty && redoButton.title.isEmpty && undoButton.image != nil && redoButton.image != nil,
                "undo and redo toolbar actions use accessible symbols without visible text")
        for (side, state, baseline) in [(Side.left, left, "left base"), (.right, right, "right base")] {
            try await activateTestWindow(D.window)
            D.window.makeFirstResponder(state.editor)
            try await D.pause()
            state.undoManager.groupsByEvent = false; state.undoManager.removeAllActions()
            try await activateTestWindow(D.window)
            toolbar.validateVisibleItems()
            D.check(!undoButton.isEnabled && !redoButton.isEnabled, "empty focused history disables both toolbar actions")
            state.undoManager.beginUndoGrouping()
            state.editor.insertText("!", replacementRange: NSRange(location: baseline.utf16.count, length: 0))
            state.editor.breakUndoCoalescing(); state.undoManager.endUndoGrouping()
            try await D.wait("toolbar source edit settles") { !session.calculating && session.value(side).text == baseline + "!" }
            let opposite = session.value(side == .left ? .right : .left).text
            try await activateTestWindow(D.window)
            toolbar.validateVisibleItems()
            D.check(undoButton.isEnabled && !redoButton.isEnabled, "toolbar validation follows focused undo history")
            undoButton.performClick(nil)
            try await D.wait("toolbar undo") { !session.calculating && session.value(side).text == baseline }
            D.check(D.window.firstResponder === state.editor && session.value(side == .left ? .right : .left).text == opposite,
                    "toolbar undo preserves editor focus and the opposite source")
            try await activateTestWindow(D.window)
            toolbar.validateVisibleItems()
            D.check(redoButton.isEnabled, "toolbar redo becomes available after undo")
            redoButton.performClick(nil)
            try await D.wait("toolbar redo") { !session.calculating && session.value(side).text == baseline + "!" }
            D.check(D.window.firstResponder === state.editor, "toolbar redo does not take editor focus")
        }

        let sourceBeforeFind = try D.encoded(session)
        try await activateTestWindow(D.window)
        session.showSearch()
        try await D.wait("toolbar test has native find field") { (D.window.firstResponder as? NSTextView)?.isFieldEditor == true }
        let field = D.window.firstResponder as! NSTextView
        guard let fieldUndo = field.undoManager else { throw D.CheckError(description: "Missing field undo manager") }
        let groupsByEvent = fieldUndo.groupsByEvent
        fieldUndo.groupsByEvent = false; fieldUndo.removeAllActions(); fieldUndo.beginUndoGrouping()
        field.insertText("base", replacementRange: NSRange(location: 0, length: field.string.utf16.count))
        field.breakUndoCoalescing(); fieldUndo.endUndoGrouping()
        try await D.wait("find query settles") { session.searchQuery == "base" && !session.searching }
        try await D.pause()
        try await activateTestWindow(D.window)
        toolbar.validateVisibleItems(); undoButton.performClick(nil)
        try await D.wait("toolbar undo affects focused find field") { session.searchQuery.isEmpty && field.string.isEmpty && !session.searching }
        D.check(try D.encoded(session) == sourceBeforeFind && D.window.firstResponder === field,
                "toolbar undo in Find preserves source text and query focus")
        try await activateTestWindow(D.window)
        toolbar.validateVisibleItems(); redoButton.performClick(nil)
        try await D.wait("toolbar redo affects focused find field") { session.searchQuery == "base" && field.string == "base" && !session.searching }
        fieldUndo.groupsByEvent = groupsByEvent
        D.check(try D.encoded(session) == sourceBeforeFind, "query toolbar redo leaves source text unchanged")
        session.closeSearch()
        try await D.wait("find field detaches") { field.window == nil }
        D.window.makeFirstResponder(right.editor)
        try await D.pause()

        try await activateTestWindow(D.window)
        NativeMenuController.shared.showSettings(nil)
        try await D.wait("settings opens") { NSApp.windows.contains { $0.identifier?.rawValue == "crossdiff-settings" && $0.isVisible } }
        let settings = NSApp.windows.first { $0.identifier?.rawValue == "crossdiff-settings" }!
        try await activateTestWindow(settings)
        toolbar.validateVisibleItems()
        D.check(!undoButton.isEnabled && !redoButton.isEnabled, "background toolbar does not expose hidden comparison undo in Settings")
        settings.performClose(nil)
        try await activateTestWindow(D.window); D.window.makeFirstResponder(right.editor)
        try await D.pause()
        try await activateTestWindow(D.window)
        toolbar.validateVisibleItems()
        try await stage("crossdiff-toolbar-light", session: session, width: 1220, dark: false)
        try await stage("crossdiff-toolbar-dark-narrow", session: session, width: 860, dark: true)
        D.log("Toolbar buttons passed: focused undo/redo, search-field isolation, disabled states and real renders")
    }
}
