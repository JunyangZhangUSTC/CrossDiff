import AppKit
import CrossDiffCore

/// Exercises Return through the shipping window/editor lifecycle. All source
/// text is synthetic, and the launcher isolates preferences and session writes.
@MainActor
enum NewlineWorkflowChecks {
    typealias D = DeletionPreviewChecks

    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-newline-workflow-checks/") == true,
              ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]?.contains(".build-newline-workflow-checks/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty
                ? "PASS: first and second native Return, full-window aligned background continuity, independent undo/redo, cross-newline native selection, light/dark and 1220/860-point windows"
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
        // The repeated ending keeps the first split paragraph paired with the
        // original logical line. A second Return exercises the native newline
        // background path that previously painted only half the padding width.
        let prefix = String(repeating: "A green leaf ", count: 8)
        let suffix = String(repeating: "Distant flowers ", count: 8) + prefix
        let original = prefix + suffix
        for dark in [false, true] {
            for width in [1220, 860] {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async {
                        AppAppearance.shared.isDark = dark
                        D.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        D.window.setFrame(NSRect(x: -10000, y: -10000, width: width, height: 790), display: true)
                        D.window.contentView?.layoutSubtreeIfNeeded()
                        continuation.resume()
                    }
                }
                let session = try await D.mount(left: original, right: original)
                session.wrapLines = true; session.alignDifferences = true
                try await D.pause()
                let editor = session.rightEditorState!.editor
                let undo = session.rightEditorState!.undoManager
                undo.groupsByEvent = false; undo.removeAllActions()
                D.window.makeFirstResponder(editor)
                editor.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
                for count in 1...2 {
                    editor.breakUndoCoalescing(); undo.beginUndoGrouping()
                    editor.insertNewline(nil)
                    editor.breakUndoCoalescing(); undo.endUndoGrouping()
                    let expected = prefix + String(repeating: "\n", count: count) + suffix
                    try await D.wait("native Return \(count) reaches comparison") {
                        !session.calculating && session.right.text == expected && editor.string == expected
                    }
                    try await D.pause()
                    let name = "newline-\(count)-\(dark ? "dark" : "light")-\(width)-window"
                    D.check(session.left.text.utf16.elementsEqual(original.utf16), "\(name): left source is unchanged")
                    D.check(session.right.text.utf16.elementsEqual(expected.utf16), "\(name): Return only inserts the requested newline")
                    try await inspect(session, firstLineEnd: prefix.utf16.count, name: name)
                }
                let variant = "\(dark ? "dark" : "light")-\(width)"
                try await checkCrossNewlineSelection(session, firstLineEnd: prefix.utf16.count, name: variant)
                for count in [1, 0] {
                    D.check(undo.canUndo, "\(variant): each Return has an independent undo action")
                    undo.undo()
                    let expected = prefix + String(repeating: "\n", count: count) + suffix
                    try await D.wait("undo Return to \(count)") {
                        !session.calculating && session.right.text == expected && editor.string == expected
                    }
                    D.check(session.left.text == original, "\(variant): undo never changes left source")
                }
                D.check(!undo.canUndo, "\(variant): undoing both Returns restores the initial text without presentation undo actions")
                for count in 1...2 {
                    D.check(undo.canRedo, "\(variant): each Return can be redone")
                    undo.redo()
                    let expected = prefix + String(repeating: "\n", count: count) + suffix
                    try await D.wait("redo Return to \(count)") {
                        !session.calculating && session.right.text == expected && editor.string == expected
                    }
                }
                try await D.pause()
                D.check(!session.leftEditorState!.undoManager.canUndo, "\(variant): left undo history remains independent")
                try await inspect(session, firstLineEnd: prefix.utf16.count, name: "newline-redo-\(variant)-window")
            }
        }
    }

    static func checkCrossNewlineSelection(_ session: ComparisonSession, firstLineEnd: Int, name: String) async throws {
        let editor = session.rightEditorState!.editor
        let layout = editor.layoutManager!, container = editor.textContainer!
        layout.ensureLayout(for: container)
        guard let parent = D.window.contentView?.superview else { throw D.CheckError(description: "No selection parent") }
        // Sample actual spaces on each side of the two source newlines, within
        // the native glyph rows, so text antialiasing cannot mimic a background.
        let positions = [firstLineEnd - 1, firstLineEnd + 2 + 7]
        let points: [NSPoint] = positions.map { character in
            let glyph = layout.glyphIndexForCharacter(at: character)
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let glyphLocation = layout.location(forGlyphAt: glyph)
            return editor.convert(NSPoint(x: editor.textContainerOrigin.x + fragment.minX + glyphLocation.x + 3,
                                          y: editor.textContainerOrigin.y + used.minY + 2), to: parent)
        }
        let baseline = try D.capture(parent, rect: parent.bounds, name: "newline-selection-before-\(name)")
        let range = NSRange(location: firstLineEnd - 5, length: 5 + 2 + 10)
        D.window.makeFirstResponder(editor); editor.setSelectedRange(range)
        try await D.pause()
        D.check(editor.selectedRange() == range, "\(name): native selection crosses both source newlines")
        let selected = try D.capture(parent, rect: parent.bounds, name: "newline-selection-\(name)")
        for (index, point) in points.enumerated() {
            func color(_ bitmap: NSBitmapImageRep) -> NSColor? {
                let x = Int((point.x - parent.bounds.minX) * CGFloat(bitmap.pixelsWide) / parent.bounds.width)
                let y = parent.isFlipped ? point.y - parent.bounds.minY : parent.bounds.maxY - point.y
                let row = Int(y * CGFloat(bitmap.pixelsHigh) / parent.bounds.height)
                guard x >= 0 && row >= 0 && x < bitmap.pixelsWide && row < bitmap.pixelsHigh else { return nil }
                return bitmap.colorAt(x: x, y: row)?.usingColorSpace(.sRGB)
            }
            guard let before = color(baseline), let after = color(selected) else {
                D.check(false, "\(name): selected glyph-row sample \(index) must remain inside the parent window")
                continue
            }
            let change = max(abs(before.redComponent - after.redComponent),
                             abs(before.greenComponent - after.greenComponent),
                             abs(before.blueComponent - after.blueComponent))
            D.check(change > 0.03, "\(name): selection background remains visible on source row \(index) (change=\(change))")
        }
        editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    }

    static func inspect(_ session: ComparisonSession, firstLineEnd: Int, name: String) async throws {
        let state = session.rightEditorState!, editor = state.editor
        let layout = editor.layoutManager!, container = editor.textContainer!
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: firstLineEnd - 1)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let gap = fragment.maxY - used.maxY
        D.check(gap > 30, "\(name): fixture exercises a large wrapped-line alignment gap (\(gap))")
        let sampleY = used.maxY + gap / 2 + editor.textContainerOrigin.y
        let sampleRect = NSRect(x: editor.textContainerOrigin.x + fragment.minX + 14, y: sampleY - 2,
                                width: max(1, fragment.width - 28), height: 4)
        if !editor.visibleRect.contains(sampleRect) {
            editor.scrollToVisible(sampleRect)
            try await D.pause()
        }
        guard let parent = D.window.contentView?.superview else { throw D.CheckError(description: "No complete native window") }
        parent.layoutSubtreeIfNeeded(); parent.displayIfNeeded()
        let bitmap = try D.capture(parent, rect: parent.bounds, name: name)
        guard gap > 30 else {
            D.log("\(name): invalid fixture geometry; fragment=\(fragment), used=\(used)")
            return
        }
        func sample(x: CGFloat) -> NSColor? {
            let point = editor.convert(NSPoint(x: x + editor.textContainerOrigin.x, y: sampleY), to: parent)
            let px = Int((point.x - parent.bounds.minX) * CGFloat(bitmap.pixelsWide) / parent.bounds.width)
            let y = parent.isFlipped ? point.y - parent.bounds.minY : parent.bounds.maxY - point.y
            let py = Int(y * CGFloat(bitmap.pixelsHigh) / parent.bounds.height)
            guard px >= 0 && py >= 0 && px < bitmap.pixelsWide && py < bitmap.pixelsHigh else { return nil }
            return bitmap.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
        }
        guard let leading = sample(x: fragment.minX + 14), let trailing = sample(x: fragment.maxX - 14) else {
            D.check(false, "\(name): alignment background samples must be visible in the composed native window")
            return
        }
        let distance = max(abs(leading.redComponent - trailing.redComponent),
                           abs(leading.greenComponent - trailing.greenComponent),
                           abs(leading.blueComponent - trailing.blueComponent))
        D.check(leading.alphaComponent > 0.99 && trailing.alphaComponent > 0.99,
                "\(name): parent background samples are opaque")
        D.check(distance <= 0.03,
                "\(name): no partial-width canvas block in aligned padding: leading=\(leading), trailing=\(trailing)")
        D.log("\(name): fragment=\(fragment), used=\(used), gap=\(gap), backgroundDistance=\(distance)")
    }
}
