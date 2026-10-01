import AppKit
import SwiftUI
import CrossDiffCore

@MainActor
enum ArchiveWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static var root: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]!).deletingLastPathComponent() }
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-archive-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty ? "PASS: bundled archive plugin, virtual folders, exact states, content groups, routing, cancellation, result validation, native UI and immutable sources" : "FAIL: " + D.failures.joined(separator: "; ")
            D.log(verdict)
            try? verdict.write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(D.failures.isEmpty ? 0 : 8)
        }
    }
    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        D.window = NativeMenuController.shared.comparisonWindow
        guard D.window != nil else { throw PluginValidationError.invalidField("native window") }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.orderFront(nil)
        let manager = PluginManager.shared, store = WorkspaceStore.shared
        let pluginID = ArchiveComparisonModel.pluginID
        manager.setEnabled(true, id: pluginID)
        let empty = ComparisonSession(); store.sessions = [empty]; store.selectedID = empty.id
        D.check(manager.plugin(id: pluginID)?.bundled == true && manager.plugin(id: pluginID)?.enabled == true, "archive capability is a bundled enabled plugin")
        let left = root.appendingPathComponent("fixtures/left.zip"), right = root.appendingPathComponent("fixtures/right.tar.gz")
        let folder = root.appendingPathComponent("fixtures/right-folder")
        let bytes = [try Data(contentsOf: left), try Data(contentsOf: right)]
        let listingBefore = try tree(root.appendingPathComponent("fixtures"))
        store.accept([left, right])
        try await D.wait("archive session routing") { store.selected?.pluginID == pluginID }
        let session = store.selected!, model = session.archiveComparisonModel
        try await D.wait("archive JS comparison") { model.result != nil || model.error != nil }
        if let error = model.error { throw error }
        let states = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.path, $0.state) })
        D.check(states["docs/common.txt"] == .same && states["docs/changed.txt"] == .changed, "content hashes distinguish same-length changed content from equality")
        D.check(states["docs"] == .changed && states["empty"] == .same, "directory aggregation and explicit empty folders")
        D.check(states["removed.txt"] == .removed && states["added.txt"] == .added, "one-sided paths retain direction")
        D.check(states["kind"] == .typeChanged && states["kind/child.txt"] == .added, "file-to-directory type change retains children")
        D.check(states["link"] == .unknown && model.result?.status == .partial, "links are unverified even when one-sided")
        D.check(model.groups.contains { Set($0.left.map(\.path)) == ["old-name.dat", "copies/duplicate.dat"] && Set($0.right.map(\.path)) == ["new-name.dat"] }, "identical bytes across distinct paths form one complete linear cohort")
        AppSettings.shared.language = .simplifiedChinese
        try await render(name: "archive-paths-light", dark: false, width: 1220)
        try await render(name: "archive-paths-dark-narrow", dark: true, width: 860)
        AppSettings.shared.language = .english
        try await render(name: "archive-paths-english-narrow", dark: false, width: 860)
        try await ArchiveUIAssertions.run(window: D.window, model: model)
        // Validate the host's trust boundary independently of the official algorithm.
        let output = model.result!, l = model.leftSnapshot!, r = model.rightSnapshot!
        func invalid(_ payload: PluginJSONValue) -> Bool {
            let fake = PluginComparisonResult(protocolVersion: output.protocolVersion, runID: output.runID, schema: output.schema, status: output.status, summary: output.summary, diagnostics: output.diagnostics, payload: payload)
            do { _ = try ArchivePluginResultValidator.parse(fake, left: l, right: r); return false } catch { return true }
        }
        guard case .object(var payload) = output.payload else { throw PluginValidationError.invalidField("payload") }
        payload["pairs"] = .array([])
        D.check(invalid(.object(payload)), "host rejects omitted path coverage")
        guard case .object(var tampered) = output.payload, var pairs = tampered["pairs"]?.arrayValue,
              case .object(var pair) = pairs[0] else { throw PluginValidationError.invalidField("pairs") }
        pair["left"] = .string("../../outside.txt"); pairs[0] = .object(pair); tampered["pairs"] = .array(pairs)
        D.check(invalid(.object(tampered)), "host rejects plugin-invented paths")
        guard case .object(var missingGroup) = output.payload else { throw PluginValidationError.invalidField("payload") }
        missingGroup["sameContentGroups"] = .array([])
        D.check(invalid(.object(missingGroup)), "host rejects missing content cohorts")
        D.check(store.persistNow(), "archive session persists")
        let stored = try SessionFile.load(from: root.appendingPathComponent("data/sessions.json"))
        D.check(stored.contains { $0.id == session.id && $0.pluginID == pluginID && $0.left.text.isEmpty && $0.right.text.isEmpty }, "archive session stores references, never expanded content")
        manager.setEnabled(false, id: pluginID); try await D.pause()
        D.check(store.selected?.id == session.id && manager.plugin(id: pluginID)?.enabled == false, "disable preserves source session")
        manager.setEnabled(true, id: pluginID); try await D.pause()
        store.accept([folder, left])
        try await D.wait("folder/archive routing") { store.selected?.id != session.id && store.selected?.pluginID == pluginID }
        let reversed = store.selected!
        try await D.wait("folder/archive comparison") { reversed.archiveComparisonModel.result != nil || reversed.archiveComparisonModel.error != nil }
        if let error = reversed.archiveComparisonModel.error { throw error }
        D.check(reversed.archiveComparisonModel.leftSnapshot?.sourceKind == .folder && reversed.archiveComparisonModel.rightSnapshot?.sourceKind == .archive, "folder on left is accepted")
        store.accept([left, folder])
        try await D.wait("archive/folder routing") { store.selected?.id != reversed.id && store.selected?.pluginID == pluginID }
        let mixed = store.selected!.archiveComparisonModel
        try await D.wait("archive/folder comparison") { mixed.result != nil || mixed.error != nil }
        if let error = mixed.error { throw error }
        D.check(mixed.rows.first { $0.path == "docs/common.txt" }?.state == .same, "archive-to-local-folder uses identical content semantics")
        let execute = try manager.execution(for: pluginID)
        let unicode = ArchiveComparisonModel()
        await unicode.load(left: root.appendingPathComponent("fixtures/unicode-left.tar"),
            right: root.appendingPathComponent("fixtures/unicode-right.tar"), execute: { try await execute.compare($0) })
        D.check(unicode.error == nil && unicode.rows.first { $0.path == "outer" }?.state == .changed,
                "canonical Unicode parent summaries propagate by depth")
        let damaged = ArchiveComparisonModel()
        await damaged.load(left: root.appendingPathComponent("fixtures/damaged.zip"), right: right, execute: { try await execute.compare($0) })
        D.check(damaged.error != nil && damaged.result == nil && damaged.rows.isEmpty, "corrupt archive cannot publish a successful empty result")
        let cancelled = ArchiveComparisonModel()
        let slow = Task { await cancelled.load(left: left, right: right, execute: { _ in
            try await Task.sleep(for: .seconds(3)); throw CancellationError()
        }) }
        try await D.pause(); cancelled.cancel(); await slow.value
        D.check(cancelled.result == nil && !cancelled.isLoading && cancelled.isCancelled, "cancel prevents obsolete result publication")
        D.check(try [Data(contentsOf: left), Data(contentsOf: right)] == bytes, "archive bytes unchanged")
        D.check(try tree(root.appendingPathComponent("fixtures")) == listingBefore, "no extracted files or source changes")
        // Cached results must be invalidated when a source changes.
        let mutable = root.appendingPathComponent("fixtures/cached.zip")
        try bytes[0].write(to: mutable)
        let cached = ArchiveComparisonModel()
        await cached.load(left: mutable, right: right, execute: { try await execute.compare($0) })
        D.check(cached.result != nil, "cache fixture completes")
        try Data("changed".utf8).write(to: mutable)
        await cached.load(left: mutable, right: right, execute: { try await execute.compare($0) })
        D.check(cached.result == nil && cached.error != nil, "source mutation clears cached result")
    }
    static func tree(_ url: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { ($0 as? URL)?.path }.sorted()
    }
    static func render(name: String, dark: Bool, width: Double) async throws {
        AppAppearance.shared.isDark = dark
        D.window.setContentSize(NSSize(width: width, height: 700))
        try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
        let view = D.window.contentView!.superview ?? D.window.contentView!
        let bitmap = try D.capture(view, rect: view.bounds, name: name)
        D.check(bitmap.pixelsWide >= 860 && bitmap.pixelsHigh > 600, "\(name) entire native parent renders")
    }
}
