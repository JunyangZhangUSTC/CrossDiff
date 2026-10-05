import AppKit
import CrossDiffCore

@MainActor
extension ReadmeRenders {
    static var fixtures: URL { D.output.deletingLastPathComponent().appendingPathComponent("fixtures") }
    static var requestedKinds: Set<String> {
        Set((ProcessInfo.processInfo.environment["CROSSDIFF_README_KINDS"] ?? "text,deletions,new,folder,archive,image,photography,pdf,office,api,audio,video,binary").split(separator: ",").map(String.init))
    }
    static func renderFeatures() async throws {
        if !requestedKinds.isDisjoint(with: ["image", "photography", "video", "pdf"]) {
            try await ReadmeMediaFixtures.prepare(in: fixtures)
        }
        for kind in ["folder", "archive", "image", "photography", "pdf", "office", "api", "audio", "video", "binary"] where requestedKinds.contains(kind) {
            D.log("Preparing real \(kind) comparison")
            let session: ComparisonSession
            switch kind {
            case "folder":
                session = mount(.folder, "Project Original", "Project Revised")
                let model = session.folderComparisonModel
                try await wait("folder content comparison") { if let e = model.error { throw e }; return model.result != nil && !model.scanning }
                model.statusFilter = .all
                model.expandedPaths = ["Sources", "Sources/Models", "Sources/Views", "Resources", "Resources/Templates", "docs", "Tests"]
                try await wait("folder paired tree") { !model.filtering && model.browserProjection.rows.count > 10 }
            case "archive":
                session = mount(.plugin, "Collection Original.zip", "Collection Revised.zip", plugin: "org.crossdiff.archive")
                let model = session.archiveComparisonModel
                try await wait("archive content groups") { if let e = model.error { throw e }; return model.result != nil && !model.isLoading }
                guard model.groups.count >= 4 else { throw D.CheckError(description: "Archive demo must verify four cross-path content groups") }
                try await choose("archive.mode", index: 1)
                for outline in descendants(D.window.contentView!).compactMap({ $0 as? NSOutlineView }) { outline.expandItem(nil, expandChildren: true) }
            case "image":
                session = mount(.image, "Alpine Lake.png", "Detail Crop.png")
                let model = session.imageComparisonModel
                try await wait("image preview") { if let e = model.error { throw e }; return model.preview != nil && !model.isRendering }
                model.alignAutomatically()
                try await wait("verified image alignment") { !model.isMatching && !model.isRendering }
                guard model.matchingResult?.status == .accepted else { throw D.CheckError(description: "Image demo did not obtain a verified alignment") }
                model.mode = .sideBySide
                model.toggleSimilarRegions()
                try await wait("real image similarity analysis") { !model.isAnalyzingSimilarity }
                guard !model.similarityFailed, let first = model.similarityResult?.regions.first else { throw D.CheckError(description: "Image demo did not find a real similar region") }
                model.selectSimilarityRegion(first.id)
            case "photography":
                session = mount(.plugin, "Cool Study.tiff", "Warm Study.tiff", plugin: "org.crossdiff.photography")
                let model = session.photoComparisonModel
                try await wait("photo RGB/Lab statistics") { if let e = model.error { throw e }; return model.leftStatistics != nil && model.rightStatistics != nil && !model.isAnalyzing && !model.isLoading }
                model.state.histogramChannel = .rgb; model.state.histogramLayout = .overlay
            case "pdf":
                session = mount(.plugin, "Field Notes Original.pdf", "Field Notes Revised.pdf", plugin: "org.crossdiff.pdf")
                let model = session.pdfComparisonModel
                try await wait("PDF pages") { if let e = model.error { throw e }; return model.pairs.count == 3 && !model.isLoading }
                model.selectedIndex = 1
            case "office":
                session = mount(.plugin, "Milestones Original.xlsx", "Milestones Revised.xlsx", plugin: "org.crossdiff.office")
                let model = session.officeModel
                try await wait("Office import and automatic cross-row matching") { if let e = model.error { throw e }; return model.comparison != nil && !model.isLoading && !model.isComparing }
                model.state.keyColumns = [1]
                try await wait("Office ID-key matching") { if let e = model.error { throw e }; return model.comparison != nil && !model.isComparing }
            case "api":
                try apiFixtures()
                session = mount(.plugin, "Response Original.http", "Response Revised.http", plugin: "org.crossdiff.api")
                let model = session.apiComparisonModel
                try await wait("HTTP response comparison") { if let e = model.error { throw e }; return model.comparison != nil && !model.isLoading && !model.isComparing }
                model.applyRules(headers: ["X-Request-ID"], pointers: ["/generatedAt"])
                try await wait("HTTP explicit ignore rules") { !model.isComparing }
                try await press("api.differencesOnly")
            case "audio":
                session = mount(.plugin, "Studio Original.wav", "Studio Edited.wav", plugin: "org.crossdiff.audio")
                let model = session.audioComparisonModel
                try await wait("audio decode and STFT") { if let e = model.error { throw e }; return model.comparison != nil && !model.isLoading && !model.isAnalyzing }
                model.runMatching()
                try await wait("real audio fingerprint matches", timeout: 90) { if let e = model.error { throw e }; return !model.isMatching && !model.correspondences.isEmpty }
                if let match = model.correspondences.first { model.selectCorrespondence(match); model.saveRegion(name: "Opening passage") }
                try await wait("selected audio spectra") { !model.isAnalyzing }
                guard !model.playback.isPlaying else { throw D.CheckError(description: "README renderer must never play audio") }
            case "video":
                session = mount(.plugin, "Lake Original.mov", "Lake Graded.mov", plugin: "org.crossdiff.video")
                let model = session.videoComparisonModel
                try await wait("video paired source frames") { if let e = model.error { throw e }; return model.leftImage != nil && model.rightImage != nil && !model.isLoading && !model.isSeeking && !model.thumbnailsLoading }
                model.seek(side: .left, seconds: 0.75)
                try await wait("video exact paired frames") { !model.isSeeking && model.leftImage != nil && model.rightImage != nil }
            default:
                try binaryFixtures()
                session = mount(.binary, "Firmware Original.bin", "Firmware Revised.bin")
                let model = session.binaryComparisonModel
                try await wait("binary byte alignment") { if let e = model.error { throw e }; return model.result != nil && model.page != nil }
                model.jump(to: 0, side: .left)
            }
            try await D.pause()
            for language in [AppLanguage.simplifiedChinese, .english] {
                AppSettings.shared.language = language
                for dark in [false, true] {
                    AppAppearance.shared.isDark = dark
                    D.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    D.window.setFrame(NSRect(x: -10000, y: -10000, width: 1200,
                                            height: ["audio", "photography"].contains(kind) ? 900 : 790), display: true)
                    NSApp.activate(ignoringOtherApps: true); D.window.makeKeyAndOrderFront(nil)
                    D.window.makeFirstResponder(nil)
                    try await D.pause(); D.window.contentView?.layoutSubtreeIfNeeded(); D.window.displayIfNeeded(); try await D.pause()
                    let name = "\(kind)-\(language == .english ? "en" : "zh-CN")-\(dark ? "dark" : "light")"
                    try verifyPublicLabels()
                    guard let full = D.window.contentView?.superview else { throw D.CheckError(description: "Missing complete native window") }
                    _ = try D.capture(full, rect: full.bounds, name: name)
                    D.log("Captured \(name)")
                }
            }
            WorkspaceStore.shared.close(session)
        }
    }

