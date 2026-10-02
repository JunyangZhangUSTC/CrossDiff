import AppKit
import SwiftUI
import CrossDiffCore

@main
@MainActor
struct AlignmentChecks {
    static func main() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        if CommandLine.arguments.contains("--newline-only") {
            await checkNewlineBackground(window: window)
            return
        }
        let cases = [
            ("shared\nend", "new first\nshared\nend\nnew last"),
            ("head\nremoved one\nremoved two\n共同🧑‍💻\ntail", "head\n共同🧑‍💻\ntail"),
            ("首行\r\n" + String(repeating: "中文🧑‍💻e\u{301} ", count: 35) + "\r\n尾行\r\n", "首行\r\n短行\r\n尾行\r\n"),
            ("", "added\nsecond\n"),
            ("removed\nsecond\n", ""),
            ("a\u{2028}long line long line long line long line\u{2028}z", "a\u{2028}b\u{2028}z")
        ]
        for (left, right) in cases {
            for width: CGFloat in [450, 300] { checkPair(left, right, width: width, wrap: true, window: window) }
            checkPair(left, right, width: 450, wrap: false, window: window)
        }
        checkEditing(window: window)
        checkNativeEditReentry(window: window)
        await checkSearchEditing(window: window)
        await checkNewlineBackground(window: window)
        print("Alignment checks passed: leading/middle/trailing gaps, empty sides, Unicode/CRLF, unequal wrapping, selection, independent undo, IME, toggles, direct scroll positions, stale refresh rejection, and search typing caret.")
    }

    // The first Return in an otherwise identical wrapped paragraph changes the
    // alignment geometry. Inspect the composed parent, not an editor-only draw:
    // empty space below the last glyph row must not split into white/green halves.
    static func checkNewlineBackground(window: NSWindow) async {
        AppAppearance.shared.isDark = false
        window.setContentSize(NSSize(width: 1000, height: 720))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        let prefix = String(repeating: "A green leaf ", count: 8)
        let suffix = String(repeating: "Distant flowers ", count: 8) + prefix
        let original = prefix + suffix
        let session = ComparisonSession(left: .init(text: original), right: .init(text: original))
        session.wrapLines = true; session.alignDifferences = true
        let left = TextEditorState(text: original, side: .left, wrapLines: true)
        let right = TextEditorState(text: original, side: .right, wrapLines: true)
        session.leftEditorState = left; session.rightEditorState = right
        let link = EditorScrollLink()
        let lc = attach(left, side: .left, session: session, link: link, width: 500, window: window)
        let rc = attach(right, side: .right, session: session, link: link, width: 500, window: window)
        left.scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 720)
        right.scroll.frame = NSRect(x: 500, y: 0, width: 500, height: 720)
        defer { lc.disconnect(); rc.disconnect(); left.scroll.removeFromSuperview(); right.scroll.removeFromSuperview() }
        await settle(session)
        lc.refresh(text: session.left.text, in: left.scroll); rc.refresh(text: session.right.text, in: right.scroll)
        window.makeFirstResponder(right.editor)
        right.editor.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build-alignment-checks/renders", isDirectory: true)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures: [String] = []
        for count in 1...2 {
            right.editor.insertNewline(nil)
            await settle(session)
            lc.refresh(text: session.left.text, in: left.scroll); rc.refresh(text: session.right.text, in: right.scroll)
            window.contentView!.layoutSubtreeIfNeeded()
            let layout = right.editor.layoutManager!, container = right.editor.textContainer!
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: prefix.utf16.count - 1)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let gap = fragment.maxY - used.maxY
            let parent = window.contentView!
            parent.displayIfNeeded()
            guard let bitmap = parent.bitmapImageRepForCachingDisplay(in: parent.bounds) else {
                preconditionFailure("No parent-window bitmap for newline regression")
            }
            parent.cacheDisplay(in: parent.bounds, to: bitmap)
            let name = "newline-\(count)-light-parent"
            try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            func sample(x: CGFloat) -> NSColor {
                let point = right.editor.convert(NSPoint(x: x + right.editor.textContainerOrigin.x,
                    y: used.maxY + gap / 2 + right.editor.textContainerOrigin.y), to: parent)
                let px = Int((point.x - parent.bounds.minX) * CGFloat(bitmap.pixelsWide) / parent.bounds.width)
                let y = parent.isFlipped ? point.y - parent.bounds.minY : parent.bounds.maxY - point.y
                let py = Int(y * CGFloat(bitmap.pixelsHigh) / parent.bounds.height)
                precondition(px >= 0 && py >= 0 && px < bitmap.pixelsWide && py < bitmap.pixelsHigh,
                             "Newline regression sample must be inside the composed parent window")
                return bitmap.colorAt(x: px, y: py)!.usingColorSpace(.sRGB)!
            }
            let leading = sample(x: fragment.minX + 14)
            let trailing = sample(x: fragment.maxX - 14)
            let distance = max(abs(leading.redComponent - trailing.redComponent),
                abs(leading.greenComponent - trailing.greenComponent), abs(leading.blueComponent - trailing.blueComponent))
            let validSource = session.left.text == original && session.right.text == prefix + String(repeating: "\n", count: count) + suffix
            if !validSource { failures.append("\(name): Return must preserve both source texts") }
            if !link.alignment.isAligned || gap < 30 { failures.append("\(name): fixture must create a visible wrapped-line alignment gap (actual \(gap))") }
            if distance > 0.03 { failures.append("\(name): blank alignment area has discontinuous background: leading=\(leading), trailing=\(trailing)") }
            print("\(name): fragment=\(fragment), used=\(used), gap=\(gap), backgroundDistance=\(distance); PNG=\(output.appendingPathComponent(name + ".png").path)")
        }
        if !failures.isEmpty { print("FAIL: " + failures.joined(separator: "; ")); exit(1) }
        print("PASS: first and second native Return preserve continuous parent-rendered alignment backgrounds")
    }

    static func checkNativeEditReentry(window: NSWindow) {
        let session = ComparisonSession(left: .init(text: "source"), right: .init(text: "source"))
        let state = TextEditorState(text: "source", side: .left, wrapLines: true)
        session.leftEditorState = state
        let binding = attach(state, side: .left, session: session, link: EditorScrollLink(), width: 450, window: window)
        defer { binding.disconnect(); state.scroll.removeFromSuperview() }
        // NSTextStorage reports characters before NSTextView publishes its
        // didChange notification. A layout-driven SwiftUI refresh in between
        // must not replay the still-old source over those native characters.
        state.editor.textStorage!.replaceCharacters(in: NSRange(location: 6, length: 0), with: "X")
        binding.refresh(text: "source", in: state.scroll)
        precondition(state.editor.string == "sourceX" && session.left.text == "source", "A refresh during native edit processing must preserve pending input")
        binding.textDidChange(Notification(name: NSText.didChangeNotification, object: state.editor))
        precondition(session.left.text == "sourceX" && !state.pendingNativeEdit)
        binding.refresh(text: "source", in: state.scroll)
        precondition(state.editor.string == "sourceX", "An obsolete SwiftUI text snapshot must not replace the current source")
        session.setText("external merge", side: .left)
        binding.refresh(text: session.left.text, in: state.scroll)
        precondition(state.editor.string == "external merge" && !state.pendingNativeEdit && !state.applyingModelText,
                     "A current external source change must still reach the native editor")
    }

    static func checkSearchEditing(window: NSWindow) async {
        let session = ComparisonSession(left: .init(text: "foo tail"), right: .init(text: "foo"))
        let left = TextEditorState(text: "foo tail", side: .left, wrapLines: true)
        let right = TextEditorState(text: "foo", side: .right, wrapLines: true)
        session.leftEditorState = left; session.rightEditorState = right
        let link = EditorScrollLink()
        let lc = attach(left, side: .left, session: session, link: link, width: 450, window: window)
        let rc = attach(right, side: .right, session: session, link: link, width: 450, window: window)
        defer { lc.disconnect(); rc.disconnect(); left.scroll.removeFromSuperview(); right.scroll.removeFromSuperview() }
        session.showSearch(); session.searchQuery = "foo"
        await settle(session)
        lc.refresh(text: session.left.text, in: left.scroll); rc.refresh(text: session.right.text, in: right.scroll)
        left.editor.setSelectedRange(NSRange(location: left.editor.string.utf16.count, length: 0))
        left.editor.insertText("X", replacementRange: left.editor.selectedRange())
        await settle(session)
        lc.refresh(text: session.left.text, in: left.scroll); rc.refresh(text: session.right.text, in: right.scroll)
        let expected = NSRange(location: "foo tailX".utf16.count, length: 0)
        if left.editor.selectedRange() != expected {
            print("FAIL: Search refresh moved typing caret to \(left.editor.selectedRange()); source=\(left.editor.string)")
            exit(1)
        }
        left.editor.insertText("Y", replacementRange: left.editor.selectedRange())
        precondition(session.left.text == "foo tailXY", "Continued typing must preserve earlier search matches")
    }

    static func settle(_ session: ComparisonSession) async {
        for _ in 0..<100 {
            if !session.calculating, !session.searching { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        preconditionFailure("Native editor search/comparison did not finish")
    }

    static func checkPair(_ a: String, _ b: String, width: CGFloat, wrap: Bool, window: NSWindow) {
        let session = ComparisonSession(left: .init(text: a), right: .init(text: b))
        session.wrapLines = wrap
        let left = TextEditorState(text: a, side: .left, wrapLines: wrap), right = TextEditorState(text: b, side: .right, wrapLines: wrap)
        session.leftEditorState = left; session.rightEditorState = right
        let link = EditorScrollLink()
        let lc = attach(left, side: .left, session: session, link: link, width: width, window: window)
        let rc = attach(right, side: .right, session: session, link: link, width: width - 37, window: window)
        defer { lc.disconnect(); rc.disconnect(); left.scroll.removeFromSuperview(); right.scroll.removeFromSuperview() }
        let result = TextDiffEngine.compare(a, b)
        session.result = result; session.calculating = false
        if wrap {
            // During first mount, the native ruler can be installed after a
            // saved clip origin of zero. Alignment must not restore that origin
            // over the native horizontal reservation when it reflows the text.
            left.scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        }
        lc.refresh(text: a, in: left.scroll); rc.refresh(text: b, in: right.scroll)
        link.alignment.update(session: session)
        precondition(link.alignment.isAligned)
        if wrap, !a.isEmpty {
            let first = left.editor.layoutManager!.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: left.editor.textContainer!)
                .offsetBy(dx: left.editor.textContainerOrigin.x, dy: left.editor.textContainerOrigin.y)
            let x = left.editor.convert(first, to: left.scroll).minX
            let rulerRight = left.ruler.convert(left.ruler.bounds, to: left.scroll).maxX
            if x < rulerRight + 5 {
                print("FAIL: First aligned glyph must clear the parent scroll ruler: x=\(x), ruler=\(rulerRight)")
                exit(1)
            }
        }
        for row in result.rows {
            if let l = row.leftLine, let r = row.rightLine {
                let ly = lineY(left, line: l), ry = lineY(right, line: r)
                if abs(ly - ry) >= 0.5 {
                    print("FAIL: Unaligned line \(l)/\(r): \(ly) vs \(ry), width=\(width), wrap=\(wrap), containers=\(left.editor.textContainer!.containerSize)/\(right.editor.textContainer!.containerSize)")
                    exit(1)
                }
            }
        }
        if wrap {
            left.scroll.frame.size.width -= 28
            left.scroll.layoutSubtreeIfNeeded()
            lc.refresh(text: a, in: left.scroll)
            for row in result.rows {
                if let l = row.leftLine, let r = row.rightLine {
                    let ly = lineY(left, line: l), ry = lineY(right, line: r)
                    if abs(ly - ry) >= 0.5 {
                        print("FAIL: Resize alignment line \(l)/\(r): \(ly)/\(ry); width=\(width), containers=\(left.editor.textContainer!.containerSize)/\(right.editor.textContainer!.containerSize), text=\(a.prefix(40))")
                        exit(1)
                    }
                }
            }
        }
        precondition(left.editor.string.utf16.elementsEqual(a.utf16) && right.editor.string.utf16.elementsEqual(b.utf16), "Alignment must preserve source UTF-16")
        precondition(abs(left.editor.frame.height - right.editor.frame.height) < 1, "Both documents must retain trailing blank display rows")
        precondition(!left.undoManager.canUndo && !right.undoManager.canUndo, "Display alignment must not create undo actions")
        let leftSelection = NSRange(location: min(2, a.utf16.count), length: 0)
        left.editor.setSelectedRange(leftSelection)
        session.alignDifferences = false
        lc.refresh(text: a, in: left.scroll); rc.refresh(text: b, in: right.scroll)
        precondition(!link.alignment.isAligned && left.editor.selectedRange() == leftSelection, "Alignment toggle must preserve native selection")
        session.alignDifferences = true
        lc.refresh(text: a, in: left.scroll); rc.refresh(text: b, in: right.scroll)
        session.showDeletions = true
        lc.refresh(text: a, in: left.scroll)
        precondition(!link.alignment.isAligned, "Deletion projection must use its original source mapping")
    }

    static func checkEditing(window: NSWindow) {
        let a = "head\nold\n" + (0..<80).map { "line \($0)\n" }.joined()
        let b = "head\nnew\ninserted\n" + (0..<80).map { $0 == 45 ? "changed 45\n" : "line \($0)\n" }.joined()
        let session = ComparisonSession(left: .init(text: a), right: .init(text: b))
        let left = TextEditorState(text: a, side: .left, wrapLines: true), right = TextEditorState(text: b, side: .right, wrapLines: true)
        session.leftEditorState = left; session.rightEditorState = right
        let link = EditorScrollLink()
        let lc = attach(left, side: .left, session: session, link: link, width: 450, window: window)
        let rc = attach(right, side: .right, session: session, link: link, width: 450, window: window)
        defer { lc.disconnect(); rc.disconnect(); left.scroll.removeFromSuperview(); right.scroll.removeFromSuperview() }
        session.result = TextDiffEngine.compare(a, b); session.calculating = false
        lc.refresh(text: a, in: left.scroll); rc.refresh(text: b, in: right.scroll)
        left.scroll.contentView.scroll(to: NSPoint(x: left.scroll.contentView.bounds.minX, y: 350))
        link.synchronize(from: .left, session: session)
        precondition(abs(left.scroll.contentView.bounds.minY - right.scroll.contentView.bounds.minY) < 1)
        right.editor.setSelectedRange((b as NSString).range(of: "changed 45"))
        precondition(session.selectedHunk == 1, "Selecting a later difference must target its merge hunk")
        right.editor.setSelectedRange(NSRange(location: 5, length: 3))
        precondition(session.selectedHunk == 0)
        right.undoManager.groupsByEvent = false; right.undoManager.beginUndoGrouping()
        right.editor.insertText("新🧑‍💻", replacementRange: NSRange(location: 5, length: 3))
        right.undoManager.endUndoGrouping()
        precondition(session.right.text.contains("新🧑‍💻") && session.left.text == a)
        right.undoManager.undo()
        precondition(session.right.text == b && session.left.text == a, "Undo must restore exact source independently")
        right.undoManager.beginUndoGrouping()
        right.editor.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 5, length: 0))
        link.alignment.update(session: session)
        precondition(right.editor.hasMarkedText(), "Alignment must not interrupt marked text")
        right.editor.unmarkText(); right.undoManager.endUndoGrouping()
        precondition(session.right.text.contains("你"))
    }

    static func attach(_ state: TextEditorState, side: Side, session: ComparisonSession, link: EditorScrollLink, width: CGFloat, window: NSWindow) -> NativeTextEditor.Coordinator {
        state.scroll.frame = NSRect(x: side == .left ? 0 : 450, y: 0, width: width, height: 450)
        window.contentView!.addSubview(state.scroll); state.scroll.layoutSubtreeIfNeeded()
        let view = NativeTextEditor(text: session.value(side).text, side: side, session: session, scrollLink: link,
                                    onChange: { [weak session] in session?.setText($0, side: side) })
        let coordinator = view.makeCoordinator(); coordinator.bind(to: state); link.register(state.scroll, side: side)
        coordinator.refresh(text: state.editor.string, in: state.scroll)
        return coordinator
    }

    static func lineY(_ state: TextEditorState, line: Int) -> CGFloat {
        let range = sourceLineRanges(state.editor.string)[line]
        let layout = state.editor.layoutManager!, container = state.editor.textContainer!
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: range.location)
        return layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).minY + state.editor.textContainerOrigin.y
    }
}
