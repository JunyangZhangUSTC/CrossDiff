import AppKit
import CrossDiffCore

@MainActor
extension WorkflowChecks {
    static func checkNavigationIndicators() async throws {
        D.log("Checking subtle native navigation locators in source editors and deletion preview")
        AppAppearance.shared.isDark = false
        D.window.appearance = NSAppearance(named: .aqua)
        D.window.setFrame(NSRect(x: -10000, y: -10000, width: 860, height: 580), display: true)
        let wrapped = "needle 中文 👩🏽‍💻 " + String(repeating: "wrapped source content · ", count: 8)
        let a = "CrossDiff navigation\n\(wrapped)\nold line\nremoved line\nend\n"
        let b = "CrossDiff navigation\n\(wrapped)\nnew line\nend\n"
        let session = try await D.mount(left: a, right: b)
        let left = session.leftEditorState!, right = session.rightEditorState!
        let snapshot = try D.encoded(session)
        let undoState = [left.undoManager.canUndo, left.undoManager.canRedo, right.undoManager.canUndo, right.undoManager.canRedo]
        session.showSearch(); session.searchQuery = wrapped
        try await D.wait("wrapped source matches") { !session.searching && session.searchMatches.count == 2 }
        try await D.pause()
        let responder = D.window.firstResponder
        session.navigateSearch(1)
        try await D.wait("right-side wrapped locator") {
            right.editor.navigationIndicator.activeRanges == [session.currentSearchMatch!.range]
                && !right.editor.navigationIndicator.visibleRects.isEmpty
        }
        D.check(right.editor.navigationIndicator.visibleRects.count > 1, "wrapped source navigation outlines each visible line")
        D.check(left.editor.navigationIndicator.activeRanges.isEmpty, "navigation into other pane removes its previous locator")
        D.check(right.editor.selectedRange() == session.currentSearchMatch!.range && D.window.firstResponder === responder,
                "locator preserves existing search selection and does not steal focus")
        let highlighted = try D.capture(right.scroll, rect: right.scroll.bounds, name: "navigation-source-light")
        if let window = D.window.contentView?.superview {
            _ = try D.capture(window, rect: window.bounds, name: "navigation-source-light-window")
        }
        right.editor.navigationIndicator.cancel()
        let normal = try D.capture(right.scroll, rect: right.scroll.bounds, name: "navigation-source-without-locator")
        D.check(navigationPixelDifference(highlighted, normal) > 30, "parent scroll rendering contains the locator's actual pixels")

        session.navigateSearch(-1); session.navigateSearch(1); session.navigateSearch(-1)
        try await D.wait("latest rapid navigation wins") {
            left.editor.navigationIndicator.activeRanges == [session.currentSearchMatch!.range]
                && right.editor.navigationIndicator.activeRanges.isEmpty
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        D.check(left.editor.navigationIndicator.activeRanges.isEmpty && left.editor.navigationIndicator.opacity == 0,
                "locator disappears after its short presentation without leaving stale outlines")

        session.closeSearch()
        try await D.pause()
        let selection = left.editor.selectedRange()
        session.navigate(0)
        try await D.wait("difference locator on both panes") {
            !left.editor.navigationIndicator.activeRanges.isEmpty && !right.editor.navigationIndicator.activeRanges.isEmpty
        }
        D.check(left.editor.selectedRange() == selection, "difference locator does not change the editing selection")
        D.check(try D.encoded(session) == snapshot && undoState == [left.undoManager.canUndo, left.undoManager.canRedo, right.undoManager.canUndo, right.undoManager.canRedo],
                "all source locators preserve raw session data and native undo stacks")

        AppAppearance.shared.isDark = true
        D.window.appearance = NSAppearance(named: .darkAqua)
        session.showDeletions = true; try await D.ready(session)
        session.navigate(0)
        let preview = D.previewScroll()!.documentView as! PreviewTextView
        try await D.wait("preview difference locator") { !preview.navigationIndicator.visibleRects.isEmpty }
        D.check(preview.navigationIndicator.activeRanges == [session.deletionPreview!.hunkRanges[session.selectedHunk]],
                "preview difference navigation uses projected hunk ranges")
        if let window = D.window.contentView?.superview {
            _ = try D.capture(window, rect: window.bounds, name: "navigation-preview-dark-window")
        }
        session.showSearch(); session.searchQuery = "new line\nend"
        try await D.wait("preview multiline source match") { !session.searching && session.searchMatches.count == 1 }
        session.navigateSearch(0)
        try await D.wait("preview source locator") {
            !preview.navigationIndicator.visibleRects.isEmpty
                && preview.navigationIndicator.activeRanges.map { (preview.string as NSString).substring(with: $0) }.joined() == session.searchQuery
        }
        D.check(PreviewCopy.sourceText(from: session.deletionPreview!, selection: preview.selectedRange()) == session.searchQuery,
                "preview locator keeps mapped source search selection")
        let markedSource = preview.navigationIndicator.activeRanges.map { (preview.string as NSString).substring(with: $0) }.joined()
        D.check(markedSource == session.searchQuery && !markedSource.contains("removed line"),
                "preview source locator excludes intervening projected deletions")
        D.check(preview.navigationIndicator.visibleRects.count >= 2, "multiline preview source navigation has line-specific rectangles")

        let empty = try await D.mount(left: "inserted line\n", right: "")
        let emptyEditor = empty.rightEditorState!.editor
        empty.navigate(0)
        try await D.wait("empty-side locator") { !emptyEditor.navigationIndicator.visibleRects.isEmpty }
        D.check(emptyEditor.navigationIndicator.activeRanges == [NSRange(location: 0, length: 0)],
                "deleted entire source locates the empty insertion position")
        D.check(emptyEditor.string.isEmpty && !emptyEditor.undoManager!.canUndo,
                "empty-side locator creates no placeholder source text or undo action")
        if let window = D.window.contentView?.superview {
            _ = try D.capture(window, rect: window.bounds, name: "navigation-empty-side-dark-window")
        }
        AppAppearance.shared.isDark = false
        D.window.appearance = NSAppearance(named: .aqua)
    }

    private static func navigationPixelDifference(_ first: NSBitmapImageRep, _ second: NSBitmapImageRep) -> Int {
        guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else { return 0 }
        var count = 0
        for y in stride(from: 0, to: first.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: first.pixelsWide, by: 2) {
                guard let a = first.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let b = second.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.08 { count += 1 }
            }
        }
        return count
    }
}