    static func mount(_ kind: ComparisonKind, _ left: String, _ right: String, plugin: String? = nil) -> ComparisonSession {
        let session = ComparisonSession(kind: kind, left: .init(path: fixtures.appendingPathComponent(left).path),
                                        right: .init(path: fixtures.appendingPathComponent(right).path), pluginID: plugin)
        let store = WorkspaceStore.shared
        store.sessions.removeAll(); store.attach(session); store.selectedID = session.id
        D.window.setFrame(NSRect(x: -10000,y: -10000,width:1200,height:790),display:true)
        return session
    }
    static func wait(_ label: String, timeout: Double = 60, _ ready: () throws -> Bool) async throws {
        let deadline=Date().addingTimeInterval(timeout)
        while try !ready() {
            if Date()>deadline { throw D.CheckError(description:"Timeout: \(label)") }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        try await D.pause()
    }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func objects() -> [NSObject] {
        var seen=Set<ObjectIdentifier>(), result:[NSObject]=[]
        func visit(_ object:NSObject, depth:Int) {
            guard depth<45, seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let view=object as? NSView, view.isHiddenOrHasHiddenAncestor { return }
            result.append(object)
            let selector=NSSelectorFromString("accessibilityChildren")
            if object.responds(to:selector), let children=object.perform(selector)?.takeUnretainedValue() as? [NSObject] { for child in children { visit(child,depth:depth+1) } }
            if let view=object as? NSView { for child in view.subviews { visit(child,depth:depth+1) } }
        }
        if let view=D.window.contentView { visit(view,depth:0) }
        return result
    }
    static func value(_ object:NSObject,_ name:String)->String {
        let selector=NSSelectorFromString(name)
        guard object.responds(to:selector) else { return "" }
        return object.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }
    static func choose(_ identifier:String,index:Int) async throws {
        try await D.pause()
        let matches=objects().filter { value($0,"accessibilityIdentifier")==identifier }
        let picker=matches.compactMap { $0 as? NSSegmentedControl }.first
            ?? matches.compactMap { ($0 as? NSCell)?.controlView as? NSSegmentedControl }.first
        guard let picker else { throw D.CheckError(description:"Missing segmented control: \(identifier)") }
        picker.selectedSegment=index; picker.sendAction(picker.action,to:picker.target)
        try await D.pause()
    }
    static func press(_ identifier:String) async throws {
        try await D.pause()
        guard let object=objects().first(where:{ value($0,"accessibilityIdentifier")==identifier }) else { throw D.CheckError(description:"Missing native control: \(identifier)") }
        if let button=object as? NSButton { button.performClick(nil) }
        else { let selector=NSSelectorFromString("accessibilityPerformPress"); guard object.responds(to:selector) else { throw D.CheckError(description:"Control cannot press: \(identifier)") }; object.perform(selector) }
        try await D.pause()
    }
    static func verifyPublicLabels() throws {
        // Help/tooltips can retain real local URLs; inspect visible labels/values
        // only. The folder header display is anonymized in the isolated snapshot.
        let strings=objects().flatMap { [value($0,"accessibilityValue"), value($0,"accessibilityLabel")] }
        if strings.contains(where:{ $0.contains("/Users/") || $0.contains("/private/") }) {
            throw D.CheckError(description:"A machine-specific path is visible in a README frame")
        }
    }
    static func apiFixtures() throws {
        try """
        HTTP/1.1 200 OK
        Content-Type: application/json
        Cache-Control: max-age=60
        X-Request-ID: demo-original

        {"product":{"name":"Studio headphones","price":129,"stock":12,"available":true},"shipping":{"days":3,"tracking":null},"generatedAt":"2026-10-02T09:00:00Z"}
        """.write(to:fixtures.appendingPathComponent("Response Original.http"),atomically:true,encoding:.utf8)
        try """
        HTTP/1.1 200 OK
        Content-Type: application/json
        Cache-Control: no-cache
        X-Request-ID: demo-revised

        {"product":{"name":"Studio headphones","price":"119.00","stock":0,"available":false},"shipping":{"days":1,"express":true},"generatedAt":"2026-10-02T10:00:00Z"}
        """.write(to:fixtures.appendingPathComponent("Response Revised.http"),atomically:true,encoding:.utf8)
    }
    static func binaryFixtures() throws {
        var left=Data((0..<1024).map { UInt8(($0*37+11)%256) })
        left.replaceSubrange(0..<16,with:Array("CrossDiff BIN 1.0".utf8))
        var right=left; right.replaceSubrange(12..<16,with:Array(" 2.0".utf8)); right.removeSubrange(48..<56)
        right.insert(contentsOf:Array("CrossDiff".utf8),at:112)
        try left.write(to:fixtures.appendingPathComponent("Firmware Original.bin")); try right.write(to:fixtures.appendingPathComponent("Firmware Revised.bin"))
    }
}
