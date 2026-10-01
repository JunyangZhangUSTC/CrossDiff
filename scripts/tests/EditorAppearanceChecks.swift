import AppKit
import SwiftUI
import CrossDiffCore

@MainActor
func runEditorAppearanceChecks(in window: NSWindow) async {
    let original = "Alpha old\nSecond line\n文本对比 2025"
    let modified = "Alpha new\nSecond line\n文本对比 2026"
    for theme in [ComparisonTheme.light, .dark] {
        for side in [Side.left, .right] {
            let desired = side == .left ? original : modified
            let peer = side == .left ? modified : original
            let session = ComparisonSession()
            session.setText(peer, side: side == .left ? .right : .left)
            let state = TextEditorState(text: "", side: side, wrapLines: true)
            if side == .left { session.leftEditorState = state } else { session.rightEditorState = state }
            let binding = EditorStateChecks.coordinator(session, side, state, EditorScrollLink())
            binding.refresh(text: "", in: state.scroll, theme: theme)
            checkEditorContrast(state, theme: theme, label: "unmounted")
            // The requested palette must remain readable even when mounting crosses appearances.
            window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            EditorStateChecks.attach(state, x: 0, to: window)
            state.scroll.tile()
            binding.refresh(text: "", in: state.scroll, theme: theme)
            checkEditorContrast(state, theme: theme, label: "mounted")

            state.editor.insertText(desired, replacementRange: NSRange(location: 0, length: 0))
            await waitForEditorComparison(session)
            binding.refresh(text: session.value(side).text, in: state.scroll, theme: theme)
            checkEditorContrast(state, theme: theme, label: "plain input")
            checkEditorHighlights(state, session: session, side: side, theme: theme)
            checkEditorPixels(state, theme: theme, side: side, label: theme.isDark ? "dark" : "light")

            // This is a real NSTextInputClient attributed-input path, not a global pasteboard edit.
            // Equal source characters intentionally do not publish a new session revision.
            let revision = side == .left ? session.leftRevision : session.rightRevision
            state.editor.insertText(NSAttributedString(string: desired, attributes: [.foregroundColor: NSColor.white, .backgroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 72)]),
                                    replacementRange: NSRange(location: 0, length: state.editor.string.utf16.count))
            precondition(revision == (side == .left ? session.leftRevision : session.rightRevision))
            checkEditorContrast(state, theme: theme, label: "same-string white attributed input")
            checkEditorHighlights(state, session: session, side: side, theme: theme)

            let changedTheme: ComparisonTheme = theme.isDark ? .light : .dark
            window.appearance = NSAppearance(named: changedTheme.isDark ? .darkAqua : .aqua)
            let selection = NSRange(location: 2, length: 5)
            state.editor.setSelectedRange(selection)
            let couldUndo = state.undoManager.canUndo
            binding.refresh(text: desired, in: state.scroll, theme: changedTheme)
            precondition(state.editor.selectedRange() == selection && state.editor.string == desired)
            precondition(state.undoManager.canUndo == couldUndo, "Theme normalization must preserve undo availability")
            checkEditorContrast(state, theme: changedTheme, label: "theme change")
            checkEditorHighlights(state, session: session, side: side, theme: changedTheme)

            state.editor.insertText(peer, replacementRange: NSRange(location: 0, length: state.editor.string.utf16.count))
            await waitForEditorComparison(session)
            binding.refresh(text: peer, in: state.scroll, theme: changedTheme)
            precondition(session.result!.hunks.isEmpty)
            let layout = state.editor.layoutManager!
            for index in 0..<state.editor.string.utf16.count {
                precondition(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) == nil)
                precondition(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) == nil,
                             "Returning to equal text must clear old difference backgrounds")
            }

            state.editor.setMarkedText("中文输入已提交。", selectedRange: NSRange(location: 8, length: 0),
                                       replacementRange: NSRange(location: 0, length: state.editor.string.utf16.count))
            state.editor.unmarkText()
            await waitForEditorComparison(session)
            binding.refresh(text: session.value(side).text, in: state.scroll, theme: changedTheme)
            precondition(session.value(side).text == "中文输入已提交。")
            checkEditorContrast(state, theme: changedTheme, label: "IME commit")
            checkEditorHighlights(state, session: session, side: side, theme: changedTheme)

            binding.disconnect(); state.scroll.removeFromSuperview()
        }
    }
    await checkRestoredEditor(in: window, original: original, modified: modified)
    await checkPrivatePasteboard(in: window)
    print("Appearance checks passed: actual plain/attributed/IME input → asynchronous session diff → editor highlights, equal/different transitions, themes, and glyph pixels.")
}

