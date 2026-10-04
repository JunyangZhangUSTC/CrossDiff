import AppKit
import AVFoundation
import CrossDiffCore

@MainActor enum VideoWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static var checks = 0
    static func check(_ condition: Bool, _ name: String) { checks += 1; D.check(condition, name) }
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-video-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty ? "PASS: \(checks) video workflow checks; native creation, linked/unlinked seeking, exact frames, regions, undo, loop, persistence, plugin lifecycle, light/dark/narrow" : "FAIL: " + D.failures.joined(separator: "; ")
            try? (D.report + [verdict]).joined(separator: "\n").write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            print(verdict); exit(D.failures.isEmpty ? 0 : 8)
        }
    }
    static var root: URL { D.output.deletingLastPathComponent() }
    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        let fixtures = root.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let a = fixtures.appendingPathComponent("Original.mov"), b = fixtures.appendingPathComponent("Alternate.mov")
        let times = (0..<72).map { CMTime(value: Int64($0), timescale: 24) }
        try await VideoFixtures.write(to: a, times: times, end: CMTime(value: 3, timescale: 1))
        try await VideoFixtures.write(to: b, times: times, end: CMTime(value: 3, timescale: 1))
        let originals = try [a,b].map { try Data(contentsOf: $0) }
        try await D.wait("own window") { D.window = NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }; return D.window != nil }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.orderFront(nil)
        AppSettings.shared.language = .simplifiedChinese
        let type = NewComparisonType(kind: .plugin, pluginID: "org.crossdiff.video")
        try type.validate(a)
        check(type.symbol == "film", "video has a dedicated native chooser identity")
        check(PluginManager.shared.matching(a)?.id == "org.crossdiff.video", "video file routing selects the plugin")
        let store = WorkspaceStore.shared
        store.beginNewComparison()
        try await D.wait("creation sheet") { store.newComparison != nil && D.window.attachedSheet != nil }
        let draft = store.newComparison!
        draft.select(type); draft.setInput(.file(a), side: .left); draft.setInput(.file(b), side: .right)
        check(draft.canCreate, "new comparison accepts local movie pair")
        draft.create()
        try await D.wait("video session") { store.newComparison == nil && store.selected?.pluginID == "org.crossdiff.video" && D.window.attachedSheet == nil }
        let session = store.selected!, model = session.videoComparisonModel
        try await ready(model)
        check(model.comparison?.metadataDifferences.isEmpty == true, "real helper validates equivalent metadata")
        check(model.leftActualTime == 0 && model.rightActualTime == 0, "first atomic frame pair is at actual source zero")
        check(model.differenceImage != nil, "tagged equal-size SDR frames enable difference preview")
        model.step(1); try await ready(model); model.step(1); try await ready(model)
        let state = model.state
        let exact = VideoComparisonModel(state: state)
        let helper = try PluginManager.shared.execution(for: "org.crossdiff.video")
        await exact.load(left: a, right: b, execute: { try await helper.compare($0, options: $1) }, executionID: "exact-restore")
        try await ready(exact)
        check(exact.leftActualTime == model.leftActualTime && exact.leftActualTime == 2.0/24, "24fps rational PTS survives session reload without stepping backward")
        exact.cancel(); model.seek(side: .left, seconds: 0); try await ready(model)
        check(model.leftPlayer.isMuted && model.rightPlayer.isMuted, "first launch is muted")
        try await render("video-light", width: 1220, height: 746, dark: false)
        try await press("video.nextFrame")
        try await ready(model)
        check(abs((model.leftActualTime ?? -1) - 1.0/24) < 0.0001, "native next-frame action advances actual sample")
        check(abs((model.rightActualTime ?? -1) - 1.0/24) < 0.0001, "linked frame step maps reference source time")
        model.setLinked(false); model.seek(side: .right, seconds: 0.529)
        try await ready(model)
        check(abs(model.leftTime - 1.0/24) < 0.0001 && abs(model.rightTime - 0.529) < 0.0001, "unlinked seek preserves opposite source time")
        let displayedOffset = model.rightActualTime! - model.leftActualTime!
        model.alignCurrentFrames(); try await ready(model)
        check(abs(model.offsetSeconds - displayedOffset) < 0.0001, "align current frames uses displayed PTS, not approximate slider time")
        check(model.isLinked && model.canUndo, "manual alignment is linked and undoable")
        model.undo(); try await ready(model)
        check(!model.isLinked && model.offsetSeconds == 0 && abs(model.rightTime - 0.529) < 0.0001, "undo restores both independent source positions")
        model.redo(); try await ready(model)
        check(model.isLinked && abs(model.offsetSeconds - displayedOffset) < 0.0001, "redo restores manual mapping")
        model.regionLinked = true
        let roi = VideoROI(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        model.setROI(roi, side: .left); try await ready(model)
        check(model.leftROI == roi && model.rightROI == roi, "linked region selection maps normalized rectangles")
        model.saveRegion(name: "Subject")
        let id = model.savedRegions[0].id
        model.resetROI(); try await ready(model)
        model.restoreRegion(id); try await ready(model)
        check(model.leftROI == roi && model.differenceImage?.width == 160, "saved region restores cropped difference inspection")
        model.displayMode = .wipe; try await ready(model)
        try await render("video-wipe-light", width: 1220, height: 746, dark: false)
        model.displayMode = .difference; try await ready(model)
        AppSettings.shared.language = .english
        try await render("video-difference-dark-narrow", width: 860, height: 580, dark: true)
        check(accessibleText().contains("Video") && accessibleText().contains("Difference"), "video controls follow English language")
        let restored = try JSONDecoder().decode(StoredComparison.self, from: JSONEncoder().encode(session.snapshot))
        check(restored.videoState?.savedRegions.first?.name == "Subject" && restored.videoState?.leftROI == roi, "actual session stores regions")
        check(restored.videoState?.offsetSeconds == model.offsetSeconds, "actual session stores manual alignment")
        check(restored.videoState?.leftTime.isValid == true, "source times persist as rational values")
        var invalid = VideoWorkspaceState(); invalid.offsetSeconds = .infinity
        check(!invalid.isValid, "nonfinite source mapping is rejected")
        invalid = .init(); invalid.leftROI = .init(x: 0.9,y: 0,width: 0.5,height: 1)
        check(!invalid.isValid, "out of bounds region state is rejected")
        model.resetROI(); model.resetAlignment(); model.seek(side: .left, seconds: 0)
        try await ready(model)
        model.setLoop(start: 0.2, end: 0.7)
        model.togglePlayback()
        try await D.wait("linked playback") { model.isPlaying || model.playback.error != nil }
        check(model.isPlaying, "native playback starts both sources")
        var internalWraps = 0, previousInternal = model.leftTime
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if model.leftTime < previousInternal - 0.05 { internalWraps += 1 }
            previousInternal = model.leftTime
        }
        check(internalWraps >= 2 && model.leftTime < 0.85 && model.playback.error == nil, "range loop actually restarts twice and stays bounded")
        model.stop(); try await ready(model)
        model.clearLoop()
        model.setLoop(start: 2.7, end: 3)
        model.seek(side: .left, seconds: 2.7); try await ready(model); model.togglePlayback()
        try await D.wait("play full-end loop") { model.isPlaying }
        var wraps = 0, previousTime = model.leftTime
        for _ in 0..<24 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let now = model.leftTime
            if now < previousTime - 0.05 { wraps += 1 }
            if model.playback.error != nil { D.log("End loop failure: \(model.playback.error!) at \(now)") }
            previousTime = now
        }
        check(wraps >= 2 && model.playback.error == nil, "loop ending exactly at video end restarts at least twice")
        model.stop(); model.clearLoop(); model.seek(side: .left, seconds: 0); try await ready(model)
        model.setAudioSide(.left)
        check(!model.leftPlayer.isMuted && model.rightPlayer.isMuted, "audio selects one side at a time")
        model.setAudioSide(.right)
        check(model.leftPlayer.isMuted && !model.rightPlayer.isMuted, "audio can switch without playing both")
        model.setAudioSide(.muted)
        model.displayMode = .sideBySide
        try await ready(model)
        try await render("video-side-dark-narrow", width: 860, height: 580, dark: true)
        model.seek(side: .left, seconds: 1.2); model.seek(side: .left, seconds: 0.4)
        try await ready(model)
        check(abs(model.leftTime - 0.4) < 0.0001, "latest rapid seek wins")
        model.seek(side: .left, seconds: 1.5); model.stop()
        try await ready(model)
        check(!model.isSeeking, "stop cancels seek without leaving controls disabled")
        model.togglePlayback(); try await D.wait("play before switch") { model.isPlaying }
        try await Task.sleep(nanoseconds: 350_000_000)
        let liveSnapshot = session.snapshot.videoState!
        check(abs(liveSnapshot.leftTime.seconds - model.leftPlayer.currentTime().seconds) < 0.05, "snapshot captures live playback position for quit without pausing")
        check(store.persistNow(), "final persistence succeeds during playback")
        store.newText(); try await D.pause()
        check(model.leftPlayer.currentItem == nil && model.rightPlayer.currentItem == nil && !model.isPlaying, "switching tab releases decoder and stops both players")
        store.selectedID = session.id; try await ready(model)
        check(model.savedRegions.count == 1 && model.hasSources, "returning to video restores region state and sources")
        for (index, url) in [a,b].enumerated() { check(try Data(contentsOf: url) == originals[index], "video source remains byte-identical") }
        let packageURL = root.appendingPathComponent("Plugins/Video.crossdiffplugin")
        let base = PluginManager(directory: root.appendingPathComponent("base-data"), bundledDirectory: root.appendingPathComponent("no-bundle"))
        base.pendingPackage = try PluginPackage.load(from: packageURL); base.installPending(trustNative: false)
        check(base.plugin(id: "org.crossdiff.video")?.enabled == true, "base installs the restricted video plugin locally")
        _ = try base.execution(for: "org.crossdiff.video")
        base.uninstall("org.crossdiff.video")
        check(base.plugin(id: "org.crossdiff.video") == nil, "installed video plugin can be uninstalled")
        let copied = root.appendingPathComponent("changed.mov")
        try originals[0].write(to: copied)
        let changed = VideoComparisonModel()
        let execution = try PluginManager.shared.execution(for: "org.crossdiff.video")
        await changed.load(left: copied, right: b, execute: { try await execution.compare($0, options: $1) }, executionID: "changed-check")
        try await ready(changed)
        try Data("changed source".utf8).write(to: copied)
        changed.seek(side: .left, seconds: 0.1)
        try await D.pause()
        check(changed.playback.error != nil && !changed.isPlaying, "source modification fails closed on next seek")
        changed.cancel()
        store.close(session)
        check(model.leftPlayer.currentItem == nil && !model.isPlaying, "closing session stops video playback")
    }
    static func ready(_ model: VideoComparisonModel) async throws {
        let deadline = Date().addingTimeInterval(35)
        repeat {
            if let error = model.error { throw error }
            if !model.isLoading && !model.isSeeking && model.hasSources && model.leftImage != nil && model.rightImage != nil { try await D.pause(); return }
            if Date() > deadline { throw D.CheckError(description: "Video timeout: \(model.status), \(model.inspectionNotice ?? "")") }
            try await Task.sleep(nanoseconds: 30_000_000)
        } while true
    }
    static func render(_ name: String, width: Double, height: Double, dark: Bool) async throws {
        AppAppearance.shared.isDark = dark
        D.window.setContentSize(NSSize(width: width, height: height)); D.window.orderFront(nil)
        try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
        let view = D.window.contentView!.superview ?? D.window.contentView!
        let bitmap = try D.capture(view, rect: view.bounds, name: name)
        check(bitmap.pixelsWide >= Int(width), "\(name) renders whole native parent")
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
        guard let field = objects().compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && ($0.placeholderString?.contains("查找内容") == true || $0.placeholderString?.contains("Find content") == true) }) else { throw D.CheckError(description: "Missing Video search field") }
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
