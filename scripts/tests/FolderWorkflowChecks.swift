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
            if !D.failures.isEmpty { captureFailureDiagnostics() }
            let verdict = D.failures.isEmpty
                ? "PASS: paired native folder tree, linked rows and scrolling, natural and metadata sorting, scoped navigation, contextual search and filters, selection/copy safety, retained scans, Chinese/English and light/dark windows"
                : "FAIL: " + D.failures.joined(separator: "; ")
            D.log(verdict)
            try? D.report.joined(separator: "\n").write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(D.failures.isEmpty ? 0 : 8)
        }
    }

    static func captureFailureDiagnostics(prefix: String = "folders-failure") {
        guard let window = D.window else {
            D.log("Failure diagnostics: no application window was created.")
            return
        }
        if let parent = window.contentView?.superview ?? window.contentView {
            parent.layoutSubtreeIfNeeded(); parent.displayIfNeeded()
            do { _ = try D.capture(parent, rect: parent.bounds, name: prefix + "-window") }
            catch { D.log("Failure window capture: \(error)") }
        }
        // Record structure rather than input contents; fixtures and diagnostics
        // remain inside the isolated project's render directory.
        let controls = objects().filter {
            $0 is NSControl || $0 is NSTextView || !string($0, "accessibilityIdentifier").isEmpty
        }.map { object in
            let type = String(reflecting: Swift.type(of: object))
            let identifier = string(object, "accessibilityIdentifier")
            let nativeIdentifier = (object as? NSView)?.identifier?.rawValue ?? ""
            let placeholder = (object as? NSTextField)?.placeholderString ?? ""
            return "type=\(type) | identifier=\(identifier) | nativeIdentifier=\(nativeIdentifier) | placeholder=\(placeholder)"
        }
        do {
            try controls.joined(separator: "\n").write(to: D.output.appendingPathComponent(prefix + "-controls.txt"), atomically: true, encoding: .utf8)
            D.log("Failure diagnostics: \(controls.count) visible controls recorded in \(prefix)-controls.txt.")
        } catch { D.log("Failure control diagnostics: \(error)") }
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
        D.check(has("folders.status-filter"), "native status filter replaces the old differences-only checkbox")
        model.statusFilter = .all
        try await D.wait("all-status filter") { !model.differencesOnly && !model.filtering }
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

        AppSettings.shared.language = .simplifiedChinese
        try await render("folders-overview-zh-dark-860", width: 860, height: 640, dark: true)
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
        let retainedEntryCount = model.result?.entries.count
        model.selection = ["left-only.md"]
        model.scan(left: left, right: right)
        let cancelledScanCount = model.scanCount
        D.check(model.scanning && !model.canCopy(toRight: true) && !model.canCopy(toRight: false), "copy is unavailable during a rescan")
        model.cancel()
        try await D.wait("cancelled scan stops") { !model.scanning && !model.busy }
        D.check(model.result?.isComplete != true && !model.canCopy(toRight: true) && !model.canCopy(toRight: false), "cancelled partial results never enable copy")
        D.check(model.result == nil && model.displayingPreviousScan && model.displayedResult?.entries.count == retainedEntryCount,
                "immediate rescan cancellation retains the old display snapshot without treating it as a current result")
        try await enter("-only.md", identifier: "folders.filter")
        model.setSort(FolderBrowserSort(key: .name, ascending: false))
        try await browserReady(model)
        D.check(model.browserProjection.rows.map { $0.entry.path } == ["right-only.md", "left-only.md"],
                "query and descending sort still work on the read-only previous snapshot after cancellation")
        model.selection = ["left-only.md"]
        D.check(model.displayingPreviousScan && !model.canCopy(toRight: true) && !model.canCopy(toRight: false),
                "selecting a retained snapshot row cannot authorize copying after cancellation")
        try await switchTo(other)
        store.selectedID = session.id
        try await D.wait("cancelled tab restored") { has("folders.reload") }
        try await D.pause()
        D.check(model.scanCount == cancelledScanCount && !model.scanning, "tab return does not restart an explicitly cancelled scan")
        try await render("folders-cancelled-dark-860", width: 860, dark: true)

        model.scan(left: left, right: right)
        try await ready(model)
        try await browserReady(model)
        D.check(model.scanCount == cancelledScanCount + 1 && !model.displayingPreviousScan && model.result?.isComplete == true,
                "a deliberate new scan replaces the retained snapshot with a complete current result")
        model.selection = ["left-only.md"]
        D.check(model.canCopy(toRight: true), "copy becomes available again only after the replacement scan is complete")
        model.scan(left: left, right: right)
        store.close(session)
        try await D.wait("closing folder tab stops its work") { !model.scanning && !model.busy }
        D.check(!store.sessions.contains { $0.id == session.id } && model.result?.isComplete != true, "closing the tab cancels the retained scan")
        D.check(!FileManager.default.fileExists(atPath: right.appendingPathComponent("left-only.md").path) && !FileManager.default.fileExists(atPath: left.appendingPathComponent("right-only.md").path), "viewing, filtering, refreshing and cancelling never copy files")
        try await checkPairedBrowser()
        try await checkFolderReplacement()
        try await checkLiveProgress()
    }

    static func checkFolderReplacement() async throws {
        D.log("Checking in-place folder replacement and copy safety")
        let store = WorkspaceStore.shared
        let fixtures = root.appendingPathComponent("replace-folders-" + UUID().uuidString, isDirectory: true)
        let left = fixtures.appendingPathComponent("Original Left")
        let right = fixtures.appendingPathComponent("Original Right")
        let nextLeft = fixtures.appendingPathComponent("新的左侧目录 · A much longer folder name")
        let nextRight = fixtures.appendingPathComponent("新的右侧目录 · Another long folder name")
        for directory in [left, right, nextLeft, nextRight] {
            try write(directory, "nested/common.txt", "same")
        }
        try write(left, "old-only.txt", "must never be copied after replacement")
        try write(nextLeft, "new-only.txt", "explicitly reviewed new copy")
        let session = ComparisonSession(kind: .folder, left: .init(path: left.path), right: .init(path: right.path))
        store.attach(session); store.selectedID = session.id
        let model = session.folderComparisonModel
        try await ready(model)
        let count = store.sessions.count, originalScans = model.scanCount
        model.selection = ["old-only.txt"]
        let originalSnapshot = try D.encoded(session)

        try await press("folders.replace-left")
        try await D.wait("left folder chooser sheet") { D.window.attachedSheet is NSOpenPanel }
        guard let panel = D.window.attachedSheet as? NSOpenPanel else { throw D.CheckError(description: "Missing folder chooser") }
        D.check(panel.canChooseDirectories && !panel.canChooseFiles && !panel.allowsMultipleSelection && !panel.canCreateDirectories,
                "replacement picker chooses one existing folder")
        panel.cancel(nil)
        try await D.wait("folder chooser cancelled") { D.window.attachedSheet == nil }
        D.check(try D.encoded(session) == originalSnapshot && model.scanCount == originalScans && model.selection == ["old-only.txt"],
                "cancelling leaves both inputs, selection and scan unchanged")
        D.check(!store.replaceFolder(left, for: session, side: .left) && model.scanCount == originalScans && model.selection == ["old-only.txt"],
                "choosing the same folder is a no-op")

        model.prepare(paths: ["old-only.txt"], toRight: true)
        D.check(!store.replaceFolder(nextLeft, for: session, side: .left), "copy verification blocks folder replacement")
        try await D.wait("replacement safety copy preview") { model.preview != nil && !model.busy }
        guard let oldPlan = model.preview else { throw D.CheckError(description: "Missing old copy plan") }
        D.check(!model.canReplaceRoots && !store.replaceFolder(nextLeft, for: session, side: .left), "pending copy confirmation blocks folder replacement")
        model.preview = nil
        try await D.wait("old copy preview dismissed") { D.window.attachedSheet == nil }

        model.browserMode = .list; model.statusFilter = .all
        model.setSort(.init(key: .rightSize, ascending: false)); model.showModifiedDates = true
        model.query = "new"; model.scopePath = "nested"; model.expandedPaths = ["nested"]
        let ignored = model.ignoredNames
        model.scan(left: left, right: right)
        D.check(model.scanning && store.replaceFolder(nextLeft, for: session, side: .left), "an active read-only scan can be replaced")
        D.check(model.selection.isEmpty && model.scopePath.isEmpty && model.expandedPaths.isEmpty && model.preview == nil,
                "new roots immediately invalidate old selection, scope, expansion and copy preview")
        // A second replacement before any worker publishes must win.
        D.check(store.replaceFolder(left, for: session, side: .left) && store.replaceFolder(nextLeft, for: session, side: .left),
                "rapid consecutive replacements remain accepted")
        try await ready(model)
        D.check(session.left.path == nextLeft.path && session.right.path == right.path && model.result?.leftRoot.path == nextLeft.path && model.result?.rightRoot.path == right.path,
                "only the latest left folder publishes; the right input is unchanged")
        D.check(model.browserMode == .list && model.statusFilter == .all && model.sortOrder == .init(key: .rightSize, ascending: false)
                && model.query == "new" && model.showModifiedDates && model.ignoredNames == ignored,
                "replacement retains view, search, filter, sort, date and ignore preferences")
        model.execute(oldPlan, left: left, right: right)
        D.check(!model.busy && !FileManager.default.fileExists(atPath: right.appendingPathComponent("old-only.txt").path),
                "a stale copy confirmation cannot write into an old root")

        // Exercise the right-hand button and native picker independently from
        // the input transition: NSOpenPanel has no public URL selection setter.
        try await press("folders.replace-right")
        try await D.wait("right folder chooser sheet") { D.window.attachedSheet is NSOpenPanel }
        guard let rightPanel = D.window.attachedSheet as? NSOpenPanel else { throw D.CheckError(description: "Missing right folder chooser") }
        D.check(rightPanel.title == L("更换右侧文件夹", "Change Right Folder"), "right-hand action opens the correctly labelled picker")
        rightPanel.cancel(nil)
        try await D.wait("right folder chooser dismissed") { D.window.attachedSheet == nil }
        D.check(store.replaceFolder(nextRight, for: session, side: .right), "right folder replacement is accepted")
        try await ready(model)
        D.check(session.left.path == nextLeft.path && model.result?.rightRoot.path == nextRight.path && store.selectedID == session.id && store.sessions.count == count,
                "right replacement retains the left folder, current tab and session count")
        D.check(session.title == "\(nextLeft.lastPathComponent) ↔ \(nextRight.lastPathComponent)", "tab title follows both new folder names")
        D.check(store.persistNow(), "replaced folder inputs save successfully")
        let saved = try SessionFile.load(from: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]!).appendingPathComponent("sessions.json"))
        D.check(saved.first { $0.id == session.id }?.left.path == nextLeft.path && saved.first { $0.id == session.id }?.right.path == nextRight.path,
                "session persistence restores new folder paths")
        for english in [false, true] {
            AppSettings.shared.language = english ? .english : .simplifiedChinese
            for dark in [false, true] {
                try await render("folders-replacement-\(english ? "en" : "zh")-\(dark ? "dark" : "light")-860", width: 860, height: 640, dark: dark)
                D.check(has("folders.replace-left") && has("folders.replace-right"), "both replacement controls remain available with long names at minimum width")
            }
        }
        model.selection = ["new-only.txt"]
        model.prepare(paths: model.selection, toRight: true)
        try await D.wait("new root copy preview") { model.preview != nil && !model.busy }
        guard let newPlan = model.preview else { throw D.CheckError(description: "Missing new copy plan") }
        model.execute(newPlan, left: nextLeft, right: nextRight)
        D.check(!store.replaceFolder(left, for: session, side: .left), "executing copy blocks folder replacement")
        try await ready(model)
        D.check(try String(contentsOf: nextRight.appendingPathComponent("new-only.txt"), encoding: .utf8) == "explicitly reviewed new copy",
                "freshly confirmed copy writes to the replacement destination")
        D.check(!store.replaceFolder(nextLeft.appendingPathComponent("new-only.txt"), for: session, side: .left)
                && session.left.path == nextLeft.path, "invalid file input cannot change a folder root")
        model.error = nil
        store.close(session)
        D.check(!store.replaceFolder(left, for: session, side: .left), "late chooser results cannot modify a closed session")
        D.log("Completed folder replacement, persistence and copy safety checks")
    }

    /// A second session keeps browser fixtures independent from the retained
    /// scan/cancellation regression above. All interactions use paired row IDs.
    static func checkPairedBrowser() async throws {
        let fixtures = root.appendingPathComponent("paired-browser-" + UUID().uuidString, isDirectory: true)
        let left = fixtures.appendingPathComponent("Project Source", isDirectory: true)
        let right = fixtures.appendingPathComponent("Project Reference", isDirectory: true)
        for directory in [left, right] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(directory, "README.md", "Shared documentation\n")
            try write(directory, "docs/manual.md", "The same manual\n")
        }
        try write(left, "docs/tutorial/chapter2.md", "Before the revision\n")
        try write(right, "docs/tutorial/chapter2.md", "After a longer revision\n")
        try write(left, "left-only.txt", "Available on the left\n")
        try write(right, "right-only.txt", "Available on the right\n")
        try write(left, "design/source-only/deep/source.md", "Nested source document\n")
        try write(right, "incoming/deep/reference.txt", "Nested reference document\n")
        try write(left, "src/empty.txt", "")
        try write(right, "src/empty.txt", "new")
        try write(left, "src/file2.swift", String(repeating: "a", count: 1024))
        try write(right, "src/file2.swift", "b")
        try write(left, "src/file10.swift", "aa")
        try write(right, "src/file10.swift", String(repeating: "b", count: 1024))
        try write(left, "src/common.swift", "let side = 1\n")
        try write(right, "src/common.swift", "let side = 2\n")
        let names = ["empty.txt", "file2.swift", "file10.swift", "common.swift"]
        for (index, name) in names.enumerated() {
            let old = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3600)
            let new = Date(timeIntervalSince1970: 1_700_000_000 + Double(names.count - index) * 3600)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: left.appendingPathComponent("src/" + name).path)
            try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: right.appendingPathComponent("src/" + name).path)
        }
        for index in 0..<180 {
            try write(left, "Bulk Import/file-\(String(format: "%03d", index)).txt", "Synthetic local-only content \(index)\n")
        }
        // A single-sided sparse fixture exercises MiB ordering without content
        // verification or a large real allocation during the workflow checks.
        let large = left.appendingPathComponent("large-only.bin")
        try Data().write(to: large)
        let largeHandle = try FileHandle(forWritingTo: large)
        try largeHandle.truncate(atOffset: 8 * 1024 * 1024)
        try largeHandle.close()
        // A type conflict belongs in the issues filter, without permissions or
        // system-specific unreadability assumptions in the fixture.
        try write(left, "conflict/inside.txt", "A directory on the left\n")
        try write(right, "conflict", "A file on the right\n")
        let store = WorkspaceStore.shared
        let session = ComparisonSession(kind: .folder, left: .init(path: left.path), right: .init(path: right.path))
        let model = session.folderComparisonModel
        store.attach(session); store.selectedID = session.id
        defer { model.cancel(); store.close(session) }
        try await ready(model)
        try await browserReady(model)
        let scanCount = model.scanCount
        D.check(model.browserMode == .tree && model.statusFilter == .differences, "paired browser defaults to a differences tree")
        D.check(!model.showModifiedDates, "modification dates are optional rather than crowding the initial table")
        D.check(model.browserProjection.rows.count < 15 && (model.result?.entries.count ?? 0) > 190,
                "hundreds of single-sided descendants stay compact behind their directory row")
        D.check(model.browserProjection.rows.contains { $0.entry.path == "Bulk Import" && $0.hasChildren && !$0.isExpanded },
                "single-sided directory has a collapsed disclosure row")
        D.check(!model.browserProjection.rows.contains { $0.entry.path == "Bulk Import/file-179.txt" },
                "collapsed directory descendants are absent from the rendered rows")
        try checkColumns(model)
        try checkMissingSide(model, path: "left-only.txt", absentColumn: "rightName", presentColumn: "leftName")
        try checkMissingSide(model, path: "right-only.txt", absentColumn: "leftName", presentColumn: "rightName")

        try await press("folders.disclosure.left.docs")
        try await browserReady(model)
        D.check(model.browserProjection.rows.contains { $0.entry.path == "docs/tutorial" && $0.depth == 1 },
                "one disclosure exposes the same directory level in both panes")
        try await press("folders.disclosure.right.docs/tutorial")
        try await browserReady(model)
        D.check(model.browserProjection.rows.contains { $0.entry.path == "docs/tutorial/chapter2.md" && $0.depth == 2 },
                "nested disclosure retains depth and correspondence")
        try await selectNative("docs/tutorial/chapter2.md", model: model)
        try await press("folders.disclosure.right.docs")
        try await browserReady(model)
        D.check(model.selection.isEmpty && !model.canCopy(toRight: true), "collapsing an ancestor clears hidden selections before copy")

        let expansionBeforeSearch = model.expandedPaths
        try await enter("source.md", identifier: "folders.filter")
        try await browserReady(model)
        let searchPaths = model.browserProjection.rows.map { $0.entry.path }
        D.check(searchPaths == ["design", "design/source-only", "design/source-only/deep", "design/source-only/deep/source.md"],
                "search reveals the complete ancestor chain of a deep match")
        D.check(model.browserProjection.matchingEntries.map(\.path) == ["design/source-only/deep/source.md"],
                "context ancestors are not counted as additional search matches")
        model.toggleFolder("design")
        model.toggleFolder("docs/tutorial")
        try await browserReady(model)
        D.check(model.expandedPaths == expansionBeforeSearch && model.browserProjection.rows.map { $0.entry.path } == searchPaths,
                "search-only expansion ignores disclosure toggles without changing the saved tree state")
        try await enter("", identifier: "folders.filter")
        try await browserReady(model)
        D.check(model.expandedPaths == expansionBeforeSearch && !model.browserProjection.rows.contains { $0.entry.path == "design/source-only/deep/source.md" },
                "clearing search restores the user's disclosure state")

        model.statusFilter = .leftOnly
        try await browserReady(model)
        D.check(!model.browserProjection.matchingEntries.isEmpty && model.browserProjection.matchingEntries.allSatisfy { $0.status == .leftOnly },
                "left-only filtering selects actual left-only matches with contextual rows")
        model.statusFilter = .rightOnly
        try await browserReady(model)
        D.check(model.browserProjection.matchingEntries.allSatisfy { $0.status == .rightOnly }, "right-only filtering uses the corresponding side")
        model.statusFilter = .changed
        try await browserReady(model)
        D.check(model.browserProjection.matchingEntries.contains { $0.path == "src/common.swift" }
                && model.browserProjection.matchingEntries.allSatisfy { $0.status == .changed }, "modified filter retains content edits independently of single-sided files")
        model.statusFilter = .issues
        try await browserReady(model)
        D.check(model.browserProjection.matchingEntries.contains { $0.path == "conflict" && $0.status == .typeMismatch },
                "issues filter exposes file-versus-directory conflicts")
        model.statusFilter = .pending
        try await browserReady(model)
        D.check(model.browserProjection.matchingEntries.isEmpty, "completed verification leaves no pending matches")
        model.statusFilter = .all
        model.openFolder("src")
        try await browserReady(model)
        D.check(model.scopePath == "src" && model.browserProjection.rows.count == 4 && model.browserProjection.rows.allSatisfy { $0.depth == 0 && $0.entry.path.hasPrefix("src/") },
                "opening a directory scopes both sides together with a fresh top level")

        try await sortNative("leftName", key: .name, ascending: true, model: model)
        let natural = model.browserProjection.rows.map { $0.entry.path }
        D.check(natural.firstIndex(of: "src/file2.swift").flatMap { two in natural.firstIndex(of: "src/file10.swift").map { two < $0 } } == true,
                "native name header uses natural numeric ordering")
        try await selectNative("src/file2.swift", model: model)
        try await sortNative("leftSize", key: .leftSize, ascending: true, model: model)
        let leftSizes = model.browserProjection.rows.compactMap { $0.entry.left?.size }
        D.check(leftSizes == leftSizes.sorted() && leftSizes.first == 0 && leftSizes.last == 1024, "left-size header sorts actual bytes, including zero and 1 KiB")
        D.check(model.selection == ["src/file2.swift"] && selectedPaths(model) == ["src/file2.swift"], "size sorting keeps the selected path in both panes")
        try await sortNative("rightSize", key: .rightSize, ascending: false, model: model)
        let rightSizes = model.browserProjection.rows.compactMap { $0.entry.right?.size }
        D.check(rightSizes == rightSizes.sorted(by: >), "right-size header reorders complete pairs by the right-hand bytes")
        model.statusFilter = .rightOnly
        D.check(model.filtering && !model.canCopy(toRight: true) && !model.canCopy(toRight: false),
                "changing a filter immediately disables copy while the old selected row is still displayed")
        model.prepare(paths: ["src/file2.swift"], toRight: true)
        D.check(model.preview == nil && !model.busy,
                "preparing copy during reprojection is rejected synchronously without starting a preview")
        try await browserReady(model)
        D.check(model.selection.isEmpty && model.browserProjection.rows.isEmpty && model.preview == nil,
                "completed filtering clears the hidden selected file and never publishes a stale copy preview")
        model.statusFilter = .all
        try await browserReady(model)
        try await selectNative("src/file2.swift", model: model)
        try await sortNative("leftName", key: .name, ascending: false, model: model)
        D.check(model.browserProjection.rows.map { $0.entry.path } == Array(natural.reversed()), "reversing the name header reverses sibling ordering")

        model.showModifiedDates = true
        try await browserReady(model)
        try await sortNative("leftModified", key: .leftModified, ascending: true, model: model)
        let leftDates = model.browserProjection.rows.compactMap { $0.entry.left?.modifiedDate }
        D.check(leftDates == leftDates.sorted(), "left date ordering uses captured timestamps")
        try await sortNative("rightModified", key: .rightModified, ascending: true, model: model)
        let rightDates = model.browserProjection.rows.compactMap { $0.entry.right?.modifiedDate }
        D.check(rightDates == rightDates.sorted(), "right date ordering independently uses the right timestamps")
        try await press("folders.root", fallback: "根目录")
        try await browserReady(model)
        D.check(model.scopePath.isEmpty, "native root breadcrumb returns both sides to their common root")

        model.browserMode = .list
        try await browserReady(model)
        D.check(model.browserProjection.rows.count == model.result?.entries.count, "flat mode exposes every entry while retaining paired columns")
        try await sortNative("leftSize", key: .leftSize, ascending: false, model: model)
        let flatSizes = model.browserProjection.rows.compactMap { $0.entry.left?.kind == .file ? $0.entry.left?.size : nil }
        D.check(flatSizes == flatSizes.sorted(by: >) && flatSizes.first == 8 * 1024 * 1024,
                "flat numeric sorting spans directories and correctly orders MiB, KiB and zero-byte files")
        try await sortNative("status", key: .status, ascending: true, model: model)
        try await selectNative("left-only.txt", model: model)
        model.statusFilter = .rightOnly
        try await browserReady(model)
        D.check(model.selection.isEmpty && !model.canCopy(toRight: true), "status filtering clears now-hidden selection instead of copying invisible files")
        model.statusFilter = .all
        try await browserReady(model)
        let table = try pairedTable()
        table.scrollRowToVisible(table.numberOfRows - 1)
        try await D.pause()
        try checkPairedRowGeometry(model, row: table.numberOfRows - 1)
        D.check(table.enclosingScrollView?.contentView.documentView === table, "one native document and scroll offset own the paired panes")
        table.scrollRowToVisible(0)
        model.showModifiedDates = false
        try await render("folders-paired-list-zh-dark-860", width: 860, height: 640, dark: true)
        try await browserReady(model)
        try checkColumns(model)
        try checkInstantiatedRows(model, context: "folders-paired-list-zh-dark-860")

        model.browserMode = .tree
        model.showModifiedDates = false
        model.statusFilter = .differences
        model.setSort(FolderBrowserSort(key: .name, ascending: true))
        model.expandedPaths = ["src", "docs", "docs/tutorial", "design"]
        try await browserReady(model)
        try await selectNative("left-only.txt", model: model)
        D.check(model.canCopy(toRight: true), "the selected visible side-only file is eligible before invoking native copy preview")
        do {
            try await press("folders.copy-right", fallback: "复制到右")
            try await D.wait("native browser copy preview") { model.preview != nil && !model.busy }
        } catch {
            D.log("Copy preview diagnostic: busy=\(model.busy), filtering=\(model.filtering), scanning=\(model.scanning), selection=\(model.selection.sorted()), canCopyRight=\(model.canCopy(toRight: true)), error=\(String(describing: model.error)), status=\(model.status)")
            captureFailureDiagnostics(prefix: "folders-copy-preview-failure")
            throw error
        }
        D.check(model.preview?.actions.map(\.path) == ["left-only.txt"], "copy preview uses the selected paired path after sorting and filtering")
        D.check(!FileManager.default.fileExists(atPath: right.appendingPathComponent("left-only.txt").path), "opening copy preview does not write the target")
        model.preview = nil
        try await D.pause()
        // The earlier status-sort test deliberately preserved a scrolled anchor.
        // Reset it for appearance captures so row zero is visibly below the header.
        try pairedTable().scrollRowToVisible(0)
        try await D.pause()

        for english in [false, true] {
            AppSettings.shared.language = english ? .english : .simplifiedChinese
            for dark in [false, true] {
                for width in [1220.0, 860.0] {
                    let name = "folders-paired-\(english ? "en" : "zh")-\(dark ? "dark" : "light")-\(Int(width))"
                    try await render(name, width: width, height: width == 860 ? 640 : 790, dark: dark)
                    try await browserReady(model)
                    try checkColumns(model)
                    try checkInstantiatedRows(model, context: name)
                    try checkPairedRowGeometry(model, row: 0)
                    D.check(has("folders.mode") && has("folders.status-filter") && has("folders.reload") && has("folders.ignore") && has("folders.copy-right"),
                            "\(name): primary controls remain available")
                    D.check(model.selection == ["left-only.txt"] && selectedPaths(model) == ["left-only.txt"],
                            "\(name): language, appearance and window changes preserve the selected file")
                }
            }
        }
        model.showModifiedDates = true
        try await render("folders-paired-dates-en-dark-1220", width: 1220, dark: true)
        try await browserReady(model)
        try checkColumns(model)
        try checkInstantiatedDateCells(model, context: "folders-paired-dates-en-dark-1220")
        try checkInstantiatedRows(model, context: "folders-paired-dates-en-dark-1220")
        D.check(try pairedTable().tableColumns.filter { ["leftModified", "rightModified"].contains($0.identifier.rawValue) }.allSatisfy { !$0.isHidden },
                "optional modification columns appear on both sides at a comfortable width")
        for mode in [FolderBrowserMode.list, .tree] {
            model.browserMode = mode
            try await browserReady(model)
            let table = try pairedTable()
            table.scrollRowToVisible(0)
            try await D.pause()
            let name = "folders-paired-first-row-\(mode.rawValue)-en-dark-1220"
            try await render(name, width: 1220, dark: true)
            try await browserReady(model)
            try checkInstantiatedRows(model, context: name)
            try checkFirstRowGeometry(context: name)
        }
        D.check(model.scanCount == scanCount, "browsing, sorting, search, filters and appearance never rescan the filesystem")
        D.check(!FileManager.default.fileExists(atPath: right.appendingPathComponent("left-only.txt").path)
                && !FileManager.default.fileExists(atPath: left.appendingPathComponent("right-only.txt").path),
                "browser interactions and a cancelled copy preview leave both source trees untouched")
    }

    static func browserReady(_ model: FolderComparisonModel) async throws {
        try await D.wait("paired folder rows published") {
            guard !model.filtering, let table = try? pairedTable() else { return false }
            return table.numberOfRows == model.browserProjection.rows.count
        }
        try await D.pause()
    }

    static func pairedTable() throws -> NSTableView {
        guard let table = objects().compactMap({ $0 as? NSTableView }).first(where: { string($0, "accessibilityIdentifier") == "folders.paired-table" }) else {
            throw D.CheckError(description: "Missing paired native folder table")
        }
        return table
    }

    static func selectNative(_ path: String, model: FolderComparisonModel) async throws {
        guard let index = model.browserProjection.rows.firstIndex(where: { $0.entry.path == path }) else {
            throw D.CheckError(description: "Missing visible selection path: \(path)")
        }
        let table = try pairedTable()
        table.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        try await D.wait("native paired row selection") { model.selection == [path] }
        // The delegate publishes selection synchronously; the SwiftUI copy
        // controls need the following render turn to update their enabled state.
        try await D.pause()
    }

    static func selectedPaths(_ model: FolderComparisonModel) -> Set<String> {
        guard let table = try? pairedTable() else { return [] }
        return Set(table.selectedRowIndexes.compactMap { index in
            model.browserProjection.rows.indices.contains(index) ? model.browserProjection.rows[index].entry.path : nil
        })
    }

    static func sortNative(_ identifier: String, key: FolderBrowserSortKey, ascending: Bool, model: FolderComparisonModel) async throws {
        let table = try pairedTable()
        guard let column = table.tableColumns.first(where: { $0.identifier.rawValue == identifier }),
              let container = table.enclosingScrollView as? FolderComparisonTableContainer else {
            throw D.CheckError(description: "Native header is not sortable: \(identifier)")
        }
        // Invoke the same delegate entry point used by the native header. A
        // second click verifies direction reversal instead of setting the model.
        container.tableView(table, didClick: column)
        try await D.wait("native header sort \(identifier)") { model.sortOrder.key == key && !model.filtering }
        try await browserReady(model)
        if model.sortOrder.ascending != ascending {
            container.tableView(table, didClick: column)
            try await D.wait("native header reverse \(identifier)") { model.sortOrder.key == key && model.sortOrder.ascending == ascending && !model.filtering }
        }
        try await browserReady(model)
        D.check(table.numberOfRows == model.browserProjection.rows.count, "\(identifier) sorting preserves a single paired row set")
    }

    static func checkColumns(_ model: FolderComparisonModel) throws {
        let table = try pairedTable()
        let expected = ["leftName", "leftSize", "leftModified", "status", "rightName", "rightSize", "rightModified"]
        D.check(table.tableColumns.map { $0.identifier.rawValue } == expected, "paired column order groups left fields, status and right fields")
        D.check(table.tableColumns.allSatisfy { !($0.headerToolTip ?? "").isEmpty }, "every sortable header explains its paired ordering")
        if !model.showModifiedDates {
            D.check(table.tableColumns.filter { ["leftModified", "rightModified"].contains($0.identifier.rawValue) }.allSatisfy(\.isHidden), "date columns stay hidden until requested")
        }
        guard let clip = table.enclosingScrollView?.contentView else { throw D.CheckError(description: "Missing shared folder viewport") }
        guard let content = table.window?.contentView else { throw D.CheckError(description: "Missing window containing folder columns") }
        let contentInWindow = content.convert(content.bounds, to: nil)
        var geometryFailure = false
        for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
            let identifier = column.identifier.rawValue
            let rect = table.rect(ofColumn: index)
            let inWindow = table.convert(rect, to: nil)
            let fitsClip = rect.width > 24 && rect.minX >= clip.bounds.minX - 1 && rect.maxX <= clip.bounds.maxX + 1
            let fitsWindow = inWindow.minX >= contentInWindow.minX - 1 && inWindow.maxX <= contentInWindow.maxX + 1
            D.check(fitsClip,
                    "\(identifier) remains inside the shared viewport at \(Int(clip.bounds.width)) points")
            D.check(fitsWindow, "\(identifier) remains inside the composed window's content width")
            geometryFailure = geometryFailure || !fitsClip || !fitsWindow
        }
        if geometryFailure {
            let columns = table.tableColumns.enumerated().filter { !$0.element.isHidden }.map {
                "\($0.element.identifier.rawValue)=\(table.rect(ofColumn: $0.offset)), window=\(table.convert(table.rect(ofColumn: $0.offset), to: nil))"
            }.joined(separator: "; ")
            D.log("Column geometry: table.frame=\(table.frame), table.bounds=\(table.bounds), clip.bounds=\(clip.bounds), content.window=\(contentInWindow); \(columns)")
        }
        D.check(table.enclosingScrollView?.hasHorizontalScroller == false, "paired browser avoids sideways scrolling at the minimum window width")
    }

    static func checkMissingSide(_ model: FolderComparisonModel, path: String, absentColumn: String, presentColumn: String) throws {
        guard let row = model.browserProjection.rows.firstIndex(where: { $0.entry.path == path }) else {
            throw D.CheckError(description: "Missing single-sided fixture row")
        }
        let table = try pairedTable()
        func text(_ identifier: String) -> String {
            guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == identifier }),
                  let view = table.view(atColumn: column, row: row, makeIfNecessary: true) else { return "" }
            func values(_ view: NSView) -> [String] {
                ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(values)
            }
            return values(view).joined(separator: " ")
        }
        D.check(text(presentColumn).contains(path), "existing side shows the actual filename: \(path)")
        D.check(!text(absentColumn).isEmpty && !text(absentColumn).contains(path), "missing side has a distinct textual placeholder rather than a duplicated filename: \(path)")
    }

    static func checkInstantiatedDateCells(_ model: FolderComparisonModel, context: String) throws {
        let table = try pairedTable()
        var checked = 0
        for row in model.browserProjection.rows.indices {
            guard table.rowView(atRow: row, makeIfNecessary: false) != nil else { continue }
            for (index, column) in table.tableColumns.enumerated() where !column.isHidden && column.identifier.rawValue.hasSuffix("Modified") {
                let nameID = column.identifier.rawValue.hasPrefix("left") ? "leftName" : "rightName"
                guard let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? NSTableCellView,
                      let field = cell.textField,
                      let nameColumn = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == nameID }),
                      let name = table.view(atColumn: nameColumn, row: row, makeIfNecessary: false) else { continue }
                let bounds = cell.bounds, textFrame = field.frame
                let contained = textFrame.width > 0 && textFrame.height > 0
                    && textFrame.minX >= bounds.minX - 1 && textFrame.maxX <= bounds.maxX + 1
                    && textFrame.minY >= bounds.minY - 1 && textFrame.maxY <= bounds.maxY + 1
                let sharedHeight = bounds.height > 0 && abs(bounds.height - name.bounds.height) <= 1
                let centered = abs(textFrame.midY - bounds.midY) <= 2
                let identity = column.identifier.rawValue + "/" + model.browserProjection.rows[row].entry.path
                D.check(contained, "\(context): displayed date label \(identity) is entirely inside its native cell")
                D.check(sharedHeight, "\(context): displayed date cell \(identity) has the paired name cell's height")
                D.check(centered, "\(context): displayed date label \(identity) is vertically centered")
                if !contained || !sharedHeight || !centered {
                    D.log("Date cell geometry: \(identity), cell.frame=\(cell.frame), cell.bounds=\(bounds), textField.frame=\(textFrame), name.frame=\(name.frame), name.bounds=\(name.bounds), cell.window=\(cell.convert(bounds, to: nil))")
                }
                checked += 1
            }
        }
        D.check(checked > 0, "\(context): already-instantiated modification date cells were actually checked")
        D.log("\(context): checked geometry of \(checked) instantiated date cells")
    }

    static func checkInstantiatedRows(_ model: FolderComparisonModel, context: String) throws {
        let table = try pairedTable()
        let theme = ComparisonTheme(isDark: AppAppearance.shared.isDark)
        let originalSelection = model.selection
        let nativeSelection = table.selectedRowIndexes
        var checked = 0
        // Do not create new cells here: cached, previously visible rows are the
        // regression target when a short window grows after a theme change.
        for row in model.browserProjection.rows.indices {
            guard table.rowView(atRow: row, makeIfNecessary: false) != nil else { continue }
            let entry = model.browserProjection.rows[row].entry
            let background = table.isRowSelected(row) ? theme.selectionBackground : theme.canvas
            for (index, column) in table.tableColumns.enumerated() where column.identifier.rawValue.hasSuffix("Name") {
                guard let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? NSTableCellView,
                      let field = cell.textField, !field.isHidden else { continue }
                let snapshot = column.identifier.rawValue.hasPrefix("left") ? entry.left : entry.right
                guard let foreground = field.textColor?.usingColorSpace(.sRGB), let base = background.usingColorSpace(.sRGB) else {
                    D.check(false, "\(context): \(column.identifier.rawValue)/\(entry.path) has a resolvable text color")
                    continue
                }
                let alpha = foreground.alphaComponent
                let rendered = NSColor(srgbRed: foreground.redComponent * alpha + base.redComponent * (1 - alpha),
                                       green: foreground.greenComponent * alpha + base.greenComponent * (1 - alpha),
                                       blue: foreground.blueComponent * alpha + base.blueComponent * (1 - alpha), alpha: 1)
                let a = D.luminance(rendered), b = D.luminance(base)
                let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                let minimum = snapshot == nil ? 3.0 : 4.5
                D.check(contrast >= minimum,
                        "\(context): cached \(column.identifier.rawValue)/\(entry.path) remains readable (contrast \(String(format: "%.2f", contrast)), minimum \(minimum))")
                if snapshot == nil {
                    let expected = entry.status == .unreadable ? L("状态未知", "Unknown") : L("此侧不存在", "Not present")
                    D.check(field.stringValue == expected,
                            "\(context): cached \(column.identifier.rawValue)/\(entry.path) missing-side text follows the current language")
                }
                checked += 1
            }
        }
        D.check(checked > 0, "\(context): instantiated paired name cells were actually checked")
        D.check(model.selection == originalSelection && table.selectedRowIndexes == nativeSelection,
                "\(context): checking cached appearance leaves paired selection unchanged")
        D.log("\(context): checked \(checked) instantiated name cells against the current theme and language")
    }

    static func checkFirstRowGeometry(context: String) throws {
        let table = try pairedTable()
        guard table.numberOfRows > 0, let scroll = table.enclosingScrollView,
              let header = table.headerView, let content = table.window?.contentView else {
            throw D.CheckError(description: "Missing native first-row geometry")
        }
        let clip = scroll.contentView
        let rowInWindow = table.convert(table.rect(ofRow: 0), to: nil)
        let headerInWindow = header.convert(header.bounds, to: nil)
        let clipInWindow = clip.convert(clip.bounds, to: nil)
        let contentInWindow = content.convert(content.bounds, to: nil)
        let overlap = rowInWindow.intersection(headerInWindow)
        let viewInWindow = table.rowView(atRow: 0, makeIfNecessary: false).map { $0.convert($0.bounds, to: nil) }
        D.log("\(context): first-row.window=\(rowInWindow), instantiated-row.window=\(String(describing: viewInWindow)), header.window=\(headerInWindow), clip.window=\(clipInWindow), content.window=\(contentInWindow), clip.frame=\(clip.frame), clip.bounds=\(clip.bounds), scroll.contentInsets=\(scroll.contentInsets), clip.contentInsets=\(clip.contentInsets), table.frame=\(table.frame), table.bounds=\(table.bounds), table.visibleRect=\(table.visibleRect)")
        D.check(overlap.isEmpty || overlap.height <= 1, "\(context): scrolling to the top keeps the first row clear of the native header")
        D.check(rowInWindow.minY >= clipInWindow.minY - 1 && rowInWindow.maxY <= clipInWindow.maxY + 1,
                "\(context): the complete first row is inside the document viewport")
    }

    static func checkPairedRowGeometry(_ model: FolderComparisonModel, row: Int) throws {
        let table = try pairedTable()
        guard row >= 0 && row < table.numberOfRows else { throw D.CheckError(description: "Missing paired row for geometry check") }
        var rectangles: [NSRect] = []
        for identifier in ["leftName", "status", "rightName"] {
            guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == identifier }),
                  let view = table.view(atColumn: column, row: row, makeIfNecessary: true) else {
                throw D.CheckError(description: "Missing native paired cell: \(identifier)")
            }
            rectangles.append(view.convert(view.bounds, to: table))
        }
        D.check((rectangles.map(\.midY).max() ?? 0) - (rectangles.map(\.midY).min() ?? 0) <= 1,
                "left, status and right cells share the same visual row before and after scrolling")
        D.check((rectangles.map(\.height).max() ?? 0) - (rectangles.map(\.height).min() ?? 0) <= 1,
                "paired cells have a shared row height")
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
    static func render(_ name: String, width: Double, height: Double = 790, dark: Bool) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                AppAppearance.shared.isDark = dark
                D.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                D.window.setFrame(NSRect(x: -10000, y: -10000, width: width, height: height), display: true)
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
        if name.hasPrefix("folders-paired-") {
            let left = readablePixels(bitmap, from: 0.02, to: 0.46, background: ComparisonTheme(isDark: dark).canvas)
            let right = readablePixels(bitmap, from: 0.54, to: 0.98, background: ComparisonTheme(isDark: dark).canvas)
            D.check(left > 50 && right > 50, "\(name): both composed panes contain readable content (\(left), \(right))")
        }
        D.log("\(name): native \(Int(parent.bounds.width))×\(Int(parent.bounds.height)), contrasting pixels=\(pixels.readable)")
    }
    static func readablePixels(_ bitmap: NSBitmapImageRep, from: Double, to: Double, background: NSColor) -> Int {
        let base = D.luminance(background)
        var count = 0
        for y in stride(from: Int(Double(bitmap.pixelsHigh) * 0.18), to: Int(Double(bitmap.pixelsHigh) * 0.88), by: 4) {
            for x in stride(from: Int(Double(bitmap.pixelsWide) * from), to: Int(Double(bitmap.pixelsWide) * to), by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.9 else { continue }
                let value = D.luminance(color)
                if (max(base, value) + 0.05) / (min(base, value) + 0.05) > 4.5 { count += 1 }
            }
        }
        return count
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
            $0.isEditable && (string($0, "accessibilityIdentifier") == identifier || identifier == "folders.filter" && ["搜索相对路径", "Search relative paths", "筛选路径", "Filter Paths"].contains($0.placeholderString ?? ""))
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
