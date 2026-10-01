import AppKit
import SwiftUI
import CrossDiffCore

@main
@MainActor
struct EditorStateChecks {
    static func main() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        let session = ComparisonSession()
        let link = EditorScrollLink()
        let left = TextEditorState(text: "", side: .left, wrapLines: true)
        let right = TextEditorState(text: "", side: .right, wrapLines: true)
        session.leftEditorState = left; session.rightEditorState = right
        attach(left, x: 0, to: window); attach(right, x: 450, to: window)
        let firstLeftCoordinator = coordinator(session, .left, left, link)
        let rightCoordinator = coordinator(session, .right, right, link)
        precondition(left.editor.undoManager !== right.editor.undoManager, "Each side needs independent undo")
        edit(left, replacement: "left")
        edit(right, replacement: "right")
        precondition(session.left.text == "left" && session.right.text == "right")
        window.makeFirstResponder(left.editor)
        left.editor.undoManager!.undo()
        precondition(session.left.text.isEmpty && session.right.text == "right", "Undo must modify only the focused side")
        left.editor.undoManager!.redo()
        precondition(session.left.text == "left")

        // Simulate SwiftUI removing and recreating a representable when switching tabs.
        NativeTextEditor.dismantleNSView(left.scroll, coordinator: firstLeftCoordinator)
        left.scroll.removeFromSuperview()
        precondition(firstLeftCoordinator.observer == nil && left.editor.delegate == nil)
        let restored = session.leftEditorState!
        precondition(restored === left)
        attach(restored, x: 0, to: window)
        let newLeftCoordinator = coordinator(session, .left, restored, link)
        NativeTextEditor.dismantleNSView(left.scroll, coordinator: firstLeftCoordinator)
        precondition(restored.editor.delegate === newLeftCoordinator, "Late dismantle must not clear the new delegate")
        precondition(newLeftCoordinator.observer != nil)
        restored.editor.undoManager!.undo()
        precondition(restored.editor.string.isEmpty && session.left.text.isEmpty && session.right.text == "right", "Undo after a tab switch must reach the current model")

        // Rebinding can also happen before the old representable is dismantled.
        let newestCoordinator = coordinator(session, .left, restored, link)
        precondition(newLeftCoordinator.observer == nil)
        NativeTextEditor.dismantleNSView(restored.scroll, coordinator: newLeftCoordinator)
        precondition(restored.editor.delegate === newestCoordinator)
        restored.editor.undoManager!.redo()
        precondition(session.left.text == "left")

