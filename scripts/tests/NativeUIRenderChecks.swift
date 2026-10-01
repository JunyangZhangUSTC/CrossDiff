import AppKit
import SwiftUI
import PDFKit
import CrossDiffCore

// Runs only in the independent check process, with project-local fixture data.
// Inspect actual editor geometry/attributes before rendering touches the views.
@MainActor
enum NativeUIRenderChecks {
    static var window: NSWindow?
    static var stage = 0
    static var failures: [String] = []
    static let inputStyle = ProcessInfo.processInfo.environment["CROSSDIFF_INPUT_STYLE"] ?? "plain"
    static let fixtureLeft = inputStyle == "ime-commit" ? "原始文本\n共同内容\n左边的版本" : "Alpha old\nSecond line\n文本对比：原始版本"
    static let fixtureRight = inputStyle == "ime-commit" ? "修改文本\n共同内容\n右边的版本" : "Alpha new\nSecond line\n文本对比：修改版本"
    static let cases: [(String, CGFloat, CGFloat, NSAppearance.Name)] = [
        ("text-light-1220", 1220, 790, .aqua),
        ("text-light-860", 860, 580, .aqua),
        ("text-dark-1220", 1220, 790, .darkAqua)
    ]
    static var output: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]!)
    }

    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-ui-checks") == true else {
            fputs("UI checks require an isolated .build-ui-checks data directory.\n", stderr)
            exit(2)
        }
        NSApp.setActivationPolicy(.accessory)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = WorkspaceStore.shared
        store.sessions.removeAll()
        let session = inputStyle == "prefilled"
            ? ComparisonSession(left: .init(text: fixtureLeft), right: .init(text: fixtureRight))
            : ComparisonSession()
        store.attach(session)
        store.selectedID = session.id
        store.message = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { findWindow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            fputs("Native UI capture timed out.\n", stderr); exit(3)
        }
    }

    static func findWindow() {
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && !($0 is NSPanel) }),
              let session = WorkspaceStore.shared.selected,
              let left = session.leftEditorState?.editor,
              let right = session.rightEditorState?.editor else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { findWindow() }; return
        }
        Self.window = window
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        // Exercise the same NSTextView/delegate path as pasting into an empty app.
        if inputStyle != "prefilled" {
            for (editor, text) in [(left, fixtureLeft), (right, fixtureRight)] {
                window.makeFirstResponder(editor)
                let input: Any = inputStyle == "white-attributed"
                    ? NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.white])
                    : text
                if inputStyle == "ime-commit" {
                    editor.setMarkedText("wenben", selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                } else {
                    editor.insertText(input, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                }
            }
        }
        renderNext()
    }

    static func renderNext() {
        guard stage < cases.count, let window else {
            let verdict = failures.isEmpty ? "PASS: model, diff, contrast, visible glyph geometry, readable text pixels and diff-color pixels" : "FAIL: " + failures.joined(separator: "; ")
            try? verdict.write(to: output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            print(verdict)
            print("Per-editor diagnostic renders and pre-capture measurements: \(output.path)")
            exit(failures.isEmpty ? 0 : 8)
        }
        let item = cases[stage]
        #if CROSSDIFF_EXPLICIT_THEME
        AppAppearance.shared.isDark = item.3 == .darkAqua
        #endif
        window.appearance = NSAppearance(named: item.3)
        window.setFrame(NSRect(x: -10000, y: -10000, width: item.1, height: item.2), display: true)
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { capture() }
    }

    static func capture() {
        guard let window, let view = window.contentView?.superview,
              let session = WorkspaceStore.shared.selected else { exit(4) }
        let item = cases[stage]
        var lines = ["Window: \(NSStringFromRect(window.frame)); native view: \(NSStringFromRect(view.bounds)); appearance=\(window.effectiveAppearance.name.rawValue)",
                     "Input style: \(inputStyle)",
                     "Session: left=\(session.left.text.utf16.count), right=\(session.right.text.utf16.count), calculating=\(session.calculating), hunks=\(session.result?.hunks.count ?? -1)"]
        check(!session.calculating, "\(item.0): diff still calculating")
        check(session.result?.hunks.isEmpty == false, "\(item.0): no diff result")
        for (name, state, expected) in [("left", session.leftEditorState, fixtureLeft), ("right", session.rightEditorState, fixtureRight)] {
            guard let state else { check(false, "\(item.0): missing \(name) editor"); continue }
            inspect(state, name: name, expected: expected, lines: &lines)
        }
        describe(view, depth: 0, lines: &lines)
        do {
            try lines.joined(separator: "\n").write(to: output.appendingPathComponent("\(item.0)-state-before.txt"), atomically: true, encoding: .utf8)
            for (name, state) in [("left", session.leftEditorState), ("right", session.rightEditorState)] {
                guard let state else { continue }
                let scroll = state.scroll
                let height = min(150, scroll.bounds.height)
                let top = NSRect(x: scroll.bounds.minX, y: scroll.isFlipped ? scroll.bounds.minY : scroll.bounds.maxY - height,
                                 width: scroll.bounds.width, height: height)
                if let bitmap = scroll.bitmapImageRepForCachingDisplay(in: top) {
                    scroll.cacheDisplay(in: top, to: bitmap)
                    inspectPixels(bitmap, editor: state.editor, name: name + " scroll", renderedHeight: top.height)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: output.appendingPathComponent("\(item.0)-\(name)-scroll-top.png"))
                    }
                }
                if ProcessInfo.processInfo.environment["CROSSDIFF_RULER_PROBE"] == "1" {
                    let oldHidden = state.ruler.isHidden, oldClips = state.ruler.clipsToBounds
                    for probe in ["ruler-hidden", "ruler-clipped"] {
                        state.ruler.isHidden = probe == "ruler-hidden"
                        state.ruler.clipsToBounds = probe == "ruler-clipped"
                        if let bitmap = scroll.bitmapImageRepForCachingDisplay(in: top) {
                            scroll.cacheDisplay(in: top, to: bitmap)
                            inspectPixels(bitmap, editor: state.editor, name: name + " " + probe, renderedHeight: top.height, assertPixels: false)
                            if let data = bitmap.representation(using: .png, properties: [:]) {
                                try data.write(to: output.appendingPathComponent("\(item.0)-\(name)-\(probe).png"))
                            }
                        }
                    }
                    state.ruler.isHidden = oldHidden
                    state.ruler.clipsToBounds = oldClips
                }
                let editor = state.editor
                let rect = editor.visibleRect
                if let bitmap = editor.bitmapImageRepForCachingDisplay(in: rect) {
                    editor.cacheDisplay(in: rect, to: bitmap)
                    inspectPixels(bitmap, editor: editor, name: name)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: output.appendingPathComponent("\(item.0)-\(name)-editor.png"))
                    }
                }
                let data = editor.dataWithPDF(inside: rect)
                try data.write(to: output.appendingPathComponent("\(item.0)-\(name)-editor.pdf"))
                if let document = PDFDocument(data: data), let page = document.page(at: 0),
                   let tiff = page.thumbnail(of: rect.size, for: .mediaBox).tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try png.write(to: output.appendingPathComponent("\(item.0)-\(name)-editor-pdf.png"))
                }
            }
            if let left = session.leftEditorState?.editor, let right = session.rightEditorState?.editor {
                try captureDetail(left: left, right: right, name: item.0)
            }
            if ProcessInfo.processInfo.environment["CROSSDIFF_CAPTURE_WINDOW"] == "1",
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: output.appendingPathComponent("\(item.0)-window.png"))
                }
            }
            var after: [String] = []
            for (name, state, expected) in [("left", session.leftEditorState, fixtureLeft), ("right", session.rightEditorState, fixtureRight)] {
                if let state { inspect(state, name: name, expected: expected, lines: &after, assertState: false) }
            }
            try after.joined(separator: "\n").write(to: output.appendingPathComponent("\(item.0)-state-after.txt"), atomically: true, encoding: .utf8)
            print("Captured \(item.0), session hunks=\(session.result?.hunks.count ?? -1)")
        } catch { fputs("\(error)\n", stderr); exit(7) }
        stage += 1
        renderNext()
    }

    static func inspect(_ state: TextEditorState, name: String, expected: String, lines: inout [String], assertState: Bool = true) {
        let editor = state.editor, scroll = state.scroll
        let storage = editor.textStorage!, layout = editor.layoutManager!, container = editor.textContainer!
        let used = layout.usedRect(for: container)
        let origin = editor.textContainerOrigin
        let ink = used.offsetBy(dx: origin.x, dy: origin.y)
        let visible = editor.visibleRect
        let range = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let firstGlyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: min(1, layout.numberOfGlyphs)), in: container).offsetBy(dx: origin.x, dy: origin.y)
        let firstInScroll = editor.convert(firstGlyph, to: scroll)
        let rulerInScroll = state.ruler.convert(state.ruler.bounds, to: scroll)
        var contrast: Double = 0
        var foregroundDescription = "", backgroundDescription = "", storedForegroundDescription = ""
        editor.effectiveAppearance.performAsCurrentDrawingAppearance {
            let foreground = editor.textColor ?? .textColor
            let background = editor.backgroundColor
            let stored = storage.length > 0 ? storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor : nil
            foregroundDescription = color(foreground)
            backgroundDescription = color(background)
            storedForegroundDescription = stored.map(color) ?? "nil"
            let l1 = luminance(stored ?? foreground), l2 = luminance(background)
            contrast = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }
        var highlightRuns = 0
        if storage.length > 0 {
            var position = 0
            while position < storage.length {
                var effective = NSRange()
                let value = layout.temporaryAttribute(.backgroundColor, atCharacterIndex: position, effectiveRange: &effective)
                if value != nil { highlightRuns += 1 }
                position = max(position + 1, NSMaxRange(effective))
            }
        }
        let attributes = storage.length > 0 ? storage.attributes(at: 0, effectiveRange: nil).description : "empty"
        lines += ["EDITOR \(name): chars=\(editor.string.utf16.count), storage=\(storage.length), glyphs=\(layout.numberOfGlyphs), appearance=\(editor.effectiveAppearance.name.rawValue)",
                  "frame=\(NSStringFromRect(editor.frame)); bounds=\(NSStringFromRect(editor.bounds)); visible=\(NSStringFromRect(visible)); ink=\(NSStringFromRect(ink)); visibleGlyphRange=\(range)",
                  "firstGlyphInScroll=\(NSStringFromRect(firstInScroll)); rulerInScroll=\(NSStringFromRect(rulerInScroll))",
                  "scroll frame=\(NSStringFromRect(scroll.frame)); clip frame=\(NSStringFromRect(scroll.contentView.frame)); clip bounds=\(NSStringFromRect(scroll.contentView.bounds)); documentRect=\(NSStringFromRect(scroll.contentView.documentRect)); contentSize=\(scroll.contentSize); insets=\(scroll.contentInsets)",
                  "container=\(container.containerSize); textOrigin=\(origin); font=\(String(describing: editor.font)); textColor=\(foregroundDescription); background=\(backgroundDescription); storedForeground=\(storedForegroundDescription); contrast=\(contrast)",
                  "hidden=\(editor.isHiddenOrHasHiddenAncestor); alpha=\(editor.alphaValue); drawsBackground=\(editor.drawsBackground); layerBacked=\(editor.wantsLayer); highlightRuns=\(highlightRuns)",
                  "attributes0=\(attributes)", "typingAttributes=\(editor.typingAttributes)"]
        if assertState {
            let prefix = "\(cases[stage].0) \(name)"
            check(editor.string.utf16.elementsEqual(expected.utf16), "\(prefix): text differs from pasted fixture")
            check(storage.length > 0 && layout.numberOfGlyphs > 0, "\(prefix): no drawable text")
            check(!visible.intersection(ink).isEmpty && range.length > 0, "\(prefix): glyphs outside visibleRect")
            check(range.location == 0 && range.length == layout.numberOfGlyphs, "\(prefix): initial fixture is clipped, visible glyph range \(range)")
            if scroll.rulersVisible && scroll.hasVerticalRuler {
                check(firstInScroll.minX >= rulerInScroll.maxX, "\(prefix): first glyph overlaps the line-number gutter")
            }
            check(contrast >= 4.5, "\(prefix): insufficient foreground/background contrast \(contrast)")
            check(!editor.isHiddenOrHasHiddenAncestor && editor.alphaValue > 0.9, "\(prefix): editor hidden/transparent")
            check(highlightRuns > 0, "\(prefix): no diff highlighting attributes")
        }
    }

    static func inspectPixels(_ bitmap: NSBitmapImageRep, editor: NSTextView, name: String, renderedHeight: CGFloat? = nil, assertPixels: Bool = true) {
        var backgroundLuminance = 1.0
        editor.effectiveAppearance.performAsCurrentDrawingAppearance { backgroundLuminance = luminance(editor.backgroundColor) }
        let scaleY = Double(bitmap.pixelsHigh) / max(1, Double(renderedHeight ?? editor.visibleRect.height))
        let rows = min(bitmap.pixelsHigh, Int(ceil(120 * scaleY)))
        var readablePixels = 0, tintedPixels = 0
        for y in stride(from: 0, to: rows, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let sample = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), sample.alphaComponent > 0.9 else { continue }
                let value = luminance(sample)
                let contrast = (max(value, backgroundLuminance) + 0.05) / (min(value, backgroundLuminance) + 0.05)
                if contrast > 4.5 { readablePixels += 1 }
                let r = sample.redComponent, g = sample.greenComponent, b = sample.blueComponent
                let diffTint = name.hasPrefix("left") ? (r > g + 0.04 && r > b + 0.04) : (g > r + 0.03 && g > b + 0.02)
                if diffTint { tintedPixels += 1 }
            }
        }
        let prefix = "\(cases[stage].0) \(name)"
        print("PIXELS \(prefix): readable=\(readablePixels), tinted=\(tintedPixels)")
        if assertPixels {
            check(readablePixels >= 30, "\(prefix): bitmap contains too few readable text pixels (\(readablePixels))")
            check(tintedPixels >= 30, "\(prefix): bitmap contains too few diff-color pixels (\(tintedPixels))")
        }
    }

    static func captureDetail(left: NSTextView, right: NSTextView, name: String) throws {
        var parts: [NSImage] = []
        for editor in [left, right] {
            var rect = editor.visibleRect
            rect.size.height = min(150, rect.height)
            guard let bitmap = editor.bitmapImageRepForCachingDisplay(in: rect) else { return }
            editor.cacheDisplay(in: rect, to: bitmap)
            let image = NSImage(size: rect.size)
            image.addRepresentation(bitmap)
            parts.append(image)
        }
        let gap: CGFloat = 1, header: CGFloat = 28
        let size = NSSize(width: parts[0].size.width + parts[1].size.width + gap,
                          height: max(parts[0].size.height, parts[1].size.height) + header)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)),
                                          pixelsHigh: Int(ceil(size.height * 2)), bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        let dark = cases[stage].3 == .darkAqua
        NSColor(calibratedWhite: dark ? 0.14 : 0.95, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                            .foregroundColor: dark ? NSColor.white : NSColor.black]
        for (index, image) in parts.enumerated() {
            let x: CGFloat = index == 0 ? 0 : parts[0].size.width + gap
            image.draw(in: NSRect(x: x, y: 0, width: image.size.width, height: image.size.height))
            let label = index == 0 ? "原生编辑区检查 · 左侧" : "原生编辑区检查 · 右侧"
            (label as NSString).draw(at: NSPoint(x: x + 12, y: size.height - 19), withAttributes: labelAttributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: output.appendingPathComponent("\(name)-editor-detail.png"))
        }
    }

    static func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
    static func color(_ value: NSColor) -> String {
        guard let rgb = value.usingColorSpace(.sRGB) else { return value.description }
        return String(format: "rgba(%.3f,%.3f,%.3f,%.3f)", rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }
    static func luminance(_ value: NSColor) -> Double {
        guard let rgb = value.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
    static func describe(_ view: NSView, depth: Int, lines: inout [String]) {
        let text = (view as? NSTextField)?.stringValue ?? (view as? NSButton)?.title ?? ""
        let label = view.accessibilityLabel() ?? ""
        lines.append("\(String(repeating: " ", count: depth))\(type(of: view)) frame=\(NSStringFromRect(view.frame)) bounds=\(NSStringFromRect(view.bounds)) visible=\(NSStringFromRect(view.visibleRect)) alpha=\(view.alphaValue) hidden=\(view.isHiddenOrHasHiddenAncestor) effectiveAppearance=\(view.effectiveAppearance.name.rawValue) label=\(label) text=\(text)")
        for child in view.subviews { describe(child, depth: depth + 1, lines: &lines) }
    }
}
