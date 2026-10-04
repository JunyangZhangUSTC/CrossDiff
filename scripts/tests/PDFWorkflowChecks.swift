import AppKit
import CoreText
import PDFKit
import CrossDiffCore

/// Actual app lifecycle, official restricted PDF plugin, source-page previews
/// and native controls. All sources and captures are synthetic and isolated.
@MainActor enum PDFWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static var root: URL { D.output.deletingLastPathComponent() }

    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-pdf-workflow-checks/") == true,
              ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]?.contains(".build-pdf-workflow-checks/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty
                ? "PASS: PDF page-number default, smart insertion/fallback, manual native page controls, source mapping, retained tabs, Chinese/English, light/dark and 860-point windows"
                : "FAIL: " + D.failures.joined(separator: "; ")
            D.log(verdict)
            try? D.report.joined(separator: "\n").write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(D.failures.isEmpty ? 0 : 8)
        }
    }

    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        try await D.wait("own PDF application window") {
            D.window = NativeMenuController.shared.comparisonWindow
            return D.window != nil
        }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.orderFront(nil)
        let fixtures = root.appendingPathComponent("fixtures-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let left = fixtures.appendingPathComponent("Research Draft.pdf")
        let right = fixtures.appendingPathComponent("Research Revision.pdf")
        let intro = "CrossDiff Research Introduction\nA study of local document comparison with reliable page correspondence and source preservation."
        let methods = "Experimental Methods and Measurements\nThis chapter explains synthetic sample collection, calibration, estimation and reproducibility."
        let results = "Results and Final Conclusions\nAcross the trials, forty subjects completed the experiment and the measured value was 10."
        let revised = "Results and Final Conclusions\nAcross the trials, forty subjects completed the experiment and the measured value was 20."
        try writePDF(left, pages: [intro, methods, results])
        try writePDF(right, pages: [intro, "Additional Laboratory Appendix\nSpecial equipment instructions, repair inventory and unrelated calibration checklist.", methods, revised])
        let originals = [try Data(contentsOf: left), try Data(contentsOf: right)]
        let store = WorkspaceStore.shared
        let session = ComparisonSession(kind: .plugin, left: .init(path: left.path), right: .init(path: right.path), pluginID: "org.crossdiff.pdf")
        let other = ComparisonSession(left: .init(text: "Other tab", savedText: "Other tab"))
        store.sessions.removeAll(); store.attach(session); store.attach(other); store.selectedID = session.id
        let model = session.pdfComparisonModel
        try await ready(model)
        D.check(model.alignmentMode == .pageNumber && model.selectedPair?.left == 0 && model.selectedPair?.right == 0,
                "native session defaults to source page 1 beside page 1")
        D.check(model.pairs[1].left == 1 && model.pairs[1].right == 1, "default pairing never guesses a shift from similar headings")
        D.check(has("pdf.alignment.menu") && has("pdf.pagePosition"), "alignment choice and explicit comparison-group navigation are exposed")
        try await press("pdf.nextPage")
        D.check(model.selectedPair?.left == 1 && model.selectedPair?.right == 1, "actual native next-group action keeps both original page numbers")
        try await selectMode(.smart)
        D.check(!model.isSmartFallback && model.pairs.contains { $0.left == 1 && $0.right == 2 }, "native smart choice finds inserted appendix without losing source pages")
        model.selectedIndex = model.pairs.firstIndex { $0.left == 2 && $0.right == 3 }!
        try await D.pause()
        D.check(model.leftText.contains("10") && model.rightText.contains("20"), "smart group content comes from the two original result pages")
        try await render("pdf-smart-zh-light-1220", width: 1220, dark: false)
        try await selectMode(.manual)
        D.check(!has("pdf.pagePosition") && has("pdf.left.pageNumber") && has("pdf.right.pageNumber"), "manual mode shows independent page inputs instead of ambiguous group navigation")
        try await enterPage("1", isLeft: true)
        try await enterPage("3", isLeft: false)
        D.check(model.manualLeftPage == 0 && model.manualRightPage == 2, "native manual page fields use one-based input and independent zero-based source indices")
        D.check(model.leftText.contains("Introduction") && model.rightText.contains("Methods"), "manual previews and extracted content follow the chosen original pages")
        for invalid in ["0", String(Int.min), "99999999999999999999999999"] {
            try await enterPage(invalid, isLeft: true)
            let field = pageField(isLeft: true)
            D.check(model.manualLeftPage == 0 && field?.stringValue == "1", "invalid native page input restores the real page number without changing its source")
        }
        try await press("pdf.left.nextPage")
        D.check(model.manualLeftPage == 1 && model.manualRightPage == 2, "left next-page button never advances the right")
        try await press("pdf.right.previousPage")
        D.check(model.manualLeftPage == 1 && model.manualRightPage == 1, "right previous-page button never advances the left")
        try await enterPage("3", isLeft: true); try await enterPage("4", isLeft: false)
        model.mode = .text
        try await D.wait("manual selected-page text diff") { model.textDiff != nil && model.leftText.contains("10") && model.rightText.contains("20") }
        D.check(model.textDiff?.hunks.isEmpty == false, "selected manual pages provide a real text difference")
        try await render("pdf-manual-text-zh-light-1220", width: 1220, dark: false)
        model.mode = .pages
        let savedLeft = model.leftDocument, savedRight = model.rightDocument
        store.selectedID = other.id
        try await D.wait("text tab visible") { !has("pdf.alignment.menu") && other.leftEditorState?.editor.window === D.window }
        store.selectedID = session.id
        try await D.wait("manual PDF tab restored") { has("pdf.left.pageNumber") }
        D.check(session.pdfComparisonModel === model && model.alignmentMode == .manual && model.manualLeftPage == 2 && model.manualRightPage == 3,
                "returning to a PDF tab retains its manual source pages and comparison mode")
        D.check(model.leftDocument?.document === savedLeft?.document && model.rightDocument?.document === savedRight?.document,
                "returning to a loaded tab keeps original PDF snapshots rather than re-reading files")
        for english in [false, true] {
            let languageFrame = D.window.frame.size
            D.log("before language \(english ? "en" : "zh"): \(windowGeometry())")
            AppSettings.shared.language = english ? .english : .simplifiedChinese
            try await D.pause()
            D.check(sameSize(D.window.frame.size, languageFrame), "changing PDF language preserves the existing window size")
            D.log("after language \(english ? "en" : "zh"): \(windowGeometry())")
            for dark in [false, true] {
                for width in [1220.0, 860.0] {
                    let name = "pdf-manual-\(english ? "en" : "zh")-\(dark ? "dark" : "light")-\(Int(width))"
                    try await render(name, width: width, dark: dark)
                    D.check(has("pdf.left.pageNumber") && has("pdf.right.pageNumber") && has("pdf.alignment.menu"), "\(name): both source controls and mode choice remain visible")
                    try checkPages(name)
                }
            }
        }
        try await selectMode(.pageNumber); try await selectMode(.manual)
        D.check(model.manualLeftPage == 2 && model.manualRightPage == 3, "manual choices survive selecting another alignment mode")
        let unrelatedLeft = fixtures.appendingPathComponent("Unrelated One.pdf"), unrelatedRight = fixtures.appendingPathComponent("Unrelated Three.pdf")
        try writePDF(unrelatedLeft, pages: ["AAAA"])
        try writePDF(unrelatedRight, pages: ["BBBB", "CCCC", "DDDD"])
        let unrelated = ComparisonSession(kind: .plugin, left: .init(path: unrelatedLeft.path), right: .init(path: unrelatedRight.path), pluginID: "org.crossdiff.pdf")
        let unrelatedFrame = D.window.frame.size
        D.log("before switching to unrelated PDF: \(windowGeometry())")
        store.attach(unrelated); store.selectedID = unrelated.id
        try await ready(unrelated.pdfComparisonModel)
        D.check(sameSize(D.window.frame.size, unrelatedFrame), "switching PDF sessions preserves the existing window size")
        D.log("after switching to unrelated PDF: \(windowGeometry())")
        D.check(unrelated.pdfComparisonModel.selectedPair?.left == 0 && unrelated.pdfComparisonModel.selectedPair?.right == 0,
                "reported bug is absent in the real app: unrelated left page 1 opens with right page 1")
        try await selectMode(.smart)
        D.check(unrelated.pdfComparisonModel.isSmartFallback && unrelated.pdfComparisonModel.selectedPair?.right == 0,
                "real smart-mode menu safely falls back for unrelated PDFs")
        try await render("pdf-unrelated-fallback-en-dark-860", width: 860, dark: true)
        D.check(try [Data(contentsOf: left), Data(contentsOf: right)] == originals, "all native PDF modes, page controls and tab changes preserve source bytes")
    }

    static func ready(_ model: PDFComparisonModel) async throws {
        try await D.wait("PDF result ready") { model.error != nil || model.result != nil && !model.isLoading }
        if let error = model.error { throw error }
        try await D.pause()
    }

    static func enterPage(_ value: String, isLeft: Bool) async throws {
        let identifier = isLeft ? "pdf.left.pageNumber" : "pdf.right.pageNumber"
        guard let field = pageField(isLeft: isLeft) else {
            throw D.CheckError(description: "Missing native page input: \(identifier)")
        }
        field.window?.makeFirstResponder(field)
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        if let action = field.action { NSApp.sendAction(action, to: field.target, from: field) }
        field.delegate?.controlTextDidEndEditing?(Notification(name: NSControl.textDidEndEditingNotification, object: field,
                                                               userInfo: ["NSTextMovement": NSReturnTextMovement]))
        field.window?.makeFirstResponder(nil)
        try await D.pause()
    }

    static func pageField(isLeft: Bool) -> NSTextField? {
        let identifier = isLeft ? "pdf.left.pageNumber" : "pdf.right.pageNumber"
        return objects().filter { string($0, "accessibilityIdentifier") == identifier }.compactMap {
            ($0 as? NSTextField) ?? ($0 as? NSCell)?.controlView as? NSTextField
        }.first { $0.isEditable }
    }

    static func selectMode(_ mode: PDFPageAlignmentMode) async throws {
        let frameBefore = D.window.frame.size
        func checkModeSize() {
            D.check(sameSize(D.window.frame.size, frameBefore), "selecting \(mode.rawValue) PDF alignment preserves the existing window size")
            D.log("after alignment \(mode.rawValue): \(windowGeometry())")
        }
        let identifier = "pdf.alignment.\(mode.rawValue)"
        let titles: [String]
        switch mode {
        case .pageNumber: titles = ["按页码比较", "按页码", "By Page Number", "Page Number", "By Page"]
        case .smart: titles = ["智能匹配", "Smart Matching", "Smart Match"]
        case .manual: titles = ["手动配对", "Manual Pairing", "Manual"]
        }
        let selector = NSSelectorFromString("menu")
        let exposed = objects().filter { string($0, "accessibilityIdentifier") == "pdf.alignment.menu" }
        let candidates = exposed + exposed.compactMap { ($0 as? NSCell)?.controlView }
        var inspected: [String] = []
        func menus() -> [NSMenu] {
            candidates.compactMap { object in
                object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? NSMenu : nil
            }
        }
        var selected = false
        func choose() {
            guard !selected else { return }
            for menu in menus() {
                inspected.append("\(menu.items.map { $0.title })")
                if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == identifier || titles.contains($0.title) }) {
                    selected = true
                    menu.performActionForItem(at: index)
                    menu.cancelTrackingWithoutAnimation()
                    return
                }
            }
        }
        // SwiftUI lazily populates popup content when its native menu begins
        // tracking. Schedule selection in that tracking run loop, then activate
        // the actual button, rather than writing the comparison model directly.
        if let button = candidates.compactMap({ $0 as? NSButton }).first {
            let deadline = Date().addingTimeInterval(3)
            let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
                MainActor.assumeIsolated {
                    choose()
                    if selected || Date() > deadline {
                        for menu in menus() { menu.cancelTrackingWithoutAnimation() }
                        timer.invalidate()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
            button.performClick(nil)
            while !selected && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            timer.invalidate()
            if selected { try await D.pause(); checkModeSize(); return }
        }
        // SwiftUI can expose the menu's native choice accessibility elements
        // directly even when its wrapper has no public NSMenu accessor.
        for title in titles {
            if objects().contains(where: { string($0, "accessibilityLabel") == title && $0.responds(to: NSSelectorFromString("accessibilityPerformPress")) }) {
                try await press(identifier, fallback: title); checkModeSize(); return
            }
        }
        throw D.CheckError(description: "Missing actual alignment menu item: \(identifier); controls: \(candidates.map { String(describing: type(of: $0)) }); menus: \(inspected)")
    }

    static func checkPages(_ name: String) throws {
        guard let parent = D.window.contentView?.superview else { throw D.CheckError(description: "Missing PDF parent window") }
        let canvases = objects().compactMap { $0 as? NSView }.filter { $0.identifier?.rawValue == "pdf.page.canvas" }
        D.check(canvases.count == 2, "\(name): two actual source page surfaces exist")
        for (index, page) in canvases.enumerated() {
            let rect = page.convert(page.bounds, to: parent).intersection(parent.bounds)
            D.check(rect.width > 200 && rect.height > 200, "\(name): side \(index) remains large enough to read")
            let bitmap = try D.capture(parent, rect: rect, name: name + "-source-\(index)")
            var ink = 0
            for y in stride(from: bitmap.pixelsHigh / 10, to: bitmap.pixelsHigh * 9 / 10, by: 2) {
                for x in stride(from: bitmap.pixelsWide / 5, to: bitmap.pixelsWide * 4 / 5, by: 2) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       max(color.redComponent, color.greenComponent, color.blueComponent) < 0.4 { ink += 1 }
                }
            }
            D.check(ink > 50, "\(name): side \(index) contains visible source-page ink in the composed window")
        }
    }

    static func writePDF(_ url: URL, pages: [String]) throws {
        var bounds = CGRect(x: 0, y: 0, width: 480, height: 640)
        guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else { throw D.CheckError(description: "Cannot write isolated PDF fixture") }
        for (index, page) in pages.enumerated() {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
            for (line, text) in page.components(separatedBy: "\n").enumerated() {
                let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: line == 0 ? 20 : 13), .foregroundColor: NSColor.black])
                let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                let path = CGPath(rect: CGRect(x: 32, y: 455 - line * 125, width: 416, height: 120), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
                CTFrameDraw(frame, context)
            }
            let marker = NSAttributedString(string: "Source page \(index + 1)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 32, y: 60)
            CTLineDraw(CTLineCreateWithAttributedString(marker), context)
            context.endPDFPage()
        }
        context.closePDF()
    }
    static func render(_ name: String, width: Double, dark: Bool) async throws {
        D.log("\(name): before resize \(windowGeometry())")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                AppAppearance.shared.isDark = dark
                D.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                D.window.setFrame(NSRect(x: -10000, y: -10000, width: width, height: 790), display: true)
                D.window.contentView?.layoutSubtreeIfNeeded()
                continuation.resume()
            }
        }
        try await D.pause()
        guard let parent = D.window.contentView?.superview else { throw D.CheckError(description: "Missing complete native window") }
        D.check(sameSize(D.window.frame.size, NSSize(width: width, height: 790)),
                "\(name): actual window keeps requested \(Int(width))×790 instead of growing from content sizing")
        let bitmap = try D.capture(parent, rect: parent.bounds, name: name)
        D.check(bitmap.pixelsWide >= Int(width), "\(name): complete parent window captured")
        let pixels = D.countPixels(bitmap, background: ComparisonTheme(isDark: dark).canvas)
        D.check(pixels.readable > 300, "\(name): contrasting text is actually drawn in the native window")
        D.log("\(name): native \(Int(parent.bounds.width))×\(Int(parent.bounds.height)), contrasting pixels=\(pixels.readable), \(windowGeometry())")
    }
    static func sameSize(_ actual: NSSize, _ expected: NSSize) -> Bool {
        abs(actual.width - expected.width) < 1 && abs(actual.height - expected.height) < 1
    }
    static func windowGeometry() -> String {
        "frame=\(D.window.frame.size), min=\(D.window.minSize), contentMin=\(D.window.contentMinSize), host=\(D.window.contentView?.frame.size ?? .zero), fitting=\(D.window.contentView?.fittingSize ?? .zero)"
    }
    static func has(_ identifier: String) -> Bool { objects().contains { string($0, "accessibilityIdentifier") == identifier } }
    static func press(_ identifier: String, fallback: String? = nil) async throws {
        let action = NSSelectorFromString("accessibilityPerformPress")
        let all = objects()
        let candidates = all.filter { string($0, "accessibilityIdentifier") == identifier && $0.responds(to: action) }
        let candidate = candidates.first(where: { $0 is NSControl }) ?? candidates.first ?? all.first {
            guard let fallback else { return false }
            return (string($0, "accessibilityLabel") == fallback || ($0 as? NSButton)?.title == fallback) && $0.responds(to: action)
        }
        guard let object = candidate else { throw D.CheckError(description: "Missing native action: \(identifier)") }
        if let button = object as? NSButton { button.performClick(nil) }
        else {
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            _ = unsafeBitCast(object.method(for: action), to: Action.self)(object, action)
        }
        try await D.pause()
    }
    static func objects() -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func descend(_ object: NSObject, depth: Int) {
            if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
            guard depth < 45, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                for child in children { descend(child, depth: depth + 1) }
            }
            if let view = object as? NSView { for child in view.subviews { descend(child, depth: depth + 1) } }
        }
        if let view = D.window.contentView { descend(view, depth: 0) }
        for window in NSApp.windows where window !== D.window && window.isVisible {
            if let view = window.contentView { descend(view, depth: 0) }
        }
        return result
    }
    static func string(_ object: NSObject, _ attribute: String) -> String {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
}
