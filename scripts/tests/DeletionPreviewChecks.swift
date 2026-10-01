import AppKit
import SwiftUI
import CrossDiffCore

// Integrates the real app scene, model, retained source editor and review editor.
// Images come from this process's views; no desktop/window capture API is used.
@MainActor
enum DeletionPreviewChecks {
    struct CheckError: Error { let description: String }
    static var window: NSWindow!
    static var report: [String] = []
    static var failures: [String] = []
    static var output: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]!)
    }

    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-deletion-preview-checks/") == true,
              ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]?.contains(".build-deletion-preview-checks/") == true else {
            fputs("Require isolated .build-deletion-preview-checks directories.\n", stderr); exit(2)
        }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() }
            catch { failures.append("Interrupted: \(error)") }
            let verdict = failures.isEmpty ? "PASS: default off, source/dirty/undo retention, focus, red strike attributes and actual pixels, Unicode, empty-right, merge, wide/narrow/light/dark" : "FAIL: " + failures.joined(separator: "; ")
            report.append(verdict)
            try? report.joined(separator: "\n").write(to: output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            print(verdict)
            print("Actual native renders: \(output.path)")
            exit(failures.isEmpty ? 0 : 8)
        }
    }

    static func run() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await wait("own app window") {
            window = NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }
            return window != nil
        }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFront(nil)
        let left = "共同内容\n版本 old 🌊\n删掉这一行 👩🏽‍💻\n结尾 e\u{301}\n"
        let right = "共同内容\n版本 new 🌊\n结尾 e\u{301}\n"
        let session = try await mount(left: left, right: right)
        log("Mounted default fixture")
        check(!session.showDeletions && session.deletionPreview == nil && previewScroll() == nil, "preview is off by default")
        let state = session.rightEditorState!, editor = state.editor, undo = state.undoManager
        check(editor.isEditable && editor.string == right && !session.dirty, "initial source remains editable and clean")
        window.makeFirstResponder(editor)
        undo.removeAllActions(); undo.groupsByEvent = false; undo.beginUndoGrouping()
        editor.insertText("编辑保留 🐈\n", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        editor.breakUndoCoalescing(); undo.endUndoGrouping()
        try await wait("source edit and diff") { !session.calculating && session.right.text.hasSuffix("编辑保留 🐈\n") }
        check(undo.canUndo && session.dirty, "real source edit creates undo and dirty state")
        let snapshot = try encoded(session), revision = session.rightRevision
        session.showDeletions = true
        try await ready(session)
        log("Preview enabled and rendered")
        check(try encoded(session) == snapshot && session.rightRevision == revision && session.dirty, "enable preserves source snapshot, revision and dirty state")
        check(session.rightEditorState === state && state.editor === editor && editor.window === window, "original source editor remains mounted")
        check(undo.canUndo, "enable preserves source undo stack")
        let preview = previewScroll()!.documentView as! NSTextView
        check(window.firstResponder === preview && session.focusSide == .right, "right-side focus transfers to review preview")
        check(preview.undoManager == nil, "review preview does not inherit source undo")
        let sourceSelection = (preview.string as NSString).range(of: "结尾")
        preview.setSelectedRange(sourceSelection)
        session.ignoreCase.toggle()
        try await ready(session)
        check((preview.string as NSString).substring(with: preview.selectedRange()) == "结尾", "option recomputation preserves preview source selection")
        session.ignoreCase.toggle()
        try await ready(session)
        if let review = preview as? PreviewTextView, let projection = session.deletionPreview {
            review.setSelectedRange(NSRange(location: 0, length: review.string.utf16.count))
            let copy = review.revisionRepresentation()
            check(copy?.plain == PreviewCopy.revisionText(from: projection, selection: review.selectedRange()), "native revision copy has explicit plain markers")
            if let data = copy?.rtf {
                let rich = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                // AppKit's RTF exporter normalizes e + combining acute to é.
                // Rich text must remain canonically equivalent; exact UTF-16 is
                // guaranteed separately by the plain-source representation.
                check(rich.string == projection.text, "rich copy preserves Unicode content")
                for range in projection.removedRanges {
                    check((rich.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue,
                          "rich copy retains real deletion strike attributes")
                }
            } else { check(false, "native rich revision representation exists") }
            review.setSelectedRange(NSRange(location: 0, length: 0))
        } else { check(false, "preview uses source-aware copy actions") }
        check(!session.snapshot.right.text.contains("删掉这一行"), "saved/session snapshot excludes projected deleted text")
        for (name, width, height, dark) in [("deletions-light-1220", 1220.0, 790.0, false),
                                           ("deletions-light-860", 860.0, 580.0, false),
                                           ("deletions-dark-1220", 1220.0, 790.0, true)] {
            try await stage(name, session: session, width: width, height: height, dark: dark)
        }
        check(try encoded(session) == snapshot, "resize and theme changes preserve source snapshot")
        session.showDeletions = false
        try await wait("preview disabled") { session.deletionPreview == nil && previewScroll() == nil }
        try await pause()
        check(session.rightEditorState === state && editor.isEditable && undo.canUndo, "disable restores original editable source and undo")
        check(window.firstResponder === editor && session.focusSide == .right, "disable restores original right focus")
        check(try encoded(session) == snapshot, "disable does not alter saved source data")
        undo.undo()
        try await wait("retained undo") { session.right.text == right && !session.calculating }
        check(!session.dirty && editor.string == right, "undo after toggling restores clean original source")

        let empty = try await mount(left: "全被删除 👩🏽‍💻\n第二行 e\u{301}\n", right: "")
        empty.showDeletions = true; try await ready(empty)
        check(empty.right.text.isEmpty && empty.rightEditorState?.editor.string.isEmpty == true, "empty-right source stays empty")
        check(!empty.dirty && empty.leftRevision == 0 && empty.rightRevision == 0, "enable on clean empty source does not mark it edited")
        check(empty.deletionPreview?.text.isEmpty == false, "empty-right preview includes deleted content")
        try await stage("deletions-empty-right-light", session: empty, width: 1220, height: 790, dark: false)
        try await stage("deletions-empty-right-dark-860", session: empty, width: 860, height: 580, dark: true)
        let saved = output.appendingPathComponent("saved-empty-source-\(UUID().uuidString).txt")
        empty.right.path = saved.path
        WorkspaceStore.shared.save(empty, side: .right)
        check(try Data(contentsOf: saved).isEmpty, "actual save writes empty source, never the visible deleted text")
        try await ready(empty)

        let merge = try await mount(left: "保留\n删除这一行 🧪\n结尾\n", right: "保留\n结尾\n")
        merge.showDeletions = true; try await ready(merge)
        check(merge.result?.hunks.count == 1 && merge.deletionPreview?.removedRanges.isEmpty == false, "merge fixture initially has one deletion")
        merge.merge(fromLeft: true)
        try await wait("merge recomputes preview") {
            !merge.calculating && merge.deletionPreview != nil && merge.deletionPreview?.removedRanges.isEmpty == true
        }
        try await ready(merge)
        check(merge.right.text == merge.left.text && merge.result?.hunks.isEmpty == true, "merge uses raw source and removes the actual diff")
        let mergedEditor = previewScroll()!.documentView as! NSTextView
        check(mergedEditor.string == merge.right.text, "preview refreshes after merge")
        var strikeRuns = 0
        mergedEditor.textStorage?.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: mergedEditor.string.utf16.count)) { value, _, _ in
            if ((value as? NSNumber)?.intValue ?? 0) != 0 { strikeRuns += 1 }
        }
        check(strikeRuns == 0, "merge clears obsolete deletion decorations")
    }

    static func mount(left: String, right: String) async throws -> ComparisonSession {
        let store = WorkspaceStore.shared
        let session = ComparisonSession(left: .init(text: left, savedText: left), right: .init(text: right, savedText: right))
        store.sessions.removeAll(); store.attach(session); store.selectedID = session.id; store.message = nil
        try await wait("mounted fixture") {
            session.leftEditorState?.editor.window === window && session.rightEditorState?.editor.window === window && !session.calculating
        }
        try await pause()
        return session
    }

    static func ready(_ session: ComparisonSession) async throws {
        do {
            try await wait("actual preview rendering") {
                guard let projection = session.deletionPreview,
                      let editor = previewScroll()?.documentView as? NSTextView else { return false }
                return editor.string.utf16.elementsEqual(projection.text.utf16)
            }
        } catch {
            log("Preview diagnostic: enabled=\(session.showDeletions), calculating=\(session.calculating), source=\(session.right.text.debugDescription), projection=\(session.deletionPreview?.text.debugDescription ?? "nil"), rendered=\((previewScroll()?.documentView as? NSTextView)?.string.debugDescription ?? "nil")")
            throw error
        }
        try await pause()
    }

    static func previewScroll() -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if view.identifier?.rawValue == "crossdiff-deletion-preview" { return view as? NSScrollView }
            for child in view.subviews { if let result = find(child) { return result } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    static func stage(_ name: String, session: ComparisonSession, width: Double, height: Double, dark: Bool) async throws {
        log("Starting \(name)")
        // Use the AppKit event queue, as a user toolbar action does. Appearance
        // changes synchronously enter SwiftUI's native control appearance hooks.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                AppAppearance.shared.isDark = dark
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setFrame(NSRect(x: -10000, y: -10000, width: width, height: height), display: true)
                window.contentView?.needsLayout = true; window.contentView?.layoutSubtreeIfNeeded()
                continuation.resume()
            }
        }
        try await pause()
        try await ready(session)
        guard let projection = session.deletionPreview, let scroll = previewScroll(),
              let editor = scroll.documentView as? NSTextView, let storage = editor.textStorage,
              let layout = editor.layoutManager, let container = editor.textContainer else {
            throw CheckError(description: "\(name): missing native preview")
        }
        let theme = ComparisonTheme(isDark: dark)
        check(!editor.isEditable && editor.isSelectable, "\(name): review is selectable and read-only")
        check(!projection.removedRanges.isEmpty, "\(name): fixture has deleted ranges")
        for range in projection.removedRanges {
            check(NSMaxRange(range) <= storage.length && range.length > 0, "\(name): deletion range is valid")
            guard range.length > 0 && NSMaxRange(range) <= storage.length else { continue }
            storage.enumerateAttributes(in: range) { attributes, subrange, _ in
                check((attributes[.strikethroughStyle] as? NSNumber)?.intValue == NSUnderlineStyle.single.rawValue,
                      "\(name): actual deleted run \(subrange) has a single strike")
                check(sameColor(attributes[.foregroundColor] as? NSColor, theme.differenceForeground(isRemoval: true)),
                      "\(name): actual deleted run uses red foreground")
                check(sameColor(attributes[.strikethroughColor] as? NSColor, theme.differenceForeground(isRemoval: true)),
                      "\(name): actual deleted run uses red strikethrough")
            }
        }
        let emoji = (projection.text as NSString).range(of: "👩🏽‍💻")
        if emoji.location != NSNotFound {
            check(projection.removedRanges.contains { NSIntersectionRange($0, emoji) == emoji }, "\(name): composed emoji is covered by a whole deletion range")
        }
        layout.ensureLayout(for: container)
        let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: min(1, layout.numberOfGlyphs)), in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        let inScroll = editor.convert(glyph, to: scroll)
        if let ruler = scroll.verticalRulerView {
            check(inScroll.minX >= ruler.convert(ruler.bounds, to: scroll).maxX, "\(name): text is clear of the line-number gutter")
        }
        check(editor.visibleRect.intersects(glyph), "\(name): first deleted/source line is actually visible")
        let top = NSRect(x: scroll.bounds.minX, y: scroll.isFlipped ? scroll.bounds.minY : scroll.bounds.maxY - min(200, scroll.bounds.height),
                         width: scroll.bounds.width, height: min(200, scroll.bounds.height))
        let bitmap = try capture(scroll, rect: top, name: name + "-preview")
        let pixels = countPixels(bitmap, background: theme.canvas)
        check(pixels.readable >= 30 && pixels.red >= 30, "\(name): parent-scroll bitmap contains visible text and red deletion pixels")
        if let full = window.contentView?.superview { _ = try capture(full, rect: full.bounds, name: name + "-window") }
        let removed = projection.removedRanges.map { (projection.text as NSString).substring(with: $0) }
        log("\(name): source right UTF16=\(session.right.text.utf16.count), preview=\(storage.length), deleted=\(removed), glyphInScroll=\(inScroll), readablePixels=\(pixels.readable), redPixels=\(pixels.red)")
    }

    static func capture(_ view: NSView, rect: NSRect, name: String) throws -> NSBitmapImageRep {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { throw CheckError(description: "No bitmap for \(name)") }
        view.cacheDisplay(in: rect, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CheckError(description: "No PNG for \(name)") }
        try data.write(to: output.appendingPathComponent(name + ".png"))
        return bitmap
    }

    static func countPixels(_ bitmap: NSBitmapImageRep, background: NSColor) -> (readable: Int, red: Int) {
        let base = luminance(background)
        var readable = 0, red = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                let value = luminance(c)
                if (max(base, value) + 0.05) / (min(base, value) + 0.05) > 4.5 { readable += 1 }
                if c.redComponent > c.greenComponent + 0.04 && c.redComponent > c.blueComponent + 0.04 { red += 1 }
            }
        }
        return (readable, red)
    }

    static func luminance(_ value: NSColor) -> Double {
        guard let c = value.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ v: CGFloat) -> Double { let d = Double(v); return d <= 0.04045 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    static func sameColor(_ value: NSColor?, _ expected: NSColor) -> Bool {
        guard let a = value?.usingColorSpace(.sRGB), let b = expected.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01 && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    static func encoded(_ session: ComparisonSession) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(session.snapshot)
    }

    static func wait(_ label: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !condition() {
            if Date() > deadline { throw CheckError(description: "Timeout: \(label)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    static func pause() async throws { try await Task.sleep(nanoseconds: 250_000_000) }
    static func check(_ value: Bool, _ description: String) {
        if !value { failures.append(description); log("FAIL: " + description) }
    }
    static func log(_ value: String) {
        report.append(value); print(value); fflush(stdout)
        try? report.joined(separator: "\n").write(to: output.appendingPathComponent("progress.txt"), atomically: true, encoding: .utf8)
    }
}
