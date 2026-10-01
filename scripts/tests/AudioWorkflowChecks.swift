import AppKit
import CrossDiffCore

/// This process captures only its own full AppKit window. It never plays audio or uses the clipboard.
@MainActor enum AudioWorkflowChecks {
    typealias D = DeletionPreviewChecks
    static var root: URL { D.output.deletingLastPathComponent() }
    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-audio-workflow/") == true,
              ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]?.contains(".build-audio-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            do { try await run() } catch { D.failures.append("Interrupted: \(error)") }
            let verdict = D.failures.isEmpty
                ? "PASS: native audio creation, Apple decode/STFT, manual regions, persistence/undo, restricted plugin, actual source matching, disable/reload lifecycle, native light/dark/minimum width; no playback started"
                : "FAIL: " + D.failures.joined(separator: "; ")
            D.log(verdict)
            try? D.report.joined(separator: "\n").write(to: D.output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(D.failures.isEmpty ? 0 : 8)
        }
    }
    static func run() async throws {
        try FileManager.default.createDirectory(at: D.output, withIntermediateDirectories: true)
        let gestureRange = AudioRegion(start: 0, end: 10), chosen = AudioRegion(start: 2, end: 5)
        func drag(_ start: Double, _ end: Double) -> AudioRegion? {
            AudioWaveformSelectionGesture.region(startX: start, currentX: end, width: 1000,
                visibleRange: gestureRange, selection: chosen, duration: 10)
        }
        D.check(drag(500, 600) == .init(start: 2, end: 6), "Right selection handle resizes without replacing the left boundary")
        D.check(drag(200, 100) == .init(start: 1, end: 5), "Left selection handle preserves the right boundary")
        D.check(drag(350, 550) == .init(start: 4, end: 7), "Dragging selection interior moves both boundaries")
        D.check(drag(350, -100) == .init(start: 0, end: 3), "Moving a selected range clamps without changing duration")
        D.check(drag(800, 650) == .init(start: 6.5, end: 8), "Empty waveform drag creates a new region in either direction")
        try await D.wait("own audio app window") {
            D.window = NSApp.windows.first { $0.contentView != nil && !($0 is NSPanel) }
            return D.window != nil
        }
        D.window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); D.window.orderFront(nil)
        PluginManager.shared.setEnabled(true, id: "org.crossdiff.audio")
        let left = root.appendingPathComponent("fixtures/source.wav"), right = root.appendingPathComponent("fixtures/reordered.wav")
        let leftBytes = try Data(contentsOf: left), rightBytes = try Data(contentsOf: right)
        let session = try await create(left: left, right: right)
        let model = session.audioComparisonModel
        try await ready(model)
        D.check(model.leftSource?.duration == 48 && model.rightSource?.duration == 24, "Apple decoder preserves the real source durations")
        D.check(model.leftSource?.waveform.first?.isEmpty == false && model.leftSpectrum != nil && model.rightSpectrum != nil, "Real waveform and STFT analyses complete")
        D.check(model.leftSpectrum?.sourceNyquist == 8000 && model.rightSpectrum?.sourceNyquist == 8000, "Low-rate source Nyquist remains recorded after analysis resampling")
        D.check(model.comparison?.analysisState == .idle && !model.isMatching, "Opening audio does not trigger recognition automatically")
        D.check(!model.playback.isPlaying && !session.dirty, "Preparing a comparison never starts playback or edits its source")
        for identifier in ["audio.findMatches", "audio.showSpectrogram", "audio.parameters", "audio.saveRegions", "audio.play.left", "audio.play.right", "audio.undo", "audio.redo"] {
            D.check(hasControl(identifier), "actual window exposes \(identifier)")
        }
        AppSettings.shared.language = .simplifiedChinese
        try await render("audio-waveform-zh-light", width: 1220, height: 850, dark: false)
        D.check(accessibleText().contains("source.wav") && accessibleText().contains("reordered.wav"), "Both source names are visible to accessibility")

        model.selectRegion(.init(start: 27, end: 39), side: .left)
        model.selectRegion(.init(start: 0, end: 12), side: .right)
        var settings = model.state
        settings.rate = 1.25; settings.pitchSemitones = -2
        model.state = settings
        model.saveRegion(name: "片段 A / Excerpt A")
        try await ready(model)
        let savedState = model.state
        D.check(savedState.regions.count == 1 && savedState.regions[0].rate == 1.25 && savedState.regions[0].pitchSemitones == -2, "Named region pair retains its local audition settings")
        model.selectRegion(.init(start: 4, end: 16), side: .left)
        let beforeUndo = model.state
        NSApp.activate(ignoringOtherApps: true); D.window.makeKeyAndOrderFront(nil)
        try await D.wait("audio window is key for menu routing") { NSApp.isActive && NSApp.keyWindow === D.window }
        D.window.makeFirstResponder(nil)
        try await D.pause()
        let undoMenu = NSMenuItem(title: "", action: #selector(NativeMenuController.undo(_:)), keyEquivalent: "z")
        D.check(NativeMenuController.shared.validateMenuItem(undoMenu), "Native Edit menu enables audio Undo outside text fields")
        NativeMenuController.shared.undo(nil)
        D.check(model.state == savedState, "Command-Z menu action routes to the active audio history")
        NativeMenuController.shared.redo(nil)
        D.check(model.state == beforeUndo, "Command-Shift-Z menu action restores audio history")
        try await press("audio.undo")
        D.check(model.state == savedState && model.canRedo, "Native Undo restores the prior selected region without changing source data")
        try await press("audio.redo")
        D.check(model.state == beforeUndo, "Native Redo restores the changed region")
        model.applyRegion(id: savedState.regions[0].id)
        try await ready(model)
        D.check(model.state.leftRegion == savedState.leftRegion && model.state.rightRegion == savedState.rightRegion, "Saved region can be selected repeatedly")
        var configured = model.state
        configured.settings = .init(fftSize: 4096, hopSize: 1024, frequencyScale: .linear, minimumDB: -90, maximumDB: 0)
        model.state = configured
        try await ready(model)
        D.check(model.leftSpectrum?.fftSize == 4096 && model.rightSpectrum?.hopSize == 1024, "Professional settings drive the real STFT pipeline")
        let snapshot = try JSONDecoder().decode(StoredComparison.self, from: JSONEncoder().encode(session.snapshot))
        D.check(snapshot.audioState == model.state && snapshot.left.path == left.path && snapshot.right.path == right.path, "Actual workspace snapshot restores original files and all manual settings")
        D.check(!model.playback.isPlaying, "Selection, saving and analysis settings never start audition")
        try await selectSpectrogram()
        try await render("audio-spectrogram-zh-light", width: 1220, height: 900, dark: false)
        AppSettings.shared.language = .english
        try await render("audio-spectrogram-en-dark-narrow", width: 860, height: 760, dark: true)
        try await render("audio-spectrogram-en-light-narrow", width: 860, height: 760, dark: false)
        try await press("audio.parameters")
        try await press("audio.clearCache")
        try await D.wait("audio cache cleanup action") { !model.isClearingCache }
        D.check(model.cacheMessage != nil, "Parameters expose scoped temporary-audio cleanup")
        try await render("audio-parameters-parent", width: 1220, height: 900, dark: false)
        try await captureAdditionalWindows("audio-parameters")
        try await press("audio.averageSpectrum")
        try await press("audio.parameters")
        model.resetRegions()
        try await ready(model)
        try await render("audio-average-spectrum-en-light", width: 1220, height: 1200, dark: false)
        D.check(accessibleText().contains("Partial region"), "Average spectrum explicitly labels the bounded portion of a long selection")
        try await scrollAudio(toBottom: true)
        try await render("audio-average-spectrum-detail-en-light", width: 1220, height: 900, dark: false)
        try await scrollAudio(toBottom: false)
        try await press("audio.parameters")
        try await press("audio.averageSpectrum")
        try await press("audio.parameters")
        model.applyRegion(id: savedState.regions[0].id)
        try await ready(model)

        try await press("audio.findMatches")
        try await waitForMatching(model)
        D.check(!model.correspondences.isEmpty && model.correspondences.allSatisfy { $0.method.lowercased().contains("olaf") }, "Actual native fingerprint helper feeds the restricted plugin")
        D.check(supports(model.correspondences, left: .init(start: 27, end: 39), right: .init(start: 0, end: 12)) &&
                supports(model.correspondences, left: .init(start: 4, end: 16), right: .init(start: 12, end: 24)), "Unknown reordered source segments are both found through the full app")
        D.check(model.correspondences.allSatisfy { $0.pitchSemitones == nil }, "Fingerprint-only matching does not invent pitch estimates")
        try await render("audio-matched-en-dark", width: 1220, height: 900, dark: true)
        if let match = model.correspondences.first {
            model.selectCorrespondence(id: match.id)
            try await ready(model)
            D.check(model.state.leftRegion == match.left && model.state.rightRegion == match.right, "Automatic correspondence selects both original time ranges")
        }
        D.check(!model.playback.isPlaying, "Automatic recognition and match selection remain silent")

        let manualBeforeDisable = model.state
        model.runMatching()
        PluginManager.shared.setEnabled(false, id: "org.crossdiff.audio")
        try await D.wait("disabled audio lifecycle") { !model.isLoading && !model.isAnalyzing && !model.isMatching }
        try await D.pause()
        D.check(!model.playback.isPlaying && model.state == manualBeforeDisable, "Disabling stops audio jobs and preserves manual region state")
        PluginManager.shared.setEnabled(true, id: "org.crossdiff.audio")
        try await ready(model)
        D.check(model.state == manualBeforeDisable && model.comparison?.analysisState != .running, "Re-enabling preserves state without a stale running result")
        D.check(try Data(contentsOf: left) == leftBytes && Data(contentsOf: right) == rightBytes, "All analysis and manual operations leave original file bytes unchanged")
        let external = PluginManager(directory: root.appendingPathComponent("base-plugin-data-\(UUID().uuidString)"),
                                     bundledDirectory: root.appendingPathComponent("no-bundled-plugins"))
        external.pendingPackage = try PluginPackage.load(from: root.appendingPathComponent("Plugins/Audio.crossdiffplugin"))
        external.installPending(trustNative: false)
        D.check(external.plugin(id: "org.crossdiff.audio")?.enabled == true, "Base edition installs the actual restricted audio package")
        let execution = try external.execution(for: "org.crossdiff.audio")
        let direct = try await execution.compare([
            .init(id: "left", role: .left, name: "source.wav", content: model.leftSource!.metadata.pluginContent),
            .init(id: "right", role: .right, name: "reordered.wav", content: model.rightSource!.metadata.pluginContent)
        ], options: AudioComparisonRequestOptions().pluginOptions)
        D.check(direct.schema == "crossdiff.audio/1", "Installed Base plugin executes with the same host protocol")
        model.cancel()
    }
    static func create(left: URL, right: URL) async throws -> ComparisonSession {
        let store = WorkspaceStore.shared
        store.beginNewComparison()
        try await D.wait("audio creation sheet") { store.newComparison != nil && D.window.attachedSheet != nil }
        guard let draft = store.newComparison, let type = draft.types.first(where: { $0.pluginID == "org.crossdiff.audio" }) else {
            throw D.CheckError(description: "Missing audio creation entry")
        }
        draft.select(type); draft.setInput(.file(left), side: .left); draft.setInput(.file(right), side: .right)
        D.check(draft.canCreate, "Audio supports two explicitly selected local sources")
        draft.create()
        try await D.wait("audio creation completes") { store.newComparison == nil && D.window.attachedSheet == nil && store.selected?.pluginID == "org.crossdiff.audio" }
        return store.selected!
    }
    static func ready(_ model: AudioComparisonModel) async throws {
        let deadline = Date().addingTimeInterval(45)
        while model.isLoading || model.isAnalyzing || model.comparison == nil {
            if let error = model.error { throw error }
            if Date() > deadline { throw D.CheckError(description: "Audio decode/analysis/plugin timeout") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if let error = model.error { throw error }
        try await D.pause()
    }
    static func waitForMatching(_ model: AudioComparisonModel) async throws {
        let deadline = Date().addingTimeInterval(90)
        while model.isMatching || ![AudioAnalysisState.complete, .partial].contains(model.comparison?.analysisState ?? .idle) {
            if let error = model.error { throw error }
            if Date() > deadline { throw D.CheckError(description: "Native audio matching timeout") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if let error = model.error { throw error }
        try await D.pause()
    }
    static func supports(_ pairs: [AudioCorrespondence], left: AudioRegion, right: AudioRegion) -> Bool {
        pairs.contains { pair in
            min(pair.left.end, left.end) - max(pair.left.start, left.start) >= 2 &&
            min(pair.right.end, right.end) - max(pair.right.start, right.start) >= 2 &&
            abs((pair.right.start - pair.left.start) - (right.start - left.start)) < 0.2
        }
    }
    static func render(_ name: String, width: Double, height: Double, dark: Bool) async throws {
        AppAppearance.shared.isDark = dark
        D.window.setContentSize(NSSize(width: width, height: height)); D.window.orderFront(nil)
        try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded()
        let view = D.window.contentView!.superview ?? D.window.contentView!
        let bitmap = try D.capture(view, rect: view.bounds, name: name)
        D.check(bitmap.pixelsWide >= Int(width), "\(name) captures the full real window")
        let contrast = D.countPixels(bitmap, background: AppAppearance.shared.colors.canvas)
        D.check(contrast.readable > 500, "\(name) contains readable text and chart contrast")
    }
    static func captureAdditionalWindows(_ name: String) async throws {
        for (index, window) in NSApp.windows.filter({ $0 !== D.window && $0.isVisible && $0.contentView != nil && $0.frame.width > 180 && $0.frame.height > 80 }).enumerated() {
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let view = window.contentView!.superview ?? window.contentView!
            _ = try D.capture(view, rect: view.bounds, name: "\(name)-\(index)")
        }
    }
    static func scrollAudio(toBottom: Bool) async throws {
        guard let scroll = objects().compactMap({ $0 as? NSScrollView }).first(where: {
            ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 80
        }), let document = scroll.documentView else { throw D.CheckError(description: "Missing scrollable audio workspace") }
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: (toBottom == document.isFlipped) ? maximum : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await D.pause()
    }
    static func hasControl(_ identifier: String) -> Bool { objects().contains { string($0, "accessibilityIdentifier") == identifier } }
    static func selectSpectrogram() async throws {
        guard let picker = objects().compactMap({ $0 as? NSSegmentedControl }).first(where: {
            $0.segmentCount == 2 && ["波形", "Waveform"].contains($0.label(forSegment: 0) ?? "")
        }) else { throw D.CheckError(description: "Missing native waveform/spectrogram control") }
        picker.selectedSegment = 1
        D.check(picker.sendAction(picker.action, to: picker.target), "Native segmented control selects the spectrogram view")
        try await D.pause()
    }
    static func press(_ identifier: String) async throws {
        let matches = objects().filter { string($0, "accessibilityIdentifier") == identifier }
        guard let object = matches.first(where: { $0 is NSControl }) ?? matches.first else { throw D.CheckError(description: "Missing audio control: \(identifier)") }
        if let button = object as? NSButton { button.performClick(nil) }
        else {
            let action = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: action) else { throw D.CheckError(description: "Audio control cannot press: \(identifier)") }
            typealias Action = @convention(c) (AnyObject, Selector) -> Bool
            D.check(unsafeBitCast(object.method(for: action), to: Action.self)(object, action), "\(identifier) dispatches its native action")
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
        for window in NSApp.windows where window.isVisible { if let view = window.contentView { descend(view, depth: 0) } }
        return result
    }
    static func string(_ object: NSObject, _ attribute: String) -> String {
        let selector = NSSelectorFromString(attribute)
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
    static func accessibleText() -> String {
        objects().flatMap { [string($0, "accessibilityValue"), string($0, "accessibilityLabel")] }.joined(separator: "\n")
    }
}