@MainActor
private func waitForEditorComparison(_ session: ComparisonSession) async {
    for _ in 0..<100 {
        if !session.calculating, session.result != nil { return }
        try? await Task.sleep(nanoseconds: 30_000_000)
    }
    preconditionFailure("The actual ComparisonSession input-to-diff pipeline did not finish")
}

@MainActor
private func editorRGBA(_ color: NSColor, appearance: NSAppearance) -> [Double] {
    var components = [Double]()
    appearance.performAsCurrentDrawingAppearance {
        let rgb = color.usingColorSpace(.sRGB)!
        components = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent), Double(rgb.alphaComponent)]
    }
    return components
}

@MainActor
private func editorContrast(_ foreground: NSColor, _ background: NSColor, appearance: NSAppearance) -> Double {
    func luminance(_ color: NSColor) -> Double {
        let values = editorRGBA(color, appearance: appearance).prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }
    let a = luminance(foreground), b = luminance(background)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

@MainActor
private func checkEditorContrast(_ state: TextEditorState, theme: ComparisonTheme, label: String) {
    let editor = state.editor, appearance = state.editor.effectiveAppearance
    precondition(editorContrast(editor.textColor!, editor.backgroundColor, appearance: appearance) >= 4.5, "Unclear editor text: \(label)")
    precondition(editorContrast(editor.typingAttributes[.foregroundColor] as! NSColor, editor.backgroundColor, appearance: appearance) >= 4.5,
                 "Unclear typing color: \(label)")
    precondition(editorContrast(editor.insertionPointColor, editor.backgroundColor, appearance: appearance) >= 4.5)
    precondition(editorContrast(editor.selectedTextAttributes[.foregroundColor] as! NSColor,
                                editor.selectedTextAttributes[.backgroundColor] as! NSColor, appearance: appearance) >= 4.5)
    let storage = editor.textStorage!
    storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        precondition(editorContrast(value as! NSColor, editor.backgroundColor, appearance: appearance) >= 4.5,
                     "Stored characters became unreadable: \(label)")
    }
    storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        precondition(value == nil, "Input presentation backgrounds must not survive in a plain text editor")
    }
    storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        precondition((value as? NSFont)?.pointSize == 15, "Attributed input must keep the editor's 15pt typography")
    }
    storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
        precondition((value as? NSParagraphStyle)?.lineSpacing == 4)
    }
    precondition(editorRGBA(editor.backgroundColor, appearance: appearance) == editorRGBA(theme.canvas, appearance: appearance))
    precondition(!editor.usesAdaptiveColorMappingForDarkAppearance)
}

@MainActor
private func checkEditorHighlights(_ state: TextEditorState, session: ComparisonSession, side: Side, theme: ComparisonTheme) {
    let result = session.result!, layout = state.editor.layoutManager!, removal = side == .left
    precondition(!session.calculating && !result.hunks.isEmpty, "Different committed input must reach the UI")
    var highlighted = 0
    for row in result.rows {
        for range in side == .left ? row.leftHighlights : row.rightHighlights {
            guard range.length > 0 else { continue }
            let foreground = layout.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor
            let background = layout.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor
            precondition(foreground != nil && background != nil, "Actual NSLayoutManager is missing difference styling")
            precondition(editorRGBA(foreground!, appearance: state.editor.effectiveAppearance) == editorRGBA(theme.differenceForeground(isRemoval: removal), appearance: state.editor.effectiveAppearance))
            precondition(editorContrast(foreground!, background!, appearance: state.editor.effectiveAppearance) >= 4.5)
            highlighted += 1
        }
    }
    precondition(highlighted > 0, "Changed characters must have actual temporary highlight attributes")
}

