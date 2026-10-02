import AppKit
import CrossDiffCore

@MainActor enum OfficeWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-office-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty ? "PASS: Office native creation, read-only import, exact/key row matches, independent sections, search, persistence, original preview, light/dark/narrow, base installation" : "FAIL: " + D.failures.joined(separator: "; ")
            try? (D.report + [verdict]).joined(separator: "\n").write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            print(verdict); exit(D.failures.isEmpty ? 0 : 8)
        }
    }
    static var fixtures: URL { D.output.deletingLastPathComponent().appendingPathComponent("fixtures") }
    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        try await D.wait("own native window") {
            D.window = NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }
            return D.window != nil
        }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.orderFront(nil)
        let urls = ["Milestones-before.xlsx", "Milestones-after.xlsx", "Research-before.docx", "Research-after.docx", "Review-before.pptx", "Review-after.pptx"].map { fixtures.appendingPathComponent($0) }
        let bytes = try urls.map { try Data(contentsOf: $0) }
        let type = NewComparisonType(kind: .plugin, pluginID: "org.crossdiff.office")
        let candidate = OpenCandidate(url: urls[0], kind: .plugin, pluginID: "org.crossdiff.office", isOfficeDocument: true)
        D.check(!candidate.isCompatible(with: OpenCandidate(url: urls[2], kind: .plugin, pluginID: "org.crossdiff.office", isOfficeDocument: true)), "batch pairing rejects different Office families")
        try type.validate(urls[0])
        D.check(PluginManager.shared.matching(urls[0])?.package.manifest.id == "org.crossdiff.office", "Office is discovered for modern Office files")
        let legacy = fixtures.appendingPathComponent("old.xls")
        try Data("legacy".utf8).write(to: legacy)
        do { try type.validate(legacy); D.check(false, "legacy Office must request conversion") }
        catch { D.check(localizedErrorDescription(error).contains("xlsx"), "legacy Office shows modern-format conversion guidance") }
        let store = WorkspaceStore.shared
        store.beginNewComparison()
        try await D.wait("new comparison sheet") { store.newComparison != nil && D.window.attachedSheet != nil }
        let draft = store.newComparison!
        draft.select(type); draft.setInput(.file(urls[0]), side: .left); draft.setInput(.file(urls[2]), side: .right)
        D.check(!draft.canCreate, "new comparison rejects Excel paired with Word")
        draft.setInput(.file(urls[1]), side: .right)
        D.check(draft.canCreate, "new comparison accepts paired workbooks")
        draft.create()
        try await D.wait("Office tab") { store.newComparison == nil && D.window.attachedSheet == nil && store.selected?.pluginID == "org.crossdiff.office" }
        let excel = store.selected!, model = excel.officeModel
        try await ready(model)
        D.check(model.leftSection?.rows.count == 7 && model.rightSection?.rows.count == 7, "both complete spreadsheet row sets are imported")
        D.check(model.comparison!.rows.contains { $0.status == .equal && $0.moved }, "automatic exact matching identifies a reordered record")
        try await render("office-excel-auto-light", width: 1220, height: 790, dark: false)
        try await press("office.keys")
        try await press("office.key.1")
        try await pressTitle("完成")
        try await ready(model)
        D.check(model.state.keyColumns == [1] && model.comparison!.rows.filter { $0.basis == .key && $0.status == .modified }.count == 3, "native key selector pairs three changed records despite their reordered positions")
        try await render("office-excel-keys-light", width: 1220, height: 790, dark: false)
        AppSettings.shared.language = .english
        try await render("office-excel-keys-dark-narrow", width: 860, height: 620, dark: true)
        D.check(accessibleText().contains("Changes Only") && accessibleText().contains("Read-only"), "Office controls follow English language changes")
        try await search("CD-102")
        D.check(accessibleText().contains("CD-102") && !accessibleText().contains("CD-104"), "native search filters rows across both sources")
        try await search("")
        try await press("office.differencesOnly")
        D.check(model.state.onlyDifferences, "changes-only native control updates workspace state")
        let restored = try JSONDecoder().decode(StoredComparison.self, from: JSONEncoder().encode(excel.snapshot))
        D.check(restored.officeState?.keyColumns == [1] && restored.officeState?.onlyDifferences == true, "Office keys and filters survive actual session snapshots")
        model.state.onlyDifferences = false
        if let row = model.comparison!.rows.first(where: { $0.basis == .key }) {
            try await press("office.row." + row.id)
            try await renderSheet("office-cell-details-dark")
            try await pressTitle("Done")
        }
        model.selectSection(model.leftDocument!.sections[1].id, side: .left)
        try await ready(model)
        D.check(model.rightSection?.name == model.leftSection?.name && model.leftSection?.rows.last?.cells.last?.formula == "SUM(C2:C3)", "sheet navigation pairs names and retains formulas with saved results")
        try await render("office-excel-formula-dark", width: 1220, height: 790, dark: true)
        let word = try await create(urls[2], urls[3]); try await ready(word.officeModel)
        D.check(OfficePresentation.sectionName(word.officeModel.leftSection!, kind: .word) == "Body", "generated Word section title follows English language")
        D.check(word.officeModel.comparison!.rows.contains { $0.status == .modified }, "Word compares extracted paragraph changes")
        AppSettings.shared.language = .simplifiedChinese
        D.check(OfficePresentation.sectionName(word.officeModel.leftSection!, kind: .word) == "正文", "generated Word section title follows Chinese language")
        D.check(OfficePresentation.sectionName(.init(id: "sheet-1", name: "Body", rows: []), kind: .spreadsheet) == "Body", "user worksheet titles are never translated")
        try await render("office-word-light", width: 1220, height: 790, dark: false)
        try await render("office-word-dark-narrow", width: 860, height: 620, dark: true)
        try await press("office.left.preview")
        try await D.wait("original preview sheet") { D.window.attachedSheet != nil }
        D.check(accessibleText().contains("系统预览"), "original-file preview is an explicit native sheet")
        try await renderSheet("office-original-preview")
        try await press("office.preview.done")
        let ppt = try await create(urls[4], urls[5]); try await ready(ppt.officeModel)
        D.check(ppt.officeModel.leftDocument?.sections.count == 3, "presentation imports three slides in playback order")
        try await render("office-ppt-light", width: 1220, height: 790, dark: false)
        ppt.officeModel.selectSection(ppt.officeModel.leftDocument!.sections[1].id, side: .left)
        try await ready(ppt.officeModel)
        D.check(ppt.officeModel.comparison!.rows.contains { $0.status == .modified }, "slide selection compares changed slide content")
        AppSettings.shared.language = .english
        try await render("office-ppt-dark-narrow", width: 860, height: 620, dark: true)
        for (index, url) in urls.enumerated() { D.check(try Data(contentsOf: url) == bytes[index], "Office comparison leaves \(url.lastPathComponent) byte-identical") }
        let root = D.output.deletingLastPathComponent()
        let base = PluginManager(directory: root.appendingPathComponent("base-plugin-data"), bundledDirectory: root.appendingPathComponent("no-bundled-plugins"))
        base.pendingPackage = try PluginPackage.load(from: root.appendingPathComponent("Plugins/Office.crossdiffplugin"))
        base.installPending(trustNative: false)
        D.check(base.plugin(id: "org.crossdiff.office")?.enabled == true, "base installs the restricted Office package")
        _ = try base.execution(for: "org.crossdiff.office")
        D.check(OfficePresentation.columnName(27) == "AA" && OfficePresentation.columnName(16384) == "XFD", "Excel headings retain real column coordinates")
    }
    static func create(_ left: URL, _ right: URL) async throws -> ComparisonSession {
        let store = WorkspaceStore.shared
        store.beginNewComparison()
        try await D.wait("Office creation sheet") { store.newComparison != nil && D.window.attachedSheet != nil }
        let draft = store.newComparison!
        draft.select(NewComparisonType(kind: .plugin, pluginID: "org.crossdiff.office"))
        draft.setInput(.file(left), side: .left); draft.setInput(.file(right), side: .right)
        D.check(draft.canCreate, "Office accepts this same-format pair")
        draft.create()
        try await D.wait("Office creation completes") { store.newComparison == nil && D.window.attachedSheet == nil && store.selected?.pluginID == "org.crossdiff.office" }
        return store.selected!
    }
    static func ready(_ model: OfficeComparisonModel) async throws {
        let deadline = Date().addingTimeInterval(45)
        while model.isLoading || model.isComparing || model.comparison == nil {
            if let error = model.error { throw error }
            if Date() > deadline { throw D.CheckError(description: "Office comparison timeout") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if let error = model.error { throw error }
        try await D.pause()
    }
    static func render(_ name: String, width: Double, height: Double, dark: Bool) async throws {
        AppAppearance.shared.isDark = dark
        D.window.setContentSize(NSSize(width: width, height: height)); D.window.orderFront(nil)
        try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
        let view = D.window.contentView!.superview ?? D.window.contentView!
        let bitmap = try D.capture(view, rect: view.bounds, name: name)
        D.check(bitmap.pixelsWide >= Int(width), "\(name) renders the actual complete parent window")
    }
    static func renderSheet(_ name: String) async throws {
        try await D.pause()
        guard let window = D.window.attachedSheet, let view = window.contentView else { throw D.CheckError(description: "Missing Office sheet") }
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let parent = view.superview ?? view
        _ = try D.capture(parent, rect: parent.bounds, name: name)
    }
    static func press(_ identifier: String) async throws {
        let matches = objects().filter { string($0, "accessibilityIdentifier") == identifier }
        guard let object = matches.first(where: { $0 is NSControl }) ?? matches.first else { throw D.CheckError(description: "Missing control: \(identifier)") }
        try perform(object); try await D.pause()
    }
    static func pressTitle(_ title: String) async throws {
        guard let object = objects().first(where: { string($0, "accessibilityLabel") == title || ($0 as? NSButton)?.title == title }) else { throw D.CheckError(description: "Missing button: \(title)") }
        try perform(object); try await D.pause()
    }
    static func search(_ value: String) async throws {
        guard let field = objects().compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && ($0.placeholderString?.contains("查找内容") == true || $0.placeholderString?.contains("Find content") == true) }) else { throw D.CheckError(description: "Missing Office search field") }
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await D.pause()
    }
    static func perform(_ object: NSObject) throws {
        if let button = object as? NSButton { button.performClick(nil); return }
        let action = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: action) else { throw D.CheckError(description: "Control cannot press") }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        D.check(unsafeBitCast(object.method(for: action), to: Action.self)(object, action), "native control dispatches its action")
    }
    static func objects() -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func descend(_ object: NSObject, depth: Int) {
            if let view = object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
            guard depth < 45, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { for child in children { descend(child, depth: depth + 1) } }
            if let view = object as? NSView { for child in view.subviews { descend(child, depth: depth + 1) } }
        }
        for window in NSApp.windows where window.isVisible { if let view = window.contentView { descend(view, depth: 0) } }
        return result
    }
    static func string(_ object: NSObject, _ attribute: String) -> String {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
    static func accessibleText() -> String { objects().flatMap { [string($0, "accessibilityValue"), string($0, "accessibilityLabel")] }.joined(separator: "\n") }
}