        // A completed IME composition must continue to update the session after rebinding.
        right.undoManager.beginUndoGrouping()
        right.editor.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: right.editor.string.utf16.count, length: 0))
        right.editor.unmarkText()
        right.undoManager.endUndoGrouping()
        precondition(session.right.text == "right你")
        let previousSourceID = session.leftSourceID
        session.replace(.init(text: "new file"), side: .left, resetUndo: true)
        precondition(session.leftEditorState == nil && session.leftSourceID != previousSourceID)
        precondition(session.rightEditorState === right)
        NativeTextEditor.dismantleNSView(restored.scroll, coordinator: newestCoordinator)
        NativeTextEditor.dismantleNSView(right.scroll, coordinator: rightCoordinator)
        restored.scroll.removeFromSuperview(); right.scroll.removeFromSuperview()

        checkScrollGuards(in: window)
        await checkDeletionPreviewScroll(in: window)
        checkSessionRelease()
        await runEditorAppearanceChecks(in: window)
        print("Editor checks passed: independent undo, tab restoration, safe rebind/dismantle, IME, source reset, scroll guards, and session release.")
    }

    static func coordinator(_ session: ComparisonSession, _ side: Side, _ state: TextEditorState, _ link: EditorScrollLink) -> NativeTextEditor.Coordinator {
        let representable = NativeTextEditor(text: session.value(side).text, side: side, session: session, scrollLink: link,
                                             onChange: { [weak session] in session?.setText($0, side: side) })
        let coordinator = representable.makeCoordinator()
        coordinator.bind(to: state)
        link.register(state.scroll, side: side)
        return coordinator
    }

    static func attach(_ state: TextEditorState, x: CGFloat, to window: NSWindow) {
        state.scroll.frame = NSRect(x: x, y: 0, width: 450, height: 450)
        window.contentView!.addSubview(state.scroll)
        state.editor.frame.size.width = state.scroll.contentSize.width
    }

    static func edit(_ state: TextEditorState, replacement: String) {
        state.undoManager.groupsByEvent = false
        state.undoManager.beginUndoGrouping()
        state.editor.insertText(replacement, replacementRange: NSRange(location: 0, length: state.editor.string.utf16.count))
        state.editor.breakUndoCoalescing()
        state.undoManager.endUndoGrouping()
    }

    static func checkScrollGuards(in window: NSWindow) {
        let text = (0..<150).map { "line \($0)" }.joined(separator: "\n")
        let session = ComparisonSession(left: .init(text: text), right: .init(text: text))
        let a = TextEditorState(text: text, side: .left, wrapLines: true)
        let b = TextEditorState(text: text, side: .right, wrapLines: true)
        attach(a, x: 0, to: window); attach(b, x: 450, to: window)
        for state in [a, b] {
            state.editor.layoutManager!.ensureLayout(for: state.editor.textContainer!)
            state.editor.frame.size.height = 4_000
        }
        let link = EditorScrollLink(); link.register(a.scroll, side: .left); link.register(b.scroll, side: .right)
        session.result = TextDiffEngine.compare(text, text)
        session.calculating = true
        a.scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
        let original = b.scroll.contentView.bounds.origin
        link.synchronize(from: .left, session: session)
        precondition(b.scroll.contentView.bounds.origin == original, "An old diff must not drive scrolling during calculation")
        session.calculating = false
        a.editor.string = "new\n" + text
        link.synchronize(from: .left, session: session)
        precondition(b.scroll.contentView.bounds.origin == original, "A stale editor/model pair must not drive scrolling")
        a.editor.string = text
        a.scroll.contentView.scroll(to: NSPoint(x: 0, y: 250))
        link.synchronize(from: .left, session: session)
        precondition(b.scroll.contentView.bounds.minY > original.y, "Current matching texts should still synchronize")
        a.editor.string = ""; session.setText("", side: .left); session.calculating = false
        link.synchronize(from: .left, session: session)
        a.scroll.removeFromSuperview(); b.scroll.removeFromSuperview()
    }

    static func checkDeletionPreviewScroll(in window: NSWindow) async {
        var common = (0..<180).map { "common \($0)\n" }
        common[25] = "wrapped " + String(repeating: "中文🧑‍💻 ", count: 30) + "\n"
        let leftText = (Array(common[..<50]) + ["removed A\n", "removed B\n", "removed C\n"] + Array(common[50...])).joined()
        let rightText = (Array(common[..<100]) + ["added A\n", "added B\n", "added C\n"] + Array(common[100...])).joined()
        let session = ComparisonSession(left: .init(text: leftText), right: .init(text: rightText))
        session.showDeletions = true
        for _ in 0..<150 {
            if session.deletionPreview != nil && !session.calculating { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let projection = session.deletionPreview else { preconditionFailure("Deletion projection must finish") }
        let a = TextEditorState(text: leftText, side: .left, wrapLines: true)
        let hiddenRight = TextEditorState(text: rightText, side: .right, wrapLines: true)
        let review = TextEditorState(text: projection.text, side: .right, wrapLines: true)
        review.editor.isEditable = false
        for (state, x) in [(a, CGFloat(0)), (hiddenRight, 450), (review, 450)] {
            attach(state, x: x, to: window)
            state.scroll.layoutSubtreeIfNeeded()
            state.editor.layoutManager!.ensureLayout(for: state.editor.textContainer!)
            state.editor.sizeToFit()
        }
        hiddenRight.scroll.isHidden = true
        defer { for state in [a, hiddenRight, review] { state.scroll.removeFromSuperview() } }
        let link = EditorScrollLink()
        link.register(a.scroll, side: .left); link.register(hiddenRight.scroll, side: .right)
        link.registerPreview(review.scroll)

        func position(_ state: TextEditorState, _ needle: String) -> CGFloat {
            let range = (state.editor.string as NSString).range(of: needle)
            precondition(range.location != NSNotFound)
            let layout = state.editor.layoutManager!
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
            return layout.boundingRect(forGlyphRange: glyphs, in: state.editor.textContainer!).minY + state.editor.textContainerOrigin.y
        }
        func scroll(_ state: TextEditorState, _ needle: String) {
            state.scroll.contentView.scroll(to: NSPoint(x: state.scroll.contentView.bounds.minX, y: position(state, needle)))
        }
        func assertPosition(_ state: TextEditorState, _ needle: String, _ message: String) {
            let actual = state.scroll.contentView.bounds.minY, expected = position(state, needle)
            precondition(abs(actual - expected) < 1, "\(message): \(actual) != \(expected)")
        }

        // Deleted rows remain addressable, while the hidden editor stays put.
        let hiddenOrigin = hiddenRight.scroll.contentView.bounds.origin
        scroll(a, "wrapped ")
        a.scroll.contentView.scroll(to: NSPoint(x: a.scroll.contentView.bounds.minX, y: a.scroll.contentView.bounds.minY + 30))
        link.synchronize(from: .left, session: session)
        precondition(abs(review.scroll.contentView.bounds.minY - position(review, "wrapped ") - 30) < 1,
                     "Wrapped Unicode lines must preserve their within-line scroll offset")
        scroll(a, "removed B\n"); link.synchronize(from: .left, session: session)
        assertPosition(review, "removed B\n", "Left deletion must target its visible preview row")
        precondition(hiddenRight.scroll.contentView.bounds.origin == hiddenOrigin)
        scroll(a, "common 120\n"); link.synchronize(from: .left, session: session)
        assertPosition(review, "common 120\n", "Inserted preview rows must not shift the mapping")
        scroll(review, "removed C\n"); link.synchronizePreview(session: session)
        assertPosition(a, "removed C\n", "Preview deletion must return to its original left row")
        scroll(review, "added A\n"); link.synchronizePreview(session: session)
        assertPosition(a, "common 99\n", "Unmapped additions must use the nearest preceding left row")
        scroll(review, "added C\n"); link.synchronizePreview(session: session)
        assertPosition(a, "common 100\n", "Unmapped additions must use the nearest following left row")

        let leftOrigin = a.scroll.contentView.bounds.origin
        let reviewOrigin = review.scroll.contentView.bounds.origin
        scroll(hiddenRight, "common 140\n"); link.synchronize(from: .right, session: session)
        precondition(a.scroll.contentView.bounds.origin == leftOrigin && review.scroll.contentView.bounds.origin == reviewOrigin,
                     "Hidden editor notifications must not drive either visible side")
        session.calculating = true
        scroll(a, "common 130\n"); link.synchronize(from: .left, session: session)
        precondition(review.scroll.contentView.bounds.origin == reviewOrigin, "Pending comparisons must not move an old projection")
        session.calculating = false
        review.editor.string = "stale\n" + projection.text
        link.synchronize(from: .left, session: session)
        precondition(review.scroll.contentView.bounds.origin == reviewOrigin, "A stale projection view must not scroll")
        review.editor.string = projection.text
        link.unregisterPreview(hiddenRight.scroll)
        link.synchronize(from: .left, session: session)
        assertPosition(review, "common 130\n", "Late dismantling must not unregister the current preview")
        link.unregisterPreview(review.scroll)
        let disconnectedOrigin = review.scroll.contentView.bounds.origin
        scroll(a, "common 110\n"); link.synchronize(from: .left, session: session)
        precondition(review.scroll.contentView.bounds.origin == disconnectedOrigin, "A disconnected preview must not scroll")

        session.showDeletions = false
        link.registerPreview(review.scroll)
        let afterDisable = a.scroll.contentView.bounds.origin
        scroll(review, "common 70\n"); link.synchronizePreview(session: session)
        precondition(a.scroll.contentView.bounds.origin == afterDisable, "Disabled previews must not move the left editor")
        link.synchronize(from: .left, session: session)
        assertPosition(hiddenRight, "common 110\n", "Disabling preview must restore ordinary two-editor scrolling")
        session.showDeletions = true
        let pendingOrigin = review.scroll.contentView.bounds.origin
        scroll(a, "common 80\n"); link.synchronize(from: .left, session: session)
        precondition(review.scroll.contentView.bounds.origin == pendingOrigin, "A missing projection must not drive scrolling")
        print("Deletion preview scrolling passed: mapped/deleted/added rows, hidden editor isolation, stale/pending guards, and toggle/dismantle.")
    }

    static func checkSessionRelease() {
        weak var released: ComparisonSession?
        var retainedView: TextEditorState?
        autoreleasepool {
            let session = ComparisonSession()
            released = session
            let state = TextEditorState(text: "", side: .left, wrapLines: true)
            session.leftEditorState = state; retainedView = state
            let binding = coordinator(session, .left, state, EditorScrollLink())
            _ = binding
        }
        precondition(released == nil, "A cached editor must not retain its closed session")
        _ = retainedView
    }
}
