import AppKit
import CrossDiffCore

/// Runs against the real app window and retained comparison sessions. Fixture
/// files, session writes, preferences and captures all stay in the project.
@MainActor enum FolderWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static var root: URL { D.output.deletingLastPathComponent() }

    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-folder-workflow-checks/") == true,
              ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]?.contains(".build-folder-workflow-checks/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty
                ? "PASS: retained folder results and active scans across tabs, explicit refresh, native filters and ignore rules, cancellation/copy safety, Chinese/English, light/dark and 860-point windows"
                : "FAIL: " + D.failures.joined(separator: "; ")
            D.log(verdict)
            try? D.report.joined(separator: "\n").write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(D.failures.isEmpty ? 0 : 8)
        }
    }

    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        try await D.wait("own application window") {
            D.window = NativeMenuController.shared.comparisonWindow
            return D.window != nil
        }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.orderFront(nil)
        let fixtures = root.appendingPathComponent("fixtures-" + UUID().uuidString, isDirectory: true)
        let left = fixtures.appendingPathComponent("Source", isDirectory: true)
        let right = fixtures.appendingPathComponent("Reference", isDirectory: true)
        for directory in [left, right] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try write(left, "same.txt", "stable alpha\n"); try write(right, "same.txt", "stable alpha\n")
        try write(left, "config.json", "{\"port\":8080}\n"); try write(right, "config.json", "{\"port\":9000}\n")
        try write(left, "size.txt", "short\n"); try write(right, "size.txt", "a considerably longer file\n")
        try write(left, "left-only.md", "Left source, never automatically copied.\n")
        try write(right, "right-only.md", "Right source, never automatically copied.\n")
        for directory in [left, right] {
            try write(directory, "Documents/résumé-中文.txt", "Unicode relative path 👩🏽‍💻\n")
            try write(directory, ".git/internal", directory == left ? "old" : "new")
            try write(directory, "node_modules/dependency.js", directory == left ? "old" : "new")
            try write(directory, "generated/cache.bin", directory == left ? "old" : "new")
        }
        let store = WorkspaceStore.shared
        let session = ComparisonSession(kind: .folder, left: .init(path: left.path), right: .init(path: right.path))
        let other = ComparisonSession(left: .init(text: "Other tab", savedText: "Other tab"))
        store.sessions.removeAll(); store.attach(session); store.attach(other)
        store.selectedID = session.id; store.message = nil
        let model = session.folderComparisonModel
        try await ready(model)
        D.check(model.scanCount == 1, "first mounted folder session starts exactly one scan")
        D.check(status("same.txt", model) == .same && status("config.json", model) == .changed && status("size.txt", model) == .changed,
                "native session receives strict identical, same-size modified and size-modified results")
        D.check(status("left-only.md", model) == .leftOnly && status("right-only.md", model) == .rightOnly,
                "single-sided files remain separate additions/deletions")
        D.check(!model.result!.entries.contains { $0.path.hasPrefix(".git") || $0.path.hasPrefix("node_modules") },
                "default ignored directories never enter the comparison")
        D.check(model.result!.ignoredCount == 4, "ignored directories count once per side")
        D.check(model.visibleEntries.allSatisfy { $0.status != .same }, "default native table shows differences only")

        // Drive native controls so the checks cover their bindings as well as
        // the retained model. No user files or system clipboard are involved.
        try await press("folders.differences-only", fallback: "仅显示差异")
        try await D.wait("native differences toggle") { !model.differencesOnly }
        try await enter("config", identifier: "folders.filter")
        try await D.wait("native path filter") { model.query == "config" && model.visibleEntries.map(\.path) == ["config.json"] }
        model.selection = ["config.json"]
        let before = model.scanCount
        try write(right, "same.txt", "stable bravo\n")
        try await switchTo(other)
        store.selectedID = session.id
        try await D.wait("folder table restored") { has("folders.reload") }
        try await D.pause()
        D.check(session.folderComparisonModel === model && model.scanCount == before, "tab return retains the same model without rescanning")
        D.check(model.query == "config" && !model.differencesOnly && model.selection == ["config.json"], "tab return preserves path filter, differences option and selection")
        D.check(status("same.txt", model) == .same, "external edits do not silently replace the saved tab result")
        try await press("folders.reload", fallback: "重新比较")
        try await ready(model)
        D.check(model.scanCount == before + 1 && status("same.txt", model) == .changed, "native Compare Again performs one new scan and reveals the external same-size edit")
        try await enter("", identifier: "folders.filter")
        try await D.wait("clear native path filter") { model.query.isEmpty && model.visibleEntries.count == model.result?.entries.count }
        model.selection = ["left-only.md"]
        D.check(model.canCopy(toRight: true) && !model.canCopy(toRight: false), "completed selected file permits only the valid copy direction")

        for english in [false, true] {
            AppSettings.shared.language = english ? .english : .simplifiedChinese
            for dark in [false, true] {
                for width in [1220.0, 860.0] {
                    let name = "folders-\(english ? "en" : "zh")-\(dark ? "dark" : "light")-\(Int(width))"
                    try await render(name, width: width, dark: dark)
                    D.check(has("folders.reload") && has("folders.ignore") && has("folders.copy-right"), "\(name): native primary controls remain exposed")
                }
            }
        }

        AppSettings.shared.language = .simplifiedChinese
        try await press("folders.ignore", fallback: "忽略规则")
        try await D.wait("native ignore rule editor") { has("folders.ignore.apply") }
        try await enter(".git\n.DS_Store\n.build\nnode_modules\ngenerated", identifier: "folders.ignore.names")
        try await captureRules("folders-ignore-rules-dark-860")
        let beforeRules = model.scanCount
        try await press("folders.ignore.apply", fallback: "应用并比较")
        try await ready(model)
        D.check(model.scanCount == beforeRules + 1 && model.ignoredNames.contains("generated"), "native rule Apply updates this session and triggers one scan")
        D.check(!model.result!.entries.contains { $0.path == "generated" || $0.path.hasPrefix("generated/") } && model.result!.ignoredCount == 6,
                "custom ignored folder is excluded with one ignored item per side")
        D.check(!other.folderComparisonModel.ignoredNames.contains("generated"), "ignore rules do not leak to other sessions")

        // Enough independent files to exercise switching during an active scan
        // without adding timing hooks to the production comparison engine.
        for index in 0..<1800 {
            let path = "many/file-\(String(format: "%04d", index)).txt"
            let data = "Synthetic same file \(index)\n"
            try write(left, path, data); try write(right, path, data)
        }
        model.scan(left: left, right: right)
        let activeScanCount = model.scanCount
        D.check(model.scanning, "large rescan starts before switching tabs")
        try await switchTo(other)
        try await ready(model)
        D.check(store.selectedID == other.id && model.result!.entries.contains { $0.path == "many/file-1799.txt" }, "active scan finishes while its tab is in the background")
        store.selectedID = session.id
        try await D.wait("background result tab restored") { has("folders.reload") }
        try await D.pause()
        D.check(model.scanCount == activeScanCount && model.result?.isComplete == true, "returning to a background scan does not start another scan")

        // Cancel synchronously after a genuine scan begins, ensuring a previous
        // complete result cannot authorize writes after cancellation.
        model.selection = ["left-only.md"]
        model.scan(left: left, right: right)
        let cancelledScanCount = model.scanCount
        D.check(model.scanning && !model.canCopy(toRight: true) && !model.canCopy(toRight: false), "copy is unavailable during a rescan")
        model.cancel()
        try await D.wait("cancelled scan stops") { !model.scanning && !model.busy }
        D.check(model.result?.isComplete != true && !model.canCopy(toRight: true) && !model.canCopy(toRight: false), "cancelled partial results never enable copy")
        try await switchTo(other)
        store.selectedID = session.id
        try await D.wait("cancelled tab restored") { has("folders.reload") }
        try await D.pause()
        D.check(model.scanCount == cancelledScanCount && !model.scanning, "tab return does not restart an explicitly cancelled scan")
        try await render("folders-cancelled-dark-860", width: 860, dark: true)

        model.scan(left: left, right: right)
        store.close(session)
        try await D.wait("closing folder tab stops its work") { !model.scanning && !model.busy }
        D.check(!store.sessions.contains { $0.id == session.id } && model.result?.isComplete != true, "closing the tab cancels the retained scan")
        D.check(!FileManager.default.fileExists(atPath: right.appendingPathComponent("left-only.md").path) && !FileManager.default.fileExists(atPath: left.appendingPathComponent("right-only.md").path), "viewing, filtering, refreshing and cancelling never copy files")
        try await checkLiveProgress()
    }

    static func checkLiveProgress() async throws {
        let fixtures = root.appendingPathComponent("sparse-progress-" + UUID().uuidString, isDirectory: true)
        let left = fixtures.appendingPathComponent("Original", isDirectory: true)
        let right = fixtures.appendingPathComponent("Updated", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        // Sparse files allocate essentially no content blocks. Their large
        // logical size lets the actual background reader stay active while the
        // native window is captured, without production timing hooks or sleeps.
        for directory in [left, right] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("recording.bin")
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 8 * 1024 * 1024 * 1024)
            try handle.close()
            let allocated = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
            D.check(allocated < 1024 * 1024, "progress fixture remains sparse rather than filling the disk")
        }
        try write(left, "notes.txt", "A newly added side-only file\n")
        try write(left, "version.txt", "v1\n"); try write(right, "version.txt", "version 2\n")
        AppSettings.shared.language = .english
        AppAppearance.shared.isDark = true
        D.window.appearance = NSAppearance(named: .darkAqua)
        D.window.setFrame(NSRect(x: -10000, y: -10000, width: 860, height: 790), display: true)
        let session = ComparisonSession(kind: .folder, left: .init(path: left.path), right: .init(path: right.path))
        let store = WorkspaceStore.shared, model = session.folderComparisonModel
        store.attach(session); store.selectedID = session.id
        defer { model.cancel(); store.close(session) }
        do {
            try await D.wait("real pending rows and live progress") {
                model.scanning && model.progress?.stage == .comparing && !model.filtering &&
                model.visibleEntries.contains { $0.status == .pending } && has("folders.cancel")
            }
        } catch {
            D.log("Live progress diagnostic: selected=\(store.selectedID == session.id), scanning=\(model.scanning), filtering=\(model.filtering), scanCount=\(model.scanCount), progress=\(String(describing: model.progress)), result=\(String(describing: model.result?.entries.map { ($0.path, $0.status.rawValue) })), visible=\(model.visibleEntries.count), cancel=\(has("folders.cancel")), error=\(String(describing: model.error))")
            if let parent = D.window.contentView?.superview { _ = try? D.capture(parent, rect: parent.bounds, name: "folders-progress-diagnostic") }
            throw error
        }
        D.check(model.result?.isComplete == false && status("notes.txt", model) == .leftOnly && status("version.txt", model) == .changed,
                "metadata differences appear while equal-size content is still pending")
        model.selection = ["notes.txt"]
        D.check(!model.canCopy(toRight: true), "even a known side-only item cannot copy while the comparison is incomplete")
        guard let parent = D.window.contentView?.superview else { throw D.CheckError(description: "Missing live progress window") }
        parent.layoutSubtreeIfNeeded(); parent.displayIfNeeded()
        _ = try D.capture(parent, rect: parent.bounds, name: "folders-progress-en-dark-860")
        D.log("Live progress capture: \(model.progress?.completedPairs ?? -1)/\(model.progress?.totalPairs ?? -1) pairs, \(model.progress?.bytesRead ?? -1) bytes read, pending=\(model.visibleEntries.filter { $0.status == .pending }.count)")
        try await press("folders.cancel", fallback: "Cancel")
        D.check(!model.scanning && !model.busy && model.result?.isComplete == false && !model.canCopy(toRight: true),
                "actual native Cancel stops live content verification and keeps partial results read-only")
    }

    static func write(_ directory: URL, _ path: String, _ text: String) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    static func status(_ path: String, _ model: FolderComparisonModel) -> FolderEntryStatus? { model.result?.entries.first { $0.path == path }?.status }
    static func ready(_ model: FolderComparisonModel) async throws {
        try await D.wait("complete folder result") { !model.scanning && !model.busy && !model.filtering && model.result?.isComplete == true }
        D.check(model.error == nil, "folder result completes without a scan error")
        try await D.pause()
    }
    static func switchTo(_ session: ComparisonSession) async throws {
        WorkspaceStore.shared.selectedID = session.id
        try await D.wait("other native tab mounted") { session.leftEditorState?.editor.window === D.window && !has("folders.reload") }
    }
    static func render(_ name: String, width: Double, dark: Bool) async throws {
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
        let bitmap = try D.capture(parent, rect: parent.bounds, name: name)
        D.check(bitmap.pixelsWide >= Int(width), "\(name): complete parent window captured")
        let pixels = D.countPixels(bitmap, background: ComparisonTheme(isDark: dark).canvas)
        D.check(pixels.readable > 300, "\(name): contrasting text is actually drawn in the native window")
        D.log("\(name): native \(Int(parent.bounds.width))×\(Int(parent.bounds.height)), contrasting pixels=\(pixels.readable)")
    }
    static func captureRules(_ name: String) async throws {
        try await D.pause()
        guard let content = NSApp.windows.first(where: { $0 !== D.window && $0.isVisible && $0.contentView != nil && $0.frame.width > 250 && $0.frame.height > 150 })?.contentView else {
            throw D.CheckError(description: "Missing actual rule editor popover")
        }
        let parent = content.superview ?? content
        _ = try D.capture(parent, rect: parent.bounds, name: name)
    }
    static func enter(_ value: String, identifier: String) async throws {
        let all = objects()
        if let field = all.compactMap({ $0 as? NSTextField }).first(where: {
            $0.isEditable && (string($0, "accessibilityIdentifier") == identifier || identifier == "folders.filter" && ["筛选路径", "Filter Paths"].contains($0.placeholderString ?? ""))
        }) {
            field.stringValue = value
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        } else if let editor = all.compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable && (string($0, "accessibilityIdentifier") == identifier || identifier == "folders.ignore.names" && $0.window !== D.window) }) {
            editor.window?.makeFirstResponder(editor)
            editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        } else { throw D.CheckError(description: "Missing native text control: \(identifier)") }
        try await D.pause()
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
