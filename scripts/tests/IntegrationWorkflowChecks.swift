import AppKit
import AVFoundation
import CryptoKit
import CrossDiffCore

/// Cross-module checks mount shipping views in one application/window. Every
/// input, preference, plugin and session lives in this run's project directory.
@MainActor enum IntegrationWorkflowChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var window: NSWindow!
    static var report: [String] = []
    static var assertions = 0
    static var output: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]!) }
    static var runDirectory: URL { output.deletingLastPathComponent() }

    static func start() {
        guard ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]?.contains(".build-integration-workflow/") == true,
              ProcessInfo.processInfo.environment["CROSSDIFF_RENDER_DIR"]?.contains(".build-integration-workflow/") == true else { exit(2) }
        NSApp.setActivationPolicy(.accessory)
        Task {
            var success = false
            do { try await run(); success = true }
            catch { log("FAIL: \(error)") }
            let verdict = success
                ? "PASS: \(assertions) cross-module checks; actual image/photo/video plugins, background isolation, folder retention, native undo routing, bilingual themes, mixed current/legacy sessions and immutable sources"
                : "FAIL: cross-module workflow did not finish"
            log(verdict)
            try? report.joined(separator: "\n").write(to: output.appendingPathComponent("verdict.txt"), atomically: true, encoding: .utf8)
            exit(success ? 0 : 8)
        }
    }

    static func run() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await wait("shipping main window") {
            window = NSApp.windows.first { $0.identifier?.rawValue == "crossdiff-main" }
            return window != nil
        }
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("own key window") { NSApp.isActive && NSApp.keyWindow === window }
        let fixtures = runDirectory.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let original = fixtures.appendingPathComponent("Original.png")
        let crop = fixtures.appendingPathComponent("Edited crop.png")
        let reference = fixtures.appendingPathComponent("Reference.png")
        let source = ImageMatchingFixtures.image(seed: 42, width: 960, height: 720)
        let cropped = source.cropping(to: CGRect(x: 137, y: 91, width: 640, height: 480))!
        try ImageMatchingFixtures.write(source, to: original)
        try ImageMatchingFixtures.write(ImageMatchingFixtures.locallyOccluded(cropped), to: crop)
        try ImageMatchingFixtures.write(ImageMatchingFixtures.image(seed: 123, width: 960, height: 720), to: reference)
        let videoLeft = fixtures.appendingPathComponent("Original.mov"), videoRight = fixtures.appendingPathComponent("Reference.mov")
        let times = (0..<36).map { CMTime(value: Int64($0), timescale: 24) }
        try await VideoFixtures.write(to: videoLeft, times: times, end: CMTime(value: 3, timescale: 2))
        try await VideoFixtures.write(to: videoRight, times: times, end: CMTime(value: 3, timescale: 2))
        let leftFolder = fixtures.appendingPathComponent("Folder A", isDirectory: true)
        let rightFolder = fixtures.appendingPathComponent("Folder B", isDirectory: true)
        var inputs = [original, crop, reference, videoLeft, videoRight]
        for directory in [leftFolder, rightFolder] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for index in 0..<24 {
            for (side, directory) in [leftFolder, rightFolder].enumerated() {
                let file = directory.appendingPathComponent("item-\(index).txt")
                try "fixture \(index)\n\(index == 3 ? side : 0)\n".write(to: file, atomically: true, encoding: .utf8)
                inputs.append(file)
            }
        }
        let originalHashes = try hashes(inputs)
        let store = WorkspaceStore.shared
        let text = ComparisonSession(left: .init(text: "left α\n", savedText: "left α\n"),
                                     right: .init(text: "right β\n", savedText: "right β\n"))
        let image = ComparisonSession(kind: .image, left: .init(path: original.path), right: .init(path: crop.path))
        let photo = ComparisonSession(kind: .plugin, left: .init(path: original.path), right: .init(path: reference.path), pluginID: "org.crossdiff.photography")
        let folder = ComparisonSession(kind: .folder, left: .init(path: leftFolder.path), right: .init(path: rightFolder.path))
        let video = ComparisonSession(kind: .plugin, left: .init(path: videoLeft.path), right: .init(path: videoRight.path), pluginID: "org.crossdiff.video")
        store.sessions = []
        for session in [text, image, photo, folder, video] { store.attach(session) }
        try expect(PluginManager.shared.plugin(id: "org.crossdiff.photography")?.enabled == true &&
                   PluginManager.shared.plugin(id: "org.crossdiff.video")?.enabled == true,
                   "both real restricted plugins are installed in the same process")

        try await select(text)
        try await wait("mounted text editors") { text.rightEditorState?.editor.window === window && !text.calculating }
        let editor = text.rightEditorState!.editor, undo = text.rightEditorState!.undoManager
        try expect(window.makeFirstResponder(editor), "text editor accepts native focus")
        undo.removeAllActions(); undo.groupsByEvent = false; undo.beginUndoGrouping()
        editor.insertText("retained edit 👩🏽‍💻\n", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        editor.breakUndoCoalescing(); undo.endUndoGrouping()
        try await wait("text edit") { !text.calculating && text.right.text.contains("retained edit") }
        let editedText = text.right.text
        try expect(undo.canUndo, "native text undo history exists before plugin switching")

        try await select(folder)
        try await folderReady(folder.folderComparisonModel)
        folder.folderComparisonModel.query = "item-3"
        try await folderReady(folder.folderComparisonModel)
        folder.folderComparisonModel.selection = ["item-3.txt"]
        let scanCount = folder.folderComparisonModel.scanCount
        try expect(folder.folderComparisonModel.visibleEntries.contains { $0.path == "item-3.txt" }, "folder projection has the fixture difference")

        try await select(image)
        try await imageReady(image.imageComparisonModel)
        image.imageComparisonModel.alignAutomatically()
        try await imageReady(image.imageComparisonModel)
        try expect(image.imageComparisonModel.matchingResult?.status == .accepted, "image alignment works with the combined PhotoCVBridge library")
        let aligned = image.imageComparisonModel.rightTransform

        try await select(photo)
        try await photoReady(photo.photoComparisonModel)
        let photoModel = photo.photoComparisonModel
        try expect(photoModel.resultStatus != nil && !photoModel.findings.isEmpty, "photography view executed its actual restricted plugin")
        try expect(photoModel.state.histogramLayout == .separated, "new photo tab defaults to separate histograms")
        try await chooseSegment("photo.histogram-layout", index: 1)
        try expect(photoModel.state.histogramLayout == .overlay, "native layout control explicitly switches to overlay")
        let roi = PhotoRegion(x: 0.12, y: 0.1, width: 0.65, height: 0.7)
        photoModel.selectRegion(roi, side: .left)
        photoModel.saveRegion(name: "Integration ROI / 联合选区")
        try await photoReady(photoModel)
        let stableStatistics = [photoModel.leftStatistics!, photoModel.rightStatistics!]

        // Run both clients of the shared native bridge concurrently. Invalidate
        // one queued image request while replacing several photo display requests.
        image.imageComparisonModel.toggleSimilarRegions()
        photoModel.state.previewChannel = .red
        photoModel.highlightedRange = .init(channel: .green, lowerBin: 20, upperBin: 190)
        photoModel.state.previewChannel = .green
        await Task.yield()
        image.imageComparisonModel.toggleSimilarRegions()
        photoModel.state.previewChannel = .blue
        photoModel.clearHighlight()
        try await photoReady(photoModel)
        try expect(!image.imageComparisonModel.showSimilarRegions && !image.imageComparisonModel.isAnalyzingSimilarity,
                   "cancelling image regions does not leave a live overlay request")
        try expect(isGrayscale(photoModel.leftDisplayImage!) && [photoModel.leftStatistics!, photoModel.rightStatistics!] == stableStatistics,
                   "newest blue-channel photo preview wins without changing original statistics")
        image.imageComparisonModel.toggleSimilarRegions()
        photoModel.highlightedRange = .init(channel: .blue, lowerBin: 0, upperBin: 255)
        try await wait("cross-module shared bridge completion", seconds: 45) {
            !image.imageComparisonModel.isAnalyzingSimilarity && !photoModel.isPreviewing
        }
        try expect(image.imageComparisonModel.similarityResult?.regions.isEmpty == false && !image.imageComparisonModel.similarityFailed,
                   "verified image regions survive simultaneous photographic channel/highlight analysis")
        try expect(photoModel.previewError == nil && photoModel.leftDisplayImage != nil &&
                   photoModel.highlightedRange?.channel == .blue && photoModel.state.leftRegion == roi,
                   "photo highlighting retains its own channel and source ROI")
        let highlightedBytes = pixels(photoModel.leftDisplayImage!)
        try expect(!isGrayscale(photoModel.leftDisplayImage!), "the selected photo range has a visible amber highlight")
        let regionCount = image.imageComparisonModel.similarityResult!.regions.count
        try await stage("integration-photo-en-light-860", height: 730, dark: false, language: .english,
                        identifiers: ["photo.histogram-layout", "photo.histogram-channel"])
        try expect(photoModel.state.histogramLayout == .overlay && pixels(photoModel.leftDisplayImage!) == highlightedBytes,
                   "language and appearance changes retain transformed photo pixels and explicit layout")

        try await select(image)
        try await imageReady(image.imageComparisonModel)
        try expect(image.imageComparisonModel.rightTransform == aligned && image.imageComparisonModel.similarityResult?.regions.count == regionCount,
                   "returning from photography preserves image registration and region evidence")
        try await stage("integration-image-zh-light-minimum", height: 580, dark: false, language: .simplifiedChinese,
                        identifiers: ["image.similarRegions", "image.matchPoints"])
        try await stage("integration-image-en-dark-minimum", height: 580, dark: true, language: .english,
                        identifiers: ["image.similarRegions", "image.matchPoints"])

        try await select(video)
        try await videoReady(video.videoComparisonModel)
        let videoModel = video.videoComparisonModel
        try expect(videoModel.comparison != nil, "video view runs its plugin alongside image and photography sessions")
        let videoROI = VideoROI(x: 0.1, y: 0.15, width: 0.6, height: 0.65)
        videoModel.setROI(videoROI, side: .left)
        try await videoReady(videoModel)
        try await focusComparison()
        let videoUndoValidated = menuEnabled(#selector(NativeMenuController.undo(_:)))
        try expect(videoModel.canUndo && videoUndoValidated, "native Undo targets the selected video history")
        try await dispatch(#selector(NativeMenuController.undo(_:)))
        try await videoReady(videoModel)
        try expect(videoModel.leftROI == nil && text.right.text == editedText && undo.canUndo,
                   "video Undo changes video ROI without consuming the hidden text history")
        try await dispatch(#selector(NativeMenuController.redo(_:)))
        try await videoReady(videoModel)
        try expect(videoModel.leftROI == videoROI, "native Redo restores only the video ROI")
        try await stage("integration-video-zh-dark-minimum", height: 580, dark: true, language: .simplifiedChinese,
                        identifiers: ["video.mode", "video.playPause"])

        try await select(folder)
        try await folderReady(folder.folderComparisonModel)
        try await focusComparison()
        try expect(!menuEnabled(#selector(NativeMenuController.undo(_:))), "folder canvas does not expose hidden video/text Undo")
        try await dispatch(#selector(NativeMenuController.undo(_:)))
        try expect(text.right.text == editedText && videoModel.leftROI == videoROI,
                   "a disabled Undo action cannot mutate another tab")
        try expect(folder.folderComparisonModel.scanCount == scanCount && folder.folderComparisonModel.query == "item-3" &&
                   folder.folderComparisonModel.selection == ["item-3.txt"], "folder tab retains scan, filter and selection while plugins run")

        try await select(text)
        try await wait("restored native text editor") { editor.window === window && !text.calculating }
        try await focusComparison(editor)
        try expect(window.firstResponder === editor, "text editor regains native command focus")
        try expect(menuEnabled(#selector(NativeMenuController.undo(_:))), "text Undo remains available after video adjustments")
        try await dispatch(#selector(NativeMenuController.undo(_:)))
        try await wait("text Undo") { text.right.text == "right β\n" && !text.calculating }
        try expect(videoModel.leftROI == videoROI, "text Undo leaves the video ROI unchanged")
        try await dispatch(#selector(NativeMenuController.redo(_:)))
        try await wait("text Redo") { text.right.text == editedText && !text.calculating }

        // Reopening a photo tab cancels/resumes only its own work. A later image
        // force-reload must clear old evidence without resetting photo preferences.
        try await select(photo)
        try await photoReady(photoModel)
        try expect(photoModel.state.previewChannel == .blue && photoModel.highlightedRange?.channel == .blue &&
                   photoModel.state.leftRegion == roi, "photo tab retains ROI and display state across folder/video/text switches")
        await image.imageComparisonModel.load(left: reference, right: reference, force: true)
        try await imageReady(image.imageComparisonModel)
        try expect(image.imageComparisonModel.matchingResult == nil && image.imageComparisonModel.similarityResult == nil &&
                   !image.imageComparisonModel.showSimilarRegions, "replacing image inputs cannot publish old region evidence")
        try expect(photoModel.state.leftRegion == roi && [photoModel.leftStatistics!, photoModel.rightStatistics!] == stableStatistics,
                   "image reload cannot invalidate the photo model's statistics")
        await image.imageComparisonModel.load(left: original, right: crop, force: true)
        try await imageReady(image.imageComparisonModel)
        try await stage("integration-photo-zh-dark-860", height: 730, dark: true, language: .simplifiedChinese,
                        identifiers: ["photo.histogram-layout", "photo.histogram-channel"])

        try await restoreSessions(store, photo: photo, video: video, expectedText: editedText)
        try expect(try hashes(inputs) == originalHashes, "all native commands, plugins, previews and restoration preserve source SHA-256 hashes")
        try expect(store.sessions.count == 5, "the final restored workspace contains every comparison kind")
        for session in store.sessions where session.pluginID == "org.crossdiff.video" { session.videoComparisonModel.cancel() }
        for session in store.sessions where session.pluginID == "org.crossdiff.photography" { session.photoComparisonModel.cancel() }
        log("Cross-module run completed without clipboard, external media, account services or source writes.")
    }

    static func restoreSessions(_ store: WorkspaceStore, photo: ComparisonSession, video: ComparisonSession, expectedText: String) async throws {
        let photoState = photo.photoComparisonModel.state
        let videoState = video.videoComparisonModel.persistedState
        try expect(store.persistNow(), "real workspace persistence writes mixed sessions")
        let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CROSSDIFF_DATA_DIR"]!).appendingPathComponent("sessions.json")
        let records = try SessionFile.load(from: file)
        try expect(records.count == 5 && records.first { $0.id == photo.id }?.photoState == photoState &&
                   records.first { $0.id == video.id }?.videoState == videoState, "on-disk mixed sessions retain current photo and video fields")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records)) as! [[String: Any]]
        for index in legacy.indices {
            legacy[index].removeValue(forKey: "videoState")
            if var state = legacy[index]["photoState"] as? [String: Any] {
                for key in ["histogramChannel", "histogramLayout", "previewChannel"] { state.removeValue(forKey: key) }
                legacy[index]["photoState"] = state
            }
        }
        let oldFile = runDirectory.appendingPathComponent("legacy-sessions.json")
        try JSONSerialization.data(withJSONObject: legacy).write(to: oldFile, options: .atomic)
        let oldRecords = try SessionFile.load(from: oldFile)
        let legacyPhoto = oldRecords.first { $0.id == photo.id }!
        try expect(legacyPhoto.photoState?.histogramLayout == .separated && legacyPhoto.photoState?.previewChannel == .original &&
                   legacyPhoto.photoState?.regions == photoState.regions && oldRecords.allSatisfy { $0.videoState == nil },
                   "legacy mixed sessions default new controls without losing saved photo regions or other kinds")
        photo.photoComparisonModel.cancel(); video.videoComparisonModel.cancel()
        // A restored session keeps its UUID, URLs and plugin execution identity.
        // Actually unmount the old view before replacing models; otherwise a
        // completed SwiftUI .task can survive an in-process "restart" and never
        // load the newly restored model. Real application launch has no old view.
        store.selectedID = nil
        try await wait("unmounted workspace before restoration") {
            !objects().contains { comparisonViewIdentifiers.contains(identifier($0)) }
        }
        store.sessions = []
        for record in records {
            guard let kind = ComparisonKind(rawValue: record.kind) else { throw Failure(description: "Unexpected saved kind") }
            store.attach(ComparisonSession(id: record.id, kind: kind, left: record.left, right: record.right,
                pluginID: record.pluginID, photoState: record.photoState, apiState: record.apiState,
                audioState: record.audioState, officeState: record.officeState, videoState: record.videoState))
        }
        let recoveredPhoto = store.sessions.first { $0.id == photo.id }!
        try await select(recoveredPhoto)
        try await photoReady(recoveredPhoto.photoComparisonModel)
        try expect(recoveredPhoto.photoComparisonModel.state == photoState && recoveredPhoto.photoComparisonModel.highlightedRange == nil,
                   "restored native photo plugin keeps preferences and excludes transient histogram highlight")
        let recoveredVideo = store.sessions.first { $0.id == video.id }!
        try await select(recoveredVideo)
        try await videoReady(recoveredVideo.videoComparisonModel)
        try expect(recoveredVideo.videoComparisonModel.leftROI == videoState.leftROI &&
                   recoveredVideo.videoComparisonModel.state.displayMode == videoState.displayMode,
                   "restored native video plugin keeps its own ROI and display mode")
        try expect(store.sessions.first { $0.kind == .text }?.right.text == expectedText, "text source survives alongside new plugin state")
        // Load an actual old photo state through the same session initializer,
        // not only through Codable, without replacing unrelated sessions.
        let oldPhoto = ComparisonSession(kind: .plugin, left: legacyPhoto.left, right: legacyPhoto.right,
                                        pluginID: legacyPhoto.pluginID, photoState: legacyPhoto.photoState)
        store.attach(oldPhoto); try await select(oldPhoto)
        try await photoReady(oldPhoto.photoComparisonModel)
        try expect(oldPhoto.photoComparisonModel.state.histogramLayout == .separated && oldPhoto.photoComparisonModel.state.previewChannel == .original,
                   "legacy photo state mounts the real native view with separate/original defaults")
        oldPhoto.photoComparisonModel.cancel()
        store.sessions.removeAll { $0.id == oldPhoto.id }
        try await select(recoveredPhoto)
        try await photoReady(recoveredPhoto.photoComparisonModel)
    }

    static let comparisonViewIdentifiers: Set<String> = ["folders.mode", "image.mode", "photo.linkRegions", "video.mode"]
    static func select(_ session: ComparisonSession) async throws {
        window.makeFirstResponder(nil)
        WorkspaceStore.shared.selectedID = session.id
        // A cached model may already be "ready" while SwiftUI still displays the
        // previous tab. Observe the shipping view before checking model results.
        try await wait("mounted selected \(session.kind.rawValue) view") {
            window.contentView?.layoutSubtreeIfNeeded()
            guard WorkspaceStore.shared.selected === session else { return false }
            if session.kind == .text {
                return session.leftEditorState?.editor.window === window && session.rightEditorState?.editor.window === window
            }
            let expected: String
            switch session.kind {
            case .folder: expected = "folders.mode"
            case .image: expected = "image.mode"
            case .plugin:
                switch session.pluginID {
                case "org.crossdiff.photography": expected = "photo.linkRegions"
                case "org.crossdiff.video": expected = "video.mode"
                default: return false
                }
            default: return false
            }
            let mounted = Set(objects().map(identifier)).intersection(comparisonViewIdentifiers)
            return mounted == [expected]
        }
    }
    static func imageReady(_ model: ImageComparisonModel) async throws {
        try await wait("image render/matching", seconds: 45) { model.error != nil || (!model.isRendering && !model.isMatching && model.preview != nil) }
        if let error = model.error { throw error }
    }
    static func photoReady(_ model: PhotoComparisonModel) async throws {
        try await wait("photo analysis/preview", seconds: 60) {
            model.error != nil || model.previewError != nil || (!model.isLoading && !model.isAnalyzing && !model.isPreviewing &&
                model.leftStatistics != nil && model.rightStatistics != nil && model.leftDisplayImage != nil && model.rightDisplayImage != nil)
        }
        if let error = model.error ?? model.previewError { throw error }
    }
    static func folderReady(_ model: FolderComparisonModel) async throws {
        try await wait("folder scan/projection", seconds: 45) { model.error != nil || (!model.scanning && !model.filtering && model.result?.isComplete == true) }
        if let error = model.error { throw error }
    }
    static func videoReady(_ model: VideoComparisonModel) async throws {
        try await wait("video frames", seconds: 45) { model.error != nil || (!model.isLoading && !model.isSeeking && model.hasSources && model.leftImage != nil && model.rightImage != nil) }
        if let error = model.error { throw error }
    }
    static func wait(_ label: String, seconds: Double = 15, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { throw Failure(description: "Timeout: \(label)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    static func expect(_ condition: Bool, _ message: String) throws {
        assertions += 1
        guard condition else { throw Failure(description: message) }
        log("PASS: " + message)
    }
    static func log(_ value: String) { report.append(value); print(value); fflush(stdout) }
    static func hashes(_ urls: [URL]) throws -> [String] { try urls.map { SHA256.hash(data: try Data(contentsOf: $0)).map { String(format: "%02x", $0) }.joined() } }
    static func pixels(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }
    static func isGrayscale(_ image: CGImage) -> Bool {
        let bytes = [UInt8](pixels(image))
        guard image.bitsPerPixel == 32 else { return false }
        for y in 0..<image.height { for x in 0..<image.width {
            let offset = y * image.bytesPerRow + x * 4
            if bytes[offset + 3] > 0 && (bytes[offset] != bytes[offset + 1] || bytes[offset + 1] != bytes[offset + 2]) { return false }
        } }
        return true
    }
    static func menuItem(_ action: Selector) -> NSMenuItem? {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items { if item.action == action { return item }; if let submenu = item.submenu, let found = find(submenu) { return found } }
            return nil
        }
        return NSApp.mainMenu.flatMap(find)
    }
    static func menuEnabled(_ action: Selector) -> Bool {
        guard let item = menuItem(action) else { return false }
        return NativeMenuController.shared.validateMenuItem(item)
    }
    static func focusComparison(_ responder: NSResponder? = nil) async throws {
        // A desktop user or another application may take focus while background
        // comparisons finish. Native commands require this window to be active;
        // disabled menus in an inactive application are correct product behavior.
        if !NSApp.isActive || NSApp.keyWindow !== window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        try await wait("active comparison window for native commands") { NSApp.isActive && NSApp.keyWindow === window }
        guard window.makeFirstResponder(responder) else { throw Failure(description: "Cannot focus the native command responder") }
        try await wait("native command responder") { window.firstResponder === (responder ?? window) }
    }
    static func dispatch(_ action: Selector) async throws {
        try await focusComparison(window.firstResponder)
        guard let item = menuItem(action), NSApp.sendAction(action, to: NativeMenuController.shared, from: item) else {
            throw Failure(description: "Missing or unrouted native menu action: \(action)")
        }
    }
    static func objects() -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), result: [NSObject] = []
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 45, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                for child in children { visit(child, depth: depth + 1) }
            }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        if let view = window.contentView { visit(view, depth: 0) }
        return result
    }
    static func identifier(_ object: NSObject) -> String {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
    static func segmentedControl(_ id: String) -> NSSegmentedControl? {
        let matches = objects().filter { identifier($0) == id }
        if let picker = matches.first(where: { $0 is NSSegmentedControl }) as? NSSegmentedControl { return picker }
        // AppKit/SwiftUI versions can expose the identifier on the cell rather
        // than the view. Follow the established photography workflow fallback.
        for case let cell as NSCell in matches {
            if let picker = cell.controlView as? NSSegmentedControl { return picker }
        }
        return nil
    }
    static func chooseSegment(_ id: String, index: Int) async throws {
        try await wait("native segmented control \(id)") { segmentedControl(id) != nil }
        guard let picker = segmentedControl(id) else { throw Failure(description: "Native control disappeared: \(id)") }
        try expect(index >= 0 && index < picker.segmentCount, "native \(id) has requested option")
        picker.selectedSegment = index
        try expect(picker.sendAction(picker.action, to: picker.target), "native \(id) dispatches selection")
    }
    static func windowGeometry() -> String {
        "frame=\(window.frame.size), min=\(window.minSize), contentMin=\(window.contentMinSize), content=\(window.contentView?.frame.size ?? .zero), fitting=\(window.contentView?.fittingSize ?? .zero)"
    }
    static func stage(_ name: String, height: Double, dark: Bool, language: AppLanguage, identifiers: [String]) async throws {
        AppSettings.shared.language = language
        AppAppearance.shared.isDark = dark
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try await wait("native \(name) controls") { identifiers.allSatisfy { id in objects().contains { identifier($0) == id } } }
        // NSHostingView updates the window minimum asynchronously after tab and
        // language changes. Previous constraints may remain for one layout cycle
        // even after the new controls are visible. Wait for stable, eligible
        // native constraints without changing them.
        let target = NSRect(x: -10000, y: -10000, width: 860, height: height)
        var previousMinimum: NSSize?
        do {
            try await wait("native \(name) layout constraints", seconds: 5) {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let minimum = window.minSize
                let stable = previousMinimum == minimum
                previousMinimum = minimum
                return stable && minimum.width <= target.width && minimum.height <= target.height
            }
        } catch {
            throw Failure(description: "Native layout cannot accept \(name) at \(target.size): \(windowGeometry())")
        }
        window.setFrame(target, display: true)
        // Let AppKit composite the resized hierarchy before inspecting it. A real
        // minimum-size regression must still fail the exact dimensions assertion.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); continuation.resume() }
        }
        guard let view = window.contentView?.superview, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(description: "Missing parent-window raster") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(description: "Cannot encode native capture") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        try expect(abs(window.frame.width - 860) < 1 && abs(window.frame.height - height) < 1 && bitmap.pixelsWide >= 860,
                   "\(name) renders actual parent window without expanding requested dimensions (requested: 860×\(height), \(windowGeometry()))")
        try expect(bitmap.pixelsHigh > 0 && png.count > 10_000, "\(name) contains rendered native content")
    }
}
