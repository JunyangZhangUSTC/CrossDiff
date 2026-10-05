import AppKit
import CrossDiffCore

@MainActor enum GitWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static var checks = 0
    static func check(_ value: Bool, _ name: String) { checks += 1; D.check(value, name) }
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-git-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty ? "PASS: \(checks) Git workflow checks" : "FAIL: " + D.failures.joined(separator: "; ")
            try? (D.report + [verdict]).joined(separator: "\n").write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            print(verdict); exit(D.failures.isEmpty ? 0 : 8)
        }
    }
    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        let root = D.output.deletingLastPathComponent().appendingPathComponent("fixtures/\(UUID().uuidString)/ReviewWorkspace")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        func git(in repository: URL? = nil, _ arguments: String...) throws -> String {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", (repository ?? root).path] + arguments
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"; environment["GIT_CONFIG_NOSYSTEM"] = "1"
            environment["GIT_AUTHOR_NAME"] = "Demo"; environment["GIT_COMMITTER_NAME"] = "Demo"
            environment["GIT_AUTHOR_EMAIL"] = "demo@example.com"; environment["GIT_COMMITTER_EMAIL"] = "demo@example.com"
            process.environment = environment
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw D.CheckError(description: "Fixture git failed") }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git("init", "-b", "main")
        let a = "// A small comparison workspace\nimport Foundation\n\nstruct ReviewOptions {\n    let title = \"CrossDiff\"\n    let contextLines = 3\n    let detectRenames = false\n\n    func summary() -> String {\n        return \"Review changes locally\"\n    }\n}\n"
        let b = "// A small comparison workspace\nimport Foundation\n\nstruct ReviewOptions {\n    let title = \"CrossDiff\"\n    let contextLines = 5\n    let detectRenames = true\n    let preserveOriginals = true\n\n    func summary() -> String {\n        return \"Compare every revision locally\"\n    }\n}\n"
        try a.write(to: root.appendingPathComponent("Sources/ReviewOptions.swift"), atomically: true, encoding: .utf8)
        try "Same content\n".write(to: root.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        try "Documentation\n".write(to: root.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8)
        _ = try git("add", "."); _ = try git("commit", "-m", "Create the comparison workspace")
        _ = try git("branch", "release"); _ = try git("tag", "v1.0")
        try b.write(to: root.appendingPathComponent("Sources/ReviewOptions.swift"), atomically: true, encoding: .utf8)
        try "# Quick start\nChoose two revisions.\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try git("mv", "Notes.md", "Guide.md")
        try Data([0, 1, 255, 32, 0]).write(to: root.appendingPathComponent("Sample.bin"))
        _ = try git("add", "."); _ = try git("commit", "-m", "Add rename detection and a safer review")
        let staged = b.replacingOccurrences(of: "contextLines = 5", with: "contextLines = 8")
        let working = staged.replacingOccurrences(of: "Compare every revision locally", with: "Compare staged and working changes")
        let sourceFile = root.appendingPathComponent("Sources/ReviewOptions.swift")
        try staged.write(to: sourceFile, atomically: true, encoding: .utf8)
        _ = try git("add", "Sources/ReviewOptions.swift")
        try working.write(to: sourceFile, atomically: true, encoding: .utf8)
        try "New working draft\n".write(to: root.appendingPathComponent("Draft.md"), atomically: true, encoding: .utf8)
        try "ignored.log\n".write(to: root.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        try "Ignored content\n".write(to: root.appendingPathComponent("ignored.log"), atomically: true, encoding: .utf8)
        let before = try git("status", "--porcelain=v1")
        let indexBefore = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try await D.wait("Git native window") { D.window = NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }; return D.window != nil }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.makeKeyAndOrderFront(nil)
        let store = WorkspaceStore.shared
        check(PluginManager.shared.enabledPlugins.contains { $0.id == GitComparisonModel.pluginID }, "Base inventory includes the real Git plugin")
        store.beginNewComparison(kind: .plugin, pluginID: GitComparisonModel.pluginID)
        try await D.wait("Git chooser") { store.newComparison?.selectedType?.isGit == true }
        let draft = store.newComparison!; draft.setInput(.file(root), side: .left)
        check(draft.canCreate && draft.right == .empty, "Git chooser accepts one repository instead of two file sources")
        draft.gitRemote = true; draft.gitRemoteURL = "https://github.com/example/repository"
        for (name, dark, language) in [("git-source-zh-light", false, AppLanguage.simplifiedChinese), ("git-source-en-dark", true, .english)] {
            AppSettings.shared.language = language; AppAppearance.shared.isDark = dark
            try await D.pause()
            if let sheet = D.window.attachedSheet, let view = sheet.contentView {
                view.layoutSubtreeIfNeeded(); sheet.displayIfNeeded()
                _ = try D.capture(view, rect: view.bounds, name: name)
            }
        }
        check(draft.canCreate, "A remote URL is validated independently of a retained local source")
        draft.gitRemote = false
        AppSettings.shared.language = .simplifiedChinese; AppAppearance.shared.isDark = false
        draft.create()
        try await D.wait("Git comparison session") { store.newComparison == nil && store.selected?.pluginID == GitComparisonModel.pluginID }
        let session = store.selected!, model = session.gitComparisonModel
        try await D.wait("Git history and comparison") { !model.isLoading && model.comparison != nil }
        check(model.errorMessage == nil && model.references.contains { $0.name == "release" }, "Branches and commits load from the repository")
        check(model.activePreset == .allChanges && model.comparison?.rightSnapshot.source == .workingTree, "A new local session defaults to all uncommitted changes")
        check(model.comparison?.files.contains { $0.path == "Draft.md" } == true && model.comparison?.files.contains { $0.path == "ignored.log" } == false, "Untracked files are included while repository exclusions are respected")
        guard let changed = model.comparison?.files.first(where: { $0.path == "Sources/ReviewOptions.swift" }) else { throw D.CheckError(description: "Missing changed file") }
        await model.selectFile(changed)
        try await D.wait("Git read-only editors") { model.detailSession?.calculating == false && model.detailSession?.leftEditorState != nil && model.detailSession?.rightEditorState != nil }
        let detail = model.detailSession!
        check(detail.left.text == b && detail.right.text == working, "All Uncommitted reads HEAD against the actual working contents")
        check(detail.leftEditorState?.editor.isEditable == false && detail.rightEditorState?.editor.isEditable == false, "Both native editors are selectable but read-only")
        check(detail.result?.hunks.isEmpty == false && detail.leftEditorState?.editor.layoutManager != nil, "Existing character diff and native rendering are active")
        check(model.filteredFiles.allSatisfy { $0.kind != .unchanged }, "Tree defaults to changes only")
        model.state.differencesOnly = false
        check(model.filteredFiles.contains { $0.path == "LICENSE" }, "All files includes unchanged blobs")
        model.pathFilter = "ReviewOptions"
        check(model.filteredFiles.count == 1, "Path filtering selects a nested changed source")
        model.pathFilter = ""; model.state.differencesOnly = true
        let snapshot = try JSONEncoder().encode(session.snapshot)
        let restored = try JSONDecoder().decode(StoredComparison.self, from: snapshot)
        check(restored.gitState?.selectedPath == changed.id && restored.left.text.isEmpty && restored.right.text.isEmpty, "Persistence keeps Git viewing state without copying blobs into sessions")
        NativeMenuController.shared.registerComparisonWindow(D.window)
        D.window.setFrameOrigin(NSPoint(x: 80, y: 100))
        NSApp.activate(ignoringOtherApps: true)
        D.window.makeKeyAndOrderFront(nil); D.window.makeFirstResponder(detail.rightEditorState!.editor)
        try await D.wait("active Git test window") { NSApp.keyWindow === D.window && D.window.attachedSheet == nil }
        NativeMenuController.shared.find(nil)
        check(detail.isSearchVisible && !detail.isReplaceVisible, "Command-F routes to Git's read-only detail")
        detail.searchQuery = "let"
        try await D.wait("Git search") { !detail.searching && detail.searchMatches.count > 1 }
        NativeMenuController.shared.findNext(nil)
        check(detail.currentMatch != nil, "Find Next navigates Git source text")
        NativeMenuController.shared.findAndReplace(nil)
        check(!detail.isReplaceVisible, "Find and Replace cannot mutate committed snapshots")
        detail.closeSearch()
        for (name, width, dark, language) in [("git-zh-light", 1220.0, false, AppLanguage.simplifiedChinese), ("git-en-dark", 1220.0, true, .english), ("git-zh-narrow", 860.0, false, .simplifiedChinese)] {
            AppSettings.shared.language = language; AppAppearance.shared.isDark = dark
            D.window.setContentSize(NSSize(width: width, height: width == 860 ? 580 : 790))
            try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
            let view = D.window.contentView!.superview ?? D.window.contentView!
            _ = try D.capture(view, rect: view.bounds, name: name)
            check(detail.leftEditorState?.editor.window === D.window && detail.rightEditorState?.editor.window === D.window, "\(name) retains both native panes in the real window")
        }
        let execution = try PluginManager.shared.execution(for: GitComparisonModel.pluginID)
        model.applyPreset(.staged); await model.compare(execution: execution)
        if let file = model.comparison?.files.first(where: { $0.path == changed.path }) { await model.selectFile(file) }
        check(model.detailSession?.left.text == b && model.detailSession?.right.text == staged, "Staged shows the index version rather than later working edits")
        let localState = try JSONDecoder().decode(StoredComparison.self, from: JSONEncoder().encode(session.snapshot))
        check(localState.gitState?.leftKind == .commit && localState.gitState?.rightKind == .index, "Session persistence retains the selected staging-area source")
        var oldRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.state)) as! [String: Any]
        oldRecord.removeValue(forKey: "leftKind"); oldRecord.removeValue(forKey: "rightKind"); oldRecord.removeValue(forKey: "includeUntracked")
        let oldState = try JSONDecoder().decode(GitWorkspaceState.self, from: JSONSerialization.data(withJSONObject: oldRecord))
        check(oldState.leftKind == .commit && oldState.rightKind == .commit, "Earlier Git sessions continue to mean two commit sources")
        model.applyPreset(.unstaged); await model.compare(execution: execution)
        if let file = model.comparison?.files.first(where: { $0.path == changed.path }) { await model.selectFile(file) }
        check(model.detailSession?.left.text == staged && model.detailSession?.right.text == working, "Unstaged isolates edits made after git add")
        model.state.includeUntracked = false; await model.compare(execution: execution)
        check(model.comparison?.files.contains { $0.path == "Draft.md" } == false, "The untracked toggle removes new files from the working snapshot")
        model.state.includeUntracked = true
        model.swapRevisions(); await model.compare(execution: execution)
        if let file = model.comparison?.files.first(where: { $0.path == changed.path }) { await model.selectFile(file) }
        check(model.state.leftKind == .workingTree && model.detailSession?.left.text == working && model.detailSession?.right.text == staged, "Swap preserves source kinds and reverses actual contents")
        model.applyPreset(.allChanges); await model.compare(execution: execution)
        let lateEdit = working + "// Changed after comparison\n"
        try lateEdit.write(to: sourceFile, atomically: true, encoding: .utf8)
        if let file = model.comparison?.files.first(where: { $0.path == changed.path }) { await model.selectFile(file) }
        check(model.detailSession == nil && model.detailMessage != nil, "A file changed after scanning never appears under an old tree snapshot")
        await model.refresh(execution: execution)
        if let file = model.comparison?.files.first(where: { $0.path == changed.path }) { await model.selectFile(file) }
        check(model.detailSession?.right.text == lateEdit, "Refresh captures external file edits")
        try working.write(to: sourceFile, atomically: true, encoding: .utf8)
        let recovery = GitComparisonModel(state: .init(source: root.path, isRemote: false))
        await recovery.open(execution: execution, executionID: "recovery-check")
        let cancelledDetail = Task { await recovery.selectFile(changed) }
        cancelledDetail.cancel(); await cancelledDetail.value
        check(recovery.detailSession == nil, "Cancellation does not publish a partial Git detail")
        await recovery.open(execution: execution, executionID: "recovery-check")
        check(recovery.detailSession?.right.text == working, "Reopening a cached tree resumes a cancelled file preview")
        recovery.cancel()
        model.setRevision("release", side: .left); model.setRevision("main", side: .right)
        await model.compare(execution: execution)
        check(model.comparison?.changedFiles.count == 4, "Branch selection compares added, renamed, binary and modified files")
        if let binary = model.comparison?.files.first(where: { $0.path == "Sample.bin" }) {
            await model.selectFile(binary)
            check(model.detailSession?.right.text.contains("00 01 FF") == true && model.detailMessage != nil, "Binary content gets an explicitly bounded hexadecimal preview")
        }
        model.setRevision("missing-revision", side: .right); await model.compare(execution: execution)
        check(model.errorMessage != nil && model.comparison == nil && model.detailSession == nil, "Invalid revision clears stale comparison under new selectors")
        let remote = GitComparisonModel(state: .init(source: "https://github.com/example/repository.git", isRemote: true))
        await remote.open(execution: execution)
        check(remote.needsConnection && !FileManager.default.fileExists(atPath: remote.cacheURL.path), "Restoring a missing remote cache never starts network work")
        let unbornRoot = root.deletingLastPathComponent().appendingPathComponent("FirstCommit")
        try FileManager.default.createDirectory(at: unbornRoot, withIntermediateDirectories: true)
        _ = try git(in: unbornRoot, "init", "-b", "main")
        try "First draft\n".write(to: unbornRoot.appendingPathComponent("Draft.txt"), atomically: true, encoding: .utf8)
        let unborn = GitComparisonModel(state: .init(source: unbornRoot.path, isRemote: false))
        await unborn.open(execution: execution)
        check(unborn.errorMessage == nil && unborn.comparison?.leftSnapshot.isEmptyBaseline == true && unborn.comparison?.changedFiles.count == 1, "A repository without commits can compare its first working draft against an empty baseline")
        unborn.cancel()
        check(try Data(contentsOf: root.appendingPathComponent(".git/index")) == indexBefore, "Reading local comparisons never writes or refreshes the actual index")
        check(try git("status", "--porcelain=v1") == before, "Working tree changes and index remain intact")
        check(!session.dirty, "Read-only Git session never becomes unsaved text")
        let empty = GitComparisonModel(state: .init(source: "", isRemote: false))
        await empty.open(execution: execution)
        check(empty.errorMessage != nil && empty.repository == nil, "An invalid restored source cannot fall back to the current directory")
        let previousRevision = model.state.rightRevision
        model.setRevision(String(repeating: "x", count: 1025), side: .right)
        check(model.state.rightRevision == previousRevision && model.state.isValid, "An excessive revision does not corrupt the persisted repository identity")
        model.cancel()
    }
}
