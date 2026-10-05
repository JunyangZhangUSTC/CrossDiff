import AppKit
import SwiftUI
import CrossDiffCore

/// Exercises the shipping sheet and entry points inside an isolated native app.
/// Fixtures, restored sessions, settings and captured bitmaps stay in the project.
@MainActor
enum NewComparisonWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static var root: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]!).deletingLastPathComponent() }
    static var store: WorkspaceStore { .shared }
    static var sheet: NSWindow? { D.window.attachedSheet }
    static var checks = 0

    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-new-comparison-workflow/") == true,
              ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]?.contains(".build-new-comparison-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty
                ? "PASS: native two-step creation, chooser navigation, draft isolation, typed inputs, plugin handoff, legacy pairing, bilingual light/dark/narrow sheets and immutable sources"
                : "FAIL: " + D.failures.joined(separator: "; ")
            D.log("Completed \(checks) assertions")
            D.log(verdict)
            try? verdict.write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(D.failures.isEmpty ? 0 : 8)
        }
    }

    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        D.window = NativeMenuController.shared.comparisonWindow
        guard D.window != nil else { throw D.CheckError(description: "Missing production main window") }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        D.window.makeKeyAndOrderFront(nil)
        let manager = PluginManager.shared
        manager.setEnabled(true, id: "org.crossdiff.pdf")
        manager.setEnabled(true, id: "org.crossdiff.archive")
        let gitID = GitComparisonModel.pluginID
        manager.restoreBundled(gitID)
        manager.setEnabled(true, id: gitID)
        let original = ComparisonSession(left: .init(text: "既有左侧 👩🏽‍💻\r\n", savedText: ""), right: .init(text: "既有右侧 e\u{301}\n", savedText: ""))
        store.sessions = [original]; store.selectedID = original.id
        let existingBytes = try D.encoded(original)
        let fixture = root.appendingPathComponent("fixtures")
        let leftFile = fixture.appendingPathComponent("original-unicode.txt")
        let rightFile = fixture.appendingPathComponent("modified-unicode.txt")
        let binary = fixture.appendingPathComponent("binary.dat")
        let image = fixture.appendingPathComponent("sample.png")
        let folder = fixture.appendingPathComponent("right-folder")
        let archive = fixture.appendingPathComponent("left.zip")
        let source = "原文 👩🏽‍💻\r\n组合 e\u{301}\r\n结尾\r\n"
        let temporary = "修改 🧪\r\n组合 e\u{301}\n"
        let data = try TextFileIO.encoded(source, encoding: .utf16LE)
        try data.write(to: leftFile)
        try Data("第二个文本\n".utf8).write(to: rightFile)
        try Data([0, 255, 10, 0, 13, 22]).write(to: binary)
        try writePNG(to: image)
        let immutableURLs = [leftFile, rightFile, binary, image, archive]
        let immutableBytes = try immutableURLs.map { try Data(contentsOf: $0) }

        // The actual toolbar action presents a chooser, without creating a tab.
        AppSettings.shared.language = .simplifiedChinese
        try await D.pause()
        guard let newButton = D.window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "crossdiff.new" })?.view as? NSButton else {
            throw D.CheckError(description: "Missing native New toolbar button")
        }
        check(newButton.title == "新建…" && newButton.image != nil, "New toolbar has a localized title and symbol")
        newButton.performClick(nil)
        let model = try await currentModel()
        check(model.selectedType == nil && store.sessions.count == 1 && store.selectedID == original.id, "New starts at type selection without mutating the current session")
        let expected = Set(["text", "folder", "image", "binary", "org.crossdiff.archive", "org.crossdiff.pdf", gitID])
        let orderedIDs = model.types.map(\.id)
        check(expected.isSubset(of: Set(orderedIDs)), "chooser contains built-ins and enabled Git/archive/PDF plugins")
        check(Array(orderedIDs.prefix(6)) == ["text", "folder", "image", gitID, "binary", ArchiveComparisonModel.pluginID]
              && orderedIDs.filter { $0 == gitID }.count == 1,
              "chooser starts with Text, Folders, Images, Git, Binary and Archives")
        let otherIDs = ["text", "folder", "image", "binary", ArchiveComparisonModel.pluginID] +
            manager.enabledPlugins.filter { $0.id != gitID && $0.id != ArchiveComparisonModel.pluginID }.map(\.id)
        check(orderedIDs.filter { $0 != gitID } == otherIDs, "remaining plugins retain their relative order after the six basic choices")
        manager.setEnabled(false, id: gitID)
        try await D.wait("disabled Git leaves chooser") { control("new-comparison.type." + gitID) == nil }
        check(model.types.map(\.id) == otherIDs, "disabled Git stays hidden while all other choices retain their order")
        manager.setEnabled(true, id: gitID)
        try await D.wait("enabled Git returns to chooser") { control("new-comparison.type." + gitID) != nil }
        check(model.types.map(\.id) == orderedIDs, "re-enabled Git returns to its priority position without duplication")
        manager.removeBundled(gitID)
        try await D.wait("removed Git leaves chooser") { control("new-comparison.type." + gitID) == nil }
        check(model.types.map(\.id) == otherIDs, "removed bundled Git is not reintroduced by priority ordering")
        manager.restoreBundled(gitID)
        try await D.wait("restored Git returns to chooser") { control("new-comparison.type." + gitID) != nil }
        check(model.types.map(\.id) == orderedIDs, "restoring bundled Git restores its priority position")
        try await renderVariants(prefix: "new-types")
        for id in expected { check(control("new-comparison.type." + id) != nil, "native chooser exposes \(id)") }
        check(control("new-comparison.more") != nil, "native chooser exposes More Comparisons")
        try await press("new-comparison.type.text")
        check(model.selectedType?.kind == .text && model.canCreate, "selecting Text advances to editable empty inputs")
        model.setInput(.text(temporary), side: .right)
        model.setInput(.file(leftFile), side: .left)
        try await D.pause()
        guard let inputEditor = objects().compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable }) else {
            throw D.CheckError(description: "Missing native temporary-text input editor")
        }
        sheet?.makeFirstResponder(inputEditor)
        inputEditor.insertText("实际输入 🐈", replacementRange: NSRange(location: inputEditor.string.utf16.count, length: 0))
        try await D.wait("native temporary-text input binding") { text(model.right)?.hasSuffix("实际输入 🐈") == true }
        check(text(model.right)?.utf16.elementsEqual((temporary + "实际输入 🐈").utf16) == true,
              "native text input updates only the draft and preserves UTF-16 content")
        check(try D.encoded(original) == existingBytes, "editing creation inputs cannot modify the comparison behind the sheet")
        model.setInput(.text(temporary), side: .right)
        try await press("new-comparison.right.choose")
        try await D.wait("nested native file chooser") { sheet?.attachedSheet is NSOpenPanel }
        guard let panel = sheet?.attachedSheet as? NSOpenPanel else { throw D.CheckError(description: "Missing source NSOpenPanel") }
        check(panel.allowsMultipleSelection == false && panel.canChooseFiles && !panel.canChooseDirectories, "source picker selects one appropriate item for the chosen side")
        panel.cancel(nil)
        try await D.wait("native file selection cancelled") { sheet?.attachedSheet == nil }
        check(file(model.left) == leftFile && text(model.right) == temporary && model.selectedType?.kind == .text, "cancelling the native file chooser retains both drafts and the source step")
        try await renderVariants(prefix: "new-text-sources")
        try await press("new-comparison.back")
        check(model.selectedType == nil, "Back returns to the same chooser")
        try await press("new-comparison.type.text")
        check(file(model.left) == leftFile && text(model.right) == temporary, "returning to the same type preserves both source drafts")
        try await press("new-comparison.swap")
        check(text(model.left) == temporary && file(model.right) == leftFile, "visible Swap preserves content and exchanges source roles")
        model.swap()
        let countBeforeCreate = store.sessions.count
        try await press("new-comparison.create")
        try await D.wait("mixed text creation") { store.newComparison == nil && store.sessions.count == countBeforeCreate + 1 }
        try await D.wait("creation sheet closes") { sheet == nil }
        let mixed = store.selected!
        check(mixed.kind == .text && mixed.left.text.utf16.elementsEqual(source.utf16) && mixed.right.text.utf16.elementsEqual(temporary.utf16), "mixed file/pasted input preserves exact Unicode and original line endings")
        check(mixed.left.encoding == .utf16LE && mixed.left.signature == TextFileIO.signature(data) && mixed.left.savedText.utf16.elementsEqual(source.utf16), "loaded text retains encoding, disk signature and clean saved content")
        check(mixed.left.path == leftFile.path && mixed.right.path == nil, "pasted side has no invented file path")
        check(mixed.title == "\(leftFile.lastPathComponent) ↔ \(L("临时文本", "Temporary Text"))", "mixed text tab names the temporary side instead of reporting it as unselected")
        check(try D.encoded(original) == existingBytes, "creation leaves prior session text and state unchanged")

        // Navigating to another type clears incompatible input; cancellation creates nothing.
        store.beginNewComparison(kind: .text)
        let draft = try await currentModel()
        draft.setInput(.text(temporary), side: .left)
        draft.back(); draft.select(try type("image", in: draft))
        check(draft.selectedType?.kind == .image && !draft.canCreate && text(draft.left) == nil, "changing comparison type resets incompatible drafts")
        draft.setInput(.file(image), side: .left)
        draft.setInput(.file(folder), side: .left)
        check(draft.errorMessage != nil && file(draft.left) == image && !draft.canCreate, "invalid image source reports an inline error without replacing the accepted file")
        let beforeCancel = store.sessions.count
        draft.cancel()
        try await D.wait("cancel dismisses sheet") { store.newComparison == nil && sheet == nil }
        check(store.sessions.count == beforeCancel && store.selectedID == mixed.id, "Cancel creates no tab and retains the selected comparison")

        store.beginNewComparison(kind: .text)
        let invalid = try await currentModel()
        invalid.setInput(.text(temporary), side: .left)
        invalid.setInput(.file(binary), side: .left)
        if invalid.errorMessage == nil { invalid.create(); try await D.wait("binary rejection") { !invalid.busy } }
        check(invalid.errorMessage != nil && text(invalid.left) == temporary && store.sessions.count == beforeCancel, "binary input cannot silently replace a text draft or create a text comparison")
        invalid.cancel()
        try await D.wait("invalid input sheet closes") { sheet == nil }

        store.beginNewComparison(kind: .text)
        let interrupted = try await currentModel()
        interrupted.setInput(.file(leftFile), side: .left)
        interrupted.setInput(.file(rightFile), side: .right)
        interrupted.create(); interrupted.cancel()
        try await D.wait("cancel loading sheet") { sheet == nil }
        try await D.pause()
        check(store.sessions.count == beforeCancel && store.newComparison == nil, "cancelling an in-flight load cannot publish an obsolete comparison tab")

        store.beginNewComparison(kind: .text)
        let blank = try await currentModel()
        check(blank.canCreate, "two empty temporary texts are a valid new comparison")
        blank.create()
        try await D.wait("blank creation") { store.newComparison == nil && store.sessions.count == beforeCancel + 1 }
        check(store.selected?.left.text.isEmpty == true && store.selected?.right.text.isEmpty == true, "empty text opens an editable blank pair")
        try await D.wait("blank creation sheet closes") { sheet == nil }

        // Typed menu shortcuts skip only the chooser and still require explicit sources.
        NativeMenuController.shared.openFolders(nil)
        let folders = try await currentModel()
        check(folders.selectedType?.kind == .folder && !folders.canCreate, "Compare Folder menu opens source selection")
        folders.setInput(.file(folder), side: .left)
        folders.setInput(.file(folder), side: .right)
        check(folders.canCreate, "two selected directories are ready for comparison")
        try await renderVariants(prefix: "new-folder-sources")
        let folderCount = store.sessions.count
        folders.create()
        try await D.wait("folder creation") { store.newComparison == nil && store.sessions.count == folderCount + 1 }
        check(store.selected?.kind == .folder && store.selected?.left.path == folder.path && store.selected?.right.path == folder.path, "folder creation keeps explicit left/right roles")
        try await D.wait("folder sheet closes") { sheet == nil }

        store.beginNewComparison(kind: .plugin, pluginID: "org.crossdiff.archive")
        let archives = try await currentModel()
        archives.setInput(.file(archive), side: .left)
        archives.setInput(.file(folder), side: .right)
        check(archives.canCreate, "archive source selection permits an archive paired with a folder")
        manager.setEnabled(false, id: "org.crossdiff.archive")
        let disabledCount = store.sessions.count
        archives.create()
        try await D.wait("disabled plugin validation") { !archives.busy }
        check(archives.errorMessage != nil && store.sessions.count == disabledCount && store.newComparison === archives,
                "disabled plugin is rechecked before creation; input sheet stays available")
        check(file(archives.left) == archive && file(archives.right) == folder, "plugin availability error retains selected sources")
        manager.setEnabled(true, id: "org.crossdiff.archive")
        archives.cancel()
        try await D.wait("archive draft closes") { sheet == nil }

        // More Comparisons dismisses the sheet before presenting plugin management.
        NativeMenuController.shared.newComparison(nil)
        _ = try await currentModel()
        try await press("new-comparison.more")
        try await D.wait("plugin management handoff") {
            store.newComparison == nil && sheet == nil && NSApp.windows.contains { $0.identifier?.rawValue == "crossdiff-plugins" && $0.isVisible }
        }
        check(store.sessions.count == disabledCount, "More Comparisons opens plugins without an empty comparison tab")
        NSApp.windows.first { $0.identifier?.rawValue == "crossdiff-plugins" }?.close()
        D.window.makeKeyAndOrderFront(nil)

        // Incoming Finder opens wait until creation has dismissed, then retain
        // the existing explicit batch-pairing workflow instead of stacking sheets.
        store.beginNewComparison(kind: .text)
        let protectedDraft = try await currentModel()
        protectedDraft.setInput(.text(temporary), side: .left)
        store.accept([leftFile, rightFile, fixture.appendingPathComponent("left.zip")])
        try await D.pause()
        check(store.newComparison === protectedDraft && text(protectedDraft.left) == temporary && !store.pairing,
              "incoming multiple-file open waits without replacing the active creation draft")
        protectedDraft.cancel()
        try await D.wait("legacy pairing") { store.pairing }
        check(store.newComparison == nil && store.candidates.count == 3, "deferred multi-item open reaches the pairing sheet after creation dismisses")
        store.pairing = false
        try await D.wait("pairing sheet closes") { sheet == nil }
        let legacyCount = store.sessions.count
        store.accept([leftFile, rightFile])
        try await D.wait("legacy two-file open") { !store.opening && store.sessions.count == legacyCount + 1 }
        check(store.selected?.kind == .text && store.selected?.left.path == leftFile.path && store.selected?.right.path == rightFile.path,
                "legacy compatible pair opens directly in its own tab")
        check(try immutableURLs.map { try Data(contentsOf: $0) } == immutableBytes, "creation and validation do not modify any selected source bytes")
        try await renderMainWindow()
    }

    static func check(_ value: Bool, _ description: String) {
        checks += 1; D.check(value, description)
    }

    static func currentModel() async throws -> NewComparisonModel {
        try await D.wait("native creation sheet") { store.newComparison != nil && sheet?.contentView != nil }
        try await D.pause()
        return store.newComparison!
    }
    static func type(_ id: String, in model: NewComparisonModel) throws -> NewComparisonType {
        guard let type = model.types.first(where: { $0.id == id }) else { throw D.CheckError(description: "Missing comparison type: \(id)") }
        return type
    }
    static func text(_ input: NewComparisonInput) -> String? { if case .text(let value) = input { return value }; return nil }
    static func file(_ input: NewComparisonInput) -> URL? { if case .file(let value) = input { return value }; return nil }

    static func renderVariants(prefix: String) async throws {
        for (suffix, dark, width, language) in [
            ("zh-light", false, 1220.0, AppLanguage.simplifiedChinese),
            ("zh-dark-narrow", true, 860.0, .simplifiedChinese),
            ("en-light-narrow", false, 860.0, .english),
            ("en-dark", true, 1220.0, .english)
        ] {
            AppSettings.shared.language = language
            AppAppearance.shared.isDark = dark
            D.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let height = width == 860 ? 580.0 : 790.0
            D.window.setFrame(NSRect(x: -10000, y: -10000, width: width, height: height), display: true)
            try await D.pause()
            guard let sheet, let parent = sheet.contentView?.superview else { throw D.CheckError(description: "Missing attached native sheet") }
            sheet.contentView?.layoutSubtreeIfNeeded(); sheet.displayIfNeeded()
            let bitmap = try D.capture(parent, rect: parent.bounds, name: prefix + "-" + suffix)
            check(sheet.sheetParent === D.window && bitmap.pixelsWide > 500 && bitmap.pixelsHigh > 300, "\(prefix)-\(suffix) captures the actual attached sheet")
            check(D.window.frame.width == width && D.window.frame.height == height, "\(prefix)-\(suffix) uses the requested whole-window dimensions")
            check(sheet.frame.width <= D.window.frame.width, "\(prefix)-\(suffix) fits the minimum supported main window width")
            check(sheet.frame.height <= D.window.contentLayoutRect.height, "\(prefix)-\(suffix) fits below the toolbar at the minimum supported window height")
            check(try readablePixels(bitmap) > 100, "\(prefix)-\(suffix) has readable native control text")
            let tree = objects().map { [String(describing: Swift.type(of: $0)), string($0, "accessibilityIdentifier"), string($0, "accessibilityLabel"), string($0, "accessibilityValue")].joined(separator: " | ") }.joined(separator: "\n")
            let localizedLabels = store.newComparison?.selectedType == nil
                ? (language == .english ? ["New Comparison", "More Comparisons"] : ["新建比较", "更多对比项"])
                : (language == .english ? ["Left", "Right", "Compare"] : ["左侧", "右侧", "开始比较"])
            check(localizedLabels.allSatisfy { tree.contains($0) }, "\(prefix)-\(suffix) exposes translated controls in the native accessibility tree")
            if store.newComparison?.selectedType == nil {
                let imageFrame = try accessibilityFrame("new-comparison.type.image")
                let gitFrame = try accessibilityFrame("new-comparison.type." + GitComparisonModel.pluginID)
                check(imageFrame.width > 0 && gitFrame.width > 0 && abs(imageFrame.midY - gitFrame.midY) < 3 && gitFrame.minX > imageFrame.maxX,
                      "\(prefix)-\(suffix) places Git to the right of Images in the second row")
                check(tree.contains(language == .english ? "Compare commits, staging area and working tree" : "比较提交、暂存区与工作区"),
                      "\(prefix)-\(suffix) exposes the current Git source capabilities")
            }
            try tree.write(to: D.output.appendingPathComponent(prefix + "-" + suffix + "-accessibility.txt"), atomically: true, encoding: .utf8)
            D.log("Rendered \(prefix)-\(suffix)")
        }
    }
    static func renderMainWindow() async throws {
        AppSettings.shared.language = .english
        AppAppearance.shared.isDark = false
        D.window.appearance = NSAppearance(named: .aqua)
        D.window.setFrame(NSRect(x: -10000, y: -10000, width: 860, height: 580), display: true)
        try await D.pause()
        guard let parent = D.window.contentView?.superview else { throw D.CheckError(description: "Missing main window chrome") }
        _ = try D.capture(parent, rect: parent.bounds, name: "new-toolbar-english-narrow")
        let button = D.window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "crossdiff.new" })?.view as? NSButton
        check(button?.title == "New…", "toolbar title follows the application language")
        let menu = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
        check(menu.contains { $0.action == #selector(NativeMenuController.newComparison(_:)) && $0.keyEquivalent == "n" }, "New menu retains Command-N")
        check(menu.contains { $0.action == #selector(NativeMenuController.open(_:)) && $0.keyEquivalent == "o" }, "File Open keeps Command-O for existing batch workflows")
    }

    /// Cached SwiftUI sheets can use an extended display color space. Measure
    /// the real rendered pixels after a deliberate conversion to standard sRGB.
    static func readablePixels(_ bitmap: NSBitmapImageRep) throws -> Int {
        guard let image = bitmap.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw D.CheckError(description: "Unable to normalize native sheet color space")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage() else { throw D.CheckError(description: "Missing normalized native pixels") }
        return D.countPixels(NSBitmapImageRep(cgImage: normalized), background: AppAppearance.shared.colors.canvas).readable
    }

    static func press(_ id: String) async throws {
        guard let object = control(id) else { throw D.CheckError(description: "Missing accessible control: \(id)") }
        if let button = object as? NSButton { button.performClick(nil) }
        else {
            let action = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: action) else { throw D.CheckError(description: "Missing press action: \(id)") }
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            check(unsafeBitCast(object.method(for: action), to: Action.self)(object, action), "\(id) performs its accessible action")
        }
        try await D.pause()
    }
    static func control(_ id: String) -> NSObject? {
        let matches = objects().filter { string($0, "accessibilityIdentifier") == id }
        if let native = matches.first(where: { $0 is NSControl }) { return native }
        if let cell = matches.first as? NSCell, let native = cell.controlView { return native }
        return matches.first
    }
    static func accessibilityFrame(_ id: String) throws -> NSRect {
        guard let object = objects().first(where: { string($0, "accessibilityIdentifier") == id }) else {
            throw D.CheckError(description: "Missing accessible control frame: \(id)")
        }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { throw D.CheckError(description: "Missing accessibility frame: \(id)") }
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(object.method(for: selector), to: Frame.self)(object, selector)
    }
    static func objects() -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func descend(_ object: NSObject, depth: Int) {
            guard depth < 45, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                for child in children { descend(child, depth: depth + 1) }
            }
            if let view = object as? NSView { for child in view.subviews { descend(child, depth: depth + 1) } }
        }
        if let view = sheet?.contentView { descend(view, depth: 0) }
        return result
    }
    static func string(_ object: NSObject, _ attribute: String) -> String {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
    static func writePNG(to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw D.CheckError(description: "PNG fixture allocation failed") }
        guard let pixels = bitmap.bitmapData else { throw D.CheckError(description: "PNG fixture has no pixel buffer") }
        for y in 0..<32 { for x in 0..<40 {
            let index = y * bitmap.bytesPerRow + x * 4
            pixels[index] = 38; pixels[index + 1] = UInt8(x * 255 / 45)
            pixels[index + 2] = UInt8(y * 255 / 36); pixels[index + 3] = 255
        } }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw D.CheckError(description: "PNG fixture encoding failed") }
        try data.write(to: url)
    }
}