@MainActor
private func checkEditorPixels(_ state: TextEditorState, theme: ComparisonTheme, side: Side, label: String) {
    let editor = state.editor
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    editor.layoutManager!.ensureLayout(for: editor.textContainer!)
    let rect = NSRect(x: 0, y: 0, width: min(440, editor.bounds.width), height: min(130, editor.bounds.height))
    let bitmap = editor.bitmapImageRepForCachingDisplay(in: rect)!
    editor.cacheDisplay(in: rect, to: bitmap)
    let body = editorRGBA(theme.text, appearance: editor.effectiveAppearance)
    let canvas = editorRGBA(theme.canvas, appearance: editor.effectiveAppearance)
    func luminance(_ values: [Double]) -> Double {
        let linear = values.prefix(3).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
    let backgroundLuminance = luminance(canvas)
    var bodyPixels = 0, differencePixels = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
            let values = editorRGBA(pixel, appearance: editor.effectiveAppearance)
            if zip(values.prefix(3), body.prefix(3)).allSatisfy({ abs($0 - $1) < 0.12 }) { bodyPixels += 1 }
            // Display-profile conversion and anti-aliasing need not produce a
            // pixel equal to the requested sRGB color. Exact attributes are
            // checked above; pixels must show readable red/green glyphs, not
            // merely a tinted background or a neutral text run.
            let colored = side == .left
                ? values[0] > values[1] + 0.10 && values[0] > values[2] + 0.10
                : values[1] > values[0] + 0.06 && values[1] > values[2] + 0.04
            let value = luminance(values)
            let contrast = (max(value, backgroundLuminance) + 0.05) / (min(value, backgroundLuminance) + 0.05)
            if colored && contrast >= 4.5 { differencePixels += 1 }
        }
    }
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build-editor-checks/appearance-\(label)-\(side == .left ? "left" : "right").png")
    try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
    print("Editor pixels \(label)/\(side): body=\(bodyPixels), readable colored glyphs=\(differencePixels), colorSpace=\(bitmap.colorSpace)")
    fflush(stdout)
    precondition(bodyPixels > 10, "No readable body glyph pixels in \(label)")
    precondition(differencePixels > 5, "Difference attributes exist but no colored glyph pixels were painted in \(label)")
}

@MainActor
private func checkRestoredEditor(in window: NSWindow, original: String, modified: String) async {
    let session = ComparisonSession(left: .init(text: original, savedText: original), right: .init(text: modified, savedText: modified))
    let state = TextEditorState(text: original, side: .left, wrapLines: true)
    session.leftEditorState = state
    let binding = EditorStateChecks.coordinator(session, .left, state, EditorScrollLink())
    binding.refresh(text: original, in: state.scroll, theme: .light)
    EditorStateChecks.attach(state, x: 0, to: window)
    await waitForEditorComparison(session)
    binding.refresh(text: original, in: state.scroll, theme: .light)
    checkEditorContrast(state, theme: .light, label: "restored prefilled text")
    checkEditorHighlights(state, session: session, side: .left, theme: .light)
    binding.disconnect(); state.scroll.removeFromSuperview()
}

@MainActor
private func checkPrivatePasteboard(in window: NSWindow) async {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    guard board.setString("Pasted text from a private test pasteboard", forType: .string) else {
        print("Private pasteboard access unavailable; general system clipboard was not touched.")
        return
    }
    let session = ComparisonSession(right: .init(text: "Different"))
    let state = TextEditorState(text: "", side: .left, wrapLines: true)
    session.leftEditorState = state
    EditorStateChecks.attach(state, x: 0, to: window)
    let binding = EditorStateChecks.coordinator(session, .left, state, EditorScrollLink())
    binding.refresh(text: "", in: state.scroll, theme: .light)
    window.makeFirstResponder(state.editor)
    guard state.editor.readSelection(from: board, type: .string) else {
        print("Private pasteboard import is unavailable in this process; attributed and plain NSTextInputClient input paths are verified separately.")
        binding.disconnect(); state.scroll.removeFromSuperview(); return
    }
    // readSelection is the import primitive; paste: normally issues didChangeText afterward.
    state.editor.didChangeText()
    await waitForEditorComparison(session)
    binding.refresh(text: session.left.text, in: state.scroll, theme: .light)
    checkEditorContrast(state, theme: .light, label: "private pasteboard")
    checkEditorHighlights(state, session: session, side: .left, theme: .light)
    binding.disconnect(); state.scroll.removeFromSuperview()
    print("Private pasteboard string import and resulting UI highlights passed.")
}
