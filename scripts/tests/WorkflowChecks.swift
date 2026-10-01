import AppKit
import SwiftUI
import CrossDiffCore
import Darwin

private func traceWorkflowSignal(_ number: Int32) {
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
    let count = frames.withUnsafeMutableBufferPointer { backtrace($0.baseAddress!, Int32($0.count)) }
    frames.withUnsafeMutableBufferPointer { backtrace_symbols_fd($0.baseAddress!, count, STDERR_FILENO) }
    _exit(128 + number)
}

/// Exercises the shipping view hierarchy with isolated source files and sessions.
/// Does not read or write the user's clipboard, windows, or saved comparisons.
@MainActor
enum WorkflowChecks {
    typealias D = DeletionPreviewChecks
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-workflow-checks/") == true,
              ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]?.contains(".build-workflow-checks/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        signal(SIGSEGV, traceWorkflowSignal)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty
                ? "PASS: full-window aligned rows, merge, independent undo, source search and preview mapping, copy, manual save and recovery, clear/restore, native keyboard commands, find/replace, settings isolation and live bilingual menus/text/folder/image views; light/dark/narrow actual renders"
                : "FAIL: " + D.failures.joined(separator: "; ")
            D.log(verdict)
            try? verdict.write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(D.failures.isEmpty ? 0 : 8)
        }
    }

    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        try await D.wait("own app window") {
            D.window = NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }
            return D.window != nil
        }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.orderFront(nil)
        let a = """
        // CrossDiff · 本地文本比较
        struct CompareOptions {
            var ignoreWhitespace = false
            var theme = "light"

            // 为下一次比较保留临时内容
            var restoreSession = true
            var legacyMode = true
            var fontSize = 14
        }

        let greeting = "你好，CrossDiff 👋"
        let paperTitle = "理解变化，专注内容"
        """
        let b = """
        // CrossDiff · 本地文本比较
        struct CompareOptions {
            var ignoreWhitespace = true
            var theme = "light"

            // 为下一次比较保留临时内容
            var restoreSession = true
            var fontSize = 15
        }

        let greeting = "你好，CrossDiff 👋"
        let paperTitle = "理解变化，专注内容"
        let searchEnabled = true
        """
        let session = try await D.mount(left: a, right: b)
        D.check(session.alignDifferences && !session.showDeletions, "alignment on and deletion preview off by default")
        try await stage("crossdiff-workspace", session: session, width: 1220, dark: false)
        try await stage("crossdiff-workspace-narrow", session: session, width: 860, dark: false)
        try await stage("crossdiff-workspace-dark", session: session, width: 1220, dark: true)
        D.check(session.result!.hunks.count == 3, "fixture has three independent merge targets")
        let editor = session.rightEditorState!.editor
        let target = session.result!.hunks[1]
        D.log("Selecting second native hunk")
        D.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: target.rightRange.location, length: 0))
        try await D.pause()
        D.check(session.selectedHunk == 1 && session.rightEditorState!.ruler.selectedHunk == 1, "native selection activates second hunk and its marker")
        let expected = TextDiffEngine.applying(target, fromLeft: true, left: a, right: b)
        let undo = session.rightEditorState!.undoManager
        // Model actions run from this async harness, outside a user event. Model
        // a single event's undo group explicitly, as the source-edit checks do.
        undo.groupsByEvent = false; undo.removeAllActions(); undo.beginUndoGrouping()
        D.log("Merging second hunk")
        session.merge(fromLeft: true)
        try await D.wait("selected merge") { !session.calculating && session.right.text == expected && editor.string == expected }
        undo.endUndoGrouping()
        D.log("Merged target; exercising undo")
        D.check(session.left.text == a && session.right.text.contains("ignoreWhitespace = true"), "merge touches only selected target")
        D.check(session.rightEditorState!.undoManager.canUndo, "merge has a native undo action")
        undo.undo()
        do { try await D.wait("merge undo") { !session.calculating && session.right.text == b && editor.string == b } }
        catch {
            D.log("Undo diagnostic: model=\(session.right.text.debugDescription), editor=\(editor.string.debugDescription), expected=\(b.debugDescription), canUndo=\(undo.canUndo), grouping=\(undo.groupingLevel)")
            throw error
        }

        session.showSearch(); session.searchQuery = "CrossDiff"
        D.log("Searching source pair")
        try await D.wait("both-side search") { !session.searching && session.searchMatches.count == 4 }
        D.check(session.currentSearchMatch?.side == .left, "search begins in left source")
        session.navigateSearch(2)
        try await D.pause()
        D.check(session.currentSearchMatch?.side == .right && editor.selectedRange() == session.currentSearchMatch?.range, "next matches navigate into real right editor")
        D.check((editor.string as NSString).substring(with: editor.selectedRange()) == "CrossDiff", "native selected text matches the query")
        try await stage("crossdiff-search", session: session, width: 1220, dark: false)
        session.searchQuery = "absent-query"; session.searchQuery = "理解变化"; session.searchQuery = "fontSize"
        try await D.wait("latest search wins") { !session.searching && session.searchMatches.count == 2 }
        D.check(session.searchMatches.allSatisfy { (session.value($0.side).text as NSString).substring(with: $0.range) == "fontSize" }, "stale search results do not replace latest query")

        session.showDeletions = true; try await D.ready(session)
        session.navigateSearch(1); try await D.pause()
        let preview = D.previewScroll()!.documentView as! PreviewTextView
        D.check(session.currentSearchMatch?.side == .right, "preview search targets source on right")
        D.check(PreviewCopy.sourceText(from: session.deletionPreview!, selection: preview.selectedRange()) == "fontSize", "source search selection maps through projected deletions")
        session.searchQuery = "legacyMode"
        try await D.wait("deleted text only in left search") { !session.searching && session.searchMatches.count == 1 }
        D.check(session.searchMatches.first?.side == .left, "deleted preview text is not searched as right source")
        session.closeSearch(); try await D.pause()
        let projection = session.deletionPreview!
        let whole = NSRange(location: 0, length: projection.text.utf16.count)
        preview.setSelectedRange(whole)
        D.check(PreviewCopy.sourceText(from: projection, selection: whole).utf16.elementsEqual(b.utf16), "preview default copy representation is exact original source")
        let marked = PreviewCopy.revisionText(from: projection, selection: whole)
        D.check(marked.contains("[-") && marked.contains("-]") && marked.contains("{+") && marked.contains("+}"), "revision copy explicitly marks both changes")
        D.check(preview.responds(to: #selector(PreviewTextView.copySource(_:))) && preview.responds(to: #selector(PreviewTextView.copyRevisions(_:))), "native copy actions are connected without using the system clipboard")
        preview.setSelectedRange(NSRange(location: projection.hunkRanges[2].location, length: 0))
        D.check(session.selectedHunk == 2, "clicking preview source selects the corresponding hunk")
        try await stage("crossdiff-review", session: session, width: 1220, dark: false)
        try await stage("crossdiff-review-narrow", session: session, width: 860, dark: false)

        let saved = D.output.appendingPathComponent("manual-source.txt")
        session.right.path = saved.path
        WorkspaceStore.shared.save(session, side: .right)
        D.check(try String(contentsOf: saved, encoding: .utf8) == b, "save during deletion review writes exact raw source")
        D.check(WorkspaceStore.shared.persistNow(), "exit flush succeeds")
        let data = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]!).appendingPathComponent("sessions.json")
        let recovered = try SessionFile.load(from: data)
        D.check(recovered.first?.right.text == b && recovered.first?.left.text == a, "local recovery excludes projected deletion content")
        if let record = recovered.first {
            let restored = ComparisonSession(kind: .text, left: record.left, right: record.right)
            D.check(!restored.showDeletions, "restored comparison retains default-off deletion review")
        }
        let typing = try await D.mount(left: "foo tail", right: "foo unchanged")
        typing.showSearch(); typing.searchQuery = "foo"
        try await D.wait("typing fixture search") { !typing.searching && typing.searchMatches.count == 2 }
        try await D.pause()
        let input = typing.leftEditorState!.editor
        D.window.makeFirstResponder(input)
        input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
        D.log("Typing before: editor=\(input.string.debugDescription), editable=\(input.isEditable), marked=\(input.hasMarkedText()), responder=\(D.window.firstResponder === input), delegate=\(String(describing: input.delegate))")
        input.insertText("X", replacementRange: input.selectedRange())
        D.log("Typing immediately after: editor=\(input.string.debugDescription), source=\(typing.left.text.debugDescription), selection=\(input.selectedRange()), marked=\(input.hasMarkedText())")
        try await D.wait("search refresh after source edit") { !typing.searching && !typing.calculating }
        try await D.pause()
        D.check(input.selectedRange() == NSRange(location: "foo tailX".utf16.count, length: 0), "background search refresh preserves typing caret: text=\(input.string.debugDescription), selection=\(input.selectedRange())")
        input.insertText("Y", replacementRange: input.selectedRange())
        try await D.pause()
        D.check(typing.left.text == "foo tailXY", "continued typing never replaces an earlier search match: \(typing.left.text.debugDescription)")
        try await checkClearText()
        try await checkMenusAndSettings()
        try await checkToolbarActions()
        try await checkNavigationIndicators()
        try await checkTranslatedSurfaces()
    }

    static func checkClearText() async throws {
        D.log("Clearing and restoring the current comparison")
        let a = "共同内容\r\n原文 👩🏽‍💻 e\u{301}\r\n已删除\r\n"
        let b = "共同内容\r\n新内容 🌊\r\n"
        let session = try await D.mount(left: a, right: b)
        let left = session.leftEditorState!, right = session.rightEditorState!
        let other = ComparisonSession(left: .init(text: "其他标签"), right: .init(text: "保持不变"))
        WorkspaceStore.shared.attach(other)
        let files = [D.output.appendingPathComponent("clear-left.txt"), D.output.appendingPathComponent("clear-right.txt")]
        for (index, side) in [Side.left, .right].enumerated() {
            let text = session.value(side).text
            let bytes = try TextFileIO.encoded(text, encoding: .utf16LE)
            try bytes.write(to: files[index])
            session.replace(.init(text: text, path: files[index].path, encoding: .utf16LE,
                                  signature: TextFileIO.signature(bytes), savedText: text), side: side)
        }
        let signatures = [session.left.signature, session.right.signature]
        for state in [left, right] { state.undoManager.groupsByEvent = false; state.undoManager.removeAllActions() }
        session.showSearch(); session.searchQuery = "内容"
        session.showDeletions = true; try await D.ready(session)
        D.check(session.canClearText && !session.canRestoreClearedText, "nonempty pair offers clear, not restore")
        session.clearText()
        try await D.wait("both sources cleared") {
            !session.calculating && left.editor.string.isEmpty && right.editor.string.isEmpty && !session.searching
        }
        D.check(session.left.text.isEmpty && session.right.text.isEmpty && session.result?.hunks.isEmpty == true,
                "clear removes both raw sources and old difference highlights")
        D.check(!session.showDeletions && !session.isSearchVisible && session.searchMatches.isEmpty,
                "clear returns to editable inputs without stale preview or search matches")
        D.check(!session.canClearText && session.canRestoreClearedText && session.dirty, "clear offers one-click restore and marks attached files dirty")
        D.check(session.left.path == files[0].path && session.right.path == files[1].path &&
                session.left.savedText == a && session.right.savedText == b &&
                session.left.encoding == .utf16LE && session.right.encoding == .utf16LE &&
                signatures == [session.left.signature, session.right.signature], "clear preserves file associations and saved baselines")
        D.check(try TextFileIO.read(files[0]).text == a && TextFileIO.read(files[1]).text == b, "clear never writes source files")
        D.check(other.left.text == "其他标签" && other.right.text == "保持不变", "clear does not touch another tab")
        D.check(left.undoManager.undoActionName == "清空文本" && right.undoManager.undoActionName == "清空文本", "both sides have clearly named native clear undo")
        if let full = D.window.contentView?.superview { _ = try D.capture(full, rect: full.bounds, name: "crossdiff-cleared") }
        session.clearText()
        D.check(session.canRestoreClearedText, "clearing an already empty pair preserves restore")
        session.restoreClearedText()
        try await D.ready(session)
        D.check(session.left.text.utf16.elementsEqual(a.utf16) && session.right.text.utf16.elementsEqual(b.utf16), "inline restore retains exact Unicode and CRLF on both sides")
        D.check(session.showDeletions && !session.canRestoreClearedText && !session.dirty, "inline restore returns preview and clean saved state")
        D.check(session.leftEditorState === left && session.rightEditorState === right, "clear and restore keep retained native editors")

        session.clearText()
        try await D.wait("second clear") { !session.calculating }
        left.undoManager.undo()
        try await D.wait("left undo clear") { !session.calculating && session.left.text == a }
        D.check(session.right.text.isEmpty && !session.canRestoreClearedText, "native left undo preserves independent right state")
        right.undoManager.undo()
        try await D.wait("right undo clear") { !session.calculating && session.right.text == b }
        D.check(!session.dirty, "independent undo restores both saved sources")
        right.undoManager.redo()
        try await D.wait("redo clear") { !session.calculating && session.right.text.isEmpty }
        D.check(session.left.text == a, "native redo clears only its own side")

        // The native marked string has not reached the model yet. Clear must
        // commit it first, and restore must retain it rather than the stale model.
        D.window.makeFirstResponder(left.editor)
        left.undoManager.beginUndoGrouping()
        left.editor.setMarkedText("输入中", selectedRange: NSRange(location: 3, length: 0),
                                  replacementRange: NSRange(location: left.editor.string.utf16.count, length: 0))
        left.undoManager.endUndoGrouping()
        session.clearText()
        try await D.wait("clear composition") { !session.calculating && session.left.text.isEmpty && left.editor.string.isEmpty }
        session.restoreClearedText()
        try await D.wait("restore composition") { !session.calculating }
        D.check(session.left.text.utf16.elementsEqual((a + "输入中").utf16) && !left.editor.hasMarkedText(), "restore retains the input committed immediately before clear")
        D.check(session.right.text.isEmpty, "one-sided clear and restore preserve empty opposite side")

        session.clearText()
        left.undoManager.beginUndoGrouping()
        left.editor.insertText("新比较", replacementRange: NSRange(location: 0, length: 0))
        left.undoManager.endUndoGrouping()
        session.restoreClearedText()
        try await D.wait("new input invalidates restore") { !session.calculating }
        D.check(session.left.text == "新比较" && session.right.text.isEmpty && !session.canRestoreClearedText,
                "typing invalidates old inline restore without overwriting new input")
        session.clearText()
        session.replace(.init(text: "新文件"), side: .right, resetUndo: true)
        D.check(!session.canRestoreClearedText, "opening a replacement source invalidates old clear snapshot")
    }

    static func stage(_ name: String, session: ComparisonSession, width: Double, dark: Bool) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                AppAppearance.shared.isDark = dark
                D.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                D.window.setFrame(NSRect(x: -10000, y: -10000, width: width, height: width == 860 ? 580 : 790), display: true)
                D.window.contentView?.layoutSubtreeIfNeeded()
                continuation.resume()
            }
        }
        try await D.pause()
        if !session.showDeletions, let left = session.leftEditorState, let right = session.rightEditorState {
            for row in session.result!.rows {
                if let l = row.leftLine, let r = row.rightLine {
                    let ly = lineY(left, line: l), ry = lineY(right, line: r)
                    D.check(abs(ly - ry) < 1, "\(name): corresponding native rows remain aligned: \(l)/\(r)")
                }
            }
        }
        for state in [session.leftEditorState!, session.rightEditorState!] where !session.showDeletions {
            let scroll = state.scroll
            let layout = state.editor.layoutManager!, container = state.editor.textContainer!
            layout.ensureLayout(for: container)
            let firstGlyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
                .offsetBy(dx: state.editor.textContainerOrigin.x, dy: state.editor.textContainerOrigin.y)
            let inScroll = state.editor.convert(firstGlyph, to: scroll)
            let rulerRight = state.ruler.convert(state.ruler.bounds, to: scroll).maxX
            D.check(inScroll.minX >= rulerRight + 5, "\(name): first text glyph clears native ruler; glyphX=\(inScroll.minX), rulerRight=\(rulerRight), clipX=\(scroll.contentView.bounds.minX)")
            let top = NSRect(x: scroll.bounds.minX, y: scroll.isFlipped ? scroll.bounds.minY : scroll.bounds.maxY - min(260, scroll.bounds.height), width: scroll.bounds.width, height: min(260, scroll.bounds.height))
            let bitmap = try D.capture(scroll, rect: top, name: name + (state === session.leftEditorState ? "-left" : "-right"))
            D.check(D.countPixels(bitmap, background: ComparisonTheme(isDark: dark).canvas).readable > 100, "\(name): actual parent-scroll bitmap has readable text")
        }
        if let full = D.window.contentView?.superview { _ = try D.capture(full, rect: full.bounds, name: name) }
        D.log("Rendered \(name)")
    }

    static func lineY(_ state: TextEditorState, line: Int) -> CGFloat {
        let range = sourceLineRanges(state.editor.string)[line]
        let layout = state.editor.layoutManager!
        layout.ensureLayout(for: state.editor.textContainer!)
        return layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil).minY + state.editor.textContainerOrigin.y
    }
}
